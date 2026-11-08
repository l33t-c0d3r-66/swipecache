import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'reel_data.dart';
import 'reel_icons.dart';
import 'reel_theme.dart';

/// A tap area that reacts immediately, even inside a feed item with
/// double-tap-to-like (a plain `GestureDetector` would wait ~300 ms to rule
/// out a double tap). Use it for your own buttons on top of the video.
class SwipeTapTarget extends StatelessWidget {
  const SwipeTapTarget({
    super.key,
    required this.onTap,
    required this.child,
    this.behavior = HitTestBehavior.opaque,
  });

  final VoidCallback? onTap;
  final Widget child;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return RawGestureDetector(
      behavior: behavior,
      gestures: {
        _EagerTapRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerTapRecognizer>(
          _EagerTapRecognizer.new,
          (recognizer) => recognizer.onTap = onTap,
        ),
      },
      child: child,
    );
  }
}

/// Claims the gesture as soon as the finger lifts instead of waiting for
/// competing double-tap recognizers to time out.
class _EagerTapRecognizer extends TapGestureRecognizer {
  @override
  void handlePrimaryPointer(PointerEvent event) {
    if (event is PointerUpEvent) resolve(GestureDisposition.accepted);
    super.handlePrimaryPointer(event);
  }
}

/// An icon with a counter/label below it, as in the right-hand action rail.
/// Bounces when tapped.
class SwipeActionButton extends StatefulWidget {
  const SwipeActionButton({
    super.key,
    this.icon,
    this.iconBuilder,
    this.activeIcon,
    this.isActive = false,
    this.activeColor,
    this.label,
    this.onTap,
    this.semanticLabel,
    this.theme = const SwipeReelTheme(),
    this.iconRotation = 0,
  }) : assert(icon != null || iconBuilder != null,
            'Give an icon or an iconBuilder');

  /// A font icon...
  final IconData? icon;

  /// ...or any widget, e.g. a [SwipeReelIcon] or your own image. Wins over
  /// [icon].
  final SwipeIconBuilder? iconBuilder;

  /// Shown instead of [icon] when [isActive] (e.g. a filled bookmark).
  final IconData? activeIcon;
  final bool isActive;
  final Color? activeColor;

  /// Text under the icon, usually a count from [formatSwipeCount].
  final String? label;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final SwipeReelTheme theme;

  /// Turns of rotation applied to the icon (the share plane is tilted).
  final double iconRotation;

  @override
  State<SwipeActionButton> createState() => _SwipeActionButtonState();
}

