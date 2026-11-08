import '../player/swipe_feed_controller.dart';
import '../player/swipe_player.dart';
import '../player/swipe_source.dart';
import '../reel/reel_data.dart';

/// Everything an item builder needs to render one feed item.
class SwipeItem {
  const SwipeItem({
    required this.index,
    required this.source,
    required this.player,
    required this.isCurrent,
    required this.controller,
  });

  final int index;
  final SwipeSource source;

  /// `null` when the item is outside the preload window.
  final SwipePlayer? player;
  final bool isCurrent;
  final SwipeFeedController controller;

  /// The reel data of this item ([SwipeSource.reel], or empty).
  SwipeReelData get reel => source.reel ?? const SwipeReelData();
}
