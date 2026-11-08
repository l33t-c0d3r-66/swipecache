// Plays every stream type on the real platform player (AVPlayer on iOS,
// ExoPlayer on Android) through the swipecache proxy.
//
//   flutter test integration_test/streams_test.dart -d <device>
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:swipecache/swipecache.dart';
import 'package:swipecache_example/reels.dart';
import 'package:video_player/video_player.dart';

final _cache = SwipeCache.instance;

Future<void> _until(WidgetTester tester, bool Function() condition,
    {Duration timeout = const Duration(seconds: 45), String? what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for ${what ?? 'condition'}');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Plays [url] until [seconds] of video have been played; returns the time
/// to a ready decoder.
Future<Duration> _play(WidgetTester tester, String url,
    {int seconds = 3,
    Duration timeout = const Duration(seconds: 45),
    bool live = false}) async {
  final uri = _cache.playableUri(url);
  expect(uri.host, '127.0.0.1', reason: 'served through the proxy');
  final path = uri.path.toLowerCase();
  final controller = VideoPlayerController.networkUrl(
    uri,
    formatHint: path.endsWith('.m3u8')
        ? VideoFormat.hls
        : path.endsWith('.mpd')
            ? VideoFormat.dash
            : null,
  );
  final stopwatch = Stopwatch()..start();
  try {
    await controller.initialize().timeout(timeout);
    final ready = stopwatch.elapsed;
    await controller.setVolume(0);
    await controller.play();
    if (live) {
      // video_player reports no position for live streams on iOS: check
      // that it keeps playing without errors instead.
      await _until(tester,
          () => controller.value.isPlaying && !controller.value.isBuffering,
          what: 'live playback', timeout: timeout);
      await tester.pump(Duration(seconds: seconds));
      expect(controller.value.hasError, isFalse,
          reason: controller.value.errorDescription);
      expect(controller.value.isPlaying, isTrue);
      expect(controller.value.size.width, greaterThan(0));
      return ready;
    }
    await _until(
      tester,
      () =>
          controller.value.hasError ||
          controller.value.position >= Duration(seconds: seconds),
      what: 'playback of $url',
      timeout: timeout,
    );
    expect(controller.value.hasError, isFalse,
        reason: controller.value.errorDescription);
    expect(controller.value.size.width, greaterThan(0), reason: 'has video');
    return ready;
  } finally {
    await controller.dispose();
  }
}

String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(2)}MB';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _cache.init();
    expect(_cache.isReady, isTrue);
    await _cache.clear();
    debugPrint('RESULT device: ${_cache.deviceProfile}');
  });

  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  for (final (title, url, isDash) in streamReels) {
    if (isDash && ios) continue; // AVPlayer has no DASH support
    final live = title.contains('LIVE');
    testWidgets(title, (tester) async {
      final errorsBefore = _cache.stats.errors;
      final ready = await _play(tester, url,
          seconds: live ? 4 : 3,
          timeout: Duration(seconds: live ? 90 : 45),
          live: live);
      // Let the last chunk writes land.
      await tester.pump(const Duration(milliseconds: 800));
      final stored = _cache.cachedBytes(url);
      if (live) {
        expect(stored, 0, reason: 'live streams are never stored');
        debugPrint('RESULT $title: ready ${ready.inMilliseconds}ms, '
            'stored ${_mb(stored)} (live, not stored)');
        return;
      }
      expect(stored, greaterThan(0), reason: 'VOD segments are stored');
      expect(_cache.stats.errors, errorsBefore);

      // Replay: the start must now come from disk.
      final fromCacheBefore = _cache.stats.bytesFromCache;
      final networkBefore = _cache.stats.networkBytesDownloaded;
      final replayReady = await _play(tester, url, seconds: 2);
      final fromCache = _cache.stats.bytesFromCache - fromCacheBefore;
      final network = _cache.stats.networkBytesDownloaded - networkBefore;
      expect(fromCache, greaterThan(0), reason: 'replay served from cache');
      debugPrint('RESULT $title: ready ${ready.inMilliseconds}ms, stored '
          '${_mb(stored)}; replay ready ${replayReady.inMilliseconds}ms, '
          '${_mb(fromCache)} from cache, ${_mb(network)} downloaded');
    });
  }

  testWidgets('baseline: first HLS stream played directly (no proxy)',
      (tester) async {
    final controller = VideoPlayerController.networkUrl(
        Uri.parse(streamReels.first.$2),
        formatHint: VideoFormat.hls);
    final stopwatch = Stopwatch()..start();
    try {
      await controller.initialize().timeout(const Duration(seconds: 40));
      debugPrint('RESULT baseline direct: ready '
          '${stopwatch.elapsedMilliseconds}ms');
    } finally {
      await controller.dispose();
    }
  });

  testWidgets('progressive MP4 still cached', (tester) async {
    final url = fileReels.first.$2;
    final ready = await _play(tester, url);
    await tester.pump(const Duration(milliseconds: 800));
    expect(_cache.cachedBytes(url), greaterThan(0));
    debugPrint('RESULT MP4: ready ${ready.inMilliseconds}ms, '
        'stored ${_mb(_cache.cachedBytes(url))}');
  });

  testWidgets('HLS prefetch stores the start before playback', (tester) async {
    final url = streamReels.first.$2;
    await _cache.remove(url);
    _cache.prefetch([url], headBytes: 512 * 1024);
    await _until(tester, () => _cache.stats.prefetchesPending == 0,
        what: 'prefetch');
    expect(_cache.isCached(url), isTrue);
    final networkBefore = _cache.stats.networkBytesDownloaded;
    final ready = await _play(tester, url, seconds: 1);
    debugPrint('RESULT prefetch: ${_mb(_cache.cachedBytes(url))} stored '
        'before play, ready ${ready.inMilliseconds}ms, '
        '${_mb(_cache.stats.networkBytesDownloaded - networkBefore)} '
        'downloaded during the first second');
  });

  tearDownAll(() {
    debugPrint('RESULT stats: ${_cache.stats}');
  });
}
