import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../util/async_lock.dart';
import '../util/http_range.dart';
import '../util/logger.dart';
import 'chunk_bitmap.dart';
import 'origin_client.dart';

/// Thrown when an origin response can not be used for caching.
class OriginException implements Exception {
  OriginException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'OriginException($statusCode): $message';
}

/// Callback receiving bytes as they stream in from the origin.
/// [offset] is the absolute file offset of `data[0]`.
typedef ChunkDataSink = FutureOr<void> Function(Uint8List data, int offset);

/// One cached remote resource, stored as a sparse file plus a chunk bitmap.
///
/// Bytes downloaded for playback and bytes downloaded by the prefetcher land
/// in the same file, and each chunk is fetched from the origin at most once
/// even when several readers ask for it concurrently.
class CacheEntry {
  CacheEntry({
    required this.key,
    required this.url,
    required this.directory,
    required this.chunkSize,
    required OriginClient client,
    Map<String, String>? headers,
    this.group,
    int? lastAccessMs,
    int? createdMs,
  })  : _client = client,
        headers = headers ?? const {},
        lastAccessMs = lastAccessMs ?? DateTime.now().millisecondsSinceEpoch,
        createdMs = createdMs ?? DateTime.now().millisecondsSinceEpoch;

  final String key;
  final Uri url;

  /// Key of the video this resource belongs to (the HLS/DASH manifest of a
  /// segment). `null` for standalone files. Limits and eviction treat a
  /// group as one video.
  final String? group;
  Map<String, String> headers;
  final Directory directory;
  final int chunkSize;
  final OriginClient _client;

  int? _totalLength;
  String _contentType = 'video/mp4';
  ChunkBitmap? _bitmap;
  bool _rangesUnsupported = false;

  /// Where the origin redirected this URL to (manifests resolve relative
  /// references against it).
  Uri? resolvedUrl;

  int lastAccessMs;
  int _generation = 0;
  final int createdMs;

  /// Active users (proxy requests, protected feed items). Pinned entries are
  /// never evicted.
  int pins = 0;
  bool _removed = false;

  RandomAccessFile? _raf;
  final AsyncLock _ioLock = AsyncLock();
  final AsyncLock _metaLock = AsyncLock();
  final Map<int, Completer<void>> _inflight = {};
  final Map<int, _FetchProgress> _inflightProgress = {};
  Future<void>? _probe;
  Timer? _metaTimer;

  /// Hook used by the store to account bytes (negative when dropped) and
  /// schedule eviction.
  void Function(CacheEntry entry, int deltaBytes)? onChunkStored;

  /// Hook called when a write failed because the disk is full.
  void Function(CacheEntry entry)? onDiskFull;

  File get dataFile => File('${directory.path}/$key.data');
  File get metaFile => File('${directory.path}/$key.meta');

  int? get totalLength => _totalLength;
  String get contentType => _contentType;
  bool get isProbed => _totalLength != null;
  bool get isRemoved => _removed;
  bool get isComplete => _bitmap?.isComplete ?? false;

  /// The origin ignores `Range` requests and always sends the whole file.
  bool get rangesUnsupported => _rangesUnsupported;
  int get chunkCount => _bitmap?.chunkCount ?? 0;

  /// Bytes currently stored on disk.
  int get cachedBytes {
    final bitmap = _bitmap;
    final total = _totalLength;
    if (bitmap == null || total == null) return 0;
    var bytes = bitmap.completedCount * chunkSize;
    if (bitmap.has(bitmap.chunkCount - 1)) {
      bytes -= bitmap.chunkCount * chunkSize - total;
    }
    return bytes;
  }

  bool hasChunk(int index) => _bitmap?.has(index) ?? false;
  bool isInflight(int index) => _inflight.containsKey(index);
  Future<void>? inflightFuture(int index) => _inflight[index]?.future;

  int chunkStart(int index) => index * chunkSize;
  int chunkEnd(int index) {
    final end = (index + 1) * chunkSize - 1;
    final total = _totalLength!;
    return end < total ? end : total - 1;
  }

  /// `true` when every byte in `[start, end]` is on disk.
  bool hasRange(int start, int end) {
    final bitmap = _bitmap;
    if (bitmap == null) return false;
    return bitmap.hasAll(start ~/ chunkSize, end ~/ chunkSize);
  }

  void touch() => lastAccessMs = DateTime.now().millisecondsSinceEpoch;

