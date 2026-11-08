import 'package:flutter/material.dart';

import '../player/swipe_feed_controller.dart';
import '../player/swipe_player.dart';
import '../player/swipe_source.dart';
import 'swipe_video_view.dart';

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
}

typedef SwipeItemBuilder = Widget Function(BuildContext context, SwipeItem item);

/// A vertical, full-screen, swipeable video feed driven by a
/// [SwipeFeedController].
///
/// ```dart
/// SwipeFeed(
///   controller: controller,
///   overlayBuilder: (context, item) => MyReelOverlay(item.source.data as Reel),
/// )
/// ```
class SwipeFeed extends StatefulWidget {
  const SwipeFeed({
    super.key,
    required this.controller,
    this.overlayBuilder,
    this.itemBuilder,
    this.placeholderBuilder,
    this.errorBuilder,
    this.bufferingBuilder,
    this.emptyBuilder,
    this.pausedIndicatorBuilder,
    this.fit = swipeAutoFit,
    this.scrollDirection = Axis.vertical,
    this.physics,
    this.tapToPause = true,
    this.onDoubleTap,
    this.onRefresh,
    this.showProgress = false,
    this.loadingMoreBuilder,
  });

  final SwipeFeedController controller;

  /// Drawn above the video (captions, buttons...).
  final SwipeItemBuilder? overlayBuilder;

  /// Replaces the default item (video + gestures + overlay) entirely.
  final SwipeItemBuilder? itemBuilder;

  final SwipePlaceholderBuilder? placeholderBuilder;
  final SwipeErrorBuilder? errorBuilder;
  final WidgetBuilder? bufferingBuilder;
  final WidgetBuilder? emptyBuilder;
  final WidgetBuilder? pausedIndicatorBuilder;
  final WidgetBuilder? loadingMoreBuilder;
  final SwipeFitResolver fit;
  final Axis scrollDirection;
  final ScrollPhysics? physics;
  final bool tapToPause;

  /// Double tap on an item (e.g. like). The details give the tap position for
  /// heart animations.
  final void Function(SwipeItem item, TapDownDetails details)? onDoubleTap;

  /// Enables pull-to-refresh on the first item.
  final RefreshCallback? onRefresh;
  final bool showProgress;

  @override
  State<SwipeFeed> createState() => _SwipeFeedState();
}

class _SwipeFeedState extends State<SwipeFeed> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.controller.index);
    widget.controller.attachPageController(_pageController);
  }

  @override
  void didUpdateWidget(SwipeFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.attachPageController(null);
      _pageController.dispose();
      _pageController = PageController(initialPage: widget.controller.index);
      widget.controller.attachPageController(_pageController);
    }
  }

  @override
  void dispose() {
    widget.controller.attachPageController(null);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.isEmpty) {
          return widget.emptyBuilder?.call(context) ??
              const ColoredBox(color: Colors.black);
        }
        Widget feed = PageView.builder(
          controller: _pageController,
          scrollDirection: widget.scrollDirection,
          physics: widget.physics ?? const _SnappyPagePhysics(),
          itemCount: controller.length,
          onPageChanged: controller.onPageChanged,
          // Players live in the controller, so pages need no keep-alive.
          allowImplicitScrolling: false,
          itemBuilder: (context, index) {
            final source = controller.sources[index];
            final item = SwipeItem(
              index: index,
              source: source,
              player: controller.playerAt(index),
              isCurrent: index == controller.index,
              controller: controller,
            );
            return KeyedSubtree(
              key: ValueKey(source.id),
              child: widget.itemBuilder?.call(context, item) ??
                  _DefaultItem(item: item, feed: widget),
            );
          },
        );
        if (widget.onRefresh != null) {
          feed = RefreshIndicator(onRefresh: widget.onRefresh!, child: feed);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            feed,
            if (controller.isLoadingMore && widget.loadingMoreBuilder != null)
              widget.loadingMoreBuilder!(context),
          ],
        );
      },
    );
  }
}

class _DefaultItem extends StatelessWidget {
  const _DefaultItem({required this.item, required this.feed});

  final SwipeItem item;
  final SwipeFeed feed;

  @override
  Widget build(BuildContext context) {
    final controller = item.controller;
    final showPaused =
        feed.tapToPause && item.isCurrent && controller.isUserPaused;
    TapDownDetails? lastDown;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: feed.tapToPause && item.isCurrent ? controller.togglePlay : null,
      onDoubleTapDown: feed.onDoubleTap == null ? null : (d) => lastDown = d,
      onDoubleTap: feed.onDoubleTap == null
          ? null
          : () => feed.onDoubleTap!(
              item, lastDown ?? TapDownDetails(globalPosition: Offset.zero)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SwipeVideoView(
            source: item.source,
            player: item.player,
            fit: feed.fit,
            placeholderBuilder: feed.placeholderBuilder,
            errorBuilder: feed.errorBuilder,
            bufferingBuilder: feed.bufferingBuilder,
            showProgress: feed.showProgress,
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: showPaused ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Center(
                child: feed.pausedIndicatorBuilder?.call(context) ??
                    const Icon(Icons.play_arrow_rounded,
                        size: 84, color: Colors.white70),
              ),
            ),
          ),
          if (feed.overlayBuilder != null) feed.overlayBuilder!(context, item),
        ],
      ),
    );
  }
}

/// Page physics with a lighter fling threshold and a crisp spring, closer to
/// what users expect from short-video apps than the default.
class _SnappyPagePhysics extends PageScrollPhysics {
  const _SnappyPagePhysics({super.parent});

  @override
  _SnappyPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _SnappyPagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      const SpringDescription(mass: 0.5, stiffness: 120, damping: 15.5);

  @override
  double get minFlingVelocity => 60;
}
