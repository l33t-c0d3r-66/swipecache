import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:swipecache/swipecache.dart';

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
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: FeedPage(),
  ));
}

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  late final SwipeFeedController _controller;
  int _page = 0;

  List<SwipeSource> _nextPage() {
    final start = _page * _pageSize;
    _page++;
    return [
      for (var i = start; i < start + _pageSize && i < _videos.length; i++)
        SwipeSource(id: 'reel_$i', url: _videos[i].$2, data: _videos[i].$1),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SwipeFeed(
            controller: _controller,
            showProgress: true,
            onDoubleTap: (item, _) => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Liked ${item.source.id}'),
                duration: const Duration(milliseconds: 600),
              ),
            ),
            overlayBuilder: (context, item) => Positioned(
              left: 16,
              bottom: 32,
              child: Text(
                '${item.index + 1}/${_videos.length}  ${item.source.data}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  shadows: [Shadow(blurRadius: 4)],
                ),
              ),
            ),
          ),
          const Positioned(top: 48, right: 12, child: _StatsBadge()),
          Positioned(
            top: 40,
            left: 4,
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => IconButton(
                color: Colors.white,
                icon: Icon(_controller.isMuted ? Icons.volume_off : Icons.volume_up),
                onPressed: () => _controller.setMuted(!_controller.isMuted),
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 48,
            child: IconButton(
              color: Colors.white,
              tooltip: 'Clear cache',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                await SwipeCache.instance.clear();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Cache cleared (playing video kept)'),
                  duration: Duration(seconds: 1),
                ));
              },
            ),
          ),
        ],
      ),
    );
  }
}

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
