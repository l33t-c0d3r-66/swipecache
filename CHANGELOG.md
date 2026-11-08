## 0.1.0

* Streaming cache proxy: playback starts immediately while bytes are cached.
* Sparse chunked disk cache with byte-budget LRU eviction and max age.
* Head-only prefetching sized to measured bandwidth, with MP4 `moov` tail
  detection for non fast-start files.
* Pooled player engine (`SwipeFeedController`) with settle debouncing,
  lifecycle, visibility and memory-pressure handling.
* `SwipeFeed` and `SwipeVideoView` widgets.
* Hardening: no audio overlap or leaked decoders when players are disposed
  mid-initialisation; video_player's own lifecycle observer is disabled so
  the feed controller alone decides what plays.
* Automatic recovery from playback errors at the same position (second
  attempt bypasses the cache).
* Stalled readers (paused players holding a connection) no longer block
  other readers of the same chunks.
* Separate connection pools for playback and prefetch; prefetch pauses while
  the current video is loading or buffering.
* Content-Type inference for origins serving `application/octet-stream`
  (required by AVPlayer).
* Detects files that changed at the same URL instead of mixing bytes.
* Proxy self-heals after iOS reclaims its socket (`SwipeCache.ensureHealthy`).
* `SwipeFeedConfig.releaseWhenHidden` frees neighbour decoders of hidden
  feeds; eviction protection is scoped per feed.
* Automatic limits (default) from device class (RAM/CPU) and measured
  bandwidth for cache size, video count, cache age, parallel downloads,
  player preloading and prefetch; developer-set limits are followed strictly.
* New limits: `maxCachedVideos`, `maxConcurrentDownloads` (replaces
  `prefetchConcurrency`); all limits are nullable (`null` = automatic).
* Periodic cleanup: expiry during runtime, idle file handles closed (fixes
  file descriptor exhaustion in long sessions), empty entries dropped,
  disk-full handling, no orphaned files after eviction.
* Thumbnails decoded at screen resolution.
