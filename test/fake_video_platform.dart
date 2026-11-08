import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// In-memory video platform: every player initialises instantly (or fails
/// for URLs containing `fail`).
class FakeVideoPlatform extends VideoPlayerPlatform {
  int _nextId = 1;
  final Map<int, StreamController<VideoEvent>> _streams = {};
  final Map<int, String> uris = {};
  final Set<int> playing = {};
  final Set<int> disposed = {};
  final Map<int, Duration> positions = {};
  int created = 0;

  /// When set, players stay initialising until [releaseInit].
  bool holdInit = false;
  final List<int> _held = [];

  void releaseInit() {
    for (final id in _held) {
      _emitInitialized(id);
    }
    _held.clear();
  }

  void _emitInitialized(int id) {
    // ignore: close_sinks
    final controller = _streams[id];
    if (controller == null || controller.isClosed) return;
    controller.add(VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 10),
      size: const Size(1080, 1920),
    ));
  }

  /// Simulates a runtime playback failure (e.g. network loss). Like
  /// ExoPlayer/AVPlayer, the native player stops when it errors.
  void failPlayback(int id) {
    playing.remove(id);
    _streams[id]?.addError(
        PlatformException(code: 'VideoError', message: 'network lost'));
  }

  Iterable<int> get alive => uris.keys.where((id) => !disposed.contains(id));

  String? uriOf(int id) => uris[id];

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => _create(dataSource.uri);

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      _create(options.dataSource.uri);

  int _create(String? uri) {
    final id = _nextId++;
    created++;
    uris[id] = uri ?? '';
    _streams[id] = StreamController<VideoEvent>.broadcast(onListen: () {
      // ignore: close_sinks
      final controller = _streams[id]!;
      if ((uri ?? '').contains('fail')) {
        controller.addError(
            PlatformException(code: 'VideoError', message: 'decode error'));
      } else if (holdInit) {
        _held.add(id);
      } else {
        _emitInitialized(id);
      }
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    playing.remove(playerId);
    unawaited(_streams[playerId]?.close());
  }

  @override
  Future<void> play(int playerId) async => playing.add(playerId);

  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      positions[playerId] = position;

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.expand();

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}
