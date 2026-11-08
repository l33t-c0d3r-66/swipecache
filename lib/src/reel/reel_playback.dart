import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../player/swipe_player.dart';

String _clock(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// A TikTok/Instagram-style progress bar at the bottom of a video.
///
/// Thin while playing, thicker with a handle while paused, and draggable:
/// while dragging, a large "0:12 / 0:45" is shown and [onScrubChanged]
/// reports `true` (the reel UI hides its buttons meanwhile). Moves smoothly
/// between the player's position updates. Hidden for live streams.
class SwipeSeekBar extends StatefulWidget {
  const SwipeSeekBar({
    super.key,
    required this.player,
    this.expanded = false,
    this.onScrubChanged,
    this.onSeek,
    this.color = Colors.white,
    this.backgroundColor = const Color(0x40FFFFFF),
  });

  /// `null` (or not ready) draws nothing.
  final SwipePlayer? player;

  /// Thicker bar with a handle (e.g. while paused).
  final bool expanded;
  final ValueChanged<bool>? onScrubChanged;

  /// After the user dropped the handle.
  final ValueChanged<Duration>? onSeek;
  final Color color;
  final Color backgroundColor;

  @override
  State<SwipeSeekBar> createState() => _SwipeSeekBarState();
}

class _SwipeSeekBarState extends State<SwipeSeekBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) {
    if (mounted) setState(() {});
  });
  SwipePlayer? _player;
  VideoPlayerController? _controller;
  Duration _lastPosition = Duration.zero;
  DateTime _lastUpdate = DateTime.now();
  double? _dragFraction;
  bool _wasPlaying = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.player);
  }

  @override
  void didUpdateWidget(SwipeSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _detach();
      _attach(widget.player);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _detach();
    _ticker.dispose();
    super.dispose();
  }

  void _attach(SwipePlayer? player) {
    _player = player;
    player?.addListener(_onPlayer);
    _bind(player?.controller);
  }

  void _detach() {
    _player?.removeListener(_onPlayer);
    _player = null;
    _bind(null);
  }

  void _onPlayer() => _bind(_player?.controller);

  void _bind(VideoPlayerController? controller) {
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_onValue);
    _controller = controller;
    controller?.addListener(_onValue);
    _onValue();
  }

  void _onValue() {
    if (_disposed) return;
    final value = _controller?.value;
    final playing = value != null && value.isPlaying && !value.isBuffering;
    if (value != null && value.position != _lastPosition) {
      _lastPosition = value.position;
      _lastUpdate = DateTime.now();
    }
    if (playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
    if (mounted) setState(() {});
  }

  Duration get _position {
    final value = _controller?.value;
    if (value == null) return Duration.zero;
    var position = _lastPosition;
    if (value.isPlaying && !value.isBuffering) {
      final elapsed = DateTime.now().difference(_lastUpdate);
      position += elapsed * value.playbackSpeed;
    }
    return position > value.duration ? value.duration : position;
  }

  void _dragTo(double dx, double width) {
    setState(() => _dragFraction = (dx / width).clamp(0.0, 1.0));
  }

  void _start(double dx, double width) {
    _wasPlaying = _controller?.value.isPlaying ?? false;
    if (_wasPlaying) _player?.pause();
    _dragTo(dx, width);
    widget.onScrubChanged?.call(true);
  }

  Future<void> _end() async {
    final fraction = _dragFraction;
    final duration = _controller?.value.duration ?? Duration.zero;
    if (fraction != null) {
      final target = duration * fraction;
      _lastPosition = target;
      _lastUpdate = DateTime.now();
      await _player?.seekTo(target);
      widget.onSeek?.call(target);
    }
    if (_wasPlaying) await _player?.play();
    if (!mounted) return;
    setState(() => _dragFraction = null);
    widget.onScrubChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final value = _controller?.value;
    final duration = value?.duration ?? Duration.zero;
    // Live streams and not-ready players have no meaningful duration.
    if (value == null || !value.isInitialized || duration <= const Duration(seconds: 1)) {
      return const SizedBox(height: 18);
    }
    final dragging = _dragFraction != null;
    final fraction = dragging
        ? _dragFraction!
        : (_position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final thick = dragging || widget.expanded;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dragging)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: _clock(duration * fraction)),
                TextSpan(
                    text: '  /  ${_clock(duration)}',
                    style: TextStyle(color: widget.color.withValues(alpha: 0.6))),
              ]),
              style: TextStyle(
                color: widget.color,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                shadows: const [Shadow(blurRadius: 10, color: Color(0x99000000))],
              ),
            ),
          ),
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (d) => _start(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _dragTo(d.localPosition.dx, width),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            child: SizedBox(
              height: 18,
              width: width,
              child: CustomPaint(
                painter: _BarPainter(
                  fraction: fraction,
                  thick: thick,
                  handle: thick,
                  color: widget.color,
                  background: widget.backgroundColor,
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.fraction,
    required this.thick,
    required this.handle,
    required this.color,
    required this.background,
  });

  final double fraction;
  final bool thick;
  final bool handle;
  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final height = thick ? 4.0 : 2.0;
    final y = size.height - height - 2;
    final track = RRect.fromLTRBR(
        0, y, size.width, y + height, Radius.circular(height));
    canvas.drawRRect(track, Paint()..color = background);
    final x = size.width * fraction;
    canvas.drawRRect(
      RRect.fromLTRBR(0, y, x, y + height, Radius.circular(height)),
      Paint()..color = color.withValues(alpha: thick ? 1 : 0.85),
    );
    if (handle) {
      canvas.drawCircle(Offset(x, y + height / 2), 6.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.fraction != fraction ||
      old.thick != thick ||
      old.handle != handle ||
      old.color != color;
}

/// TikTok-style "paused" mark: a large, translucent play triangle that pops
/// in.
class SwipePausedIndicator extends StatelessWidget {
  const SwipePausedIndicator({super.key, required this.visible, this.size = 86});

  final bool visible;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: AnimatedScale(
          scale: visible ? 1 : 1.35,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: Icon(
            Icons.play_arrow_rounded,
            size: size,
            color: Colors.white.withValues(alpha: 0.6),
            shadows: const [Shadow(blurRadius: 16, color: Color(0x66000000))],
          ),
        ),
      ),
    );
  }
}

/// The pill shown while a video plays faster because it is being held.
class SwipeSpeedBadge extends StatelessWidget {
  const SwipeSpeedBadge({super.key, required this.visible, this.speed = 2});

  final bool visible;
  final double speed;

  @override
  Widget build(BuildContext context) {
    final label = speed == speed.roundToDouble()
        ? speed.toStringAsFixed(0)
        : speed.toString();
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('${label}x',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14)),
            const SizedBox(width: 4),
            const Icon(Icons.fast_forward_rounded, color: Colors.white, size: 18),
          ]),
        ),
      ),
    );
  }
}

/// Lets the user pick a playback speed (TikTok's "Speed" option).
Future<void> showSwipeSpeedSheet(
  BuildContext context, {
  required double current,
  required ValueChanged<double> onSelected,
  List<double> speeds = const [0.5, 1, 1.5, 2],
  String title = 'Playback speed',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final speed in speeds)
            ListTile(
              title: Text(speed == 1 ? 'Normal' : '${speed}x'),
              trailing: speed == current ? const Icon(Icons.check_rounded) : null,
              onTap: () {
                Navigator.of(context).pop();
                onSelected(speed);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
