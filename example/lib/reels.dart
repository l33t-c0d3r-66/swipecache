// Public test reels used by the example app and its device tests.
// ignore_for_file: lines_longer_than_80_chars

const _px = 'https://videos.pexels.com/video-files';
const _bl = 'https://download.blender.org';
const _w3 = 'https://media.w3.org/2010/05';
const _plyr = 'https://cdn.plyr.io/static/demo/View_From_A_Blue_Moon_Trailer';

/// Adaptive streams with sound: HLS (TS and fMP4, separate audio
/// renditions, subtitles), one live HLS stream (played, never stored) and
/// DASH (Android only - AVPlayer on iOS can't play DASH).
const streamReels = [
  ('HLS · Big Buck Bunny (TS)', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8', false),
  ('HLS · Apple bipbop (fMP4, separate audio)', 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8', false),
  ('DASH · Big Buck Bunny', 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd', true),
  ('HLS · Angel One (multi audio + subtitles)', 'https://storage.googleapis.com/shaka-demo-assets/angel-one-hls/hls.m3u8', false),
  ('HLS LIVE · Blender loop (fMP4, separate audio)', 'https://ireplay.tv/test/blender.m3u8', false),
  ('DASH · Angel One', 'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd', true),
  ('HLS · Dark Truths (fMP4)', 'https://storage.googleapis.com/shaka-demo-assets/bbb-dark-truths-hls/hls.m3u8', false),
  ('DASH · Sintel', 'https://storage.googleapis.com/shaka-demo-assets/sintel/dash.mpd', true),
];

/// 35 public test reels, all with sound. Each URL was verified to be
/// reachable on a fast CDN, to support Range requests and to contain an
/// audio track; files up to 70 MB were decoded and measured audible.
/// Includes portrait clips in several resolutions (same clip at different
/// sizes exercises distinct cache entries), trailers with music, and two very
/// large files (237 MB / 328 MB) to stress stream-while-caching.
const fileReels = [
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
