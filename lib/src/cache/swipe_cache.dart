import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../device/adaptive_policy.dart';
import '../device/device_profile.dart';
import '../util/logger.dart';
import 'cache_config.dart';
import 'cache_store.dart';
import 'origin_client.dart';
import 'prefetcher.dart';
import 'proxy_server.dart';

/// Snapshot of cache and network statistics. All numbers are measured.
class SwipeCacheStats {
  const SwipeCacheStats({
    required this.entries,
    required this.diskBytes,
    required this.maxDiskBytes,
    required this.requests,
    required this.bytesFromCache,
    required this.bytesFromNetwork,
    required this.networkBytesDownloaded,
    required this.errors,
    required this.prefetchesCompleted,
    required this.prefetchesPending,
    required this.bandwidthBps,
    required this.cachedVideos,
    required this.openFiles,
    required this.evicted,
    required this.limits,
  });

  /// Entries known in memory (including videos with nothing cached yet).
  final int entries;

  /// Videos with at least one byte on disk.
  final int cachedVideos;

  /// Cache files currently held open.
  final int openFiles;

  /// Videos evicted since start (age, size or count limits).
  final int evicted;

  /// Limits in force right now (automatic ones reflect current conditions).
  final SwipeResolvedLimits limits;
  final int diskBytes;
  final int maxDiskBytes;
  final int requests;

  /// Bytes the player received straight from disk.
  final int bytesFromCache;

  /// Bytes the player received while they were being downloaded.
  final int bytesFromNetwork;

  /// Total bytes downloaded from origins (playback + prefetch).
  final int networkBytesDownloaded;
  final int errors;
  final int prefetchesCompleted;
  final int prefetchesPending;

  /// Estimated network throughput in bits/s, `null` until measured.
  final double? bandwidthBps;

  /// Share of played bytes served from disk (0..1).
  double get hitRatio {
    final total = bytesFromCache + bytesFromNetwork;
    return total == 0 ? 0 : bytesFromCache / total;
  }

  @override
  String toString() => 'SwipeCacheStats(videos: $cachedVideos, disk: $diskBytes/'
      '$maxDiskBytes, hitRatio: ${(hitRatio * 100).toStringAsFixed(1)}%, '
      'network: $networkBytesDownloaded, '
      'bandwidth: ${bandwidthBps?.round()} bps)';
}

/// Entry point of the video cache.
///
/// ```dart
/// await SwipeCache.instance.init();
/// final uri = SwipeCache.instance.playableUri(videoUrl);
/// VideoPlayerController.networkUrl(uri);
/// ```
///
/// If initialisation fails (or has not happened yet) [playableUri] returns the
/// original URL, so playback never depends on the cache working.
class SwipeCache with WidgetsBindingObserver {
  SwipeCache._();

  /// Creates an isolated cache (mostly useful for tests). [config] applies
  /// before [init] too, e.g. to pin a device profile.
  SwipeCache.custom({SwipeCacheConfig config = const SwipeCacheConfig()})
      : _config = config;

  static final SwipeCache instance = SwipeCache._();

  SwipeCacheConfig _config = const SwipeCacheConfig();
  OriginClient? _client;
  CacheStore? _store;
  ProxyServer? _proxy;
  Prefetcher? _prefetcher;
  Future<void>? _init;
  bool _ready = false;
  bool _observing = false;
  AdaptivePolicy? _policy;

  /// Resolves automatic limits; fixed limits from the config pass through.
  AdaptivePolicy get policy => _policy ??= _createPolicy(_config);

  AdaptivePolicy _createPolicy(SwipeCacheConfig config) => AdaptivePolicy(
        config: config,
        device: config.deviceProfile ?? SwipeDeviceProfile.detect(),
        bandwidth: () => bandwidthBps,
      );

  /// The detected (or configured) device profile.
  SwipeDeviceProfile get deviceProfile => policy.device;

  bool get isReady => _ready;

  /// Completes when [init] finished (successfully or not). Completes
  /// immediately when [init] was never called.
  Future<void> get whenReady => _init ?? Future<void>.value();
  SwipeCacheConfig get config => _config;

  /// Starts the cache. Safe to call multiple times; later calls return the
  /// first call's future.
  Future<void> init({SwipeCacheConfig config = const SwipeCacheConfig()}) {
    return _init ??= _doInit(config);
  }

  Future<void> _doInit(SwipeCacheConfig config) async {
    _config = config;
    _policy = _createPolicy(config);
    SwipeLog.i('Device: ${_policy!.device}');
    try {
      final dir = config.directory ??
          Directory('${(await getTemporaryDirectory()).path}/swipecache');
      final client = OriginClient(config);
      final store = CacheStore(
          directory: dir, config: config, client: client, policy: _policy!);
      await store.open();
      final proxy = ProxyServer(store, config);
      await proxy.start();
      _client = client;
      _store = store;
      _proxy = proxy;
      _prefetcher = Prefetcher(store, config, _policy!);
      _ready = true;
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (_) {
        // No Flutter binding (pure Dart tests): lifecycle hooks unavailable.
      }
    } catch (error) {
      SwipeLog.e('Cache initialisation failed, falling back to network', error);
      _ready = false;
    }
  }

  bool _shouldBypass(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') return true;
    final path = url.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _config.bypassExtensions.contains(path.substring(dot + 1));
  }

  /// URL to hand to the video player for [url]. Served through the caching
  /// proxy when available, the original URL otherwise.
  Uri playableUri(String url, {Map<String, String>? headers}) {
    final uri = Uri.parse(url);
    final proxy = _proxy;
    final store = _store;
    if (!_ready || proxy == null || store == null || !proxy.isRunning) {
      return uri;
    }
    if (_shouldBypass(uri)) return uri;
    final entry = store.obtain(uri, headers: headers);
    return proxy.uriFor(entry);
  }

