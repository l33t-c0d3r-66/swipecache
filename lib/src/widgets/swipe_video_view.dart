import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../player/swipe_player.dart';
import '../player/swipe_source.dart';

/// Chooses how a video of a given size is fitted into the item.
typedef SwipeFitResolver = BoxFit Function(Size videoSize);

/// Portrait videos fill the screen, landscape videos are letterboxed.
BoxFit swipeAutoFit(Size videoSize) =>
    videoSize.height >= videoSize.width ? BoxFit.cover : BoxFit.contain;

typedef SwipePlaceholderBuilder = Widget Function(
    BuildContext context, SwipeSource source);

typedef SwipeErrorBuilder = Widget Function(
    BuildContext context, SwipeSource source, VoidCallback retry);

/// Renders a [SwipePlayer]: a placeholder (thumbnail) until the first frame
/// is available, then the video, cross-faded to avoid a black flash.
///
/// Only rebuilds on state changes that matter (ready, buffering, size,
/// error) – never on position ticks, so it costs nothing while playing.
class SwipeVideoView extends StatefulWidget {
  const SwipeVideoView({
    super.key,
    required this.source,
    required this.player,
    this.fit = swipeAutoFit,
    this.placeholderBuilder,
    this.errorBuilder,
    this.bufferingBuilder,
    this.showProgress = false,
    this.progressColors,
  });

  final SwipeSource source;

  /// May be `null` while the item is outside the preload window.
  final SwipePlayer? player;
  final SwipeFitResolver fit;
  final SwipePlaceholderBuilder? placeholderBuilder;
  final SwipeErrorBuilder? errorBuilder;
  final WidgetBuilder? bufferingBuilder;
  final bool showProgress;
  final VideoProgressColors? progressColors;

  @override
  State<SwipeVideoView> createState() => _SwipeVideoViewState();
}

class _SwipeVideoViewState extends State<SwipeVideoView> {
  SwipePlayer? _player;
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _buffering = false;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _attach(widget.player);
  }

  @override
  void didUpdateWidget(SwipeVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _detach();
      _attach(widget.player);
    }
  }

  void _attach(SwipePlayer? player) {
    _player = player;
    player?.addListener(_onPlayer);
    _bindController(player?.controller);
  }

  void _detach() {
    _player?.removeListener(_onPlayer);
    _controller?.removeListener(_onValue);
    _player = null;
    _controller = null;
  }

  void _bindController(VideoPlayerController? controller) {
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onValue);
    _controller = controller;
    controller?.addListener(_onValue);
    _readValue();
  }

  void _onPlayer() {
    if (!mounted) return;
    final player = _player;
    _bindController(player?.isDisposed ?? true ? null : player!.controller);
    setState(() {});
  }

  void _onValue() {
    final before = (_initialized, _buffering, _size);
    _readValue();
    if (mounted && before != (_initialized, _buffering, _size)) {
      setState(() {});
    }
  }

  void _readValue() {
    final value = _controller?.value;
    _initialized = value?.isInitialized ?? false;
    _buffering = value?.isBuffering ?? false;
    _size = value?.size ?? Size.zero;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  Widget _placeholder(BuildContext context) {
    final builder = widget.placeholderBuilder;
    if (builder != null) return builder(context, widget.source);
    final thumb = widget.source.thumbnailUrl;
    if (thumb == null || thumb.isEmpty) return const ColoredBox(color: Colors.black);
    // Decode at screen resolution: full-size thumbnails cost several MB of
    // RAM each in the image cache.
    final width = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context))
        .round();
    return Image.network(
      thumb,
      cacheWidth: width > 0 ? width : null,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final controller = _controller;
    final hasError = player?.status == SwipePlayerStatus.error;
    final showVideo = controller != null &&
        _initialized &&
        _size != Size.zero &&
        (player?.hasFrame ?? false);

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        _placeholder(context),
        AnimatedOpacity(
          opacity: showVideo ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: showVideo
              ? RepaintBoundary(
                  child: FittedBox(
                    fit: widget.fit(_size),
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: _size.width,
                      height: _size.height,
                      child: VideoPlayer(controller),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        if (hasError)
          (widget.errorBuilder ?? _defaultError)(
              context, widget.source, () => player!.retry())
        else if ((showVideo && _buffering) || (player != null && !showVideo))
          Center(
            child: widget.bufferingBuilder?.call(context) ??
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white70,
                  ),
                ),
          ),
        if (widget.showProgress && showVideo)
          Align(
            alignment: Alignment.bottomCenter,
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              padding: EdgeInsets.zero,
              colors: widget.progressColors ??
                  const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.white10,
                  ),
            ),
          ),
      ],
    );
  }

  static Widget _defaultError(
      BuildContext context, SwipeSource source, VoidCallback retry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 40),
          const SizedBox(height: 12),
          TextButton(
            onPressed: retry,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
