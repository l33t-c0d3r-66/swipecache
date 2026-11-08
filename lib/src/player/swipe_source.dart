import 'package:flutter/foundation.dart';

/// One item of a feed.
@immutable
class SwipeSource {
  const SwipeSource({
    required this.id,
    required this.url,
    this.thumbnailUrl,
    this.headers,
    this.data,
  });

  /// Stable identifier (e.g. the reel id). Used to keep players across list
  /// updates.
  final String id;

  /// Remote (http/https) or `file://` video URL.
  final String url;

  final String? thumbnailUrl;

  /// HTTP headers sent to the origin (e.g. auth).
  final Map<String, String>? headers;

  /// Arbitrary payload, e.g. your own model object.
  final Object? data;

  @override
  bool operator ==(Object other) =>
      other is SwipeSource && other.id == id && other.url == url;

  @override
  int get hashCode => Object.hash(id, url);

  @override
  String toString() => 'SwipeSource($id)';
}
