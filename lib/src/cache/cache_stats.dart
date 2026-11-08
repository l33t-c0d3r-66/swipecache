import '../device/adaptive_policy.dart';

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
