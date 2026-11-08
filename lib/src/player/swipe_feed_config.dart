/// Tuning of the player pool and prefetching of a feed.
///
/// `preloadAhead`, `preloadBehind`, `prefetchAhead` and `prefetchHeadBytes`
/// are automatic when `null` (the default): they follow the device class
/// (RAM/CPU) and measured network speed. Values you set are used exactly.
class SwipeFeedConfig {
  const SwipeFeedConfig({
    this.preloadAhead,
    this.preloadBehind,
    this.prefetchAhead,
    this.prefetchHeadBytes,
    this.settleDelay = const Duration(milliseconds: 90),
    this.initTimeout = const Duration(seconds: 20),
    this.maxRetries = 2,
    this.looping = true,
    this.autoplay = true,
    this.restartOnLeave = true,
    this.mixWithOthers = false,
    this.loadMoreThreshold = 3,
    this.pausePrefetchUntilReady = true,
    this.releaseWhenHidden = true,
  })  : assert(preloadAhead == null || preloadAhead >= 0),
        assert(preloadBehind == null || preloadBehind >= 0),
        assert(prefetchAhead == null || prefetchAhead >= 0),
        assert(prefetchHeadBytes == null || prefetchHeadBytes > 0);

  /// Videos loaded into players (decoder ready, first frame shown) after the
  /// current item – these load in parallel with it. Hardware decoders are
  /// limited on many Android devices, so keep 1 + ahead + behind small.
  /// `null` = automatic (1, or 2 on high-end devices with a good network).
  final int? preloadAhead;

  /// Players kept alive before the current item. `null` = automatic (0 on
  /// low-end devices, otherwise 1).
  final int? preloadBehind;

  /// Upcoming videos whose first bytes are cached in the background.
  /// `null` = automatic (2–6 from network speed, capped by device class).
  final int? prefetchAhead;

  /// Bytes cached per prefetched video. `null` = automatic (512 KB on slow
  /// networks up to 2 MB on fast ones).
  final int? prefetchHeadBytes;

  /// The window is rebuilt only once scrolling settles for this long, which
  /// avoids creating and destroying decoders during fast flings.
  final Duration settleDelay;

  final Duration initTimeout;

  /// Initialisation retries (the last retry bypasses the cache proxy).
  final int maxRetries;

  final bool looping;
  final bool autoplay;

  /// Seek to the start when a video leaves the screen.
  final bool restartOnLeave;

  /// Mix audio with other apps instead of interrupting them.
  final bool mixWithOthers;

  /// `onLoadMore` fires when the current index is this close to the end.
  final int loadMoreThreshold;

  /// Hold background prefetching while the current video is loading or
  /// buffering so it gets all available bandwidth.
  final bool pausePrefetchUntilReady;

  /// Dispose all but the current player while the feed is hidden
  /// ([SwipeFeedController.setVisible]). Keeps stacked feeds from exhausting
  /// hardware decoders; neighbours are re-created when it becomes visible.
  final bool releaseWhenHidden;
}