  // ---------------------------------------------------------------------------
  // Probing
  // ---------------------------------------------------------------------------

  /// Makes sure total length and content type are known. The probe downloads
  /// (and caches) the first chunk, which every player needs anyway, so it
  /// costs no extra bandwidth.
  Future<void> ensureProbed() {
    if (_totalLength != null) return Future<void>.value();
    return _probe ??= _runProbe().whenComplete(() => _probe = null);
  }

  Future<void> _runProbe() async {
    await _fetch(0, null, firstChunk: 0, lastChunk: 0);
    if (_totalLength == null) {
      throw OriginException('Origin did not report a content length');
    }
  }

  void _applyLength(int total, String? contentType) {
    final known = _totalLength;
    if (known == total) return;
    if (known != null) {
      // Same URL, different file: drop everything cached so far instead of
      // mixing bytes of two versions.
      SwipeLog.i('Origin content changed for $url ($known -> $total bytes)');
      _resetFor(total, contentType);
      return;
    }
    _totalLength = total;
    _contentType = _resolveContentType(contentType);
    _bitmap = ChunkBitmap(_chunksFor(total));
    _scheduleMetaWrite();
  }

  int _chunksFor(int total) =>
      total == 0 ? 0 : (total + chunkSize - 1) ~/ chunkSize;

  void _resetFor(int total, String? contentType) {
    final dropped = cachedBytes;
    _generation++;
    _totalLength = total;
    _contentType = _resolveContentType(contentType);
    _bitmap = ChunkBitmap(_chunksFor(total));
    unawaited(_ioLock.run(() async {
      try {
        final raf = await _openFile();
        await raf.truncate(0);
      } catch (_) {}
    }));
    if (dropped > 0) onChunkStored?.call(this, -dropped);
    _scheduleMetaWrite();
  }

  /// AVPlayer refuses streams whose Content-Type is not a media type, and
  /// many CDNs/buckets serve `application/octet-stream`. Fall back to the
  /// file extension in that case.
  String _resolveContentType(String? header) {
    final type = header?.split(';').first.trim().toLowerCase() ?? '';
    if (type.startsWith('video/') ||
        type.startsWith('audio/') ||
        type.startsWith('text/') ||
        _keptTypes.contains(type)) {
      return type;
    }
    final path = url.path.toLowerCase();
    for (final MapEntry(key: ext, value: mime) in _typesByExtension.entries) {
      if (path.endsWith(ext)) return mime;
    }
    return 'video/mp4';
  }

  static const _keptTypes = {
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'application/dash+xml',
    'application/mp4',
  };

  static const _typesByExtension = {
    '.mov': 'video/quicktime',
    '.m4v': 'video/x-m4v',
    '.webm': 'video/webm',
    '.mkv': 'video/x-matroska',
    '.3gp': 'video/3gpp',
    '.ts': 'video/mp2t',
    '.m4s': 'video/iso.segment',
    '.cmfv': 'video/mp4',
    '.cmfa': 'audio/mp4',
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.aac': 'audio/aac',
    '.vtt': 'text/vtt',
    '.webvtt': 'text/vtt',
    '.m3u8': 'application/vnd.apple.mpegurl',
    '.mpd': 'application/dash+xml',
  };

  /// Stores a resource that was downloaded in one piece (a manifest).
  Future<void> storeWhole(Uint8List bytes, String? contentType) async {
    if (_removed) return;
    _applyLength(bytes.length, contentType);
    final generation = _generation;
    for (var i = 0; i < chunkCount; i++) {
      if (hasChunk(i)) continue;
      final start = chunkStart(i);
      await _writeChunk(
          i, Uint8List.sublistView(bytes, start, chunkEnd(i) + 1), generation);
    }
  }

  /// Reads the whole resource. Only valid when [isComplete].
  Future<Uint8List> readAll() async {
    final total = _totalLength ?? 0;
    if (total == 0) return Uint8List(0);
    return read(0, total - 1);
  }

  // ---------------------------------------------------------------------------
  // Reading
  // ---------------------------------------------------------------------------

  /// Reads `[start, end]` (inclusive) from disk. The caller must have checked
  /// [hasRange].
  Future<Uint8List> read(int start, int end) {
    return _ioLock.run(() async {
      final raf = await _openFile();
      await raf.setPosition(start);
      return raf.read(end - start + 1);
    });
  }

  // ---------------------------------------------------------------------------
  // Fetching
  // ---------------------------------------------------------------------------

