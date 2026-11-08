import 'dart:async';

import 'package:flutter/material.dart';

import '../player/swipe_feed_controller.dart';
import '../player/swipe_source.dart';
import '../reel/reel_overlay.dart';
import '../reel/reel_playback.dart';
import '../reel/reel_widgets.dart';
import 'swipe_item.dart';
import 'swipe_video_view.dart';

export 'swipe_item.dart';

typedef SwipeItemBuilder = Widget Function(BuildContext context, SwipeItem item);

/// A vertical, full-screen, swipeable video feed driven by a
/// [SwipeFeedController].
///
/// ```dart
/// SwipeFeed(
///   controller: controller,
///   // Built-in Instagram-style UI (like, comment, share, save...):
///   reel: SwipeReelOptions(onLike: (item, liked) => api.like(item.source.id, liked)),
///   // Anything of your own on top:
///   overlayBuilder: (context, item) => MyBadge(item),
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
    this.reel,
    this.header,
  });

  final SwipeFeedController controller;

  /// Turns on the built-in reel UI (action rail, author, caption, music,
  /// double-tap like, hold to pause). Data comes from [SwipeSource.reel].
  final SwipeReelOptions? reel;

  /// Fixed content above the feed that does not scroll with the videos,
  /// e.g. a [SwipeReelTopBar]. Placed inside the top safe area.
  final Widget? header;

  /// Drawn above the video (and above the [reel] UI): your own widgets.
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
            if (widget.header != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(bottom: false, child: widget.header!),
              ),
          ],
        );
      },
    );
  }
}

class _DefaultItem extends StatefulWidget {
  const _DefaultItem({required this.item, required this.feed});

  final SwipeItem item;
  final SwipeFeed feed;

  @override
  State<_DefaultItem> createState() => _DefaultItemState();
}

class _DefaultItemState extends State<_DefaultItem> {
  final List<(int, Offset)> _bursts = [];
  int _burstId = 0;
  Timer? _singleTapTimer;
  Offset? _firstTap;
  bool _holding = false;
  bool _pausedBeforeHold = false;
  bool _speeding = false;
  bool _scrubbing = false;
  SwipeHoldAction? _activeHold;
  Timer? _muteFlashTimer;
  bool _showMuteFlash = false;

  @override
  void dispose() {
    _muteFlashTimer?.cancel();
    _singleTapTimer?.cancel();
    super.dispose();
  }

  static const _doubleTapTimeout = Duration(milliseconds: 280);

  /// Double taps are detected here instead of with a double-tap recognizer:
  /// that recognizer holds every tap for ~300 ms, which would make buttons
  /// on top of the video (ours and the app's) feel slow.
  void _onTapUp(TapUpDetails details, {required bool canDoubleTap}) {
    if (!canDoubleTap) {
      _onTap();
      return;
    }
    final first = _firstTap;
    if (_singleTapTimer?.isActive == true &&
        first != null &&
        (first - details.localPosition).distance < 40) {
      _singleTapTimer!.cancel();
      _firstTap = null;
      _onDoubleTap(details);
      return;
    }
    _firstTap = details.localPosition;
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(_doubleTapTimeout, () {
      _firstTap = null;
      if (mounted && widget.item.isCurrent) _onTap();
    });
  }

  SwipeReelOptions? get _reel => widget.feed.reel;

