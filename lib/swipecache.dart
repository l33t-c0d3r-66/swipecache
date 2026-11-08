/// Short-video feeds with stream-while-caching, smart prefetching and a
/// pooled player engine.
library;

export 'src/cache/cache_config.dart' show SwipeCacheConfig, SwipeCacheKeyBuilder;
export 'src/cache/prefetch_request.dart';
export 'src/cache/swipe_cache.dart' show SwipeCache, SwipeCacheStats;
export 'src/device/adaptive_policy.dart'
    show SwipeNetworkTier, SwipeResolvedLimits;
export 'src/device/device_profile.dart' show SwipeDeviceProfile, SwipeDeviceTier;
export 'src/player/swipe_feed_config.dart';
export 'src/player/swipe_feed_controller.dart';
export 'src/player/swipe_player.dart';
export 'src/player/swipe_source.dart';
export 'src/reel/reel_data.dart';
export 'src/reel/reel_icons.dart';
export 'src/reel/reel_overlay.dart';
export 'src/reel/reel_playback.dart';
export 'src/reel/reel_sheets.dart';
export 'src/reel/reel_theme.dart';
export 'src/reel/reel_widgets.dart';
export 'src/util/logger.dart' show SwipeLog, SwipeLogLevel;
export 'src/widgets/swipe_feed.dart';
export 'src/widgets/swipe_video_view.dart';
