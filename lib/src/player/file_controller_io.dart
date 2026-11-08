import 'dart:io';

import 'package:video_player/video_player.dart';

VideoPlayerController fileController(
        String path, VideoPlayerOptions options) =>
    VideoPlayerController.file(File(path), videoPlayerOptions: options);