  void _onTap() {
    final controller = widget.item.controller;
    final action = _reel?.tapAction ?? SwipeTapAction.pause;
    if (!widget.feed.tapToPause || action == SwipeTapAction.none) return;
    final reel = _reel;
    if (action == SwipeTapAction.mute) {
      controller.setMuted(!controller.isMuted);
      if (reel != null) {
        SwipeReelActions(widget.item, reel).emit(controller.isMuted
            ? SwipeReelEventType.mute
            : SwipeReelEventType.unmute);
      }
      _muteFlashTimer?.cancel();
      setState(() => _showMuteFlash = true);
      _muteFlashTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _showMuteFlash = false);
      });
    } else {
      controller.togglePlay();
      if (reel != null) {
        SwipeReelActions(widget.item, reel).emit(controller.isUserPaused
            ? SwipeReelEventType.pause
            : SwipeReelEventType.resume);
      }
    }
  }

  void _onDoubleTap(TapUpDetails up) {
    final item = widget.item;
    final down = TapDownDetails(
        globalPosition: up.globalPosition, localPosition: up.localPosition);
    final reel = _reel;
    if (reel != null && reel.doubleTapToLike) {
      unawaited(SwipeReelActions(item, reel)
          .toggleLike(value: true, fromDoubleTap: true));
      setState(() => _bursts.add((_burstId++, up.localPosition)));
    }
    widget.feed.onDoubleTap?.call(item, down);
  }

  void _onHoldStart(LongPressStartDetails details) {
    final reel = _reel;
    if (reel == null) return;
    final width = context.size?.width ?? 0;
    final x = details.localPosition.dx;
    final onEdge = width > 0 && (x < width * 0.2 || x > width * 0.8);
    final action = reel.holdEdgesToSpeedUp && onEdge
        ? SwipeHoldAction.speedUp
        : reel.holdAction;
    _activeHold = action;
    final controller = widget.item.controller;
    final actions = SwipeReelActions(widget.item, reel);
    switch (action) {
      case SwipeHoldAction.pause:
        _pausedBeforeHold = controller.isUserPaused;
        if (!_pausedBeforeHold) controller.pause();
        actions.emit(SwipeReelEventType.pause);
        setState(() => _holding = true);
      case SwipeHoldAction.speedUp:
        if (controller.isUserPaused) return;
        unawaited(widget.item.player?.setPlaybackSpeed(reel.holdSpeed));
        actions.emit(SwipeReelEventType.speedUp, value: '${reel.holdSpeed}');
        setState(() => _speeding = true);
      case SwipeHoldAction.menu:
        unawaited(actions.openMore(context));
      case SwipeHoldAction.none:
        break;
    }
  }

  void _onHoldEnd() {
    final action = _activeHold;
    _activeHold = null;
    if (action == SwipeHoldAction.pause && _holding) {
      if (!_pausedBeforeHold) widget.item.controller.play();
      setState(() => _holding = false);
    } else if (action == SwipeHoldAction.speedUp && _speeding) {
      unawaited(widget.item.player
          ?.setPlaybackSpeed(widget.item.controller.playbackSpeed));
      setState(() => _speeding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final feed = widget.feed;
    final controller = item.controller;
    final reel = _reel;
    final canDoubleTap =
        feed.onDoubleTap != null || (reel != null && reel.doubleTapToLike);
    final canHold = reel != null &&
        item.isCurrent &&
        (reel.holdAction != SwipeHoldAction.none || reel.holdEdgesToSpeedUp);
    final paused = item.isCurrent && controller.isUserPaused;
    final showPaused = paused && !_holding && !_scrubbing;
    final hideUi = _holding || _scrubbing;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: item.isCurrent || canDoubleTap
          ? (d) => _onTapUp(d, canDoubleTap: canDoubleTap)
          : null,
      onLongPressStart: canHold ? _onHoldStart : null,
      onLongPressEnd: canHold ? (_) => _onHoldEnd() : null,
      onLongPressCancel: canHold ? _onHoldEnd : null,
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
          Center(
            child: feed.pausedIndicatorBuilder != null
                ? IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: showPaused ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: feed.pausedIndicatorBuilder!(context),
                    ),
                  )
                : SwipePausedIndicator(visible: showPaused),
          ),
          if (reel != null || feed.overlayBuilder != null)
            // Holding the video hides the UI so the frame can be seen.
            AnimatedOpacity(
              opacity: hideUi ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: hideUi,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (reel != null) SwipeReelOverlay(item: item, options: reel),
                    if (feed.overlayBuilder != null)
                      feed.overlayBuilder!(context, item),
                  ],
                ),
              ),
            ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showMuteFlash ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                      color: Color(0x88000000), shape: BoxShape.circle),
                  child: Icon(
                    controller.isMuted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
          if (reel != null && reel.showSeekBar && item.isCurrent)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: SwipeSeekBar(
                  player: item.player,
                  expanded: paused,
                  onScrubChanged: (scrubbing) =>
                      setState(() => _scrubbing = scrubbing),
                  onSeek: (position) => SwipeReelActions(item, reel).emit(
                      SwipeReelEventType.seek,
                      value: '${position.inMilliseconds / 1000}'),
                ),
              ),
            ),
          if (reel != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 64,
              left: 0,
              right: 0,
              child: Center(
                child: SwipeSpeedBadge(visible: _speeding, speed: reel.holdSpeed),
              ),
            ),
          for (final (id, position) in _bursts)
            SwipeHeartBurst(
              key: ValueKey(id),
              position: position,
              color: reel?.theme.likeColor ?? const Color(0xFFFF3040),
              onDone: () {
                if (mounted) setState(() => _bursts.removeWhere((b) => b.$1 == id));
              },
            ),
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
