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
* HLS and DASH caching: playlists/manifests are rewritten so every segment
  goes through the proxy. VOD streams are stored (and replay offline), live
  streams pass through without being stored, encryption keys are never
  stored. All resources of a stream count and are evicted as one video.
* HLS prefetch: playlist, start variant (first listed on iOS/macOS, by
  bandwidth on Android), its default audio rendition, init section and first
  segments.
* `SwipeSource.formatHint` / `PrefetchRequest.formatHint` for stream URLs
  without a `.m3u8`/`.mpd` extension; the player passes the format to
  ExoPlayer.
* Origins without Range support are downloaded once: bytes before a seek
  position are stored instead of discarded, and requests read through in one
  pass instead of restarting every few chunks.
* iOS simulator: automatic limits use the simulated model's hardware instead
  of the host Mac's (`SwipeDeviceProfile.forAppleModel`).
* Web support: the package compiles for the web and plays directly (no disk
  cache); falls back to muted playback when the browser blocks autoplay with
  sound.
* Breaking: `SwipeCacheConfig.directory` (a `Directory`) is now
  `directoryPath` (a `String`), keeping the public API free of `dart:io`.
  `bypassExtensions` is empty by default (HLS/DASH are cached).
* Origins that repeat a response header (e.g. `Accept-Ranges` twice) no
  longer break pass-through and cached responses.
* Live streams behind a master playlist store nothing (the master playlist
  is dropped once a live variant is seen).
* Segment file handles are released as soon as a segment has been served.
* Verbose logging (`SwipeLogLevel.verbose`) prints one line per proxy request
  with range, time and bytes from disk / network.
* Reel UI (`SwipeFeed(reel: SwipeReelOptions(...))`): Instagram- or
  TikTok-style action rail (like, comment, share, save, more, custom
  actions), author row / follow badge, expandable caption with tappable
  hashtags and mentions, music ticker and disc, double-tap heart, tap to
  mute, hold to pause. Vector icons for both styles (`SwipeReelIcons`).
* Optimistic like/save/follow with automatic rollback when the callback
  returns `false` or throws; `onEvent` reports every action.
* Built-in sheets: comments (paging, posting, comment likes), share (copy
  link + custom targets) and options.
* Everything replaceable: `actionBuilder`, part builders, `SwipeReelTheme`,
  custom icon sets; building blocks exported for fully custom overlays.
* `SwipeFeed.header` for a fixed top bar (`SwipeReelTopBar`).
* `SwipeSource.reel`, `SwipeSource.copyWith`, `SwipeFeedController.updateReel`
  / `updateSource` / `sourceById`.
* Buttons on top of the video react immediately: double taps are detected
  without holding back other taps.
* Pause like Instagram or TikTok: `tapAction` (mute / pause), `holdAction`
  (pause / speedUp / menu), `holdEdgesToSpeedUp` and `holdSpeed`; TikTok
  style pause mark (`SwipePausedIndicator`) and "2x" pill
  (`SwipeSpeedBadge`).
* `SwipeSeekBar`: smooth, draggable progress bar (thicker while paused, time
  shown and UI hidden while dragging, hidden for live streams).
* `SwipeFeedController.setPlaybackSpeed` / `playbackSpeed` (kept for new
  videos) and `showSwipeSpeedSheet`.
* New events: `speedUp`, `seek`.
