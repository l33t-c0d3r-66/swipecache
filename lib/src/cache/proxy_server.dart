import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../util/http_range.dart';
import '../util/logger.dart';
import 'cache_config.dart';
import 'cache_entry.dart';
import 'cache_store.dart';

/// Counters describing what the proxy served to players.
class ProxyCounters {
  int requests = 0;
  int bytesFromCache = 0;
  int bytesFromNetwork = 0;
  int errors = 0;
}

/// Loopback HTTP server the native player talks to.
///
/// Every request is answered from the sparse cache where possible; missing
/// ranges are downloaded from the origin, streamed to the player immediately
/// and stored at the same time. This gives instant start on a cache miss
/// (unlike "download then play" caches) and free replays/seek-backs.
class ProxyServer {
  ProxyServer(this.store, this.config);

  final CacheStore store;
  final SwipeCacheConfig config;
  final ProxyCounters counters = ProxyCounters();

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  bool get isRunning => _server != null;
  int _port = 0;

  /// Bound port, remembered so a reclaimed socket can be rebound to it.
  int get port => _port;

  Future<void> start({int port = 0}) async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30)
      ..defaultResponseHeaders.clear();
    _server = server;
    _port = server.port;
    _subscription = server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error) => SwipeLog.e('Proxy server error', error),
    );
    SwipeLog.i('Proxy listening on 127.0.0.1:$_port');
  }

  /// URL the player should open for [entry].
  Uri uriFor(CacheEntry entry) {
    final segments = entry.url.pathSegments;
    final last = segments.isEmpty ? '' : segments.last;
    final dot = last.lastIndexOf('.');
    final ext = dot > 0 && last.length - dot <= 5 ? last.substring(dot) : '.mp4';
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      path: '/v/${entry.key}$ext',
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    counters.requests++;
    final segments = request.uri.pathSegments;
    if (segments.length != 2 || segments.first != 'v') {
      return _reject(response, HttpStatus.notFound);
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      return _reject(response, HttpStatus.methodNotAllowed);
    }
    final name = segments[1];
    final dot = name.indexOf('.');
    final key = dot < 0 ? name : name.substring(0, dot);
    final entry = store.byKey(key);
    if (entry == null) return _reject(response, HttpStatus.notFound);

    entry.pins++;
    entry.touch();
    Socket? socket;
    StreamSubscription<Uint8List>? socketSub;
    var clientGone = false;

    try {
      try {
        await entry.ensureProbed();
      } on OriginException catch (error) {
        SwipeLog.e('Probe failed for ${entry.url}', error);
        await _reject(response, error.statusCode ?? HttpStatus.badGateway);
        return;
      }
      final total = entry.totalLength!;
      final parsed = parseRangeHeader(
        request.headers.value(HttpHeaders.rangeHeader),
        total,
      );
      ByteRange range;
      switch (parsed) {
        case UnsatisfiableRange():
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await _reject(response, HttpStatus.requestedRangeNotSatisfiable);
          return;
        case PartialContent(range: final r):
          range = r;
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes ${r.start}-${r.end}/$total',
          );
        case FullContent():
          if (total == 0) {
            response.statusCode = HttpStatus.ok;
            response.contentLength = 0;
            await response.close();
            return;
          }
          range = ByteRange(0, total - 1);
          response.statusCode = HttpStatus.ok;
      }
      response.headers
        ..set(HttpHeaders.contentTypeHeader, entry.contentType)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = range.length;

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      // HttpResponse silently swallows writes after the client disconnects,
      // so we would keep downloading for a player that is gone. A detached
      // socket reports the disconnect (read side closes / flush throws).
      response.persistentConnection = false;
      final raw = await response.detachSocket();
      socket = raw;
      // Players hang up mid-stream all the time (every swipe). Depending on
      // timing a write can hit the reset connection before the read side
      // reports it; that error lands on `done`, which must always be handled
      // or it surfaces as an unhandled SocketException (seen on Android).
      unawaited(raw.done.then<void>((_) {}, onError: (Object _) {
        clientGone = true;
      }));
      socketSub = raw.listen(
        (_) {},
        onError: (Object _) => clientGone = true,
        onDone: () => clientGone = true,
        cancelOnError: true,
      );

      await _stream(entry, range, raw, () => clientGone);
      if (!clientGone) {
        await raw.flush();
        await raw.close();
      }
    } catch (error) {
      if (!clientGone) {
        counters.errors++;
        SwipeLog.e('Proxy stream failed for ${entry.url}', error);
      }
      if (socket == null) {
        await _reject(response, HttpStatus.badGateway);
      }
    } finally {
      await socketSub?.cancel();
      socket?.destroy();
      entry.pins--;
      entry.touch();
    }
  }

  Future<void> _stream(
    CacheEntry entry,
    ByteRange range,
    Socket socket,
    bool Function() clientGone,
  ) async {
    var pos = range.start;
    final end = range.end;
    final lastChunk = end ~/ entry.chunkSize;
    var unflushed = 0;
    var stalls = 0;

    Future<void> send(Uint8List data, {required bool fromCache}) async {
      if (clientGone()) throw const SocketException('Client disconnected');
      socket.add(data);
      if (fromCache) {
        counters.bytesFromCache += data.length;
      } else {
        counters.bytesFromNetwork += data.length;
      }
      unflushed += data.length;
      // Periodic flush gives back-pressure: we never buffer more than ~256KB
      // ahead of what the player actually consumes.
      if (unflushed >= 256 * 1024) {
        unflushed = 0;
        await socket.flush();
      }
    }

    // Forwards the part of an origin packet that falls inside the request.
    Future<void> forward(Uint8List data, int offset) async {
      final dataEnd = offset + data.length - 1;
      if (dataEnd < pos || offset > end) return;
      final from = pos - offset;
      final to = (dataEnd > end ? end : dataEnd) - offset + 1;
      await send(
        from == 0 && to == data.length
            ? data
            : Uint8List.sublistView(data, from, to),
        fromCache: false,
      );
      pos = offset + to;
    }

    while (pos <= end) {
      if (clientGone() || entry.isRemoved) return;
      final chunk = pos ~/ entry.chunkSize;

      if (entry.hasChunk(chunk)) {
        // Coalesce consecutive cached chunks into reads of up to 1MB.
        var lastCached = chunk;
        while (lastCached < lastChunk &&
            entry.hasChunk(lastCached + 1) &&
            (lastCached + 1 - chunk) * entry.chunkSize < 1024 * 1024) {
          lastCached++;
        }
        final readEnd = entry.chunkEnd(lastCached) < end
            ? entry.chunkEnd(lastCached)
            : end;
        final data = await entry.read(pos, readEnd);
        if (data.length != readEnd - pos + 1) {
          throw StateError('Short read from cache file');
        }
        await send(data, fromCache: true);
        pos = readEnd + 1;
        continue;
      }

      final pending = entry.inflightFuture(chunk);
      if (pending != null) {
        // Someone else (prefetcher or another request) is downloading it.
        // If that download stalls - typically a paused player holding its
        // connection open - take over instead of waiting forever.
        var stalled = false;
        await pending.timeout(const Duration(milliseconds: 400), onTimeout: () {
          stalled = entry.msSinceProgress(chunk) > 1200;
        });
        if (clientGone()) return;
        if (stalled && !entry.hasChunk(chunk)) {
          final before = pos;
          await entry.stealRun(
            chunk,
            chunk,
            isCancelled: clientGone,
            sink: forward,
          );
          if (pos == before && ++stalls > 3) {
            throw StateError('Chunk $chunk could not be fetched');
          }
        }
        continue;
      }

      // Claim a run of missing chunks and fetch them in one origin request.
      var runEnd = chunk;
      while (runEnd < lastChunk &&
          runEnd - chunk + 1 < config.maxRunChunks &&
          !entry.hasChunk(runEnd + 1) &&
          !entry.isInflight(runEnd + 1)) {
        runEnd++;
      }
      final before = pos;
      await entry.fetchRun(
        chunk,
        runEnd,
        isCancelled: clientGone,
        sink: forward,
      );
      if (pos == before && !entry.hasChunk(chunk) && ++stalls > 3) {
        throw StateError('Origin made no progress for chunk $chunk');
      }
    }
  }

  /// Closes the listening socket without updating state, simulating the OS
  /// reclaiming it. Test-only.
  Future<void> debugCloseListener() async => _server?.close(force: true);

  /// iOS may reclaim the listening socket of a suspended app. Verifies the
  /// server still accepts connections and rebinds it (on the same port when
  /// possible, so URLs held by players stay valid) if not.
  Future<bool> ensureAlive() async {
    final port = this.port;
    if (_server == null) return false;
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 500));
      socket.destroy();
      return true;
    } catch (_) {
      SwipeLog.i('Proxy listener lost, restarting');
      await stop();
      try {
        await start(port: port);
      } catch (_) {
        await start();
      }
      return isRunning;
    }
  }

  Future<void> _reject(HttpResponse response, int status) async {
    try {
      response.statusCode = status;
      response.contentLength = 0;
      await response.close();
    } catch (_) {}
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
  }
}
