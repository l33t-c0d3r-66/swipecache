import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../util/logger.dart';
import '../widgets/swipe_item.dart';
import 'reel_data.dart';
import 'reel_sheets.dart';
import 'reel_theme.dart';
import 'reel_widgets.dart';

/// A callback for a reel button.
typedef SwipeReelCallback = FutureOr<void> Function(SwipeItem item);

/// A callback for an on/off button (like, save, follow) with the new value.
/// Return `false` or throw to undo the change in the UI (e.g. the request
/// failed); anything else keeps it.
typedef SwipeReelToggle = FutureOr<bool?> Function(SwipeItem item, bool value);

/// Builds a part of the reel layout. [actions] gives access to the built-in
/// behaviour (toggleLike, openComments, share...) for your own widgets.
typedef SwipeReelPartBuilder = Widget Function(
    BuildContext context, SwipeItem item, SwipeReelActions actions);

/// Wraps or replaces one button of the action rail. [button] is the
/// built-in button; return it, wrap it, or return something else.
typedef SwipeReelActionBuilder = Widget Function(
  BuildContext context,
  SwipeItem item,
  SwipeReelActionType type,
  Widget button,
  SwipeReelActions actions,
);

/// What a single tap on the video does.
enum SwipeTapAction {
  /// Mute / unmute with a speaker flash, as in Instagram Reels (hold to
  /// pause). The default.
  mute,

  /// Pause / resume, as in TikTok.
  pause,

  /// Nothing.
  none,
}

/// What holding the video does.
enum SwipeHoldAction {
  /// Pause while held and hide the UI (Instagram). The default.
  pause,

  /// Play faster while held, with a "2x" pill (TikTok).
  speedUp,

  /// Open the "…" menu (`onMore` / `moreOptions`), as TikTok's long press.
  menu,

  /// Nothing.
  none,
}

/// The kinds of buttons in the action rail.
enum SwipeReelActionType { like, comment, share, save, more, custom, widget }

/// Something the user did in the reel UI. Delivered to
/// [SwipeReelOptions.onEvent] – one place for analytics/logging.
enum SwipeReelEventType {
  like,
  unlike,
  doubleTapLike,
  save,
  unsave,
  follow,
  unfollow,
  openComments,
  commentPosted,
  share,
  openMore,
  authorTap,
  musicTap,
  hashtagTap,
  mentionTap,
  customAction,
  mute,
  unmute,
  pause,
  resume,

  /// Held to play faster (value: the speed).
  speedUp,

  /// The seek bar was dragged (value: the new position in seconds).
  seek,
}

class SwipeReelEvent {
  const SwipeReelEvent(this.type, this.item, {this.value});

  final SwipeReelEventType type;
  final SwipeItem item;

  /// The hashtag, username, custom action label or posted comment text.
  final String? value;

  @override
  String toString() =>
      'SwipeReelEvent(${type.name}, ${item.source.id}${value == null ? '' : ', $value'})';
}

/// One entry of the right-hand action rail. Use the built-ins
/// ([like], [comment], [share], [save], [more]) and your own:
///
/// ```dart
/// actions: [
///   SwipeReelAction.like,
///   SwipeReelAction.custom(icon: Icons.card_giftcard, label: 'Gift',
///       onTap: (item) => sendGift(item)),
///   SwipeReelAction.comment,
///   SwipeReelAction.share,
/// ]
/// ```
class SwipeReelAction {
  const SwipeReelAction._(this.type)
      : icon = null,
        iconBuilder = null,
        activeIcon = null,
        label = null,
        onTap = null,
        isActive = null,
        activeColor = null,
        builder = null;

  /// A button of your own: a font [icon] or any widget via [iconBuilder].
  const SwipeReelAction.custom({
    this.icon,
    this.iconBuilder,
    required SwipeReelCallback this.onTap,
    this.label,
    this.activeIcon,
    this.isActive,
    this.activeColor,
  })  : type = SwipeReelActionType.custom,
        builder = null,
        assert(icon != null || iconBuilder != null);

  /// Any widget in the rail.
  const SwipeReelAction.widget(Widget Function(BuildContext, SwipeItem) this.builder)
      : type = SwipeReelActionType.widget,
        icon = null,
        iconBuilder = null,
        activeIcon = null,
        label = null,
        onTap = null,
        isActive = null,
        activeColor = null;

