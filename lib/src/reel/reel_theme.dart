import 'package:flutter/material.dart';

import 'reel_icons.dart';

/// Layout family of the reel UI.
enum SwipeReelStyle {
  /// Outline icons; author row with a Follow button at the bottom.
  instagram,

  /// Solid icons; avatar with a "+" follow badge on top of the action rail.
  tiktok,
}

/// Look of the built-in reel UI. Start from a preset and override only what
/// you need:
///
/// ```dart
/// SwipeReelTheme.instagram(likeColor: Colors.pink)
/// SwipeReelTheme.tiktok()
/// const SwipeReelTheme(icons: SwipeReelIcons.material) // Material icons
/// ```
@immutable
class SwipeReelTheme {
  const SwipeReelTheme({
    this.style = SwipeReelStyle.instagram,
    this.icons = SwipeReelIcons.instagram,
    this.saveActiveColor,
    this.foreground = Colors.white,
    this.likeColor = const Color(0xFFFF3040),
    this.verifiedColor = const Color(0xFF3897F0),
    this.iconSize = 28,
    this.actionSpacing = 20,
    this.labelStyle = const TextStyle(
        fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
    this.nameStyle = const TextStyle(
        fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
    this.captionStyle =
        const TextStyle(fontSize: 14, height: 1.35, color: Colors.white),
    this.musicStyle = const TextStyle(fontSize: 13, color: Colors.white),
    this.shadows = const [Shadow(blurRadius: 8, color: Color(0x99000000))],
    this.showGradient = true,
    this.gradientColor = const Color(0xAA000000),
    this.padding = const EdgeInsets.fromLTRB(14, 0, 10, 22),
    this.avatarSize = 34,
    this.captionMaxLines = 2,
  });

  /// Instagram-like (default) or TikTok-like layout.
  final SwipeReelStyle style;

  /// Icons of the action rail.
  final SwipeReelIcons icons;

  /// Colour of a saved bookmark (TikTok: yellow). `null` = [foreground].
  final Color? saveActiveColor;

  /// Instagram Reels look (the default).
  const SwipeReelTheme.instagram({
    Color likeColor = const Color(0xFFFF3040),
    double iconSize = 28,
    SwipeReelIcons icons = SwipeReelIcons.instagram,
  }) : this(likeColor: likeColor, iconSize: iconSize, icons: icons);

  /// TikTok look: solid icons, pink likes, yellow saves, follow badge on the
  /// avatar at the top of the rail.
  const SwipeReelTheme.tiktok({
    Color likeColor = const Color(0xFFFE2C55),
    double iconSize = 36,
    SwipeReelIcons icons = SwipeReelIcons.tiktok,
  }) : this(
          style: SwipeReelStyle.tiktok,
          icons: icons,
          likeColor: likeColor,
          saveActiveColor: const Color(0xFFFACE15),
          iconSize: iconSize,
          actionSpacing: 16,
          avatarSize: 46,
          nameStyle: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
        );

  /// Icons and text.
  final Color foreground;

  /// Filled heart (like button and double-tap burst).
  final Color likeColor;
  final Color verifiedColor;
  final double iconSize;

  /// Vertical gap between the action buttons.
  final double actionSpacing;
  final TextStyle labelStyle;
  final TextStyle nameStyle;
  final TextStyle captionStyle;
  final TextStyle musicStyle;

  /// Keeps white icons and text readable on bright videos.
  final List<Shadow> shadows;

  /// A dark gradient behind the bottom texts.
  final bool showGradient;
  final Color gradientColor;

  /// Space around the bottom block (above the safe area).
  final EdgeInsets padding;
  final double avatarSize;

  /// Caption lines shown before "more".
  final int captionMaxLines;

  SwipeReelTheme copyWith({
    SwipeReelStyle? style,
    SwipeReelIcons? icons,
    Color? saveActiveColor,
    Color? foreground,
    Color? likeColor,
    double? iconSize,
    double? actionSpacing,
    TextStyle? labelStyle,
    TextStyle? nameStyle,
    TextStyle? captionStyle,
    TextStyle? musicStyle,
    bool? showGradient,
    EdgeInsets? padding,
    int? captionMaxLines,
  }) =>
      SwipeReelTheme(
        style: style ?? this.style,
        icons: icons ?? this.icons,
        saveActiveColor: saveActiveColor ?? this.saveActiveColor,
        foreground: foreground ?? this.foreground,
        likeColor: likeColor ?? this.likeColor,
        verifiedColor: verifiedColor,
        iconSize: iconSize ?? this.iconSize,
        actionSpacing: actionSpacing ?? this.actionSpacing,
        labelStyle: labelStyle ?? this.labelStyle,
        nameStyle: nameStyle ?? this.nameStyle,
        captionStyle: captionStyle ?? this.captionStyle,
        musicStyle: musicStyle ?? this.musicStyle,
        shadows: shadows,
        showGradient: showGradient ?? this.showGradient,
        gradientColor: gradientColor,
        padding: padding ?? this.padding,
        avatarSize: avatarSize,
        captionMaxLines: captionMaxLines ?? this.captionMaxLines,
      );
}