  /// Warms the cache for [urls], in order of priority. Replaces previously
  /// scheduled prefetches unless [replace] is `false`.
  void prefetch(
    List<String> urls, {
    int? headBytes,
    Map<String, String>? headers,
    bool replace = true,
  }) {
    final prefetcher = _prefetcher;
    if (!_ready || prefetcher == null) return;
    final requests = <PrefetchRequest>[];
    for (var i = 0; i < urls.length; i++) {
      final uri = Uri.tryParse(urls[i]);
      if (uri == null || _shouldBypass(uri)) continue;
      requests.add(PrefetchRequest(uri,
          headers: headers, headBytes: headBytes, priority: i));
    }
    prefetcher.schedule(requests, replace: replace);
  }

  /// Advanced: schedule prefetches with individual sizes and priorities.
  void schedulePrefetch(List<PrefetchRequest> requests, {bool replace = true}) {
    if (!_ready) return;
    _prefetcher?.schedule(
      requests.where((r) => !_shouldBypass(r.url)).toList(),
      replace: replace,
    );
  }

  void pausePrefetch() => _prefetcher?.pause();
  void resumePrefetch() => _prefetcher?.resume();
  void cancelPrefetch() => _prefetcher?.cancelAll();

  final Map<Object, Set<String>> _protectedByOwner = {};

  /// Protects [urls] from eviction on behalf of [owner] (e.g. a feed's
  /// visible window). Each owner's set replaces its previous one; several
  /// feeds can protect their windows independently.
  void protect(Iterable<String> urls, {Object owner = const _DefaultOwner()}) {
    final store = _store;
    if (store == null) return;
    final keys = {
      for (final url in urls)
        if (Uri.tryParse(url) case final uri?) store.keyFor(uri),
    };
    if (keys.isEmpty) {
      _protectedByOwner.remove(owner);
    } else {
      _protectedByOwner[owner] = keys;
    }
    store.setProtected(_protectedByOwner.values.expand((k) => k));
  }

  void unprotect(Object owner) => protect(const [], owner: owner);

  /// Verifies the loopback proxy still accepts connections and restarts it
  /// if the OS reclaimed its socket (iOS does this to suspended apps).
  /// `SwipeFeedController` calls this on app resume; call it yourself when
  /// using the cache without a feed controller.
  Future<void> ensureHealthy() async {
    if (!_ready) return;
    await _proxy?.ensureAlive();
  }

  /// `true` when at least the first [bytes] (or the full file when `null`) of
  /// [url] are on disk.
  bool isCached(String url, {int? bytes}) {
    final entry = _store?.lookup(Uri.parse(url));
    final total = entry?.totalLength;
    if (entry == null || total == null) return false;
    if (total == 0) return true;
    final end = bytes == null || bytes >= total ? total - 1 : bytes - 1;
    return entry.hasRange(0, end);
  }

  /// Bytes of [url] stored on disk.
  int cachedBytes(String url) =>
      _store?.lookup(Uri.parse(url))?.cachedBytes ?? 0;

  /// Estimated throughput in bits/s, `null` before the first measurement.
  double? get bandwidthBps => _client?.bandwidth.bitsPerSecond;

  Future<void> remove(String url) async {
    final store = _store;
    if (store == null) return;
    await store.remove(store.keyFor(Uri.parse(url)));
  }

  /// Deletes every cached video that is not currently being played.
  Future<void> clear() async => _store?.clear();

  /// Runs eviction and housekeeping now (normally periodic). Applies new
  /// automatic limits immediately, e.g. after a network change.
  Future<void> trimNow() async => _store?.sweep();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Release file handles and persist state while in the background.
      unawaited(_store?.trim());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(ensureHealthy());
    }
  }

  @override
  void didHaveMemoryPressure() {
    _prefetcher?.cancelAll();
    unawaited(_store?.trim());
  }

  SwipeCacheStats get stats {
    final proxy = _proxy;
    final store = _store;
    return SwipeCacheStats(
      entries: store?.entryCount ?? 0,
      diskBytes: store?.totalBytes ?? 0,
      maxDiskBytes: policy.maxCacheBytes,
      cachedVideos: store?.cachedVideoCount ?? 0,
      openFiles: store?.openFileCount ?? 0,
      evicted: store?.evictedCount ?? 0,
      limits: policy.resolve(),
      requests: proxy?.counters.requests ?? 0,
      bytesFromCache: proxy?.counters.bytesFromCache ?? 0,
      bytesFromNetwork: proxy?.counters.bytesFromNetwork ?? 0,
      networkBytesDownloaded: _client?.networkBytes ?? 0,
      errors: proxy?.counters.errors ?? 0,
      prefetchesCompleted: _prefetcher?.completed ?? 0,
      prefetchesPending: _prefetcher?.pendingCount ?? 0,
      bandwidthBps: bandwidthBps,
    );
  }

  @visibleForTesting
  Future<void> debugSimulateSocketReclaim() async =>
      _proxy?.debugCloseListener();

  /// Stops the proxy and flushes metadata. The cache can be re-initialised.
  Future<void> dispose() async {
    _ready = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _prefetcher?.cancelAll();
    await _proxy?.stop();
    await _store?.close();
    _client?.close();
    _proxy = null;
    _store = null;
    _protectedByOwner.clear();
    _prefetcher = null;
    _client = null;
    _init = null;
  }
}

class _DefaultOwner {
  const _DefaultOwner();
}
