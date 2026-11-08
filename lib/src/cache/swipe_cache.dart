import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import '../device/adaptive_policy.dart';
import '../device/device_profile.dart';
import '../stream/stream_manifest.dart';
import '../util/logger.dart';
import 'cache_backend.dart';
import 'cache_config.dart';
import 'cache_stats.dart';
import 'prefetch_request.dart';

export 'cache_stats.dart';

/// Entry point of the video cache.
///
/// ```dart
/// await SwipeCache.instance.init();
/// final uri = SwipeCache.instance.playableUri(videoUrl);
/// VideoPlayerController.networkUrl(uri);
/// ```
///
/// If initialisation fails (or has not happened yet) [playableUri] returns the
/// original URL, so playback never depends on the cache working. On the web
/// there is no disk cache: every call is a safe no-op and videos play
/// directly (the browser's HTTP cache applies).
class SwipeCache with WidgetsBindingObserver {
  SwipeCache._();

  /// Creates an isolated cache (mostly useful for tests). [config] applies
  /// before [init] too, e.g. to pin a device profile.
  SwipeCache.custom({SwipeCacheConfig config = const SwipeCacheConfig()})
      : _config = config;

  static final SwipeCache instance = SwipeCache._();

  SwipeCacheConfig _config = const SwipeCacheConfig();
  CacheBackend? _backend;
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

  /// `true` once the disk cache is running (never on the web).
  bool get isReady => _ready;

  /// Whether this platform has a disk cache at all (`false` on the web).
  static bool get isSupported => !kIsWeb;

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
    final backend = createCacheBackend(config, _policy!);
    if (backend == null) {
      SwipeLog.i('No disk cache on this platform; playing from the network');
      return;
    }
    try {
      await backend.start();
      _backend = backend;
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

  CacheBackend? get _running {
    final backend = _backend;
    return _ready && backend != null && backend.isRunning ? backend : null;
  }

  bool _shouldBypass(Uri url) {
    if (url.scheme != 'http' && url.scheme != 'https') return true;
    final path = url.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _config.bypassExtensions.contains(path.substring(dot + 1));
  }

  static bool _isStream(Uri url, VideoFormat? hint) =>
      hint == VideoFormat.hls ||
      hint == VideoFormat.dash ||
      streamKindFor(url) != null;

  /// URL to hand to the video player for [url]. Served through the caching
  /// proxy when available, the original URL otherwise.
  ///
  /// HLS (`.m3u8`) and DASH (`.mpd`) are detected from the URL; pass
  /// [formatHint] for streams whose URL has no such extension.
  Uri playableUri(
    String url, {
    Map<String, String>? headers,
    VideoFormat? formatHint,
  }) {
    final uri = Uri.parse(url);
    final backend = _running;
    if (backend == null || _shouldBypass(uri)) return uri;
    // Smooth Streaming manifests are not supported by the proxy.
    if (formatHint == VideoFormat.ss) return uri;
    return backend.playableUri(uri,
        headers: headers, isStream: _isStream(uri, formatHint));
  }

  /// Warms the cache for [urls], in order of priority. Replaces previously
  /// scheduled prefetches unless [replace] is `false`.
  void prefetch(
    List<String> urls, {
    int? headBytes,
    Map<String, String>? headers,
    bool replace = true,
  }) {
    final requests = <PrefetchRequest>[];
    for (var i = 0; i < urls.length; i++) {
      final uri = Uri.tryParse(urls[i]);
      if (uri == null) continue;
      requests.add(PrefetchRequest(uri,
          headers: headers, headBytes: headBytes, priority: i));
    }
    schedulePrefetch(requests, replace: replace);
  }

  /// Advanced: schedule prefetches with individual sizes and priorities.
  void schedulePrefetch(List<PrefetchRequest> requests, {bool replace = true}) {
    _running?.schedulePrefetch(
      requests
          .where((r) => !_shouldBypass(r.url) && r.formatHint != VideoFormat.ss)
          .toList(),
      replace: replace,
    );
  }

  void pausePrefetch() => _running?.pausePrefetch();
  void resumePrefetch() => _running?.resumePrefetch();
  void cancelPrefetch() => _running?.cancelPrefetch();

  final Map<Object, Set<String>> _protectedByOwner = {};

  /// Protects [urls] from eviction on behalf of [owner] (e.g. a feed's
  /// visible window). Each owner's set replaces its previous one; several
  /// feeds can protect their windows independently.
  void protect(Iterable<String> urls, {Object owner = const _DefaultOwner()}) {
    final backend = _running;
    if (backend == null) return;
    final keys = {
      for (final url in urls)
        if (Uri.tryParse(url) case final uri?) backend.keyFor(uri),
    };
    if (keys.isEmpty) {
      _protectedByOwner.remove(owner);
    } else {
      _protectedByOwner[owner] = keys;
    }
    backend.setProtected(_protectedByOwner.values.expand((k) => k));
  }

  void unprotect(Object owner) => protect(const [], owner: owner);

  /// Verifies the loopback proxy still accepts connections and restarts it
  /// if the OS reclaimed its socket (iOS does this to suspended apps).
  /// `SwipeFeedController` calls this on app resume; call it yourself when
  /// using the cache without a feed controller.
  Future<void> ensureHealthy() async {
    if (!_ready) return;
    await _backend?.ensureHealthy();
  }

  /// `true` when at least the first [bytes] (or the full file when `null`) of
  /// [url] are on disk. For HLS/DASH: when at least [bytes] (default: any)
  /// of media beyond the manifest is stored.
  bool isCached(String url, {int? bytes, VideoFormat? formatHint}) {
    final backend = _running;
    final uri = Uri.tryParse(url);
    if (backend == null || uri == null) return false;
    final (cached, _, headCached) = backend.resourceState(uri, bytes);
    if (_isStream(uri, formatHint)) {
      return backend.videoBytes(uri) - cached >= (bytes ?? 1);
    }
    return headCached;
  }

  /// Bytes of [url] stored on disk (all segments for HLS/DASH).
  int cachedBytes(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 0;
    return _running?.videoBytes(uri) ?? 0;
  }

  /// Estimated throughput in bits/s, `null` before the first measurement.
  double? get bandwidthBps => _backend?.bandwidthBps;

  /// Deletes [url] (with all its segments for a stream).
  Future<void> remove(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) await _running?.remove(uri);
  }

