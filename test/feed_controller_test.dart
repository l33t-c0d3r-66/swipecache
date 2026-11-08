import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_video_platform.dart';

List<SwipeSource> sources(int n, {int from = 0}) => [
      for (var i = from; i < from + n; i++)
        SwipeSource(id: 'v$i', url: 'https://cdn.test/v$i.mp4'),
    ];

void main() {
  late FakeVideoPlatform platform;
  late SwipeCache cache;

  setUp(() {
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    // Not initialised: players use the origin URL directly.
    // Mid-range profile: window of current + 1 ahead + 1 behind.
    cache = SwipeCache.custom(
      config: const SwipeCacheConfig(
        deviceProfile: SwipeDeviceProfile(
            totalRamBytes: 4 * 1024 * 1024 * 1024, cpuCores: 8),
      ),
    );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('keeps a bounded window and plays only the current item',
      (tester) async {
    final controller = SwipeFeedController(sources: sources(10), cache: cache);
    await settle(tester);

    expect(controller.activePlayerCount, 2, reason: 'current + 1 ahead at index 0');
    expect(controller.currentPlayer!.isReady, isTrue);
    expect(controller.playerAt(1)!.isReady, isTrue);
    expect(platform.playing.length, 1);

    controller.onPageChanged(1);
    await settle(tester);
    expect(controller.activePlayerCount, 3, reason: 'behind + current + ahead');
    expect(platform.playing.length, 1);
    final playingUri = platform.uriOf(platform.playing.single);
    expect(playingUri, contains('v1.mp4'));

    controller.onPageChanged(5);
    await settle(tester);
    expect(controller.activeSources.map((s) => s.id),
        unorderedEquals(['v4', 'v5', 'v6']));
    expect(platform.playing.length, 1);
    controller.dispose();
    expect(controller.activePlayerCount, 0);
  });

  testWidgets('swiping to a preloaded item plays instantly', (tester) async {
    final controller = SwipeFeedController(sources: sources(5), cache: cache);
    await settle(tester);
    final next = controller.playerAt(1)!;
    expect(next.isReady, isTrue);

    controller.onPageChanged(1);
    await tester.pump(); // No settle delay: next was pre-initialised.
    expect(identical(controller.currentPlayer, next), isTrue);
    expect(platform.uriOf(platform.playing.single), contains('v1.mp4'));
    controller.dispose();
  });

  testWidgets('fast flings do not create decoders for skipped items',
      (tester) async {
    final controller = SwipeFeedController(sources: sources(30), cache: cache);
    await settle(tester);
    final before = platform.created;
    for (var i = 1; i <= 15; i++) {
      controller.onPageChanged(i);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await settle(tester);
    // Only the final window (14, 15, 16) is created.
    expect(platform.created - before, 3);
    controller.dispose();
  });

  testWidgets('user pause, visibility and lifecycle control playback',
      (tester) async {
    final controller = SwipeFeedController(sources: sources(3), cache: cache);
    await settle(tester);
    expect(platform.playing.length, 1);

    controller.togglePlay();
    await tester.pump();
    expect(controller.isUserPaused, isTrue);
    expect(platform.playing, isEmpty);

    controller.togglePlay();
    await tester.pump();
    expect(platform.playing.length, 1);

    controller.setVisible(false);
    await tester.pump();
    expect(platform.playing, isEmpty);
    controller.setVisible(true);
    await tester.pump();
    expect(platform.playing.length, 1);

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(platform.playing, isEmpty);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.playing.length, 1);

    // Swiping clears the user pause.
    controller.pause();
    controller.onPageChanged(1);
    await settle(tester);
    expect(controller.isUserPaused, isFalse);
    expect(platform.playing.length, 1);
    controller.dispose();
  });

  testWidgets('memory pressure releases everything but the current player',
      (tester) async {
    final controller = SwipeFeedController(
        sources: sources(5), initialIndex: 2, cache: cache);
    await settle(tester);
    expect(controller.activePlayerCount, 3);
    controller.didHaveMemoryPressure();
    await tester.pump();
    expect(controller.activeSources.single.id, 'v2');
    controller.dispose();
  });

  testWidgets('requests more items near the end and appends them',
      (tester) async {
    late SwipeFeedController controller;
    var loads = 0;
    controller = SwipeFeedController(
      sources: sources(5),
      cache: cache,
      onLoadMore: () async {
        loads++;
        controller.appendSources(sources(5, from: 5));
      },
    );
    await settle(tester);
    controller.onPageChanged(1);
    expect(loads, 0);
    controller.onPageChanged(2);
    await settle(tester);
    expect(loads, 1);
    expect(controller.length, 10);
    // Duplicates are ignored.
    controller.appendSources(sources(3, from: 7));
    expect(controller.length, 10);
    controller.dispose();
  });

  testWidgets('setSources keeps the current player when the item survives',
      (tester) async {
    final controller = SwipeFeedController(
        sources: sources(5), initialIndex: 2, cache: cache);
    await settle(tester);
    final current = controller.currentPlayer;
    controller.setSources([...sources(2, from: 100), ...sources(5)]);
    await settle(tester);
    expect(controller.index, 4);
    expect(identical(controller.currentPlayer, current), isTrue);
    controller.dispose();
  });

  testWidgets('init failures retry and surface an error state',
      (tester) async {
    final controller = SwipeFeedController(
      sources: const [SwipeSource(id: 'bad', url: 'https://cdn.test/fail.mp4')],
      cache: cache,
    );
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.currentPlayer!.status, SwipePlayerStatus.error);
    expect(platform.created, 3, reason: '1 attempt + 2 retries');
    controller.dispose();
  });

  testWidgets('SwipeFeed renders and pages', (tester) async {
    final controller = SwipeFeedController(sources: sources(4), cache: cache);
    await tester.pumpWidget(MaterialApp(
      home: SwipeFeed(
        controller: controller,
        overlayBuilder: (context, item) => Text('overlay ${item.index}'),
      ),
    ));
    await settle(tester);
    expect(find.text('overlay 0'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(0, -400), 1500);
    await tester.pumpAndSettle();
    await settle(tester);
    expect(controller.index, 1);
    expect(find.text('overlay 1'), findsOneWidget);

    await tester.tap(find.text('overlay 1'));
    await tester.pump();
    expect(controller.isUserPaused, isTrue);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await settle(tester);
  });
}
