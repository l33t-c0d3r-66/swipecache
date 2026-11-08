import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../cache/swipe_cache.dart';
import '../util/logger.dart';
import 'file_controller_stub.dart'
    if (dart.library.io) 'file_controller_io.dart';
import 'swipe_feed_config.dart';
import 'swipe_source.dart';

enum SwipePlayerStatus { idle, loading, ready, error, disposed }

/// Owns the [VideoPlayerController] of one feed item.
///
/// All operations are safe to call at any time, including during
/// initialisation and after disposal. A controller is owned from the moment
/// it is created, so a player disposed mid-initialisation can never leak a
/// decoder or start playing audio afterwards.
class SwipePlayer extends ChangeNotifier {
  SwipePlayer({
    required this.source,
    required SwipeCache cache,
    required SwipeFeedConfig config,
    bool muted = false,
    double speed = 1,
    this.onAutoplayBlocked,
  })  : _cache = cache,
        _config = config,
        _muted = muted,
        _speed = speed;

  final SwipeSource source;

  /// Called when a browser refused to autoplay with sound and the player
  /// fell back to muted playback (web only).
  final VoidCallback? onAutoplayBlocked;
  final SwipeCache _cache;
  final SwipeFeedConfig _config;

  VideoPlayerController? _controller;
  SwipePlayerStatus _status = SwipePlayerStatus.idle;
  Object? _error;
  Future<void>? _initFuture;
  bool _wantPlay = false;
  bool _muted;
  double _speed;
  bool _disposed = false;
  bool _servedByCache = false;
  bool _buffering = false;
  bool _hasFrame = false;
  bool _forceDirect = false;
  int _recoveries = 0;
  Duration? _initDuration;

  /// The controller, available once [status] is [SwipePlayerStatus.ready].
  VideoPlayerController? get controller =>
      _status == SwipePlayerStatus.ready ? _controller : null;

  SwipePlayerStatus get status => _status;
  Object? get error => _error;
  bool get isReady => _status == SwipePlayerStatus.ready;
  bool get isDisposed => _disposed;
  bool get wantsToPlay => _wantPlay;
  bool get isBuffering => _buffering;

  /// `true` once a decoded frame is guaranteed on screen: the video is
  /// paused at its first frame or has advanced while playing. Used to keep
  /// the thumbnail up until then (no black flash).
  bool get hasFrame => _hasFrame;

  /// Whether playback goes through the caching proxy.
  bool get servedByCache => _servedByCache;

  /// Time from [initialize] to a ready decoder.
  Duration? get initDuration => _initDuration;

  Future<void> initialize() {
    if (_disposed) return Future<void>.value();
    return _initFuture ??= _initLoop(Duration.zero);
  }

  Future<void> _initLoop(Duration startAt) async {
    _setStatus(SwipePlayerStatus.loading);
    final stopwatch = Stopwatch()..start();
    // Give an in-progress cache init a moment so the first video is cached too.
    await _cache.whenReady.timeout(const Duration(seconds: 2), onTimeout: () {});

    for (var attempt = 0; attempt <= _config.maxRetries; attempt++) {
      if (_disposed) return;
      final bypassCache =
          _forceDirect || (attempt > 0 && attempt == _config.maxRetries);
      final controller = _createController(bypassCache: bypassCache);
      // Owned immediately: dispose() releases it whatever happens below.
      _controller = controller;
      try {
        if (!await _awaitInit(controller)) return; // disposed meanwhile
        await controller.setLooping(_config.looping);
        if (_disposed) return;
        await controller.setVolume(_muted ? 0 : 1);
        if (_disposed) return;
        if (_speed != 1) {
          await controller.setPlaybackSpeed(_speed);
          if (_disposed) return;
        }
        if (startAt > Duration.zero) {
          await controller.seekTo(startAt);
          if (_disposed) return;
        }
        controller.addListener(_onValue);
        _initDuration = stopwatch.elapsed;
        _error = null;
        _hasFrame = !_wantPlay;
        if (!_hasFrame) {
          // Position updates arrive every ~500ms; don't hold the thumbnail
          // longer than the first frame needs to be presented.
          Timer(const Duration(milliseconds: 120), () {
            if (_disposed || _hasFrame || !identical(_controller, controller)) {
              return;
            }
            _hasFrame = true;
            notifyListeners();
          });
        }
        _setStatus(SwipePlayerStatus.ready);
        if (_wantPlay) await controller.play();
        SwipeLog.v('Ready ${source.id} in ${_initDuration!.inMilliseconds}ms '
            '(cache: $_servedByCache)');
        return;
      } catch (error) {
        _error = error;
        SwipeLog.e('Init attempt ${attempt + 1} failed for ${source.id}', error);
        if (identical(_controller, controller)) _controller = null;
        // Don't wait for native teardown before retrying.
        _release(controller);
        if (_disposed) return;
        if (attempt < _config.maxRetries) {
          await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
        }
      }
    }
    if (!_disposed) _setStatus(SwipePlayerStatus.error);
  }

  final Completer<void> _disposeSignal = Completer<void>();