  /// Downloads chunks `[firstChunk, lastChunk]` from the origin, storing every
  /// complete chunk and streaming all bytes to [sink] as they arrive.
  ///
  /// Chunks already on disk or being downloaded by someone else are skipped
  /// at the edges of the run; callers normally pass a run of missing chunks.
  /// Returns the number of bytes received.
  Future<int> fetchRun(
    int firstChunk,
    int lastChunk, {
    ChunkDataSink? sink,
    bool Function()? isCancelled,
  }) async {
    await ensureProbed();
    if (_removed) return 0;
    var first = firstChunk;
    var last = lastChunk;
    while (first <= last && (hasChunk(first) || isInflight(first))) {
      first++;
    }
    while (last >= first && (hasChunk(last) || isInflight(last))) {
      last--;
    }
    if (first > last) return 0;
    return _fetch(
      chunkStart(first),
      chunkEnd(last),
      firstChunk: first,
      lastChunk: last,
      sink: sink,
      isCancelled: isCancelled,
    );
  }

  /// Downloads chunks `[firstChunk, lastChunk]` even if another reader has
  /// claimed them. Used when that reader stopped making progress (e.g. a
  /// paused player holding its connection) so nobody waits forever.
  Future<int> stealRun(
    int firstChunk,
    int lastChunk, {
    required ChunkDataSink sink,
    bool Function()? isCancelled,
  }) async {
    await ensureProbed();
    if (_removed) return 0;
    return _fetch(
      chunkStart(firstChunk),
      chunkEnd(lastChunk),
      firstChunk: firstChunk,
      lastChunk: lastChunk,
      sink: sink,
      isCancelled: isCancelled,
      steal: true,
    );
  }

  /// Milliseconds since the download that claimed [chunk] last received
  /// data (0 when the chunk is not claimed).
  int msSinceProgress(int chunk) {
    final progress = _inflightProgress[chunk];
    if (progress == null) return 0;
    return DateTime.now().millisecondsSinceEpoch - progress.lastDataMs;
  }