  /// Heart with like count. Always shown.
  static const like = SwipeReelAction._(SwipeReelActionType.like);

  /// Opens comments. Shown when `onComment` or `comments` is set.
  static const comment = SwipeReelAction._(SwipeReelActionType.comment);

  /// Shown when `onShare`, `shareOptions` or a `shareUrl` is available.
  static const share = SwipeReelAction._(SwipeReelActionType.share);

  /// Bookmark. Always shown.
  static const save = SwipeReelAction._(SwipeReelActionType.save);

  /// "…" button. Shown when `onMore` or `moreOptions` is set.
  static const more = SwipeReelAction._(SwipeReelActionType.more);

  /// like, comment, share, save, more.
  static const defaults = [like, comment, share, save, more];

  final SwipeReelActionType type;
  final IconData? icon;
  final Widget Function(BuildContext context, bool active, Color color, double size)?
      iconBuilder;
  final IconData? activeIcon;
  final String? label;
  final SwipeReelCallback? onTap;
  final bool Function(SwipeItem item)? isActive;
  final Color? activeColor;
  final Widget Function(BuildContext, SwipeItem)? builder;
}

/// Turns on and configures the built-in reel UI of a `SwipeFeed`. Only set
/// what you need; every part can be replaced.
class SwipeReelOptions {
  const SwipeReelOptions({
    this.actions = SwipeReelAction.defaults,
    this.onLike,
    this.onSave,
    this.onFollow,
    this.onComment,
    this.comments,
    this.onShare,
    this.shareOptions,
    this.onMore,
    this.moreOptions,
    this.onAuthorTap,
    this.onMusicTap,
    this.onHashtagTap,
    this.onMentionTap,
    this.onEvent,
    this.doubleTapToLike = true,
    this.tapAction = SwipeTapAction.mute,
    this.holdAction = SwipeHoldAction.pause,
    this.holdEdgesToSpeedUp = false,
    this.holdSpeed = 2,
    this.showSeekBar = true,
    this.showMusicDisc = true,
    this.theme = const SwipeReelTheme(),
    this.actionBuilder,
    this.authorBuilder,
    this.captionBuilder,
    this.musicBuilder,
    this.actionsBuilder,
    this.topBuilder,
    this.bottomBuilder,
  });

  /// Buttons of the right-hand rail, top to bottom.
  final List<SwipeReelAction> actions;

  /// Like changed (button or double tap). The UI updates at once.
  final SwipeReelToggle? onLike;
  final SwipeReelToggle? onSave;

  /// Shows a Follow button (TikTok: "+" badge) while not following.
  final SwipeReelToggle? onFollow;

  /// Your own comments screen. Takes precedence over [comments].
  final SwipeReelCallback? onComment;

  /// Uses the built-in comments sheet for an item.
  final SwipeCommentsDelegate Function(SwipeItem item)? comments;

  /// Your own share action (e.g. `Share.share` from `share_plus`). Without
  /// it, a share sheet with "Copy link" (from `shareUrl`) and
  /// [shareOptions] opens.
  final SwipeReelCallback? onShare;
  final List<SwipeReelOption> Function(SwipeItem item)? shareOptions;

  /// Your own "…" action. Without it, [moreOptions] open in a sheet.
  final SwipeReelCallback? onMore;
  final List<SwipeReelOption> Function(SwipeItem item)? moreOptions;

  final SwipeReelCallback? onAuthorTap;
  final SwipeReelCallback? onMusicTap;

  /// A `#hashtag` in the caption was tapped (without the `#`).
  final void Function(SwipeItem item, String hashtag)? onHashtagTap;

  /// An `@mention` in the caption was tapped (without the `@`).
  final void Function(SwipeItem item, String username)? onMentionTap;

  /// Every user action, after it happened (for analytics).
  final void Function(SwipeReelEvent event)? onEvent;

  /// Double tap likes (never unlikes) and shows a heart.
  final bool doubleTapToLike;
  final SwipeTapAction tapAction;

  /// What holding the video does: pause (Instagram, default), speed up,
  /// open the menu, or nothing.
  final SwipeHoldAction holdAction;

  /// Holding the left or right fifth of the screen plays at [holdSpeed]
  /// (TikTok); the middle keeps [holdAction].
  final bool holdEdgesToSpeedUp;

