import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import '../reel/reel_data.dart';

/// One item of a feed.
@immutable
class SwipeSource {
  const SwipeSource({
    required this.id,
    required this.url,
    this.thumbnailUrl,
    this.headers,
    this.data,
    this.formatHint,
    this.reel,
  });

  /// Stable identifier (e.g. the reel id). Used to keep players across list
  /// updates.
  final String id;

  /// Remote (http/https) video file, HLS playlist (`.m3u8`), DASH manifest
  /// (`.mpd`) or `file://` URL.
  final String url;

  final String? thumbnailUrl;

  /// HTTP headers sent to the origin (e.g. auth).
  final Map<String, String>? headers;

  /// Arbitrary payload, e.g. your own model object.
  final Object? data;

  /// Set to [VideoFormat.hls] or [VideoFormat.dash] for streams whose URL
  /// does not end in `.m3u8` / `.mpd`. Detected automatically otherwise.
  final VideoFormat? formatHint;

  /// Author, caption, music and counters shown by the built-in reel UI
  /// (`SwipeFeed(reel: SwipeReelOptions(...))`).
  final SwipeReelData? reel;

  /// A copy with other display data. `id` and `url` never change, so the
  /// player of the item is kept.
  SwipeSource copyWith({
    String? thumbnailUrl,
    Map<String, String>? headers,
    Object? data,
    SwipeReelData? reel,
  }) =>
      SwipeSource(
        id: id,
        url: url,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        headers: headers ?? this.headers,
        data: data ?? this.data,
        formatHint: formatHint,
        reel: reel ?? this.reel,
      );

  @override
  bool operator ==(Object other) =>
      other is SwipeSource && other.id == id && other.url == url;

  @override
  int get hashCode => Object.hash(id, url);

  @override
  String toString() => 'SwipeSource($id)';
}