  Future<int> _fetch(
    int start,
    int? end, {
    required int firstChunk,
    required int lastChunk,
    ChunkDataSink? sink,
    bool Function()? isCancelled,
    bool steal = false,
  }) async {
    // Claim the chunks so concurrent readers wait instead of re-downloading.
    final claimed = <int, Completer<void>>{};
    final progress = _FetchProgress();
    if (!steal) {
      for (var i = firstChunk; i <= lastChunk; i++) {
        if (hasChunk(i) || _inflight.containsKey(i)) continue;
        final completer = Completer<void>();
        _inflight[i] = completer;
        _inflightProgress[i] = progress;
        claimed[i] = completer;
      }
    }

    void release(int index) {
      final completer = claimed.remove(index);
      if (completer != null) {
        if (identical(_inflight[index], completer)) {
          _inflight.remove(index);
          _inflightProgress.remove(index);
        }
        completer.complete();
      }
    }

    final generation = _generation;
    final foreground = sink != null;
    final requestEnd = end ?? (start + chunkSize - 1);
    final stopwatch = Stopwatch()..start();
    var received = 0;
    var preStart = 0;
    OriginResponse? response;
    try {
      response = await _client.get(url, headers, start, requestEnd,
          foreground: foreground);
      final status = response.statusCode;
      var position = start;

      if (status == HttpStatus.partialContent) {
        final range = parseContentRange(response.header('content-range'));
        if (range == null || range.start != start) {
          throw OriginException('Bad Content-Range', statusCode: status);
        }
        if (range.total != null) {
          _applyLength(range.total!, response.header('content-type'));
        }
      } else if (status == HttpStatus.ok) {
        // Server ignores ranges: the body starts at offset 0.
        position = 0;
        final length = response.contentLength;
        if (length >= 0) _applyLength(length, response.header('content-type'));
        final total = _totalLength;
        if (total != null &&
            (start > 0 || requestEnd < total - 1) &&
            !_rangesUnsupported) {
          SwipeLog.i('Origin ignores Range requests: $url');
          _rangesUnsupported = true;
          _scheduleMetaWrite();
        }
      } else if (status == HttpStatus.requestedRangeNotSatisfiable) {
        final range = parseContentRange(response.header('content-range'));
        if (range?.total == 0) _applyLength(0, response.header('content-type'));
        throw OriginException('Range not satisfiable', statusCode: status);
      } else {
        throw OriginException('Unexpected status', statusCode: status);
      }
      if (generation != _generation) {
        throw OriginException('Origin content changed');
      }

      final total = _totalLength;
      if (total == null) {
        throw OriginException('Unknown content length', statusCode: status);
      }
      if (total == 0) return 0;

      // Make sure chunks claimed before the length was known are valid.
      final realLast = lastChunk.clamp(0, _bitmap!.chunkCount - 1);
      for (final index in claimed.keys.toList()) {
        if (index > realLast) release(index);
      }
      final stopAt = (end ?? chunkEnd(realLast)).clamp(0, total - 1);

      // A 200 answer starts at byte 0. Those bytes are valid too: store the
      // missing chunks before the requested start instead of discarding
      // them, so a server without Range support is downloaded once.
      if (position < start) {
        for (var i = 0; i < start ~/ chunkSize; i++) {
          if (hasChunk(i) || _inflight.containsKey(i)) continue;
          final completer = Completer<void>();
          _inflight[i] = completer;
          _inflightProgress[i] = progress;
          claimed[i] = completer;
        }
      }

      final builder = BytesBuilder(copy: false);
      var chunkIndex = position ~/ chunkSize;
      var bufferStart = chunkStart(chunkIndex);

      // Assembles complete chunks and persists them.
      Future<void> assemble(Uint8List data) async {
        var cursor = 0;
        while (cursor < data.length) {
          final chunkEndOffset = chunkEnd(chunkIndex);
          final need = chunkEndOffset - (bufferStart + builder.length) + 1;
          final take =
              need < data.length - cursor ? need : data.length - cursor;
          builder.add(Uint8List.sublistView(data, cursor, cursor + take));
          cursor += take;
          if (bufferStart + builder.length - 1 == chunkEndOffset) {
            final bytes = builder.takeBytes();
            if (claimed.containsKey(chunkIndex) ||
                (steal && !hasChunk(chunkIndex))) {
              await _writeChunk(chunkIndex, bytes, generation);
              release(chunkIndex);
            }
            chunkIndex++;
            bufferStart = chunkStart(chunkIndex);
          }
        }
      }

      await for (final piece in response.stream) {
        if (_removed || generation != _generation) break;
        if (isCancelled?.call() ?? false) break;
        progress.lastDataMs = DateTime.now().millisecondsSinceEpoch;
        var data = piece is Uint8List ? piece : Uint8List.fromList(piece);

        // Bytes before the requested start (200 responses): store only.
        if (position < start) {
          final take = start - position < data.length
              ? start - position
              : data.length;
          await assemble(Uint8List.sublistView(data, 0, take));
          position += take;
          preStart += take;
          if (take == data.length) continue;
          data = Uint8List.sublistView(data, take);
        }
        // Trim anything past the end we care about.
        final remaining = stopAt - position + 1;
        if (remaining <= 0) break;
        if (data.length > remaining) {
          data = Uint8List.sublistView(data, 0, remaining);
        }

        received += data.length;
        if (sink != null) await sink(data, position);
        position += data.length;
        await assemble(data);
        if (position > stopAt) break;
      }
      return received;
    } finally {
      stopwatch.stop();
      response?.detach();
      _client.networkBytes += received + preStart;
      for (final index in claimed.keys.toList()) {
        release(index);
      }
      // Player-driven downloads are throttled by playback (back-pressure), so
      // only unthrottled downloads are representative of network speed.
      if (received + preStart > 0 && !foreground) {
        _client.reportThroughput(received + preStart, stopwatch.elapsed);
      }
    }
  }

  Future<void> _writeChunk(int index, Uint8List bytes, int generation) async {
    if (_removed || generation != _generation || hasChunk(index)) return;
    try {
      await _ioLock.run(() async {
        if (generation != _generation || _removed) return;
        final raf = await _openFile();
        await raf.setPosition(chunkStart(index));
        await raf.writeFrom(bytes);
      });
      if (generation != _generation || _removed) return;
      // Only count bytes the first time a chunk lands (two writers may race).
      if (_bitmap!.set(index)) {
        _scheduleMetaWrite();
        onChunkStored?.call(this, bytes.length);
      }
    } on FileSystemException catch (error) {
      // ENOSPC is 28 on Linux/Android and Darwin alike.
      if (error.osError?.errorCode == 28) {
        SwipeLog.e('Disk full while caching $key');
        onDiskFull?.call(this);
      } else {
        SwipeLog.e('Failed to write chunk $index of $key', error);
      }
    } catch (error) {
      SwipeLog.e('Failed to write chunk $index of $key', error);
    }
  }

