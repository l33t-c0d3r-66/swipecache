import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../stream/stream_loader.dart';
import '../stream/stream_manifest.dart';
import '../util/http_range.dart';
import '../util/logger.dart';
import 'cache_config.dart';
import 'cache_entry.dart';
import 'cache_store.dart';
import 'origin_client.dart';

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
  ProxyServer(this.store, this.config, this.client, this.streams);

  final CacheStore store;
  final SwipeCacheConfig config;
  final OriginClient client;
  final StreamLoader streams;
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
      (request) => unawaited(_logged(request).catchError((Object error,
          StackTrace stack) {
        counters.errors++;
        SwipeLog.e('Proxy request failed: ${request.uri}', '$error\n$stack');
        return _reject(request.response, HttpStatus.internalServerError);
      })),
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

  static const _modeLetters = {
    ProxyMode.cache: 'c',
    ProxyMode.passthrough: 'n',
    ProxyMode.manifest: 'm',
  };

  static final _absoluteUrl =
      RegExp(r'^(https?)://([^/?#]+)([^#]*)', caseSensitive: false);

  /// Proxy URL for a resource of the stream [group].
  ///
  /// The origin scheme, host and path are mirrored into the proxy path
  /// (`/s/<group>/<mode>/<scheme>/<host>/<path>`), so URLs a player resolves
  /// relative to a manifest still point at the proxy.
  String streamUrl(String group, ProxyMode mode, String absolute) {
    final m = _absoluteUrl.firstMatch(absolute);
    if (m == null) return absolute;
    var rest = m.group(3)!;
    if (!rest.startsWith('/')) rest = '/$rest';
    return 'http://${InternetAddress.loopbackIPv4.address}:$port/s/$group/'
        '${_modeLetters[mode]}/${m.group(1)!.toLowerCase()}/${m.group(2)}$rest';
  }

  /// [_handle] with a verbose log line per request (path, range, time,
  /// bytes from disk / network).
  Future<void> _logged(HttpRequest request) async {
    if (SwipeLog.level != SwipeLogLevel.verbose) return _handle(request);
    final stopwatch = Stopwatch()..start();
    final disk = counters.bytesFromCache;
    final net = counters.bytesFromNetwork;
    try {
      await _handle(request);
    } finally {
      final name = request.uri.pathSegments.isEmpty
          ? '/'
          : request.uri.pathSegments.last;
      SwipeLog.v('${request.method} $name '
          '${request.headers.value(HttpHeaders.rangeHeader) ?? ''} -> '
          '${request.response.statusCode} in ${stopwatch.elapsedMilliseconds}ms '
          '(disk ${counters.bytesFromCache - disk}, '
          'net ${counters.bytesFromNetwork - net})');
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    counters.requests++;
    if (request.method != 'GET' && request.method != 'HEAD') {
      return _reject(response, HttpStatus.methodNotAllowed);
    }
    final segments = request.uri.pathSegments;
    if (segments.length >= 5 && segments.first == 's') {
      return _handleStream(request);
    }
    if (segments.length != 2 || segments.first != 'v') {
      return _reject(response, HttpStatus.notFound);
    }
    final name = segments[1];
    final dot = name.indexOf('.');
    final key = dot < 0 ? name : name.substring(0, dot);
    final entry = store.byKey(key);
    if (entry == null) return _reject(response, HttpStatus.notFound);
    return _serveEntry(request, entry);
  }

  Future<void> _handleStream(HttpRequest request) async {
    final response = request.response;
    // Work on the raw (still percent-encoded) path so it is mirrored exactly.
    final parts = request.uri.path.split('/');
    if (parts.length < 6) return _reject(response, HttpStatus.notFound);
    final group = parts[2];
    final mode = parts[3];
    final rest = '/${parts.sublist(6).join('/')}';
    final query = request.uri.hasQuery ? '?${request.uri.query}' : '';
    final Uri origin;
    try {
      origin = Uri.parse('${parts[4]}://${parts[5]}$rest$query');
    } on FormatException {
      return _reject(response, HttpStatus.badRequest);
    }
    switch (mode) {
      case 'm':
        return _serveManifest(request, origin, group);
      case 'n':
        return _passthrough(request, origin, group);
      case 'c':
        if (streamKindFor(origin) != null) {
          return _serveManifest(request, origin, group);
        }
        final entry = store.obtain(origin,
            headers: streams.headersFor(group), group: group);
        return _serveEntry(request, entry);
      default:
        return _reject(response, HttpStatus.notFound);
    }
  }

  /// Serves an HLS playlist / DASH manifest rewritten to point at the proxy.
  Future<void> _serveManifest(
      HttpRequest request, Uri origin, String group) async {
    final response = request.response;
    final LoadedManifest manifest;
    try {
      manifest = await streams.load(origin, group);
    } catch (error) {
      counters.errors++;
      SwipeLog.e('Manifest failed for $origin', error);
      final status = error is HttpException &&
              error.message.startsWith('Status ')
          ? int.tryParse(error.message.substring(7)) ?? HttpStatus.badGateway
          : HttpStatus.badGateway;
      return _reject(response, status);
    }
    String proxy(String url, ProxyMode mode) => streamUrl(group, mode, url);
    final body = switch (manifest.kind) {
      StreamKind.hls => rewriteHls(manifest.body, manifest.base, proxy),
      StreamKind.dash => rewriteDash(manifest.body, manifest.base, proxy),
    };
    final bytes = utf8.encode(body);
    if (manifest.fromCache) {
      counters.bytesFromCache += bytes.length;
    } else {
      counters.bytesFromNetwork += bytes.length;
    }
    try {
      response.statusCode = HttpStatus.ok;
      response.headers
        ..set(HttpHeaders.contentTypeHeader, manifestContentType(manifest.kind))
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      response.contentLength = bytes.length;
      if (request.method != 'HEAD') response.add(bytes);
      await response.close();
    } catch (_) {
      // Player went away.
    }
  }

  /// Streams a resource from the origin without storing it (live segments,
  /// encryption keys).
  Future<void> _passthrough(
      HttpRequest request, Uri origin, String group) async {
    final response = request.response;
    OriginResponse upstream;
    try {
      upstream = await client.send(origin, streams.headersFor(group),
          range: request.headers.value(HttpHeaders.rangeHeader));
    } catch (error) {
      counters.errors++;
      SwipeLog.e('Pass-through failed for $origin', error);
      return _reject(response, HttpStatus.badGateway);
    }
    try {
      response.statusCode = upstream.statusCode;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
      ]) {
        final value = upstream.header(name);
        if (value != null) response.headers.set(name, value);
      }
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (upstream.contentLength >= 0) {
        response.contentLength = upstream.contentLength;
      }
      if (request.method == 'HEAD') {
        upstream.detach();
      } else {
        await response.addStream(upstream.stream.map((data) {
          counters.bytesFromNetwork += data.length;
          client.networkBytes += data.length;
          return data;
        }));
      }
      await response.close();
    } catch (error) {
      upstream.detach();
      // Player went away or origin failed mid-stream: never leave the
      // response open (the player would wait for it forever).
      SwipeLog.v('Pass-through ended early for $origin: $error');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveEntry(HttpRequest request, CacheEntry entry) async {
    final response = request.response;
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
      if (streamKindFor(entry.url, contentType: entry.contentType) != null) {
        // A playlist behind a URL without .m3u8/.mpd: rewrite it.
        await _serveManifest(
            request, entry.url, entry.group ?? entry.key);
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
      // Stream segments are read once in a row: release the file handle now
      // instead of at the next sweep (iOS allows 256 open files).
      if (entry.group != null && entry.pins == 0) {
        unawaited(entry.closeIdleFile());
      }
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
      if (entry.rangesUnsupported) {
        // Every request restarts at byte 0 on such servers: read through to
        // the end of the request in one go instead of in short runs.
        runEnd = lastChunk;
      } else {
        while (runEnd < lastChunk &&
            runEnd - chunk + 1 < config.maxRunChunks &&
            !entry.hasChunk(runEnd + 1) &&
            !entry.isInflight(runEnd + 1)) {
          runEnd++;
        }
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
