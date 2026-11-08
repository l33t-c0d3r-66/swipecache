import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../device/adaptive_policy.dart';
import '../stream/stream_loader.dart';
import '../stream/stream_manifest.dart';
import 'cache_backend.dart';
import 'cache_config.dart';
import 'cache_stats.dart';
import 'cache_store.dart';
import 'origin_client.dart';
import 'prefetch_request.dart';
import 'prefetcher.dart';
import 'proxy_server.dart';

CacheBackend? createCacheBackend(
        SwipeCacheConfig config, AdaptivePolicy policy) =>
    IoCacheBackend(config, policy);

class IoCacheBackend implements CacheBackend {
  IoCacheBackend(this.config, this.policy);

  final SwipeCacheConfig config;
  final AdaptivePolicy policy;

  late final OriginClient _client;
  late final CacheStore _store;
  late final ProxyServer _proxy;
  late final Prefetcher _prefetcher;
  late final StreamLoader _streams;
  bool _started = false;

  @override
  Future<void> start() async {
    final path = config.directoryPath ??
        '${(await getTemporaryDirectory()).path}/swipecache';
    _client = OriginClient(config);
    _store = CacheStore(
        directory: Directory(path),
        config: config,
        client: _client,
        policy: policy);
    try {
      await _store.open();
      _streams = StreamLoader(_store, _client, config);
      _proxy = ProxyServer(_store, config, _client, _streams);
      await _proxy.start();
    } catch (_) {
      _client.close();
      rethrow;
    }
    _prefetcher = Prefetcher(_store, config, policy, _streams,
        bandwidth: () => _client.bandwidth.bitsPerSecond);
    _started = true;
  }

  @override
  bool get isRunning => _started && _proxy.isRunning;

  @override
  Uri playableUri(Uri url, {Map<String, String>? headers, bool isStream = false}) {
    if (isStream || streamKindFor(url) != null) {
      final group = _store.keyFor(url);
      _streams.registerHeaders(group, headers);
      return Uri.parse(
          _proxy.streamUrl(group, ProxyMode.manifest, url.toString()));
    }
    return _proxy.uriFor(_store.obtain(url, headers: headers));
  }

  @override
  String keyFor(Uri url) => _store.keyFor(url);

  @override
  void schedulePrefetch(List<PrefetchRequest> requests, {bool replace = true}) =>
      _prefetcher.schedule(requests, replace: replace);

  @override
  void pausePrefetch() => _prefetcher.pause();

  @override
  void resumePrefetch() => _prefetcher.resume();

  @override
  void cancelPrefetch() => _prefetcher.cancelAll();

  @override
  void setProtected(Iterable<String> keys) => _store.setProtected(keys);

  @override
  Future<void> ensureHealthy() async {
    await _proxy.ensureAlive();
  }

  @override
  int videoBytes(Uri url) => _store.groupBytes(_store.keyFor(url));

  @override
  (int, int?, bool) resourceState(Uri url, int? bytes) {
    final entry = _store.lookup(url);
    final total = entry?.totalLength;
    if (entry == null || total == null) return (0, null, false);
    if (total == 0) return (0, 0, true);
    final end = bytes == null || bytes >= total ? total - 1 : bytes - 1;
    return (entry.cachedBytes, total, entry.hasRange(0, end));
  }

  @override
  double? get bandwidthBps =>
      _started ? _client.bandwidth.bitsPerSecond : null;

  @override
  Future<void> remove(Uri url) => _store.removeGroup(_store.keyFor(url));

  @override
  Future<void> clear() async {
    await _store.clear();
  }

  @override
  Future<void> sweep() => _store.sweep();

  @override
  Future<void> trim() => _store.trim();

  @override
  void onMemoryPressure() {
    _prefetcher.cancelAll();
    unawaited(_store.trim());
  }

  @override
  SwipeCacheStats stats(SwipeResolvedLimits limits) => SwipeCacheStats(
        entries: _store.entryCount,
        diskBytes: _store.totalBytes,
        maxDiskBytes: limits.maxCacheBytes,
        cachedVideos: _store.cachedVideoCount,
        openFiles: _store.openFileCount,
        evicted: _store.evictedCount,
        limits: limits,
        requests: _proxy.counters.requests,
        bytesFromCache: _proxy.counters.bytesFromCache,
        bytesFromNetwork: _proxy.counters.bytesFromNetwork,
        networkBytesDownloaded: _client.networkBytes,
        errors: _proxy.counters.errors,
        prefetchesCompleted: _prefetcher.completed,
        prefetchesPending: _prefetcher.pendingCount,
        bandwidthBps: bandwidthBps,
      );

  @override
  Future<void> debugCloseListener() => _proxy.debugCloseListener();

  @override
  Future<void> dispose() async {
    if (!_started) return;
    _started = false;
    _prefetcher.cancelAll();
    await _proxy.stop();
    await _store.close();
    _client.close();
  }
}
