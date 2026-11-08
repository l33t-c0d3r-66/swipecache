import '../device/adaptive_policy.dart';
import 'cache_stats.dart';
import 'prefetch_request.dart';

export 'backend_stub.dart' if (dart.library.io) 'backend_io.dart'
    show createCacheBackend;

/// Disk cache, proxy and prefetcher. Only exists where `dart:io` does; on
/// the web [createCacheBackend] returns `null` and videos play directly
/// (the browser's own HTTP cache applies).
abstract class CacheBackend {
  /// Opens the cache and starts the proxy. Throws on failure.
  Future<void> start();

  bool get isRunning;

  /// Proxy URL for [url]; [isStream] marks an HLS/DASH manifest.
  Uri playableUri(Uri url, {Map<String, String>? headers, bool isStream});

  String keyFor(Uri url);

  void schedulePrefetch(List<PrefetchRequest> requests, {bool replace});
  void pausePrefetch();
  void resumePrefetch();
  void cancelPrefetch();

  void setProtected(Iterable<String> keys);
  Future<void> ensureHealthy();

  /// Bytes stored for the video of [url] (all segments for a stream).
  int videoBytes(Uri url);

  /// Bytes stored for the resource [url] itself, and its total length.
  (int cached, int? total, bool headCached) resourceState(Uri url, int? bytes);

  double? get bandwidthBps;

  Future<void> remove(Uri url);
  Future<void> clear();
  Future<void> sweep();
  Future<void> trim();

  /// Drops prefetches and releases file handles.
  void onMemoryPressure();

  SwipeCacheStats stats(SwipeResolvedLimits limits);

  Future<void> debugCloseListener();
  Future<void> dispose();
}
