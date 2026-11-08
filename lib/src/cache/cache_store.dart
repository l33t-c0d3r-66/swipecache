import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../device/adaptive_policy.dart';
import '../util/hash.dart';
import '../util/logger.dart';
import 'cache_config.dart';
import 'cache_entry.dart';
import 'origin_client.dart';

/// Index of all [CacheEntry]s. Enforces three limits – total bytes, number of
/// videos and age – evicting least-recently watched videos first, and keeps
/// memory and file handles bounded with a periodic sweep.
class CacheStore {
  CacheStore({
    required this.directory,
    required this.config,
    required this.client,
    required this.policy,
  });

  final Directory directory;
  final SwipeCacheConfig config;
  final OriginClient client;
  final AdaptivePolicy policy;

  final Map<String, CacheEntry> _entries = {};
  final Set<String> _protected = {};
  int _totalBytes = 0;

  /// Bytes per video (a standalone file, or all resources of a stream).
  final Map<String, int> _groupBytes = {};
  Timer? _evictTimer;
  Timer? _sweepTimer;
  bool _evicting = false;
  int evictedCount = 0;

  /// Entries without any cached byte are dropped from memory after this
  /// long without use (they are recreated on demand).
  static const _emptyEntryIdle = Duration(minutes: 10);

  int get totalBytes => _totalBytes;
  int get entryCount => _entries.length;

  /// Videos with at least one cached byte (a stream counts once).
  int get cachedVideoCount => _groupBytes.length;

  /// The video [entry] belongs to.
  static String groupOf(CacheEntry entry) => entry.group ?? entry.key;

  /// Bytes stored for the video identified by [group].
  int groupBytes(String group) => _groupBytes[group] ?? 0;

  void _account(CacheEntry entry, int delta) {
    if (delta == 0) return;
    _totalBytes += delta;
    if (_totalBytes < 0) _totalBytes = 0;
    final group = groupOf(entry);
    final bytes = (_groupBytes[group] ?? 0) + delta;
    if (bytes > 0) {
      _groupBytes[group] = bytes;
    } else {
      _groupBytes.remove(group);
    }
  }
  int get openFileCount => _entries.values.where((e) => e.hasOpenFile).length;
  Iterable<CacheEntry> get entries => _entries.values;

