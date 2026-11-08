import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The shapes drawn by [SwipeReelIcon].
enum SwipeReelGlyph {
  /// Heart (outline or filled).
  heart,

  /// Instagram's round speech bubble.
  bubble,

  /// TikTok's filled oval bubble with three dots.
  bubbleDots,

  /// Instagram's paper plane ("Send").
  paperPlane,

  /// TikTok's curved forward arrow ("Share").
  shareArrow,

  /// Bookmark ("Save" / "Favorites").
  bookmark,

  /// Three horizontal dots.
  more,
}

/// A vector icon in the style of short-video apps, drawn from paths (no
/// font): crisp at any size, outline or filled, with a soft shadow that
/// keeps it readable on bright videos.
class SwipeReelIcon extends StatelessWidget {
  const SwipeReelIcon(
    this.glyph, {
    super.key,
    this.size = 30,
    this.color = Colors.white,
    this.filled = false,
    this.strokeWidth,
    this.shadow = true,
  });

  final SwipeReelGlyph glyph;
  final double size;
  final Color color;

  /// Solid shape instead of an outline.
  final bool filled;

  /// Outline width in a 24-unit box (default 1.9, like Instagram).
  final double? strokeWidth;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _GlyphPainter(
          glyph: glyph,
          color: color,
          filled: filled,
          strokeWidth: strokeWidth ?? 1.9,
          shadow: shadow,
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.filled,
    required this.strokeWidth,
    required this.shadow,
  });

  final SwipeReelGlyph glyph;
  final Color color;
  final bool filled;
  final double strokeWidth;
  final bool shadow;

  static Path heart() => Path()
    ..moveTo(12, 20.6)
    ..cubicTo(6.2, 16.4, 2.4, 12.9, 2.4, 8.6)
    ..cubicTo(2.4, 5.6, 4.7, 3.4, 7.5, 3.4)
    ..cubicTo(9.4, 3.4, 11, 4.4, 12, 6.1)
    ..cubicTo(13, 4.4, 14.6, 3.4, 16.5, 3.4)
    ..cubicTo(19.3, 3.4, 21.6, 5.6, 21.6, 8.6)
    ..cubicTo(21.6, 12.9, 17.8, 16.4, 12, 20.6)
    ..close();

  static Path bubble() {
    // A circle with a short tail at the bottom left.
    const c = Offset(12, 11.6);
    const r = 9.0;
    double rad(double deg) => deg * math.pi / 180;
    final rect = Rect.fromCircle(center: c, radius: r);
    return Path()
      ..moveTo(2.6, 21.2)
      ..lineTo(c.dx + r * math.cos(rad(118)), c.dy + r * math.sin(rad(118)))
      ..arcTo(rect, rad(118), -rad(306), false)
      ..close();
  }

  static Path bubbleOval() {
    final rect = Rect.fromCenter(center: const Offset(12, 11), width: 21, height: 17.4);
    return Path()
      ..addOval(rect)
      ..moveTo(15.5, 18.6)
      ..lineTo(19.8, 22)
      ..lineTo(18.6, 17.2)
      ..close();
  }

  static Path paperPlane() => Path()
    ..moveTo(21.6, 2.6)
    ..lineTo(2.4, 9.7)
    ..lineTo(10.1, 13.3)
    ..lineTo(13.6, 21.4)
    ..close()
    ..moveTo(10.1, 13.3)
    ..lineTo(21.6, 2.6);

  static Path shareArrow() => Path()
    ..moveTo(13.2, 3.4)
    ..lineTo(22.2, 11.6)
    ..lineTo(13.2, 19.8)
    ..lineTo(13.2, 15.2)
    ..cubicTo(7.9, 15.0, 4.6, 16.7, 1.9, 20.9)
    ..cubicTo(2.6, 14.2, 6.6, 9.4, 13.2, 8.4)
    ..close();

  static Path bookmark() => Path()
    ..moveTo(5.4, 3.2)
    ..lineTo(18.6, 3.2)
    ..lineTo(18.6, 21.1)
    ..lineTo(12, 15.3)
    ..lineTo(5.4, 21.1)
    ..close();

  Path _path() => switch (glyph) {
        SwipeReelGlyph.heart => heart(),
        SwipeReelGlyph.bubble => bubble(),
        SwipeReelGlyph.bubbleDots => bubbleOval(),
        SwipeReelGlyph.paperPlane => paperPlane(),
        SwipeReelGlyph.shareArrow => shareArrow(),
        SwipeReelGlyph.bookmark => bookmark(),
        SwipeReelGlyph.more => Path()
          ..addOval(Rect.fromCircle(center: const Offset(4.6, 12), radius: 1.9))
          ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 1.9))
          ..addOval(Rect.fromCircle(center: const Offset(19.4, 12), radius: 1.9)),
      };

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.scale(scale);
    final path = _path();
    // Filled glyphs by nature (dots, TikTok shapes) ignore `filled: false`.
    final solid = filled ||
        glyph == SwipeReelGlyph.more ||
        glyph == SwipeReelGlyph.bubbleDots ||
        glyph == SwipeReelGlyph.shareArrow;
    final style = solid ? PaintingStyle.fill : PaintingStyle.stroke;

    if (shadow) {
      canvas.drawPath(
        path.shift(const Offset(0, 0.6)),
        Paint()
          ..style = style
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0x55000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.4),
      );
    }

    if (glyph == SwipeReelGlyph.bubbleDots) {
      // Punch the three dots out of the bubble.
      canvas.saveLayer(const Rect.fromLTWH(-2, -2, 28, 28), Paint());
      canvas.drawPath(path, Paint()..color = color);
      final clear = Paint()..blendMode = ui.BlendMode.clear;
      for (final x in [7.2, 12.0, 16.8]) {
        canvas.drawCircle(Offset(x, 11), 1.55, clear);
      }
      canvas.restore();
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..style = style
          ..color = color
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.filled != filled ||
      old.strokeWidth != strokeWidth ||
      old.shadow != shadow;
}