  /// Waits for [controller] to initialise. Returns `false` as soon as this
  /// player is disposed, instead of waiting for an initialisation that will
  /// never complete; throws on failure or timeout.
  Future<bool> _awaitInit(VideoPlayerController controller) {
    final done = Completer<bool>();
    final timer = Timer(_config.initTimeout, () {
      if (!done.isCompleted) {
        done.completeError(TimeoutException('initialize', _config.initTimeout));
      }
    });
    controller.initialize().then((_) {
      if (!done.isCompleted) done.complete(true);
    }, onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    });
    unawaited(_disposeSignal.future.then((_) {
      if (!done.isCompleted) done.complete(false);
    }));
    return done.future.whenComplete(timer.cancel);
  }

  /// Silences and releases a controller. Native teardown is asynchronous, so
  /// mute and pause first to guarantee no overlapping audio.
  static void _release(VideoPlayerController controller) {
    unawaited(controller.setVolume(0).catchError((Object _) {}));
    unawaited(controller.pause().catchError((Object _) {}));
    unawaited(controller.dispose().catchError((Object _) {}));
  }

  VideoPlayerController _createController({required bool bypassCache}) {
    // allowBackgroundPlayback disables video_player's own lifecycle observer,
    // which would otherwise resume audio on app resume behind our back. The
    // feed controller is the single authority on what plays.
    final options = VideoPlayerOptions(
      mixWithOthers: _config.mixWithOthers,
      allowBackgroundPlayback: true,
    );
    final url = source.url;
    if (!kIsWeb && (url.startsWith('file://') || url.startsWith('/'))) {
      _servedByCache = false;
      final path = url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
      return fileController(path, options);
    }
    final uri = bypassCache
        ? Uri.parse(url)
        : _cache.playableUri(url,
            headers: source.headers, formatHint: source.formatHint);
    _servedByCache = uri.host == '127.0.0.1';
    return VideoPlayerController.networkUrl(
      uri,
      formatHint: source.formatHint ?? _formatFromUrl(url),
      httpHeaders: _servedByCache ? const {} : (source.headers ?? const {}),
      videoPlayerOptions: options,
    );
  }

  /// Proxy URLs keep the extension, but tell ExoPlayer explicitly so a
  /// stream is never mistaken for a progressive file.
  static VideoFormat? _formatFromUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return VideoFormat.hls;
    if (path.endsWith('.mpd')) return VideoFormat.dash;
    return null;
  }

  static bool _isAutoplayBlock(Object? error) {
    final text = '$error'.toLowerCase();
    return text.contains('notallowed') ||
        text.contains("didn't interact") ||
        text.contains('user gesture');
  }

  void _onValue() {
    final value = _controller?.value;
    if (value == null || _disposed || _status != SwipePlayerStatus.ready) return;
    var changed = false;
    if (value.isBuffering != _buffering) {
      _buffering = value.isBuffering;
      changed = true;
    }
    if (!_hasFrame && value.position > Duration.zero) {
      _hasFrame = true;
      changed = true;
    }
    if (value.hasError) {
      _onRuntimeError(value.errorDescription, value.position);
      return;
    }
    if (changed) notifyListeners();
  }

  /// Network drops, a reclaimed proxy socket or a decoder hiccup: rebuild
  /// the decoder at the same position (bypassing the cache on the second
  /// try) before surfacing an error.
  void _onRuntimeError(Object? error, Duration position) {
    if (kIsWeb && !_muted && _isAutoplayBlock(error)) {
      // Browsers only autoplay muted until the user interacts with the page.
      SwipeLog.i('Autoplay with sound blocked by the browser; muting');
      _muted = true;
      onAutoplayBlocked?.call();
      _restart(position);
      return;
    }
    _error = error;
    if (_recoveries >= 2) {
      _setStatus(SwipePlayerStatus.error);
      return;
    }
    _recoveries++;
    if (_recoveries == 2 && _servedByCache) _forceDirect = true;
    SwipeLog.e('Playback error for ${source.id}, recovering', error);
    _restart(position);
  }

  void _restart(Duration position) {
    final old = _controller;
    _controller = null;
    old?.removeListener(_onValue);
    if (old != null) _release(old);
    _buffering = false;
    _hasFrame = false;
    _initFuture = _initLoop(position);
  }

  /// Re-creates the decoder after an error.
  Future<void> retry() async {
    if (_disposed || _status == SwipePlayerStatus.loading) return;
    _recoveries = 0;
    _restart(Duration.zero);
    await _initFuture;
  }

  Future<void> play() async {
    _wantPlay = true;
    final c = controller;
    if (c == null) {
      if (_status == SwipePlayerStatus.idle) unawaited(initialize());
      return;
    }
    if (!c.value.isPlaying) await _guard(c.play);
  }

  Future<void> pause() async {
    _wantPlay = false;
    final c = controller;
    // Always forward: cheap, and never leaves a native player running when
    // the Dart-side value is momentarily out of date.
    if (c != null) await _guard(c.pause);
  }

  Future<void> seekTo(Duration position) async {
    final c = controller;
    if (c != null) await _guard(() => c.seekTo(position));
  }

  /// Pauses and rewinds (used when the item leaves the screen).
  Future<void> reset() async {
    _wantPlay = false;
    final c = controller;
    if (c == null) return;
    await _guard(c.pause);
    if (!_wantPlay && c.value.position > Duration.zero) {
      await _guard(() => c.seekTo(Duration.zero));
    }
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    final c = controller;
    if (c != null) await _guard(() => c.setVolume(muted ? 0 : 1));
  }

  /// Current playback speed (kept across re-initialisations).
  double get playbackSpeed => _speed;

  Future<void> setPlaybackSpeed(double speed) async {
    _speed = speed;
    final c = controller;
    if (c != null) await _guard(() => c.setPlaybackSpeed(speed));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_disposed) return;
    try {
      await action();
    } catch (error) {
      SwipeLog.v('Ignored player error for ${source.id}: $error');
    }
  }

  void _setStatus(SwipePlayerStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _wantPlay = false;
    _status = SwipePlayerStatus.disposed;
    notifyListeners();
    _disposed = true;
    _disposeSignal.complete();
    final c = _controller;
    _controller = null;
    if (c != null) {
      c.removeListener(_onValue);
      _release(c);
    }
    super.dispose();
  }
}
