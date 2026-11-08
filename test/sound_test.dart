import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_video_platform.dart';

List<SwipeSource> sources(int n) => [
      for (var i = 0; i < n; i++)
        SwipeSource(id: 'v$i', url: 'https://cdn.test/v$i.mp4'),
    ];

void main() {
  late FakeVideoPlatform platform;
  late SwipeCache cache;

  setUp(() {
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
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

  testWidgets('a player disposed while initialising never plays',
      (tester) async {
    platform.holdInit = true;
    final player = SwipePlayer(
      source: sources(1).single,
      cache: cache,
      config: const SwipeFeedConfig(),
    );
    final init = player.play(); // wants to play once ready
    await tester.pump();
    player.dispose();
    platform.releaseInit();
    await init;
    await settle(tester);
    expect(platform.playing, isEmpty);
    expect(player.controller, isNull);
  });

  testWidgets('fast swipes during slow init never overlap audio',
      (tester) async {
    platform.holdInit = true;
    final controller = SwipeFeedController(sources: sources(10), cache: cache);
    await tester.pump();
    for (var i = 1; i <= 4; i++) {
      controller.onPageChanged(i);
      await tester.pump(const Duration(milliseconds: 120));
    }
    platform.releaseInit();
    await settle(tester);
    platform.releaseInit();
    await settle(tester);
    expect(platform.playing.length, 1);
    expect(platform.uriOf(platform.playing.single), contains('v4.mp4'));
    controller.dispose();
  });

  testWidgets('app resume does not restart audio of a hidden feed',
      (tester) async {
    final controller = SwipeFeedController(sources: sources(3), cache: cache);
    await settle(tester);
    expect(platform.playing.length, 1);

    controller.setVisible(false);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(platform.playing, isEmpty);

    controller.setVisible(true);
    await settle(tester);
    expect(platform.playing.length, 1);
    controller.dispose();
  });

  testWidgets('user pause survives app background and resume', (tester) async {
    final controller = SwipeFeedController(sources: sources(3), cache: cache);
    await settle(tester);
    controller.pause();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(platform.playing, isEmpty);
    controller.dispose();
  });

  testWidgets('hidden feeds release neighbour decoders and restore them',
      (tester) async {
    final controller =
        SwipeFeedController(sources: sources(5), initialIndex: 2, cache: cache);
    await settle(tester);
    expect(controller.activePlayerCount, 3);
    controller.setVisible(false);
    await tester.pump();
    expect(controller.activePlayerCount, 1);
    controller.setVisible(true);
    await settle(tester);
    expect(controller.activePlayerCount, 3);
    expect(platform.playing.length, 1);
    controller.dispose();
  });

  testWidgets('playback errors recover at the same item automatically',
      (tester) async {
    final controller = SwipeFeedController(sources: sources(2), cache: cache);
    await settle(tester);
    final player = controller.currentPlayer!;
    final id = platform.playing.single;
    final before = platform.created;
    platform.failPlayback(id);
    await settle(tester);
    expect(platform.created, before + 1, reason: 'decoder rebuilt');
    expect(player.status, SwipePlayerStatus.ready);
    expect(platform.playing.length, 1);
    expect(platform.uriOf(platform.playing.single), contains('v0.mp4'));
    controller.dispose();
  });

  testWidgets('mute applies to players created later', (tester) async {
    final controller = SwipeFeedController(sources: sources(6), cache: cache);
    await settle(tester);
    controller.setMuted(true);
    controller.onPageChanged(3);
    await settle(tester);
    for (final i in [2, 3, 4]) {
      expect(controller.playerAt(i)!.controller!.value.volume, 0);
    }
    controller.dispose();
  });
}
