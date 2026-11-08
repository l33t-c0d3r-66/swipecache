import 'dart:math' as math;

import '../cache/cache_config.dart';
import 'device_profile.dart';

/// Network class derived from measured throughput.
enum SwipeNetworkTier { unknown, slow, medium, fast }

SwipeNetworkTier networkTierFor(double? bitsPerSecond) {
  if (bitsPerSecond == null) return SwipeNetworkTier.unknown;
  if (bitsPerSecond < 1.5e6) return SwipeNetworkTier.slow;
  if (bitsPerSecond < 6e6) return SwipeNetworkTier.medium;
  return SwipeNetworkTier.fast;
}

/// The limits currently in force, with where each one came from.
class SwipeResolvedLimits {
  const SwipeResolvedLimits({
    required this.maxCacheBytes,
    required this.maxCachedVideos,
    required this.maxAge,
    required this.maxConcurrentDownloads,
    required this.preloadAhead,
    required this.preloadBehind,
    required this.prefetchAhead,
    required this.prefetchHeadBytes,
    required this.device,
    required this.network,
    required this.autoFields,
  });

  final int maxCacheBytes;
  final int maxCachedVideos;
  final Duration maxAge;
  final int maxConcurrentDownloads;
  final int preloadAhead;
  final int preloadBehind;
  final int prefetchAhead;
  final int prefetchHeadBytes;
  final SwipeDeviceTier device;
  final SwipeNetworkTier network;

  /// Names of the limits chosen automatically; all others are the
  /// developer's fixed values.
  final Set<String> autoFields;

  @override
  String toString() => 'SwipeResolvedLimits(device: ${device.name}, '
      'network: ${network.name}, cache: ${maxCacheBytes ~/ (1024 * 1024)}MB/'
      '$maxCachedVideos videos/${maxAge.inHours}h, downloads: '
      '$maxConcurrentDownloads, players: +$preloadAhead/-$preloadBehind, '
      'prefetch: $prefetchAhead x ${prefetchHeadBytes ~/ 1024}KB, '
      'auto: $autoFields)';
}

/// Resolves every limit that the developer left on automatic.
///
/// Rules:
/// * a value set in [SwipeCacheConfig]/`SwipeFeedConfig` is returned as-is,
///   always – automatic logic never overrides it;
/// * automatic values depend on the [device] tier (RAM/CPU) and on measured
///   bandwidth, and are re-evaluated on every call, so they follow the
///   network as it changes.
class AdaptivePolicy {
  AdaptivePolicy({
    required this.config,
    required this.device,
    required double? Function() bandwidth,
  }) : _bandwidth = bandwidth;

  final SwipeCacheConfig config;
  final SwipeDeviceProfile device;
  final double? Function() _bandwidth;

  /// Set when the disk ran full; caps the automatic cache size.
  int? _diskFullCap;

  static const _mb = 1024 * 1024;

  SwipeDeviceTier get deviceTier => device.tier;
  SwipeNetworkTier get networkTier => networkTierFor(_bandwidth());

  // --- Cache -----------------------------------------------------------------

  int get maxCacheBytes {
    final fixed = config.maxCacheBytes;
    if (fixed != null) return fixed;
    final auto = switch (deviceTier) {
      SwipeDeviceTier.low => 200 * _mb,
      SwipeDeviceTier.mid => 400 * _mb,
      SwipeDeviceTier.high => 800 * _mb,
    };
    final cap = _diskFullCap;
    return cap == null ? auto : math.min(auto, cap);
  }

  int get maxCachedVideos =>
      config.maxCachedVideos ??
      switch (deviceTier) {
        SwipeDeviceTier.low => 60,
        SwipeDeviceTier.mid => 120,
        SwipeDeviceTier.high => 250,
      };

  Duration get maxAge =>
      config.maxAge ??
      switch (deviceTier) {
        SwipeDeviceTier.low => const Duration(days: 3),
        SwipeDeviceTier.mid => const Duration(days: 7),
        SwipeDeviceTier.high => const Duration(days: 14),
      };

