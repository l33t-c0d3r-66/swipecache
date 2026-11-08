import 'package:flutter/foundation.dart';

/// The person who posted a reel.
@immutable
class SwipeReelAuthor {
  const SwipeReelAuthor({
    required this.name,
    this.id,
    this.avatarUrl,
    this.isVerified = false,
    this.isFollowing = false,
  });

  final String? id;

  /// Shown next to the avatar (e.g. the username).
  final String name;

  /// Profile picture. Initials are shown when `null` or while loading.
  final String? avatarUrl;
  final bool isVerified;
  final bool isFollowing;

  SwipeReelAuthor copyWith({
    String? name,
    String? avatarUrl,
    bool? isVerified,
    bool? isFollowing,
  }) =>
      SwipeReelAuthor(
        id: id,
        name: name ?? this.name,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        isVerified: isVerified ?? this.isVerified,
        isFollowing: isFollowing ?? this.isFollowing,
      );
}

/// The audio track of a reel.
@immutable
class SwipeReelMusic {
  const SwipeReelMusic({required this.title, this.artist, this.coverUrl});

  final String title;
  final String? artist;

  /// Shown in the spinning disc. The author's avatar is used when `null`.
  final String? coverUrl;

  String get label => artist == null ? title : '$artist · $title';
}

/// Everything the built-in reel UI shows for one item: author, caption,
/// music, counters and the viewer's like/save/follow state.
///
/// Attach it to a [SwipeSource] with `reel:`; update it with
/// `SwipeFeedController.updateReel` (the built-in buttons do this for you).
@immutable
class SwipeReelData {
  const SwipeReelData({
    this.author,
    this.caption,
    this.music,
    this.likeCount = 0,
    this.commentCount = 0,
    this.shareCount = 0,
    this.isLiked = false,
    this.isSaved = false,
    this.shareUrl,
    this.location,
  });

  final SwipeReelAuthor? author;
  final String? caption;
  final SwipeReelMusic? music;
  final int likeCount;
  final int commentCount;
  final int shareCount;
  final bool isLiked;
  final bool isSaved;

  /// Link copied by the default share sheet.
  final String? shareUrl;
  final String? location;

  SwipeReelData copyWith({
    SwipeReelAuthor? author,
    String? caption,
    SwipeReelMusic? music,
    int? likeCount,
    int? commentCount,
    int? shareCount,
    bool? isLiked,
    bool? isSaved,
    String? shareUrl,
    String? location,
  }) =>
      SwipeReelData(
        author: author ?? this.author,
        caption: caption ?? this.caption,
        music: music ?? this.music,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        shareCount: shareCount ?? this.shareCount,
        isLiked: isLiked ?? this.isLiked,
        isSaved: isSaved ?? this.isSaved,
        shareUrl: shareUrl ?? this.shareUrl,
        location: location ?? this.location,
      );
}

/// One comment in the built-in comments sheet.
@immutable
class SwipeComment {
  const SwipeComment({
    required this.id,
    required this.author,
    required this.text,
    this.createdAt,
    this.likeCount = 0,
    this.isLiked = false,
    this.replyCount = 0,
  });

  final String id;
  final SwipeReelAuthor author;
  final String text;
  final DateTime? createdAt;
  final int likeCount;
  final bool isLiked;
  final int replyCount;

  SwipeComment copyWith({int? likeCount, bool? isLiked}) => SwipeComment(
        id: id,
        author: author,
        text: text,
        createdAt: createdAt,
        likeCount: likeCount ?? this.likeCount,
        isLiked: isLiked ?? this.isLiked,
        replyCount: replyCount,
      );
}

/// A page of comments returned by [SwipeCommentsDelegate.load].
@immutable
class SwipeCommentPage {
  const SwipeCommentPage(this.comments, {this.nextCursor});

  final List<SwipeComment> comments;

  /// Pass back to `load` for the next page; `null` when there are no more.
  final String? nextCursor;
}

/// Short counter text as in short-video apps: 999, 1.2K, 3.4M, 1.1B.
String formatSwipeCount(int value) {
  if (value < 1000) return '$value';
  String short(double v, String unit) {
    final text = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}$unit';
  }

  if (value < 1000000) return short(value / 1000, 'K');
  if (value < 1000000000) return short(value / 1000000, 'M');
  return short(value / 1000000000, 'B');
}

/// "now", "5m", "3h", "2d", "4w" – compact relative time for comments.
String formatSwipeAge(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${diff.inDays ~/ 7}w';
}