  /// Speed while held with [SwipeHoldAction.speedUp].
  final double holdSpeed;

  /// Draggable progress bar at the bottom (thicker while paused).
  final bool showSeekBar;
  final bool showMusicDisc;
  final SwipeReelTheme theme;

  /// Wraps or replaces single buttons of the rail.
  final SwipeReelActionBuilder? actionBuilder;

  /// Replace parts of the layout.
  final SwipeReelPartBuilder? authorBuilder;
  final SwipeReelPartBuilder? captionBuilder;
  final SwipeReelPartBuilder? musicBuilder;

  /// Replaces the whole right-hand rail.
  final SwipeReelPartBuilder? actionsBuilder;

  /// Content at the top of each item (scrolls with it). For a fixed header
  /// use `SwipeFeed(header: ...)`.
  final SwipeReelPartBuilder? topBuilder;

  /// Extra content below the caption/music (tags, a product card...).
  final SwipeReelPartBuilder? bottomBuilder;
}

/// The built-in behaviour behind the reel buttons, for use in your own
/// widgets: like/save/follow update the UI immediately and roll back when
/// your callback returns `false` or throws.
class SwipeReelActions {
  SwipeReelActions(this.item, this.options);

  final SwipeItem item;
  final SwipeReelOptions options;

  /// Current reel data (reflects changes made since the last build).
  SwipeReelData get reel =>
      item.controller.sourceById(item.source.id)?.reel ?? item.reel;

  void _update(SwipeReelData Function(SwipeReelData r) change) =>
      item.controller.updateReel(item.source.id, change);

  /// Reports an event to [SwipeReelOptions.onEvent].
  void emit(SwipeReelEventType type, {String? value}) {
    try {
      options.onEvent?.call(SwipeReelEvent(type, item, value: value));
    } catch (error) {
      SwipeLog.e('onEvent failed', error);
    }
  }

  static Future<bool> _confirm(FutureOr<bool?> Function()? call) async {
    if (call == null) return true;
    try {
      return await call() != false;
    } catch (error) {
      SwipeLog.e('Reel action failed', error);
      return false;
    }
  }

  /// Toggles (or sets, with [value]) the like.
  Future<void> toggleLike({bool? value, bool fromDoubleTap = false}) async {
    final next = value ?? !reel.isLiked;
    if (next == reel.isLiked) return;
    int bump(int count, bool up) => math.max(0, count + (up ? 1 : -1));
    _update((r) => r.copyWith(isLiked: next, likeCount: bump(r.likeCount, next)));
    emit(fromDoubleTap
        ? SwipeReelEventType.doubleTapLike
        : next
            ? SwipeReelEventType.like
            : SwipeReelEventType.unlike);
    final ok = await _confirm(
        options.onLike == null ? null : () => options.onLike!(item, next));
    if (!ok) {
      _update((r) => r.isLiked != next
          ? r
          : r.copyWith(isLiked: !next, likeCount: bump(r.likeCount, !next)));
    }
  }

  Future<void> toggleSave() async {
    final next = !reel.isSaved;
    _update((r) => r.copyWith(isSaved: next));
    emit(next ? SwipeReelEventType.save : SwipeReelEventType.unsave);
    final ok = await _confirm(
        options.onSave == null ? null : () => options.onSave!(item, next));
    if (!ok) _update((r) => r.isSaved != next ? r : r.copyWith(isSaved: !next));
  }

  Future<void> toggleFollow() async {
    final author = reel.author;
    if (author == null) return;
    final next = !author.isFollowing;
    void set(bool following) => _update((r) => r.author == null
        ? r
        : r.copyWith(author: r.author!.copyWith(isFollowing: following)));
    set(next);
    emit(next ? SwipeReelEventType.follow : SwipeReelEventType.unfollow);
    final ok = await _confirm(
        options.onFollow == null ? null : () => options.onFollow!(item, next));
    if (!ok && reel.author?.isFollowing == next) set(!next);
  }

  bool get canComment => options.onComment != null || options.comments != null;

  bool get canShare =>
      options.onShare != null ||
      options.shareOptions != null ||
      reel.shareUrl != null;

  bool get canMore => options.onMore != null || options.moreOptions != null;

