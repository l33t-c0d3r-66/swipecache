import 'package:video_player/video_player.dart';

/// Web: local files can not be opened; play the path as a URL.
VideoPlayerController fileController(
        String path, VideoPlayerOptions options) =>
    VideoPlayerController.networkUrl(Uri.parse(path),
        videoPlayerOptions: options);
