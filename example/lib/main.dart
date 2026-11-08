import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:swipecache/swipecache.dart';

import 'fake_backend.dart' as api;
import 'reels.dart';

final _videos = [
  for (final (title, url, isDash) in streamReels)
    if (!isDash || defaultTargetPlatform != TargetPlatform.iOS) (title, url),
  ...fileReels,
];

/// Served in pages to exercise pagination (onLoadMore).
const _pageSize = 5;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SwipeLog.level = SwipeLogLevel.info;
  // Start the cache early; feeds work (uncached) even if this fails.
  unawaited(SwipeCache.instance.init());
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: const FeedPage(),
  ));
}

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  late final SwipeFeedController _controller;

  // Demo settings (header ⚙ button).
  bool _tiktok = false;
  bool _showCacheTools = false;
  int _page = 0;

  List<SwipeSource> _nextPage() {
    final start = _page * _pageSize;
    _page++;
    return [
      for (var i = start; i < start + _pageSize && i < _videos.length; i++)
        SwipeSource(
          id: 'reel_$i',
          url: _videos[i].$2,
          data: _videos[i].$1,
          reel: api.reelFor(i, '${i + 1}/${_videos.length} · ${_videos[i].$1}'),
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    _controller = SwipeFeedController(
      sources: _nextPage(),
      onLoadMore: () async {
        // Simulates a paginated API.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        _controller.appendSources(_nextPage());
        _controller.hasMore = _page * _pageSize < _videos.length;
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SwitchListTile(
              title: const Text('TikTok style'),
              subtitle: const Text(
                  'Tap to pause, hold the sides for 2x. Off = Instagram: '
                  'tap to mute, hold to pause'),
              value: _tiktok,
              onChanged: (v) {
                setState(() => _tiktok = v);
                setSheet(() {});
              },
            ),
            SwitchListTile(
              title: const Text('Show cache tools'),
              subtitle: const Text('Clear-cache button and live statistics'),
              value: _showCacheTools,
              onChanged: (v) {
                setState(() => _showCacheTools = v);
                setSheet(() {});
              },
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SwipeFeed(
            controller: _controller,
            // Fixed header (does not scroll with the videos).
            header: SwipeReelTopBar(
              style: _tiktok ? SwipeReelStyle.tiktok : SwipeReelStyle.instagram,
              onCamera: () => _toast(context, 'Open camera'),
              onSearch: () => _toast(context, 'Open search'),
              onTabSelected: (i) => _toast(context, 'Tab $i'),
              actions: [
                IconButton(
                  tooltip: 'Demo settings',
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: _openSettings,
                ),
              ],
            ),
            // The built-in reel UI, wired to a pretend backend. Tap the video
            // to mute/unmute, hold to pause, double-tap to like.
            reel: SwipeReelOptions(
              theme: _tiktok
                  ? const SwipeReelTheme.tiktok()
                  : const SwipeReelTheme.instagram(),
              // Instagram: tap = mute, hold = pause.
              // TikTok: tap = pause, hold the sides = 2x, hold the middle = menu.
              tapAction: _tiktok ? SwipeTapAction.pause : SwipeTapAction.mute,
              holdAction:
                  _tiktok ? SwipeHoldAction.menu : SwipeHoldAction.pause,
              holdEdgesToSpeedUp: _tiktok,
              onHashtagTap: (item, tag) => _toast(context, 'Open #$tag'),
              onMentionTap: (item, user) => _toast(context, 'Open @$user'),
              onEvent: (event) => debugPrint('reel event: $event'),
              onLike: (item, liked) => api.like(item.source.id, liked),
              onSave: (item, saved) => api.save(item.source.id, saved),
              onFollow: (item, following) =>
                  api.follow(item.reel.author!.id!, following),
              comments: (item) => SwipeCommentsDelegate(
                viewer: api.viewer,
                load: (cursor) => api.loadComments(item.source.id, cursor),
                send: (text) => api.postComment(item.source.id, text),
                like: (comment, liked) => true,
              ),
              shareOptions: (item) => [
                SwipeReelOption(
                  icon: Icons.send_rounded,
                  label: 'Send to friend',
                  onTap: () => _toast(context, 'Sent ${item.source.id}'),
                ),
                SwipeReelOption(
                  icon: Icons.add_circle_outline,
                  label: 'Add to story',
                  onTap: () => _toast(context, 'Added to your story'),
                ),
              ],
              moreOptions: (item) => [
                SwipeReelOption(
                  icon: Icons.visibility_off_outlined,
                  label: 'Not interested',
                  onTap: () => _controller.removeSource(item.source.id),
                ),
                SwipeReelOption(
                  icon: Icons.speed_rounded,
                  label: 'Playback speed',
                  onTap: () => showSwipeSpeedSheet(
                    context,
                    current: _controller.playbackSpeed,
                    onSelected: _controller.setPlaybackSpeed,
                  ),
                ),
                SwipeReelOption(
                  icon: Icons.closed_caption_outlined,
                  label: 'Captions',
                  onTap: () => _toast(context, 'Captions coming soon'),
                ),
                SwipeReelOption(
                  icon: Icons.flag_outlined,
                  label: 'Report',
                  isDestructive: true,
                  onTap: () => _toast(context, 'Thanks for reporting'),
                ),
              ],
              onAuthorTap: (item) =>
                  _toast(context, 'Open profile of ${item.reel.author!.name}'),
              onMusicTap: (item) =>
                  _toast(context, 'Open audio "${item.reel.music!.title}"'),
              // A custom button between the built-in ones.
              actions: [
                SwipeReelAction.like,
                SwipeReelAction.comment,
                SwipeReelAction.share,
                SwipeReelAction.custom(
                  iconBuilder: (context, active, color, size) => Icon(
                    Icons.card_giftcard_rounded,
                    color: color,
                    size: size * 0.95,
                    shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                  ),
                  label: 'Gift',
                  onTap: (item) => _toast(context, 'Gift sent 🎁'),
                ),
                SwipeReelAction.save,
                SwipeReelAction.more,
              ],
            ),
          ),
          if (_showCacheTools) ...[
            const Positioned(top: 110, right: 12, child: _StatsBadge()),
            Positioned(
              top: 110,
              left: 8,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear cache'),
                onPressed: () async {
                  await SwipeCache.instance.clear();
                  if (context.mounted) {
                    _toast(context, 'Cache cleared (playing video kept)');
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

void _toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 1200),
    ));

/// Live cache statistics, refreshed every second.
class _StatsBadge extends StatefulWidget {
  const _StatsBadge();

  @override
  State<_StatsBadge> createState() => _StatsBadgeState();
}

class _StatsBadgeState extends State<_StatsBadge> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  @override
  Widget build(BuildContext context) {
    final s = SwipeCache.instance.stats;
    final bw = s.bandwidthBps;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('hit ${(s.hitRatio * 100).toStringAsFixed(0)}%'),
              Text('disk ${_mb(s.diskBytes)} / ${s.entries} files'),
              Text('net ${_mb(s.networkBytesDownloaded)}'),
              Text('bw ${bw == null ? '-' : '${(bw / 1e6).toStringAsFixed(1)}Mbps'}'),
              Text('prefetch ${s.prefetchesCompleted}/${s.prefetchesPending}'),
              Text('${s.limits.device.name} device, ${s.limits.network.name} net'),
              Text('max ${_mb(s.limits.maxCacheBytes)} / '
                  '${s.limits.maxCachedVideos} videos'),
              Text('${s.limits.maxConcurrentDownloads} parallel downloads'),
              Text('${s.cachedVideos} cached, ${s.openFiles} open files'),
            ],
          ),
        ),
      ),
    );
  }
}