  Future<void> openComments(BuildContext context) async {
    emit(SwipeReelEventType.openComments);
    if (options.onComment != null) return options.onComment!(item);
    final delegate = options.comments?.call(item);
    if (delegate == null) return;
    await showSwipeCommentsSheet(
      context,
      delegate: delegate,
      commentCount: reel.commentCount,
      onSent: (comment) {
        _update((r) => r.copyWith(commentCount: r.commentCount + 1));
        emit(SwipeReelEventType.commentPosted, value: comment.text);
      },
    );
  }

  Future<void> share(BuildContext context) async {
    emit(SwipeReelEventType.share);
    if (options.onShare != null) return options.onShare!(item);
    await showSwipeShareSheet(
      context,
      link: reel.shareUrl,
      options: options.shareOptions?.call(item) ?? const [],
    );
  }

  Future<void> openMore(BuildContext context) async {
    emit(SwipeReelEventType.openMore);
    if (options.onMore != null) return options.onMore!(item);
    final list = options.moreOptions?.call(item);
    if (list == null || list.isEmpty) return;
    await showSwipeOptionsSheet(context, options: list);
  }

  void openAuthor() {
    emit(SwipeReelEventType.authorTap);
    options.onAuthorTap?.call(item);
  }

  void openMusic() {
    emit(SwipeReelEventType.musicTap);
    options.onMusicTap?.call(item);
  }

  void openHashtag(String tag) {
    emit(SwipeReelEventType.hashtagTap, value: tag);
    options.onHashtagTap?.call(item, tag);
  }

  void openMention(String username) {
    emit(SwipeReelEventType.mentionTap, value: username);
    options.onMentionTap?.call(item, username);
  }
}

/// The complete reel layer drawn above a video: action rail on the right;
/// author, caption and music at the bottom (Instagram or TikTok layout).
///
/// `SwipeFeed(reel: SwipeReelOptions(...))` draws it for you and adds the
/// gestures (tap to mute, double-tap like, hold to pause). It can also be
/// used inside an `overlayBuilder`.
class SwipeReelOverlay extends StatelessWidget {
  const SwipeReelOverlay({
    super.key,
    required this.item,
    this.options = const SwipeReelOptions(),
  });

  final SwipeItem item;
  final SwipeReelOptions options;