/// Builds the icon of an action button. [active] is `true` for a liked /
/// saved item; [color] and [size] come from the theme.
typedef SwipeIconBuilder = Widget Function(
    BuildContext context, bool active, Color color, double size);

/// The icons of the action rail. Use a preset or mix your own:
///
/// ```dart
/// SwipeReelIcons.instagram.copyWith(
///   share: (context, active, color, size) => Icon(Icons.ios_share, color: color, size: size),
/// )
/// ```
class SwipeReelIcons {
  const SwipeReelIcons({
    required this.like,
    required this.comment,
    required this.share,
    required this.save,
    required this.more,
  });

  final SwipeIconBuilder like;
  final SwipeIconBuilder comment;
  final SwipeIconBuilder share;
  final SwipeIconBuilder save;
  final SwipeIconBuilder more;

  /// Outline icons: heart, round bubble, paper plane, bookmark, dots.
  static const instagram = SwipeReelIcons(
    like: _igLike,
    comment: _igComment,
    share: _igShare,
    save: _igSave,
    more: _more,
  );

  /// Solid icons: heart, dotted bubble, curved arrow, bookmark, dots.
  static const tiktok = SwipeReelIcons(
    like: _ttLike,
    comment: _ttComment,
    share: _ttShare,
    save: _ttSave,
    more: _more,
  );

  /// Flutter's Material icons.
  static const material = SwipeReelIcons(
    like: _mLike,
    comment: _mComment,
    share: _mShare,
    save: _mSave,
    more: _mMore,
  );

  SwipeReelIcons copyWith({
    SwipeIconBuilder? like,
    SwipeIconBuilder? comment,
    SwipeIconBuilder? share,
    SwipeIconBuilder? save,
    SwipeIconBuilder? more,
  }) =>
      SwipeReelIcons(
        like: like ?? this.like,
        comment: comment ?? this.comment,
        share: share ?? this.share,
        save: save ?? this.save,
        more: more ?? this.more,
      );

  static Widget _igLike(BuildContext c, bool active, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.heart,
          size: size, color: color, filled: active);
  static Widget _igComment(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.bubble, size: size, color: color);
  static Widget _igShare(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.paperPlane, size: size, color: color);
  static Widget _igSave(BuildContext c, bool active, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.bookmark,
          size: size, color: color, filled: active);
  static Widget _more(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.more, size: size * 0.9, color: color);

  static Widget _ttLike(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.heart,
          size: size, color: color, filled: true);
  static Widget _ttComment(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.bubbleDots, size: size, color: color);
  static Widget _ttShare(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.shareArrow, size: size, color: color);
  static Widget _ttSave(BuildContext c, bool a, Color color, double size) =>
      SwipeReelIcon(SwipeReelGlyph.bookmark,
          size: size, color: color, filled: true);

  static const _shadows = [Shadow(blurRadius: 8, color: Color(0x99000000))];
  static Widget _mLike(BuildContext c, bool active, Color color, double size) =>
      Icon(active ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: size, color: color, shadows: _shadows);
  static Widget _mComment(BuildContext c, bool a, Color color, double size) =>
      Icon(Icons.mode_comment_outlined,
          size: size, color: color, shadows: _shadows);
  static Widget _mShare(BuildContext c, bool a, Color color, double size) =>
      Icon(Icons.send_outlined, size: size, color: color, shadows: _shadows);
  static Widget _mSave(BuildContext c, bool active, Color color, double size) =>
      Icon(active ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          size: size, color: color, shadows: _shadows);
  static Widget _mMore(BuildContext c, bool a, Color color, double size) =>
      Icon(Icons.more_horiz_rounded, size: size, color: color, shadows: _shadows);
}