  /// Loads the persisted index and drops stale/corrupt entries.
  Future<void> open() async {
    await directory.create(recursive: true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final maxAgeMs = policy.maxAge.inMilliseconds;
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File) continue;
      final name = file.uri.pathSegments.last;
      if (name.endsWith('.tmp')) {
        await _safeDelete(file);
        continue;
      }
      if (!name.endsWith('.meta')) continue;
      final key = name.substring(0, name.length - 5);
      CacheEntry? entry;
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) {
          entry = CacheEntry.fromJson(
            json,
            key: key,
            directory: directory,
            chunkSize: config.chunkSize,
            client: client,
          );
        }
      } catch (_) {}
      final expired = entry != null && now - entry.lastAccessMs > maxAgeMs;
      if (entry == null ||
          expired ||
          entry.cachedBytes == 0 ||
          !await entry.dataFile.exists()) {
        await (entry?.delete() ?? _safeDelete(file));
        await _safeDelete(File('${directory.path}/$key.data'));
        continue;
      }
      _register(entry);
    }
    // Remove orphaned data files.
    await for (final file in directory.list(followLinks: false)) {
      if (file is! File) continue;
      final name = file.uri.pathSegments.last;
      if (name.endsWith('.data') &&
          !_entries.containsKey(name.substring(0, name.length - 5))) {
        await _safeDelete(file);
      }
    }
    SwipeLog.i('Cache opened: $cachedVideoCount videos '
        '(${_entries.length} files), $_totalBytes bytes');
    _sweepTimer = Timer.periodic(config.sweepInterval, (_) => unawaited(sweep()));
    await evict();
  }

  String keyFor(Uri url) => fnv1a64Hex(config.cacheKeyBuilder(url));

  CacheEntry? byKey(String key) => _entries[key];

  CacheEntry? lookup(Uri url) => _entries[keyFor(url)];

  /// Returns the entry for [url], creating it on first use. [group] links a
  /// stream resource to its video.
  CacheEntry obtain(Uri url, {Map<String, String>? headers, String? group}) {
    final key = keyFor(url);
    final existing = _entries[key];
    if (existing != null) {
      if (headers != null) existing.headers = headers;
      existing.touch();
      return existing;
    }
    final entry = CacheEntry(
      key: key,
      url: url,
      directory: directory,
      chunkSize: config.chunkSize,
      client: client,
      headers: headers,
      group: group,
    );
    _register(entry);
    return entry;
  }

  void _register(CacheEntry entry) {
    _entries[entry.key] = entry;
    _account(entry, entry.cachedBytes);
    entry.onChunkStored = (stored, delta) {
      _account(stored, delta);
      if (_overLimits()) scheduleEviction();
    };
    entry.onDiskFull = (_) {
      policy.onDiskFull(_totalBytes);
      scheduleEviction(immediate: true, freeSpace: true);
    };
  }

  bool _overLimits() =>
      _totalBytes > policy.maxCacheBytes ||
      cachedVideoCount > policy.maxCachedVideos;

  /// Keys that must survive eviction (e.g. the visible feed window).
  void setProtected(Iterable<String> keys) {
    _protected
      ..clear()
      ..addAll(keys);
  }

  bool _freeSpaceRequested = false;

  void scheduleEviction({bool immediate = false, bool freeSpace = false}) {
    if (freeSpace) _freeSpaceRequested = true;
    if (_evictTimer != null && !immediate) return;
    _evictTimer?.cancel();
    _evictTimer = Timer(
      immediate ? Duration.zero : const Duration(seconds: 2),
      () {
        _evictTimer = null;
        unawaited(evict());
      },
    );
  }

  /// Evicts expired videos, then least-recently watched ones until both the
  /// byte and the video-count limits hold. A 10% hysteresis on bytes avoids
  /// evicting on every write.
  Future<void> evict() async {
    if (_evicting) return;
    _evicting = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final maxAgeMs = policy.maxAge.inMilliseconds;
      var byteTarget = (policy.maxCacheBytes * 0.9).floor();
      if (_freeSpaceRequested) {
        // Disk full: free a quarter of what we hold, whatever the limits.
        byteTarget = (_totalBytes * 0.75).floor().clamp(0, byteTarget);
        _freeSpaceRequested = false;
      }
      final maxVideos = policy.maxCachedVideos;

      // Videos (groups) are evicted as a whole, least recently watched first.
      final groups = <String, List<CacheEntry>>{};
      for (final entry in _entries.values) {
        groups.putIfAbsent(groupOf(entry), () => []).add(entry);
      }
      final candidates = [
        for (final MapEntry(key: group, value: members) in groups.entries)
          if (!_protected.contains(group) && members.every((e) => e.pins == 0))
            (
              group: group,
              members: members,
              lastAccess: members.map((e) => e.lastAccessMs).reduce(math.max),
            ),
      ]..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
      var videos = cachedVideoCount;
      for (final candidate in candidates) {
        final expired = now - candidate.lastAccess > maxAgeMs;
        final hasData = groupBytes(candidate.group) > 0;
        final overBytes = _totalBytes > byteTarget;
        final overCount = videos > maxVideos;
        if (!expired && !overBytes && !overCount) continue;
        if (!expired && !hasData) continue; // costs no disk
        for (final entry in candidate.members) {
          await remove(entry.key);
        }
        evictedCount++;
        if (hasData) videos--;
      }
    } finally {
      _evicting = false;
    }
  }

  /// Periodic housekeeping: expiry, limits that changed (automatic limits
  /// follow the network), idle file handles and empty in-memory entries.
  Future<void> sweep() async {
    await evict();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _entries.values.toList()) {
      final idleMs = now - entry.lastAccessMs;
      // Handles unused for a whole sweep interval are closed.
      if (idleMs >= config.sweepInterval.inMilliseconds) {
        await entry.closeIdleFile();
      }
      if (entry.cachedBytes == 0 &&
          entry.pins == 0 &&
          !_protected.contains(groupOf(entry)) &&
          !entry.hasOpenFile &&
          idleMs > _emptyEntryIdle.inMilliseconds) {
        await remove(entry.key);
      }
    }
  }

  /// Closes every idle file handle and persists metadata (app backgrounded).
  Future<void> trim() async {
    for (final entry in _entries.values.toList()) {
      await entry.flushMeta();
      await entry.closeIdleFile();
    }
  }

  Future<void> remove(String key) async {
    final entry = _entries.remove(key);
    if (entry == null) return;
    _account(entry, -entry.cachedBytes);
    entry.onChunkStored = null;
    await entry.delete();
  }

  /// Removes a video with all its resources (stream segments).
  Future<void> removeGroup(String group) async {
    for (final entry in _entries.values.toList()) {
      if (groupOf(entry) == group) await remove(entry.key);
    }
  }

  /// Deletes every video that is not currently being played. Returns the
  /// number of videos kept because they are in use.
  Future<int> clear() async {
    final inUse = {
      for (final entry in _entries.values)
        if (entry.pins > 0) groupOf(entry),
    };
    for (final entry in _entries.values.toList()) {
      if (!inUse.contains(groupOf(entry))) await remove(entry.key);
    }
    return inUse.length;
  }

  Future<void> close() async {
    _evictTimer?.cancel();
    _evictTimer = null;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    for (final entry in _entries.values) {
      await entry.close();
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