class _SwipeActionButtonState extends State<SwipeActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.28), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.28, end: 0.92), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 0.92, end: 1), weight: 30),
  ]).animate(CurvedAnimation(parent: _bounce, curve: Curves.easeOut));

  @override
  void didUpdateWidget(SwipeActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pop when switched on (like, save), as users expect.
    if (widget.isActive && !oldWidget.isActive) _bounce.forward(from: 0);
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final active = widget.isActive;
    final color =
        active ? (widget.activeColor ?? theme.foreground) : theme.foreground;
    Widget icon = widget.iconBuilder != null
        ? widget.iconBuilder!(context, active, color, theme.iconSize)
        : Icon(
            active ? (widget.activeIcon ?? widget.icon) : widget.icon,
            size: theme.iconSize,
            color: color,
            shadows: theme.shadows,
          );
    if (widget.iconRotation != 0) {
      icon = Transform.rotate(angle: widget.iconRotation * 2 * math.pi, child: icon);
    }
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      value: widget.label,
      toggled: widget.activeIcon == null && widget.iconBuilder == null
          ? null
          : active,
      child: SwipeTapTarget(
        onTap: widget.onTap == null
            ? null
            : () {
                if (!_bounce.isAnimating) _bounce.forward(from: 0);
                widget.onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(scale: _scale, child: icon),
              if (widget.label != null) ...[
                const SizedBox(height: 4),
                Text(widget.label!,
                    style: theme.labelStyle.copyWith(
                        color: theme.foreground, shadows: theme.shadows)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Round profile picture with an initials fallback (also shown while the
/// image loads or when it fails).
class SwipeAvatar extends StatelessWidget {
  const SwipeAvatar({
    super.key,
    this.author,
    this.imageUrl,
    this.size = 34,
    this.borderColor = Colors.white,
  });

  final SwipeReelAuthor? author;

  /// Overrides `author.avatarUrl`.
  final String? imageUrl;
  final double size;
  final Color? borderColor;

  static const _palette = [
    Color(0xFF8E44AD),
    Color(0xFF2980B9),
    Color(0xFF16A085),
    Color(0xFFD35400),
    Color(0xFFC0392B),
    Color(0xFF7F8C8D),
  ];

  @override
  Widget build(BuildContext context) {
    final name = author?.name ?? '';
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'[\s._]+')).take(2).map((w) {
            return w.isEmpty ? '' : w[0].toUpperCase();
          }).join();
    final fallback = ColoredBox(
      color: _palette[name.hashCode.abs() % _palette.length],
      child: Center(
        child: Text(initials,
            style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w700)),
      ),
    );
    final url = imageUrl ?? author?.avatarUrl;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor!, width: 1.2),
      ),
      child: ClipOval(
        child: url == null
            ? fallback
            : Image.network(
                url,
                fit: BoxFit.cover,
                cacheWidth: (size * dpr).round(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : fallback,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

/// Avatar, name, verified badge and a Follow button.
class SwipeAuthorRow extends StatelessWidget {
  const SwipeAuthorRow({
    super.key,
    required this.author,
    this.onTap,
    this.onFollow,
    this.theme = const SwipeReelTheme(),
    this.followLabel = 'Follow',
  });

  final SwipeReelAuthor author;
  final VoidCallback? onTap;

  /// Shows a Follow button while not following. `null` hides it.
  final VoidCallback? onFollow;
  final SwipeReelTheme theme;
  final String followLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SwipeTapTarget(
            onTap: onTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwipeAvatar(author: author, size: theme.avatarSize),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    author.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.nameStyle.copyWith(
                        color: theme.foreground, shadows: theme.shadows),
                  ),
                ),
                if (author.isVerified) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.verified, size: 15, color: theme.verifiedColor),
                ],
              ],
            ),
          ),
        ),
        if (onFollow != null && !author.isFollowing) ...[
          const SizedBox(width: 10),
          Semantics(
            button: true,
            child: SwipeTapTarget(
              onTap: onFollow,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: theme.foreground.withValues(alpha: 0.85)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(followLabel,
                    style: TextStyle(
                        color: theme.foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A caption that shows a few lines with "more", and expands on tap.
/// `#hashtags` and `@mentions` are bold and tappable.
class SwipeCaption extends StatefulWidget {
  const SwipeCaption({
    super.key,
    required this.text,
    this.theme = const SwipeReelTheme(),
    this.moreLabel = 'more',
    this.onHashtagTap,
    this.onMentionTap,
  });

  final String text;
  final SwipeReelTheme theme;
  final String moreLabel;

  /// Called with the tag without `#`.
  final ValueChanged<String>? onHashtagTap;

  /// Called with the username without `@`.
  final ValueChanged<String>? onMentionTap;

  @override
  State<SwipeCaption> createState() => _SwipeCaptionState();
}

class _SwipeCaptionState extends State<SwipeCaption> {
  static final _token = RegExp(r'([#@][\w.\u00C0-\uFFFF]+)');
  bool _expanded = false;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TextSpan _spans(TextStyle style) {
    _disposeRecognizers();
    final children = <InlineSpan>[];
    var last = 0;
    for (final m in _token.allMatches(widget.text)) {
      if (m.start > last) {
        children.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      var token = m.group(0)!;
      // A trailing dot ends a sentence, it is not part of the tag.
      var trailing = '';
      while (token.endsWith('.')) {
        token = token.substring(0, token.length - 1);
        trailing += '.';
      }
      final value = token.substring(1);
      final onTap = token.startsWith('#')
          ? widget.onHashtagTap
          : widget.onMentionTap;
      TapGestureRecognizer? recognizer;
      if (onTap != null && value.isNotEmpty) {
        recognizer = TapGestureRecognizer()..onTap = () => onTap(value);
        _recognizers.add(recognizer);
      }
      children.add(TextSpan(
        text: token,
        style: const TextStyle(fontWeight: FontWeight.w700),
        recognizer: recognizer,
      ));
      if (trailing.isNotEmpty) children.add(TextSpan(text: trailing));
      last = m.end;
    }
    if (last < widget.text.length) {
      children.add(TextSpan(text: widget.text.substring(last)));
    }
    return TextSpan(style: style, children: children);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final style =
        theme.captionStyle.copyWith(color: theme.foreground, shadows: theme.shadows);
    final span = _spans(style);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: span,
        maxLines: theme.captionMaxLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();

      if (_expanded) {
        return SwipeTapTarget(
          onTap: () => setState(() => _expanded = false),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.35),
            child: SingleChildScrollView(child: Text.rich(span)),
          ),
        );
      }
      return SwipeTapTarget(
        onTap: overflows ? () => setState(() => _expanded = true) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(span,
                maxLines: theme.captionMaxLines,
                overflow: TextOverflow.ellipsis),
            if (overflows)
              Text(widget.moreLabel,
                  style: style.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.foreground.withValues(alpha: 0.8))),
          ],
        ),
      );
    });
  }
}