  /// Deletes every cached video that is not currently being played.
  Future<void> clear() async => _running?.clear();

  /// Runs eviction and housekeeping now (normally periodic). Applies new
  /// automatic limits immediately, e.g. after a network change.
  Future<void> trimNow() async => _running?.sweep();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Release file handles and persist state while in the background.
      unawaited(_running?.trim());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(ensureHealthy());
    }
  }

  @override
  void didHaveMemoryPressure() => _running?.onMemoryPressure();

  SwipeCacheStats get stats {
    final limits = policy.resolve();
    return _backend?.stats(limits) ??
        SwipeCacheStats(
          entries: 0,
          diskBytes: 0,
          maxDiskBytes: limits.maxCacheBytes,
          cachedVideos: 0,
          openFiles: 0,
          evicted: 0,
          limits: limits,
          requests: 0,
          bytesFromCache: 0,
          bytesFromNetwork: 0,
          networkBytesDownloaded: 0,
          errors: 0,
          prefetchesCompleted: 0,
          prefetchesPending: 0,
          bandwidthBps: null,
        );
  }

  @visibleForTesting
  Future<void> debugSimulateSocketReclaim() async =>
      _backend?.debugCloseListener();

  /// Stops the proxy and flushes metadata. The cache can be re-initialised.
  Future<void> dispose() async {
    _ready = false;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    final backend = _backend;
    _backend = null;
    await backend?.dispose();
    _protectedByOwner.clear();
    _init = null;
  }
}

class _DefaultOwner {
  const _DefaultOwner();
}
