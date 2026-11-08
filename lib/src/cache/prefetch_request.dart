import 'package:video_player/video_player.dart' show VideoFormat;

/// A request to warm the cache for one video.
class PrefetchRequest {
  const PrefetchRequest(
    this.url, {
    this.headers,
    this.headBytes,
    this.priority = 0,
    this.formatHint,
  });

  final Uri url;
  final Map<String, String>? headers;

  /// Bytes from the start of the video to cache. `null` uses the default.
  /// For HLS this is a budget for the first segments.
  final int? headBytes;

  /// Lower runs first.
  final int priority;

  /// Marks an HLS/DASH stream whose URL has no `.m3u8`/`.mpd` extension.
  final VideoFormat? formatHint;
}
