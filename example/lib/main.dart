import 'dart:async';

import 'package:flutter/material.dart';
import 'package:swipecache/swipecache.dart';

const _px = 'https://videos.pexels.com/video-files';
const _bl = 'https://download.blender.org';
const _w3 = 'https://media.w3.org/2010/05';
const _plyr = 'https://cdn.plyr.io/static/demo/View_From_A_Blue_Moon_Trailer';

/// 35 public test reels, all with sound. Each URL was verified to be
/// reachable on a fast CDN, to support Range requests and to contain an
/// audio track; files up to 70 MB were decoded and measured audible.
/// Includes portrait clips in several resolutions (same clip at different
/// sizes exercises distinct cache entries), trailers with music, and two very
/// large files (237 MB / 328 MB) to stress stream-while-caching.
const _videos = [
  ('Portrait A · 360p', '$_px/3833491/3833491-sd_360_640_30fps.mp4'),
  ('Oceans', 'https://vjs.zencdn.net/v/oceans.mp4'),
  ('Portrait B · 360p', '$_px/6924608/6924608-sd_360_640_24fps.mp4'),
  ('Sintel trailer · 480p', '$_bl/durian/trailer/sintel_trailer-480p.mp4'),
  ('Portrait C · 360p', '$_px/6190918/6190918-sd_360_640_30fps.mp4'),
  ('Bee', 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4'),
  ('Big Buck Bunny trailer · iPhone', '$_bl/peach/trailer/trailer_iphone.m4v'),
  ('Portrait A · 540p', '$_px/3833491/3833491-sd_540_960_30fps.mp4'),
  ('Android screens', 'https://storage.googleapis.com/exoplayer-test-media-1/mp4/android-screens-10s.mp4'),
  ('Butterfly', 'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4'),
  ('Portrait B · 540p', '$_px/6924608/6924608-sd_540_960_24fps.mp4'),
  ('W3C test movie', '$_w3/video/movie_300.mp4'),
  ('Sintel trailer · W3C', '$_w3/sintel/trailer.mp4'),
  ('Portrait C · 540p', '$_px/6190918/6190918-sd_540_960_30fps.mp4'),
  ('Big Buck Bunny trailer · 480p', '$_bl/peach/trailer/trailer_480p.mov'),
  ('Sample clip', 'https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4'),
  ('Portrait A · 720p', '$_px/3833491/3833491-hd_720_1280_30fps.mp4'),
  ('Big Buck Bunny trailer · W3C', '$_w3/bunny/trailer.mp4'),
  ('Blue Moon trailer · 576p', '$_plyr-576p.mp4'),
  ('Portrait B · 720p', '$_px/6924608/6924608-hd_720_1280_24fps.mp4'),
  ('Big Buck Bunny trailer · 405p', '$_bl/peach/trailer/trailer_720x405.mov'),
  ('Sintel trailer · 720p', '$_bl/durian/trailer/sintel_trailer-720p.mp4'),
  ('Portrait C · 720p', '$_px/6190918/6190918-hd_720_1280_30fps.mp4'),
  ('Big Buck Bunny · full film (61 MB)', 'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4'),
  ('Portrait A · 1080p', '$_px/3833491/3833491-hd_1080_1920_30fps.mp4'),
  ('Big Buck Bunny trailer · 720p', '$_bl/peach/trailer/trailer_720p.mov'),
  ('Blue Moon trailer · 720p', '$_plyr-720p.mp4'),
  ('Portrait B · 1080p', '$_px/6924608/6924608-hd_1080_1920_24fps.mp4'),
  ('Sintel trailer · 1080p', '$_bl/durian/trailer/sintel_trailer-1080p.mp4'),
  ('Sintel trailer · W3C HD', '$_w3/sintel/trailer_hd.mp4'),
  ('Portrait C · 1080p', '$_px/6190918/6190918-hd_1080_1920_30fps.mp4'),
  ('Big Buck Bunny trailer · 1080p', '$_bl/peach/trailer/trailer_1080p.mov'),
  ('Blue Moon trailer · 1080p (113 MB)', '$_plyr-1080p.mp4'),
  ('Cycles demo reel (328 MB)', '$_bl/demo/movies/Cycles_Demoreel_2015.mov'),
  ('Big Buck Bunny · W3C full film (237 MB)', '$_w3/bunny/movie.mp4'),
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