  /// Called when a write failed with "no space left on device". In automatic
  /// mode the budget shrinks below what is stored now; fixed limits are left
  /// untouched (eviction still frees space under them).
  void onDiskFull(int currentBytes) {
    if (config.maxCacheBytes != null) return;
    _diskFullCap = math.max(32 * _mb, (currentBytes * 0.7).floor());
  }

  // --- Downloads ---------------------------------------------------------------

  int get maxConcurrentDownloads {
    final fixed = config.maxConcurrentDownloads;
    if (fixed != null) return fixed;
    final device = deviceTier;
    return switch (networkTier) {
      SwipeNetworkTier.slow => 1,
      SwipeNetworkTier.unknown => device == SwipeDeviceTier.low ? 1 : 2,
      SwipeNetworkTier.medium => device == SwipeDeviceTier.low ? 1 : 2,
      SwipeNetworkTier.fast => switch (device) {
          SwipeDeviceTier.low => 2,
          SwipeDeviceTier.mid => 3,
          SwipeDeviceTier.high => 4,
        },
    };
  }

  // --- Players / prefetch (fed by SwipeFeedConfig) -----------------------------

  /// Decoders kept ready after the current item.
  int preloadAhead(int? fixed) {
    if (fixed != null) return fixed;
    return switch (deviceTier) {
      SwipeDeviceTier.low => 1,
      SwipeDeviceTier.mid => 1,
      SwipeDeviceTier.high => networkTier == SwipeNetworkTier.slow ? 1 : 2,
    };
  }

  /// Decoders kept alive before the current item.
  int preloadBehind(int? fixed) {
    if (fixed != null) return fixed;
    return deviceTier == SwipeDeviceTier.low ? 0 : 1;
  }

  /// Upcoming videos whose head is downloaded in the background.
  int prefetchAhead(int? fixed) {
    if (fixed != null) return fixed;
    final byNetwork = switch (networkTier) {
      SwipeNetworkTier.unknown => 3,
      SwipeNetworkTier.slow => 2,
      SwipeNetworkTier.medium => 3,
      SwipeNetworkTier.fast => 5,
    };
    final byDevice = switch (deviceTier) {
      SwipeDeviceTier.low => 3,
      SwipeDeviceTier.mid => 5,
      SwipeDeviceTier.high => 6,
    };
    return math.min(byNetwork, byDevice);
  }

  /// Bytes downloaded per prefetched video.
  int prefetchHeadBytes(int? fixed) {
    if (fixed != null) return fixed;
    return switch (networkTier) {
      SwipeNetworkTier.unknown => config.defaultPrefetchBytes,
      SwipeNetworkTier.slow => 512 * 1024,
      SwipeNetworkTier.medium => 1024 * 1024,
      SwipeNetworkTier.fast => 2 * _mb,
    };
  }

  SwipeResolvedLimits resolve({
    int? preloadAhead,
    int? preloadBehind,
    int? prefetchAhead,
    int? prefetchHeadBytes,
  }) {
    return SwipeResolvedLimits(
      maxCacheBytes: maxCacheBytes,
      maxCachedVideos: maxCachedVideos,
      maxAge: maxAge,
      maxConcurrentDownloads: maxConcurrentDownloads,
      preloadAhead: this.preloadAhead(preloadAhead),
      preloadBehind: this.preloadBehind(preloadBehind),
      prefetchAhead: this.prefetchAhead(prefetchAhead),
      prefetchHeadBytes: this.prefetchHeadBytes(prefetchHeadBytes),
      device: deviceTier,
      network: networkTier,
      autoFields: {
        if (config.maxCacheBytes == null) 'maxCacheBytes',
        if (config.maxCachedVideos == null) 'maxCachedVideos',
        if (config.maxAge == null) 'maxAge',
        if (config.maxConcurrentDownloads == null) 'maxConcurrentDownloads',
        if (preloadAhead == null) 'preloadAhead',
        if (preloadBehind == null) 'preloadBehind',
        if (prefetchAhead == null) 'prefetchAhead',
        if (prefetchHeadBytes == null) 'prefetchHeadBytes',
      },
    );
  }
}
