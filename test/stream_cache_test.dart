import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';

import 'test_origin.dart';

const chunk = 64 * 1024;
final hlsType = ContentType('application', 'vnd.apple.mpegurl');
final dashType = ContentType('application', 'dash+xml');

/// Proxy URLs on the lines/attributes of a rewritten playlist.
List<String> proxied(String body) => [
      for (final m in RegExp(r'http://127\.0\.0\.1:\d+/s/[^"\s]+').allMatches(body))
        m.group(0)!,
    ];

void main() {
  late TestOrigin origin;
  late Directory dir;
  late SwipeCache cache;

  Future<void> start({int? maxVideos}) async {
    cache = SwipeCache.custom();
    await cache.init(
      config: SwipeCacheConfig(
        directoryPath: dir.path,
        chunkSize: chunk,
        maxRunChunks: 4,
        maxCacheBytes: 64 * 1024 * 1024,
        maxCachedVideos: maxVideos,
      ),
    );
    expect(cache.isReady, isTrue);
  }

  void addVod() {
    origin.addText(
        'hls/master.m3u8',
        '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,URI="audio/en.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"\n'
            'low/index.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=3000000,AUDIO="aud"\n'
            'high/index.m3u8\n',
        hlsType);
    for (final variant in ['low', 'high']) {
      origin.addText(
          'hls/$variant/index.m3u8',
          '#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:4\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="/keys/k1"\n'
              '#EXT-X-MAP:URI="init.mp4"\n'
              '#EXTINF:4.0,\nseg0.m4s\n#EXTINF:4.0,\nseg1.m4s\n'
              '#EXTINF:4.0,\nseg2.m4s\n#EXT-X-ENDLIST\n',
          hlsType);
      origin.addRandom('hls/$variant/init.mp4', 2000, seed: 3);
      for (var i = 0; i < 3; i++) {
        origin.addRandom('hls/$variant/seg$i.m4s', 150 * 1024, seed: 10 + i);
      }
    }
    origin.addText(
        'hls/audio/en.m3u8',
        '#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4.0,\na0.aac\n'
            '#EXTINF:4.0,\na1.aac\n#EXT-X-ENDLIST\n',
        hlsType);
    origin.addRandom('hls/audio/a0.aac', 40 * 1024, seed: 20);
    origin.addRandom('hls/audio/a1.aac', 40 * 1024, seed: 21);
    origin.addRandom('keys/k1', 16, seed: 30);
  }

  setUp(() async {
    origin = await TestOrigin.start();
    dir = await Directory.systemTemp.createTemp('swipecache_stream');
  });

  tearDown(() async {
    await cache.dispose();
    await origin.close();
    await dir.delete(recursive: true);
  });

  test('HLS VOD: rewritten through the proxy, cached, replayed offline',
      () async {
    await start();
    addVod();
    final masterUrl = origin.url('hls/master.m3u8');
    final uri = cache.playableUri(masterUrl);
    expect(uri.host, '127.0.0.1');
    expect(uri.path, startsWith('/s/'));
    expect(uri.path, endsWith('/hls/master.m3u8'));

    final (status, masterBody, headers) = await fetch(uri);
    expect(status, 200);
    expect(headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    final master = utf8.decode(masterBody);
    final refs = proxied(master);
    expect(refs, hasLength(3)); // audio rendition + two variants
    expect(refs.every((r) => r.contains('/m/')), isTrue);

    final lowUrl = refs.firstWhere((r) => r.endsWith('low/index.m3u8'));
    final media = utf8.decode((await fetch(Uri.parse(lowUrl))).$2);
    final mediaRefs = proxied(media);
    final key = mediaRefs.singleWhere((r) => r.contains('/keys/k1'));
    expect(key, contains('/n/'), reason: 'keys are never stored');
    final segments = mediaRefs.where((r) => !r.contains('/keys/')).toList();
    expect(segments, hasLength(4)); // init + 3 segments
    expect(segments.every((r) => r.contains('/c/')), isTrue);

    for (final s in segments) {
      final name = 'hls/low/${s.split('/').last}';
      final (st, body, _) = await fetch(Uri.parse(s));
      expect(st, 200);
      expect(body, origin.files[name], reason: name);
    }
    final (_, keyBody, _) = await fetch(Uri.parse(key));
    expect(keyBody, origin.files['keys/k1']);

    // One video, however many files it consists of.
    expect(cache.stats.cachedVideos, 1);
    expect(cache.isCached(masterUrl), isTrue);
    expect(cache.cachedBytes(masterUrl), greaterThan(3 * 150 * 1024));

    // Replay with the origin gone: playlists and segments come from disk.
    final segmentHits = origin.hits['hls/low/seg1.m4s'];
    final keyHits = origin.hits['keys/k1']!;
    await origin.close();
    final (replayStatus, replay, _) = await fetch(uri);
    expect(replayStatus, 200);
    expect(proxied(utf8.decode(replay)), refs);
    expect(utf8.decode((await fetch(Uri.parse(lowUrl))).$2), media);
    final (_, seg1, _) = await fetch(Uri.parse(segments[2]));
    expect(seg1, origin.files['hls/low/seg1.m4s']);
    expect(origin.hits['hls/low/seg1.m4s'], segmentHits);
    expect(origin.hits['keys/k1'], keyHits);
    origin = await TestOrigin.start(); // for tearDown

    await cache.remove(masterUrl);
    expect(cache.cachedBytes(masterUrl), 0);
    expect(cache.stats.cachedVideos, 0);
  });

  test('HLS live behind a master playlist: nothing stored', () async {
    await start();
    origin.addText(
        'lm/master.m3u8',
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nv.m3u8\n',
        hlsType);
    origin.addText('lm/v.m3u8',
        '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:3\n#EXTINF:2.0,\ns3.ts\n', hlsType);
    final url = origin.url('lm/master.m3u8');
    final master = utf8.decode((await fetch(cache.playableUri(url))).$2);
    await fetch(Uri.parse(proxied(master).single));
    await eventually(() => cache.cachedBytes(url) == 0);
    // Later loads of the master do not store it again.
    await fetch(cache.playableUri(url));
    expect(cache.cachedBytes(url), 0);
    expect(cache.stats.cachedVideos, 0);
  });

  test('HLS live: playlist always refetched, segments never stored', () async {
    await start();
    origin.addText(
        'live/index.m3u8',
        '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:10\n'
            '#EXTINF:2.0,\nlive10.ts\n#EXTINF:2.0,\nlive11.ts\n',
        hlsType);
    final seg = origin.addRandom('live/live10.ts', 100 * 1024, seed: 5);
    final url = origin.url('live/index.m3u8');
    final uri = cache.playableUri(url);
    final body = utf8.decode((await fetch(uri)).$2);
    await fetch(uri);
    expect(origin.hits['live/index.m3u8'], 2);
    final segUrl = proxied(body).first;
    expect(segUrl, contains('/n/'));
    final (status, data, _) = await fetch(Uri.parse(segUrl), range: 'bytes=100-');
    expect(status, 206, reason: 'Range requests are forwarded');
    expect(data, seg.sublist(100));
    expect(cache.cachedBytes(url), 0);
    expect(cache.stats.cachedVideos, 0);
  });

  test('HLS prefetch caches the start variant, its audio and first segment',
      () async {
    await start();
    addVod();
    final masterUrl = origin.url('hls/master.m3u8');
    cache.prefetch([masterUrl], headBytes: 1);
    await eventually(() => cache.stats.prefetchesPending == 0 &&
        cache.stats.prefetchesCompleted == 1);
    // AVPlayer (macOS host here) starts with the first listed variant.
    expect(origin.hits['hls/low/init.mp4'], 1);
    expect(origin.hits['hls/low/seg0.m4s'], 1);
    expect(origin.hits['hls/low/seg1.m4s'], isNull);
    expect(origin.hits['hls/audio/a0.aac'], 1);
    expect(origin.hits['hls/high/index.m3u8'], isNull);
    expect(cache.isCached(masterUrl), isTrue);

    // Playback afterwards reuses everything that was prefetched.
    final uri = cache.playableUri(masterUrl);
    final lowUrl = proxied(utf8.decode((await fetch(uri)).$2))
        .firstWhere((r) => r.endsWith('low/index.m3u8'));
    final media = utf8.decode((await fetch(Uri.parse(lowUrl))).$2);
    final seg0 = proxied(media).firstWhere((r) => r.endsWith('seg0.m4s'));
    final (_, body, _) = await fetch(Uri.parse(seg0));
    expect(body, origin.files['hls/low/seg0.m4s']);
    expect(origin.hits['hls/master.m3u8'], 1);
    expect(origin.hits['hls/low/index.m3u8'], 1);
    expect(origin.hits['hls/low/init.mp4'], 1);
  });

  test('a stream is evicted as one video', () async {
    await start(maxVideos: 1);
    addVod();
    final masterUrl = origin.url('hls/master.m3u8');
    final uri = cache.playableUri(masterUrl);
    final lowUrl = proxied(utf8.decode((await fetch(uri)).$2))
        .firstWhere((r) => r.endsWith('low/index.m3u8'));
    for (final s in proxied(utf8.decode((await fetch(Uri.parse(lowUrl))).$2))
        .where((r) => r.contains('/c/'))) {
      await fetch(Uri.parse(s));
    }
    await cache.trimNow();
    expect(cache.stats.cachedVideos, 1, reason: 'many files, one video');
    expect(cache.isCached(masterUrl), isTrue);

    origin.addRandom('b.mp4', 200 * 1024);
    await fetch(cache.playableUri(origin.url('b.mp4')));
    await cache.trimNow();
    expect(cache.stats.cachedVideos, 1);
    expect(cache.cachedBytes(masterUrl), 0, reason: 'whole stream evicted');
    expect(cache.isCached(origin.url('b.mp4')), isTrue);
  });

  test('DASH: relative SegmentTemplate URLs resolve to the proxy', () async {
    await start();
    origin.addText(
        'dash/manifest.mpd',
        '<?xml version="1.0"?>\n'
            '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT8S">'
            '<Period><AdaptationSet mimeType="video/mp4">'
            r'<SegmentTemplate initialization="v/init.mp4" media="v/seg$Number$.m4s" startNumber="1" duration="4" timescale="1"/>'
            '<Representation id="v" bandwidth="500000"/>'
            '</AdaptationSet></Period></MPD>',
        dashType);
    final seg = origin.addRandom('dash/v/seg1.m4s', 120 * 1024, seed: 8);
    final url = origin.url('dash/manifest.mpd');
    final uri = cache.playableUri(url);
    final (status, body, headers) = await fetch(uri);
    expect(status, 200);
    expect(headers.contentType?.mimeType, 'application/dash+xml');
    final baseUrl = RegExp(r'<BaseURL>([^<]+)</BaseURL>')
        .firstMatch(utf8.decode(body))!
        .group(1)!;
    // What a player does with the template.
    final segUri = Uri.parse(baseUrl).resolve('v/seg1.m4s');
    expect(segUri.host, '127.0.0.1');
    final (_, data, _) = await fetch(segUri);
    expect(data, seg);
    await eventually(() => cache.cachedBytes(url) > seg.length);
    expect(cache.stats.cachedVideos, 1);
  });

  test('a playlist behind an extension-less URL is detected and rewritten',
      () async {
    await start();
    addVod();
    origin.addText('play', utf8.decode(origin.files['hls/master.m3u8']!), hlsType);
    final uri = cache.playableUri(origin.url('play'));
    final body = utf8.decode((await fetch(uri)).$2);
    expect(body, startsWith('#EXTM3U'));
    expect(proxied(body), hasLength(3));
  });

  test('servers repeating headers work (pass-through and cached)', () async {
    await start();
    origin.duplicateHeaders = true;
    origin.addText(
        'live2/index.m3u8',
        '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2.0,\ns1.m4s\n',
        hlsType);
    final init = origin.addRandom('live2/init.mp4', 795, seed: 6);
    final body = utf8.decode(
        (await fetch(cache.playableUri(origin.url('live2/index.m3u8')))).$2);
    final initUrl = proxied(body).firstWhere((u) => u.endsWith('init.mp4'));
    expect(initUrl, contains('/n/'));
    final (status, data, _) = await fetch(Uri.parse(initUrl))
        .timeout(const Duration(seconds: 5));
    expect(status, 200);
    expect(data, init);

    final file = origin.addRandom('dup.mp4', 300 * 1024, seed: 7);
    final (_, cached, _) = await fetch(cache.playableUri(origin.url('dup.mp4')))
        .timeout(const Duration(seconds: 5));
    expect(cached, file);
  });
}
