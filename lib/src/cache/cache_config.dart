import '../device/device_profile.dart';

/// Builds the identity of a cached resource from its URL. Override it to drop
/// volatile query parameters (e.g. signed-URL expiry) so the same video is
/// not cached twice.
typedef SwipeCacheKeyBuilder = String Function(Uri url);

String defaultCacheKeyBuilder(Uri url) => url.toString();

/// Configuration of the SwipeCache disk cache and streaming proxy.
///
/// **Limits** (`maxCacheBytes`, `maxCachedVideos`, `maxAge`,
/// `maxConcurrentDownloads`) are automatic when left `null` (the default):
/// they are chosen from the device's RAM/CPU class and the measured network
/// speed, and adapt while the app runs. Any limit you set is followed
/// strictly and never adjusted.
class SwipeCacheConfig {
  const SwipeCacheConfig({
    this.maxCacheBytes,
    this.maxCachedVideos,
    this.maxAge,
    this.maxConcurrentDownloads,
    this.chunkSize = 256 * 1024,
    this.maxRunChunks = 32,
    this.defaultPrefetchBytes = 1024 * 1024,
    this.maxTailPrefetchBytes = 2 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 20),
    this.sweepInterval = const Duration(seconds: 30),
    this.directoryPath,
    this.deviceProfile,
    this.cacheKeyBuilder = defaultCacheKeyBuilder,
    this.userAgent = 'swipecache',
    this.bypassExtensions = const {},
    this.maxManifestBytes = 8 * 1024 * 1024,
  })  : assert(maxCacheBytes == null || maxCacheBytes > 0),
        assert(maxCachedVideos == null || maxCachedVideos > 0),
        assert(maxConcurrentDownloads == null || maxConcurrentDownloads > 0),
        assert(chunkSize >= 16 * 1024),
        assert(maxRunChunks >= 1);

  /// Disk budget in bytes. Least-recently watched videos are evicted beyond
  /// it. `null` = automatic (200 MB / 400 MB / 800 MB for low / mid / high
  /// end devices, shrinking automatically if the disk runs full).
  final int? maxCacheBytes;

  /// Maximum number of videos kept on disk. `null` = automatic (60 / 120 /
  /// 250).
  final int? maxCachedVideos;

  /// How long a video stays cached after it was last watched. `null` =
  /// automatic (3 / 7 / 14 days).
  final Duration? maxAge;

  /// Background downloads (prefetches) running at the same time. `null` =
  /// automatic (1–4, from network speed and device class). Playback itself
  /// is never queued behind these.
  final int? maxConcurrentDownloads;

  /// Granularity of the sparse cache. Smaller wastes less on aborted
  /// downloads, larger means fewer disk writes.
  final int chunkSize;

  /// Maximum number of chunks requested from the origin in one HTTP request.
  final int maxRunChunks;

  /// Head bytes prefetched per upcoming video when bandwidth is unknown.
  final int defaultPrefetchBytes;

  /// Upper bound for prefetching the `moov` atom of non fast-start MP4s.
  final int maxTailPrefetchBytes;

  final Duration connectTimeout;

  /// Origin connections that stall for longer than this are dropped.
  final Duration idleTimeout;

  /// How often expired videos are removed and idle file handles closed.
  final Duration sweepInterval;

  /// Absolute path of the cache directory. Defaults to
  /// `<temporary dir>/swipecache`.
  final String? directoryPath;

  /// Overrides device detection for automatic limits (useful for tests or
  /// to force a tier).
  final SwipeDeviceProfile? deviceProfile;

  final SwipeCacheKeyBuilder cacheKeyBuilder;
  final String userAgent;

  /// File extensions (without the dot, lower case) that are never cached and
  /// play straight from the network, e.g. `{'m3u8'}` to opt HLS out.
  /// HLS (`.m3u8`) and DASH (`.mpd`) are cached by default.
  final Set<String> bypassExtensions;

  /// Largest HLS playlist / DASH manifest accepted (protects memory against
  /// a misbehaving server).
  final int maxManifestBytes;
}