/// TikTok-style avatar for the top of the action rail: a round picture with
/// a red "+" badge to follow, which turns into a check once following.
class SwipeFollowAvatar extends StatelessWidget {
  const SwipeFollowAvatar({
    super.key,
    required this.author,
    this.onTap,
    this.onFollow,
    this.size = 46,
    this.badgeColor = const Color(0xFFFE2C55),
  });

  final SwipeReelAuthor author;
  final VoidCallback? onTap;

  /// Shows the "+" badge while not following. `null` hides it.
  final VoidCallback? onFollow;
  final double size;
  final Color badgeColor;

  @override
  Widget build(BuildContext context) {
    const badge = 20.0;
    return SizedBox(
      width: size,
      height: size + badge / 2,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          SwipeTapTarget(
            onTap: onTap,
            child: SwipeAvatar(author: author, size: size, borderColor: Colors.white),
          ),
          if (onFollow != null)
            Positioned(
              bottom: 0,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: author.isFollowing
                    ? const SizedBox(key: ValueKey('following'), width: badge)
                    : SwipeTapTarget(
                        key: const ValueKey('follow'),
                        onTap: onFollow,
                        child: Container(
                          width: badge,
                          height: badge,
                          decoration:
                              BoxDecoration(color: badgeColor, shape: BoxShape.circle),
                          child: const Icon(Icons.add_rounded,
                              size: 16, color: Colors.white),
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The fixed header above a reels feed: Instagram's "Reels" title with a
/// camera button, or TikTok's centred tabs with a search button. Give it to
/// `SwipeFeed(header: ...)`.
class SwipeReelTopBar extends StatelessWidget {
  const SwipeReelTopBar({
    super.key,
    this.style = SwipeReelStyle.instagram,
    this.title = 'Reels',
    this.tabs = const ['Following', 'For You'],
    this.selectedTab = 1,
    this.onTabSelected,
    this.onCamera,
    this.onSearch,
    this.leading,
    this.actions = const [],
    this.foreground = Colors.white,
  });

  final SwipeReelStyle style;

  /// Instagram style: the title on the left.
  final String title;

  /// TikTok style: the centred tabs.
  final List<String> tabs;
  final int selectedTab;
  final ValueChanged<int>? onTabSelected;

  /// Shows a camera button (Instagram style) when set.
  final VoidCallback? onCamera;

  /// Shows a search button (TikTok style) when set.
  final VoidCallback? onSearch;
  final Widget? leading;

  /// Extra buttons on the right.
  final List<Widget> actions;
  final Color foreground;

  static const _shadows = [Shadow(blurRadius: 8, color: Color(0x88000000))];

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconThemeData(color: foreground, size: 27, shadows: _shadows);
    if (style == SwipeReelStyle.tiktok) {
      return IconTheme(
        data: iconTheme,
        child: SizedBox(
          height: 48,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    SwipeTapTarget(
                      onTap: onTabSelected == null ? null : () => onTabSelected!(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(tabs[i],
                                style: TextStyle(
                                  color: i == selectedTab
                                      ? foreground
                                      : foreground.withValues(alpha: 0.65),
                                  fontSize: 17,
                                  fontWeight: i == selectedTab
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  shadows: _shadows,
                                )),
                            const SizedBox(height: 4),
                            Container(
                              width: 26,
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: i == selectedTab
                                    ? foreground
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              Positioned(left: 8, child: leading ?? const SizedBox()),
              Positioned(
                right: 4,
                child: Row(children: [
                  ...actions,
                  if (onSearch != null)
                    IconButton(
                        onPressed: onSearch,
                        icon: const Icon(Icons.search_rounded, size: 30)),
                ]),
              ),
            ],
          ),
        ),
      );
    }
    return IconTheme(
      data: iconTheme,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Text(title,
                style: TextStyle(
                  color: foreground,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  shadows: _shadows,
                )),
            const Spacer(),
            ...actions,
            if (onCamera != null)
              IconButton(
                  onPressed: onCamera,
                  icon: const Icon(Icons.photo_camera_outlined)),
          ],
        ),
      ),
    );
  }
}

/// Music note and a scrolling song title.
class SwipeMusicRow extends StatelessWidget {
  const SwipeMusicRow({
    super.key,
    required this.music,
    this.onTap,
    this.animate = true,
    this.theme = const SwipeReelTheme(),
  });

  final SwipeReelMusic music;
  final VoidCallback? onTap;

  /// Scrolls long titles (only for the playing item).
  final bool animate;
  final SwipeReelTheme theme;

  @override
  Widget build(BuildContext context) {
    final style =
        theme.musicStyle.copyWith(color: theme.foreground, shadows: theme.shadows);
    return SwipeTapTarget(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_note_rounded,
              size: 15, color: theme.foreground, shadows: theme.shadows),
          const SizedBox(width: 4),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: SwipeMarquee(text: music.label, style: style, animate: animate),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text that scrolls horizontally when it does not fit.
class SwipeMarquee extends StatefulWidget {
  const SwipeMarquee({
    super.key,
    required this.text,
    this.style,
    this.animate = true,
    this.velocity = 30,
    this.gap = 36,
  });

  final String text;
  final TextStyle? style;
  final bool animate;

  /// Logical pixels per second.
  final double velocity;
  final double gap;

  @override
  State<SwipeMarquee> createState() => _SwipeMarqueeState();
}

class _SwipeMarqueeState extends State<SwipeMarquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker = AnimationController(vsync: this);

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final width = painter.width;
      final height = painter.height;
      painter.dispose();
      final fits = width <= constraints.maxWidth;
      if (fits || !widget.animate) {
        if (_ticker.isAnimating) _ticker.stop();
        return Text(widget.text,
            style: widget.style, maxLines: 1, overflow: TextOverflow.ellipsis);
      }
      final distance = width + widget.gap;
      final duration =
          Duration(milliseconds: (distance / widget.velocity * 1000).round());
      if (_ticker.duration != duration || !_ticker.isAnimating) {
        _ticker
          ..duration = duration
          ..repeat();
      }
      return SizedBox(
        height: height,
        width: constraints.maxWidth,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _ticker,
            builder: (context, child) => Transform.translate(
              offset: Offset(-_ticker.value * distance, 0),
              child: child,
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.text, style: widget.style, maxLines: 1),
                  SizedBox(width: widget.gap),
                  Text(widget.text, style: widget.style, maxLines: 1),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// The spinning record at the bottom of the action rail.
class SwipeMusicDisc extends StatefulWidget {
  const SwipeMusicDisc({
    super.key,
    this.imageUrl,
    this.author,
    this.spinning = true,
    this.size = 30,
    this.onTap,
    this.circular = false,
  });

  /// A round vinyl (TikTok) instead of a rounded square (Instagram).
  final bool circular;

  final String? imageUrl;

  /// Its avatar is used when [imageUrl] is `null`.
  final SwipeReelAuthor? author;
  final bool spinning;
  final double size;
  final VoidCallback? onTap;

  @override
  State<SwipeMusicDisc> createState() => _SwipeMusicDiscState();
}

class _SwipeMusicDiscState extends State<SwipeMusicDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _spin.repeat();
  }

  @override
  void didUpdateWidget(SwipeMusicDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.spinning && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SwipeTapTarget(
      onTap: widget.onTap,
      child: RotationTransition(
        turns: _spin,
        child: Container(
          width: widget.size,
          height: widget.size,
          padding: widget.circular ? EdgeInsets.all(widget.size * 0.2) : null,
          decoration: BoxDecoration(
            color: widget.circular ? const Color(0xFF1C1C1C) : null,
            borderRadius:
                BorderRadius.circular(widget.size * (widget.circular ? 0.5 : 0.28)),
            border: widget.circular
                ? null
                : Border.all(color: Colors.white, width: 2),
          ),
          child: ClipRRect(
            borderRadius:
                BorderRadius.circular(widget.size * (widget.circular ? 0.5 : 0.2)),
            child: widget.imageUrl == null && widget.author == null
                ? const ColoredBox(
                    color: Color(0xFF333333),
                    child: Icon(Icons.music_note_rounded,
                        size: 16, color: Colors.white))
                : SwipeAvatar(
                    author: widget.author,
                    imageUrl: widget.imageUrl,
                    size: widget.circular ? widget.size * 0.6 : widget.size,
                    borderColor: null,
                  ),
          ),
        ),
      ),
    );
  }
}

/// A big heart that pops at [position] and fades away (double-tap like).
class SwipeHeartBurst extends StatefulWidget {
  const SwipeHeartBurst({
    super.key,
    required this.position,
    this.color = const Color(0xFFFF3040),
    this.size = 100,
    this.onDone,
  });

  final Offset position;
  final Color color;
  final double size;
  final VoidCallback? onDone;

  @override
  State<SwipeHeartBurst> createState() => _SwipeHeartBurstState();
}

class _SwipeHeartBurstState extends State<SwipeHeartBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward().whenComplete(() => widget.onDone?.call());

  // A slight random tilt, like the apps users know.
  late final double _tilt = (math.Random().nextDouble() - 0.5) * 0.5;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.2, end: 1.2)
              .chain(CurveTween(curve: Curves.easeOutBack)),
          weight: 25),
      TweenSequenceItem(tween: Tween(begin: 1.2, end: 1), weight: 10),
      TweenSequenceItem(tween: ConstantTween(1), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1, end: 1.4), weight: 25),
    ]).animate(_c);
    final opacity = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1), weight: 70),
      TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 30),
    ]).animate(_c);
    final rise = Tween<double>(begin: 0, end: -40)
        .chain(CurveTween(curve: const Interval(0.7, 1)))
        .animate(_c);
    return Positioned(
      left: widget.position.dx - widget.size / 2,
      top: widget.position.dy - widget.size / 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) => Opacity(
            opacity: opacity.value,
            child: Transform.translate(
              offset: Offset(0, rise.value),
              child: Transform.rotate(
                angle: _tilt,
                child: Transform.scale(scale: scale.value, child: child),
              ),
            ),
          ),
          child: Icon(Icons.favorite,
              size: widget.size,
              color: widget.color,
              shadows: const [Shadow(blurRadius: 18, color: Color(0x66000000))]),
        ),
      ),
    );
  }
}
