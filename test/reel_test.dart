import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_video_platform.dart';

const _author = SwipeReelAuthor(name: 'jane.doe', isVerified: true);

List<SwipeSource> reels(int n) => [
      for (var i = 0; i < n; i++)
        SwipeSource(
          id: 'r$i',
          url: 'https://cdn.test/r$i.mp4',
          reel: SwipeReelData(
            author: _author,
            caption: 'Caption $i',
            music: const SwipeReelMusic(title: 'Original audio', artist: 'jane'),
            likeCount: 1200,
            commentCount: 34,
            shareUrl: 'https://example.com/r/$i',
          ),
        ),
    ];

void main() {
  late FakeVideoPlatform platform;
  late SwipeCache cache;
  SwipeFeedController? ctl;

  setUp(() {
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    cache = SwipeCache.custom(
      config: const SwipeCacheConfig(
        deviceProfile: SwipeDeviceProfile(
            totalRamBytes: 4 * 1024 * 1024 * 1024, cpuCores: 8),
      ),
    );
  });

  tearDown(() {
    ctl?.dispose();
    ctl = null;
  });

  List<SwipeSource>? controllerSources;
  TestGesture? holdGesture;

  Future<void> pumpFeed(WidgetTester tester, SwipeReelOptions options,
      {int count = 3, SwipeItemBuilder? overlay}) async {
    ctl = SwipeFeedController(
        sources: controllerSources ?? reels(count), cache: cache);
    controllerSources = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SwipeFeed(
            controller: ctl!, reel: options, overlayBuilder: overlay),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // The music disc spins forever, so pumpAndSettle would never return.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// testWidgets that tears the feed down inside the test (pending timers
  /// are checked before tearDown runs).
  void reelTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox());
      ctl?.dispose();
      ctl = null;
      await tester.pump(const Duration(seconds: 2));
    });
  }

  Finder button(String label) => find.byWidgetPredicate(
      (w) => w is SwipeActionButton && w.semanticLabel == label);

  SwipeReelData reelOf(String id) => ctl!.sourceById(id)!.reel!;

  test('formatSwipeCount', () {
    expect(formatSwipeCount(999), '999');
    expect(formatSwipeCount(1000), '1K');
    expect(formatSwipeCount(1250), '1.3K');
    expect(formatSwipeCount(15300), '15.3K');
    expect(formatSwipeCount(250000), '250K');
    expect(formatSwipeCount(3400000), '3.4M');
    expect(formatSwipeCount(1100000000), '1.1B');
  });

  reelTest('shows author, caption, music and counts', (tester) async {
    await pumpFeed(tester, const SwipeReelOptions());
    expect(find.text('jane.doe'), findsOneWidget);
    expect(find.byIcon(Icons.verified), findsOneWidget);
    expect(find.text('Caption 0'), findsOneWidget);
    expect(find.text('1.2K'), findsOneWidget);
    // No comment/more handlers: those buttons are hidden; share has a URL.
    expect(button('Comments'), findsNothing);
    expect(button('More options'), findsNothing);
    expect(button('Share'), findsOneWidget);
    expect(button('Like'), findsOneWidget);
    expect(button('Save'), findsOneWidget);
  });

  reelTest('like updates at once and reports to the app', (tester) async {
    final calls = <bool>[];
    await pumpFeed(tester, SwipeReelOptions(onLike: (item, liked) {
      calls.add(liked);
      return true;
    }));
    await tester.tap(button('Like'));
    await tester.pump();
    expect(reelOf('r0').isLiked, isTrue);
    expect(reelOf('r0').likeCount, 1201);
    expect(tester.widget<SwipeActionButton>(button('Like')).isActive, isTrue);
    await tester.tap(button('Like'));
    await tester.pump();
    expect(reelOf('r0').isLiked, isFalse);
    expect(reelOf('r0').likeCount, 1200);
    expect(calls, [true, false]);
  });

  reelTest('a failed like is rolled back', (tester) async {
    final gate = Completer<bool>();
    await pumpFeed(tester, SwipeReelOptions(onLike: (_, __) => gate.future));
    await tester.tap(button('Like'));
    await tester.pump();
    expect(reelOf('r0').isLiked, isTrue, reason: 'optimistic');
    gate.complete(false);
    await tester.pump();
    expect(reelOf('r0').isLiked, isFalse);
    expect(reelOf('r0').likeCount, 1200);
  });

  reelTest('an exception also rolls back (save)', (tester) async {
    await pumpFeed(tester,
        SwipeReelOptions(onSave: (_, __) => throw StateError('offline')));
    await tester.tap(button('Save'));
    await tester.pump();
    await tester.pump();
    expect(reelOf('r0').isSaved, isFalse);
  });

  reelTest('double tap likes with a heart, never unlikes', (tester) async {
    var likes = 0;
    await pumpFeed(tester, SwipeReelOptions(onLike: (_, liked) {
      if (liked) likes++;
      return null;
    }));
    final center = tester.getCenter(find.byType(SwipeFeed));
    Future<void> doubleTap() async {
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
    }

    await doubleTap();
    expect(reelOf('r0').isLiked, isTrue);
    expect(find.byType(SwipeHeartBurst), findsOneWidget);
    await doubleTap();
    expect(reelOf('r0').isLiked, isTrue);
    expect(likes, 1, reason: 'already liked: no second request');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SwipeHeartBurst), findsNothing, reason: 'cleaned up');
  });

  reelTest('built-in comments sheet loads, posts and counts', (tester) async {
    final posted = <String>[];
    await pumpFeed(
      tester,
      SwipeReelOptions(
        comments: (item) => SwipeCommentsDelegate(
          load: (cursor) async => SwipeCommentPage([
            SwipeComment(
                id: 'c1',
                author: const SwipeReelAuthor(name: 'sam'),
                text: 'Nice one ${item.source.id}',
                likeCount: 3),
          ]),
          send: (text) async {
            posted.add(text);
            return SwipeComment(
                id: 'new', author: const SwipeReelAuthor(name: 'me'), text: text);
          },
          like: (_, __) => true,
        ),
      ),
    );
    await tester.tap(button('Comments'));
    await settle(tester);
    expect(find.text('Comments · 34'), findsOneWidget);
    expect(find.text('Nice one r0'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Great reel');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await settle(tester);
    expect(posted, ['Great reel']);
    expect(find.text('Great reel'), findsOneWidget);
    expect(find.text('Comments · 35'), findsOneWidget);
    expect(reelOf('r0').commentCount, 35);

    // Like a comment.
    await tester.tap(find.byIcon(Icons.favorite_border).last);
    await tester.pump();
    expect(find.text('4'), findsOneWidget);
  });

  reelTest('share sheet copies the link; onShare replaces it',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await pumpFeed(tester, const SwipeReelOptions());
    await tester.tap(button('Share'));
    await settle(tester);
    await tester.tap(find.text('Copy link'));
    await settle(tester);
    expect(copied, 'https://example.com/r/0');
    expect(find.text('Link copied'), findsOneWidget);
    ctl!.dispose();

    final shared = <String>[];
    await pumpFeed(tester,
        SwipeReelOptions(onShare: (item) => shared.add(item.source.id)));
    await tester.tap(button('Share'));
    await settle(tester);
    expect(shared, ['r0']);
    expect(find.text('Copy link'), findsNothing);
  });

  reelTest('custom actions, order and "more" options', (tester) async {
    final gifts = <String>[];
    var reported = false;
    await pumpFeed(
      tester,
      SwipeReelOptions(
        actions: [
          SwipeReelAction.custom(
              icon: Icons.card_giftcard,
              label: 'Gift',
              onTap: (item) => gifts.add(item.source.id)),
          SwipeReelAction.like,
          SwipeReelAction.more,
        ],
        moreOptions: (item) => [
          SwipeReelOption(
              icon: Icons.flag_outlined,
              label: 'Report',
              isDestructive: true,
              onTap: () => reported = true),
        ],
      ),
    );
    expect(button('Save'), findsNothing, reason: 'not listed');
    final gift = tester.getCenter(find.text('Gift'));
    final like = tester.getCenter(button('Like'));
    expect(gift.dy, lessThan(like.dy), reason: 'listed order');
    await tester.tap(find.text('Gift'));
    await tester.pump();
    expect(gifts, ['r0']);

    await tester.tap(button('More options'));
    await settle(tester);
    await tester.tap(find.text('Report'));
    await settle(tester);
    expect(reported, isTrue);
  });

  reelTest('follow button follows and disappears', (tester) async {
    final follows = <bool>[];
    await pumpFeed(tester, SwipeReelOptions(onFollow: (_, v) {
      follows.add(v);
      return true;
    }));
    await tester.tap(find.text('Follow'));
    await tester.pump();
    expect(follows, [true]);
    expect(reelOf('r0').author!.isFollowing, isTrue);
    expect(find.text('Follow'), findsNothing);
  });

  reelTest('hold pauses and hides the UI; release resumes', (tester) async {
    await pumpFeed(tester, const SwipeReelOptions());
    expect(platform.playing, isNotEmpty);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(SwipeFeed)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(platform.playing, isEmpty);
    final opacity = tester.widget<AnimatedOpacity>(find
        .ancestor(
            of: find.byType(SwipeReelOverlay), matching: find.byType(AnimatedOpacity))
        .first);
    expect(opacity.opacity, 0);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(platform.playing, isNotEmpty);
    expect(ctl!.isUserPaused, isFalse);
  });

  reelTest('tap to mute (Instagram style)', (tester) async {
    await pumpFeed(
        tester, const SwipeReelOptions(tapAction: SwipeTapAction.mute));
    await tester.tapAt(tester.getCenter(find.byType(SwipeFeed)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(ctl!.isMuted, isTrue);
    expect(ctl!.isUserPaused, isFalse);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  reelTest('own widgets on top, and builders replace parts',
      (tester) async {
    await pumpFeed(
      tester,
      SwipeReelOptions(
        captionBuilder: (context, item, actions) =>
            Text('custom caption ${item.source.id}'),
        topBuilder: (context, item, actions) => const Text('Reels'),
        bottomBuilder: (context, item, actions) => TextButton(
            onPressed: () => actions.toggleLike(), child: const Text('Like it')),
      ),
      overlay: (context, item) =>
          const Align(alignment: Alignment.topRight, child: Text('LIVE')),
    );
    expect(find.text('custom caption r0'), findsOneWidget);
    expect(find.text('Caption 0'), findsNothing);
    expect(find.text('Reels'), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
    await tester.tap(find.text('Like it'));
    await tester.pump();
    expect(reelOf('r0').isLiked, isTrue);
  });

  reelTest('updateReel keeps the player', (tester) async {
    await pumpFeed(tester, const SwipeReelOptions());
    final player = ctl!.currentPlayer;
    ctl!.updateReel('r0', (r) => r.copyWith(commentCount: 99));
    await tester.pump();
    expect(identical(ctl!.currentPlayer, player), isTrue);
    expect(reelOf('r0').commentCount, 99);
  });

  reelTest('TikTok style: follow badge on the avatar, counts always shown',
      (tester) async {
    final follows = <bool>[];
    await pumpFeed(
      tester,
      SwipeReelOptions(
        theme: const SwipeReelTheme.tiktok(),
        onFollow: (_, v) {
          follows.add(v);
          return true;
        },
      ),
    );
    expect(find.byType(SwipeFollowAvatar), findsOneWidget);
    expect(find.text('@jane.doe'), findsOneWidget);
    expect(find.text('Follow'), findsNothing, reason: 'TikTok uses the badge');
    expect(find.text('0'), findsOneWidget, reason: 'share count 0 is shown');
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    expect(follows, [true]);
    expect(reelOf('r0').author!.isFollowing, isTrue);
  });

  reelTest('hashtags, mentions and onEvent', (tester) async {
    final events = <String>[];
    final tags = <String>[];
    controllerSources = [
      const SwipeSource(
        id: 't0',
        url: 'https://cdn.test/t0.mp4',
        reel: SwipeReelData(caption: 'Hi @sam.k look #sunset.'),
      ),
    ];
    await pumpFeed(
      tester,
      SwipeReelOptions(
        onHashtagTap: (item, tag) => tags.add('#$tag'),
        onMentionTap: (item, user) => tags.add('@$user'),
        onEvent: (e) => events.add('${e.type.name}:${e.value ?? ''}'),
      ),
    );
    final caption = find.byType(RichText).evaluate().map((e) => e.widget as RichText).firstWhere(
        (r) => r.text.toPlainText().contains('#sunset'));
    final spans = <TextSpan>[];
    caption.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) spans.add(span);
      return true;
    });
    expect(spans.map((s) => s.text), ['@sam.k', '#sunset']);
    for (final span in spans) {
      (span.recognizer! as TapGestureRecognizer).onTap!();
    }
    expect(tags, ['@sam.k', '#sunset']);
    await tester.tap(button('Like'));
    await tester.pump();
    await tester.tap(button('Save'));
    await tester.pump();
    expect(events, ['mentionTap:sam.k', 'hashtagTap:sunset', 'like:', 'save:']);
  });

  reelTest('actionBuilder wraps or replaces single buttons; icons swap',
      (tester) async {
    await pumpFeed(
      tester,
      SwipeReelOptions(
        theme: const SwipeReelTheme(icons: SwipeReelIcons.material),
        actionBuilder: (context, item, type, button, actions) =>
            type == SwipeReelActionType.save
                ? TextButton(
                    onPressed: actions.toggleSave, child: const Text('Keep'))
                : button,
      ),
    );
    expect(button('Save'), findsNothing, reason: 'replaced');
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget,
        reason: 'material icon set');
    await tester.tap(find.text('Keep'));
    await tester.pump();
    expect(reelOf('r0').isSaved, isTrue);
  });

  reelTest('fixed header does not scroll with the items', (tester) async {
    ctl = SwipeFeedController(sources: reels(3), cache: cache);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SwipeFeed(
          controller: ctl!,
          reel: const SwipeReelOptions(),
          header: SwipeReelTopBar(onCamera: () {}),
        ),
      ),
    ));
    await settle(tester);
    expect(find.text('Reels'), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
  });

  Future<void> hold(WidgetTester tester, Offset at) async {
    final gesture = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    holdGesture = gesture;
  }

  reelTest('hold to speed up (TikTok) shows 2x and restores speed',
      (tester) async {
    await pumpFeed(
        tester, const SwipeReelOptions(holdAction: SwipeHoldAction.speedUp));
    final id = platform.playing.single;
    await hold(tester, tester.getCenter(find.byType(SwipeFeed)));
    expect(platform.speeds[id], 2);
    expect(platform.playing, contains(id), reason: 'keeps playing');
    final badge = tester.widget<SwipeSpeedBadge>(find.byType(SwipeSpeedBadge));
    expect(badge.visible, isTrue);
    await holdGesture!.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(platform.speeds[id], 1);
  });

  reelTest('edges speed up, middle pauses', (tester) async {
    await pumpFeed(tester, const SwipeReelOptions(holdEdgesToSpeedUp: true));
    final id = platform.playing.single;
    final box = tester.getRect(find.byType(SwipeFeed));
    await hold(tester, Offset(box.left + 10, box.center.dy));
    expect(platform.speeds[id], 2);
    await holdGesture!.up();
    await tester.pump(const Duration(milliseconds: 300));
    await hold(tester, box.center);
    expect(platform.playing, isEmpty, reason: 'middle = pause');
    await holdGesture!.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(platform.playing, isNotEmpty);
  });

  reelTest('hold opens the menu (TikTok long press)', (tester) async {
    await pumpFeed(
      tester,
      SwipeReelOptions(
        holdAction: SwipeHoldAction.menu,
        moreOptions: (item) => [
          SwipeReelOption(icon: Icons.speed, label: 'Speed', onTap: () {}),
        ],
      ),
    );
    await hold(tester, tester.getCenter(find.byType(SwipeFeed)));
    await holdGesture!.up();
    await settle(tester);
    expect(find.text('Speed'), findsOneWidget);
  });

  reelTest('tap to pause shows the play mark; swiping resumes', (tester) async {
    await pumpFeed(
        tester, const SwipeReelOptions(tapAction: SwipeTapAction.pause));
    await tester.tapAt(tester.getCenter(find.byType(SwipeFeed)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(ctl!.isUserPaused, isTrue);
    expect(platform.playing, isEmpty);
    expect(
        tester.widget<SwipePausedIndicator>(find.byType(SwipePausedIndicator).first)
            .visible,
        isTrue);
    ctl!.onPageChanged(1);
    await settle(tester);
    expect(ctl!.isUserPaused, isFalse, reason: 'next video plays');
    expect(platform.playing, hasLength(1));
  });

  reelTest('seek bar drag seeks and hides the UI meanwhile', (tester) async {
    final events = <String>[];
    await pumpFeed(tester,
        SwipeReelOptions(onEvent: (e) => events.add('${e.type.name}:${e.value}')));
    final id = platform.playing.single;
    final bar = find.byType(SwipeSeekBar);
    expect(bar, findsOneWidget);
    final rect = tester.getRect(bar);
    final gesture = await tester.startGesture(Offset(rect.left + 5, rect.bottom - 6));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(Offset(rect.center.dx, rect.bottom - 6));
    await tester.pump();
    expect(find.textContaining(' /  0:10'), findsOneWidget, reason: 'time shown');
    final opacity = tester.widget<AnimatedOpacity>(find
        .ancestor(of: find.byType(SwipeReelOverlay), matching: find.byType(AnimatedOpacity))
        .first);
    expect(opacity.opacity, 0, reason: 'UI hidden while scrubbing');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    final seconds = platform.positions[id]!.inMilliseconds / 1000;
    expect(seconds, closeTo(5, 0.6), reason: 'middle of a 10 s video');
    expect(events.single, startsWith('seek:'));
    expect(platform.playing, contains(id), reason: 'resumes after seeking');
  });

  reelTest('playback speed sticks for the next videos', (tester) async {
    await pumpFeed(tester, const SwipeReelOptions());
    ctl!.setPlaybackSpeed(1.5);
    await tester.pump();
    expect(platform.speeds[platform.playing.single], 1.5);
    ctl!.onPageChanged(2);
    await settle(tester);
    expect(platform.speeds[platform.playing.single], 1.5);
  });
}