  @override
  Widget build(BuildContext context) {
    final actions = SwipeReelActions(item, options);
    final theme = options.theme;
    final tiktok = theme.style == SwipeReelStyle.tiktok;
    final reel = item.reel;
    final playing = item.isCurrent &&
        !item.controller.isUserPaused &&
        item.controller.isVisible;

    final author = reel.author;
    final hasAuthorTap = options.onAuthorTap != null || options.onEvent != null;
    final bottom = <Widget>[
      if (options.authorBuilder != null)
        options.authorBuilder!(context, item, actions)
      else if (author != null && tiktok)
        SwipeTapTarget(
          onTap: hasAuthorTap ? actions.openAuthor : null,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text('@${author.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.nameStyle
                      .copyWith(color: theme.foreground, shadows: theme.shadows)),
            ),
            if (author.isVerified) ...[
              const SizedBox(width: 4),
              Icon(Icons.verified, size: 15, color: theme.verifiedColor),
            ],
          ]),
        )
      else if (author != null)
        SwipeAuthorRow(
          author: author,
          theme: theme,
          onTap: hasAuthorTap ? actions.openAuthor : null,
          onFollow: options.onFollow == null ? null : actions.toggleFollow,
        ),
      if (options.captionBuilder != null)
        options.captionBuilder!(context, item, actions)
      else if (reel.caption != null && reel.caption!.isNotEmpty)
        SwipeCaption(
          key: ValueKey('caption-${item.source.id}'),
          text: reel.caption!,
          theme: theme,
          onHashtagTap: options.onHashtagTap == null && options.onEvent == null
              ? null
              : actions.openHashtag,
          onMentionTap: options.onMentionTap == null && options.onEvent == null
              ? null
              : actions.openMention,
        ),
      if (options.musicBuilder != null)
        options.musicBuilder!(context, item, actions)
      else if (reel.music != null)
        SwipeMusicRow(
          music: reel.music!,
          theme: theme,
          animate: playing,
          onTap: options.onMusicTap == null && options.onEvent == null
              ? null
              : actions.openMusic,
        ),
      if (options.bottomBuilder != null)
        options.bottomBuilder!(context, item, actions),
    ];

    return Stack(
      fit: StackFit.expand,
      children: [
        if (theme.showGradient)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: MediaQuery.sizeOf(context).height * 0.42,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      theme.gradientColor.withValues(alpha: 0),
                      theme.gradientColor
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (options.topBuilder != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
                bottom: false, child: options.topBuilder!(context, item, actions)),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: theme.padding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < bottom.length; i++) ...[
                          if (i > 0) SizedBox(height: tiktok ? 6 : 10),
                          bottom[i],
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  options.actionsBuilder?.call(context, item, actions) ??
                      SwipeReelActionRail(
                          item: item, options: options, actions: actions),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The right-hand column of buttons. Used by [SwipeReelOverlay]; usable on
/// its own in a custom layout.
class SwipeReelActionRail extends StatelessWidget {
  const SwipeReelActionRail({
    super.key,
    required this.item,
    required this.options,
    required this.actions,
  });

  final SwipeItem item;
  final SwipeReelOptions options;
  final SwipeReelActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = options.theme;
    final icons = theme.icons;
    final tiktok = theme.style == SwipeReelStyle.tiktok;
    final reel = item.reel;
    final playing = item.isCurrent &&
        !item.controller.isUserPaused &&
        item.controller.isVisible;
    // TikTok always shows numbers; Instagram hides zeros.
    String? count(int value) =>
        value > 0 || tiktok ? formatSwipeCount(value) : null;

    final buttons = <Widget>[];
    final author = reel.author;
    if (tiktok && author != null) {
      buttons.add(SwipeFollowAvatar(
        author: author,
        size: theme.avatarSize,
        badgeColor: theme.likeColor,
        onTap: actions.openAuthor,
        onFollow: options.onFollow == null ? null : actions.toggleFollow,
      ));
    }
    for (final action in options.actions) {
      final Widget? button = switch (action.type) {
        SwipeReelActionType.like => SwipeActionButton(
            iconBuilder: icons.like,
            isActive: reel.isLiked,
            activeColor: theme.likeColor,
            label: count(reel.likeCount),
            semanticLabel: 'Like',
            theme: theme,
            onTap: actions.toggleLike,
          ),
        SwipeReelActionType.comment => actions.canComment
            ? SwipeActionButton(
                iconBuilder: icons.comment,
                label: count(reel.commentCount),
                semanticLabel: 'Comments',
                theme: theme,
                onTap: () => actions.openComments(context),
              )
            : null,
        SwipeReelActionType.share => actions.canShare
            ? SwipeActionButton(
                iconBuilder: icons.share,
                label: count(reel.shareCount),
                semanticLabel: 'Share',
                theme: theme,
                onTap: () => actions.share(context),
              )
            : null,
        SwipeReelActionType.save => SwipeActionButton(
            iconBuilder: icons.save,
            isActive: reel.isSaved,
            activeColor: theme.saveActiveColor,
            semanticLabel: 'Save',
            theme: theme,
            onTap: actions.toggleSave,
          ),
        SwipeReelActionType.more => actions.canMore
            ? SwipeActionButton(
                iconBuilder: icons.more,
                semanticLabel: 'More options',
                theme: theme,
                onTap: () => actions.openMore(context),
              )
            : null,
        SwipeReelActionType.custom => SwipeActionButton(
            icon: action.icon,
            iconBuilder: action.iconBuilder,
            activeIcon: action.activeIcon,
            isActive: action.isActive?.call(item) ?? false,
            activeColor: action.activeColor,
            label: action.label,
            semanticLabel: action.label,
            theme: theme,
            onTap: () {
              actions.emit(SwipeReelEventType.customAction, value: action.label);
              action.onTap!(item);
            },
          ),
        SwipeReelActionType.widget => action.builder!(context, item),
      };
      if (button == null) continue;
      buttons.add(options.actionBuilder
              ?.call(context, item, action.type, button, actions) ??
          button);
    }
    final showDisc = options.showMusicDisc && (reel.music != null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) SizedBox(height: theme.actionSpacing),
          buttons[i],
        ],
        if (showDisc) ...[
          SizedBox(height: theme.actionSpacing),
          SwipeMusicDisc(
            imageUrl: reel.music!.coverUrl,
            author: reel.author,
            spinning: playing,
            size: tiktok ? 44 : 30,
            circular: tiktok,
            onTap: actions.openMusic,
          ),
        ],
      ],
    );
  }
}