  bool get hasOpenFile => _raf != null;

  /// Closes the file handle if nobody is using the entry. Handles are
  /// reopened on demand; keeping one per video would exhaust the per-process
  /// file descriptor limit (256 on iOS) after a long session.
  Future<void> closeIdleFile() async {
    if (_raf == null || pins > 0 || _inflight.isNotEmpty) return;
    await _ioLock.run(() async {
      if (pins > 0 || _inflight.isNotEmpty) return;
      await _raf?.close();
      _raf = null;
    });
  }

  Future<RandomAccessFile> _openFile() async {
    final existing = _raf;
    if (existing != null) return existing;
    // A deleted/closed entry must never recreate its file (it would leak on
    // disk until the next start).
    if (_removed) throw StateError('Cache entry $key was removed');
    final raf = await dataFile.open(mode: FileMode.append);
    _raf = raf;
    return raf;
  }

  // ---------------------------------------------------------------------------
  // Metadata persistence
  // ---------------------------------------------------------------------------

  Map<String, Object?> toJson() => {
        'v': 1,
        'url': url.toString(),
        if (group != null) 'group': group,
        if (_rangesUnsupported) 'nr': true,
        if (resolvedUrl != null) 'base': resolvedUrl.toString(),
        'total': _totalLength,
        'type': _contentType,
        'chunk': chunkSize,
        'bits': _bitmap?.encode(),
        'access': lastAccessMs,
        'created': createdMs,
      };

  /// Restores an entry from its `.meta` file. Returns `null` when the file is
  /// unreadable or incompatible.
  static CacheEntry? fromJson(
    Map<String, Object?> json, {
    required String key,
    required Directory directory,
    required int chunkSize,
    required OriginClient client,
  }) {
    if (json['v'] != 1 || json['chunk'] != chunkSize) return null;
    final url = Uri.tryParse(json['url'] as String? ?? '');
    if (url == null) return null;
    final entry = CacheEntry(
      key: key,
      url: url,
      directory: directory,
      chunkSize: chunkSize,
      client: client,
      group: json['group'] as String?,
      lastAccessMs: json['access'] as int?,
      createdMs: json['created'] as int?,
    );
    entry._rangesUnsupported = json['nr'] == true;
    final base = json['base'];
    if (base is String) entry.resolvedUrl = Uri.tryParse(base);
    final total = json['total'] as int?;
    if (total != null) {
      entry._totalLength = total;
      entry._contentType = entry._resolveContentType(json['type'] as String?);
      final chunks = total == 0 ? 0 : (total + chunkSize - 1) ~/ chunkSize;
      final bits = json['bits'] as String?;
      entry._bitmap =
          bits == null ? ChunkBitmap(chunks) : ChunkBitmap.decode(chunks, bits);
    }
    return entry;
  }

  void _scheduleMetaWrite() {
    if (_removed) return;
    _metaTimer ??= Timer(const Duration(milliseconds: 500), () {
      _metaTimer = null;
      unawaited(flushMeta());
    });
  }

  /// Writes metadata atomically (temp file + rename).
  Future<void> flushMeta() async {
    _metaTimer?.cancel();
    _metaTimer = null;
    if (_removed) return;
    await _metaLock.run(() async {
      if (_removed) return;
      try {
        final tmp = File('${metaFile.path}.tmp');
        await tmp.writeAsString(jsonEncode(toJson()), flush: true);
        await tmp.rename(metaFile.path);
      } catch (error) {
        if (!_removed) SwipeLog.e('Failed to persist metadata for $key', error);
      }
    });
  }

  /// Persists metadata and closes the file handle. The entry is inert
  /// afterwards: running downloads stop and nothing more is written.
  Future<void> close() async {
    await flushMeta();
    _removed = true;
    await _ioLock.run(() async {
      await _raf?.close();
      _raf = null;
    });
  }

  /// Deletes data and metadata. In-flight downloads stop at the next packet.
  Future<void> delete() async {
    _removed = true;
    _metaTimer?.cancel();
    _metaTimer = null;
    await _ioLock.run(() async {
      await _raf?.close();
      _raf = null;
    });
    await _metaLock.run(() async {});
    for (final file in [dataFile, metaFile, File('${metaFile.path}.tmp')]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}

class _FetchProgress {
  int lastDataMs = DateTime.now().millisecondsSinceEpoch;
}
