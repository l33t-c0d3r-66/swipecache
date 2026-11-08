import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';

import 'test_origin.dart';

const chunk = 64 * 1024;

void main() {
  late TestOrigin origin;
  late Directory dir;
  late SwipeCache cache;

  SwipeCacheConfig config({int maxBytes = 64 * 1024 * 1024}) => SwipeCacheConfig(
        directory: dir,
        chunkSize: chunk,
        maxRunChunks: 4,
        maxCacheBytes: maxBytes,
        defaultPrefetchBytes: 3 * chunk,
        maxTailPrefetchBytes: 2 * chunk,
      );

  setUp(() async {
    origin = await TestOrigin.start();
    dir = await Directory.systemTemp.createTemp('swipecache_test');
    cache = SwipeCache.custom();
    await cache.init(config: config());
    expect(cache.isReady, isTrue);
  });

  tearDown(() async {
    await cache.dispose();
    await origin.close();
    await dir.delete(recursive: true);
  });

  test('proxies a full file byte-exact and serves replays from disk', () async {
    final data = origin.addRandom('a.mp4', 700 * 1024 + 123);
    final uri = cache.playableUri(origin.url('a.mp4'));
    expect(uri.host, '127.0.0.1');
    expect(uri.path, endsWith('.mp4'));

    final (status, body, headers) = await fetch(uri);
    expect(status, 200);
    expect(body, data);
    expect(headers.value('accept-ranges'), 'bytes');
    expect(headers.contentType?.mimeType, 'video/mp4');

    await eventually(() => cache.isCached(origin.url('a.mp4')));
    final downloaded = origin.bytesSent;
    expect(downloaded, lessThan(data.length + 2 * chunk));

    final (_, replay, _) = await fetch(uri);
    expect(replay, data);
    expect(origin.bytesSent, downloaded, reason: 'replay must not hit origin');
    expect(cache.stats.bytesFromCache, greaterThanOrEqualTo(data.length));
  });

  test('answers player style range probes', () async {
    final data = origin.addRandom('r.mp4', 500 * 1024);
    final uri = cache.playableUri(origin.url('r.mp4'));

    final (s1, b1, h1) = await fetch(uri, range: 'bytes=0-1');
    expect(s1, 206);
    expect(b1, data.sublist(0, 2));
    expect(h1.value('content-range'), 'bytes 0-1/${data.length}');

    final (s2, b2, _) = await fetch(uri, range: 'bytes=200000-300005');
    expect(s2, 206);
    expect(b2, data.sublist(200000, 300006));

    final (_, b3, _) = await fetch(uri, range: 'bytes=-1000');
    expect(b3, data.sublist(data.length - 1000));

    final (s4, _, _) = await fetch(uri, range: 'bytes=${data.length}-');
    expect(s4, 416);
  });

  test('works with origins that ignore Range', () async {
    origin.supportRanges = false;
    final data = origin.addRandom('n.mp4', 300 * 1024);
    final uri = cache.playableUri(origin.url('n.mp4'));
    final (status, body, _) = await fetch(uri, range: 'bytes=100000-');
    expect(status, 206);
    expect(body, data.sublist(100000));
    final (_, full, _) = await fetch(uri);
    expect(full, data);
  });

  test('concurrent readers share downloads', () async {
    origin
      ..delayPerPacket = const Duration(milliseconds: 2)
      ..packetSize = 8 * 1024;
    final data = origin.addRandom('c.mp4', 600 * 1024);
    final uri = cache.playableUri(origin.url('c.mp4'));
    final results = await Future.wait([fetch(uri), fetch(uri), fetch(uri)]);
    for (final (_, body, _) in results) {
      expect(body, data);
    }
    // Each chunk is fetched once, plus at most one partial chunk per run.
    expect(origin.bytesSent, lessThan(data.length + 3 * chunk));
  });

  test('client abort mid-stream keeps cache consistent', () async {
    origin
      ..delayPerPacket = const Duration(milliseconds: 1)
      ..packetSize = 8 * 1024;
    final data = origin.addRandom('x.mp4', 800 * 1024);
    final uri = cache.playableUri(origin.url('x.mp4'));
    final (_, partial, _) = await fetch(uri, abortAfter: 150 * 1024);
    expect(partial.sublist(0, 150 * 1024), data.sublist(0, 150 * 1024));
    // The proxy notices the disconnect and stops pulling from the origin.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final sent = origin.bytesSent;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(origin.bytesSent - sent, lessThan(chunk));
    expect(origin.bytesSent, lessThan(data.length ~/ 2));

    final (_, full, _) = await fetch(uri);
    expect(full, data);
  });

  test('prefetch downloads only the head', () async {
    final data = origin.addRandom('p.mp4', 2 * 1024 * 1024);
    final url = origin.url('p.mp4');
    cache.prefetch([url]);
    await eventually(() => cache.isCached(url, bytes: 3 * chunk));
    await eventually(() => cache.stats.prefetchesPending == 0);
    expect(cache.isCached(url), isFalse);
    expect(origin.bytesSent, lessThanOrEqualTo(3 * chunk));

    // Playback starts from the prefetched head without touching the origin.
    origin.resetCounters();
    final (_, head, _) =
        await fetch(cache.playableUri(url), range: 'bytes=0-${3 * chunk - 1}');
    expect(head, data.sublist(0, 3 * chunk));
    expect(origin.bytesSent, 0);
  });

  test('prefetch also fetches moov of non fast-start mp4', () async {
    final file = buildMp4(mdatPayload: 900 * 1024, moovPayload: 40 * 1024);
    origin.files['m.mp4'] = file;
    final url = origin.url('m.mp4');
    cache.prefetch([url]);
    await eventually(() => cache.stats.prefetchesPending == 0);
    final moovOffset = 24 + 900 * 1024 + 8;
    origin.resetCounters();
    final (_, tail, _) =
        await fetch(cache.playableUri(url), range: 'bytes=$moovOffset-');
    expect(tail, file.sublist(moovOffset));
    expect(origin.bytesSent, 0, reason: 'moov must already be cached');
  });

  test('cancelled prefetches stop downloading', () async {
    origin
      ..delayPerPacket = const Duration(milliseconds: 5)
      ..packetSize = 4 * 1024;
    origin.addRandom('s1.mp4', 4 * 1024 * 1024);
    final url = origin.url('s1.mp4');
    cache.prefetch([url], headBytes: 4 * 1024 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cache.cancelPrefetch();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final sent = origin.bytesSent;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(origin.bytesSent - sent, lessThan(64 * 1024));
    expect(cache.isCached(url), isFalse);
  });

  test('cache survives restart', () async {
    final data = origin.addRandom('k.mp4', 400 * 1024);
    final url = origin.url('k.mp4');
    await fetch(cache.playableUri(url));
    await eventually(() => cache.isCached(url));
    await cache.dispose();

    cache = SwipeCache.custom();
    await cache.init(config: config());
    expect(cache.isCached(url), isTrue);
    origin.resetCounters();
    final (_, body, _) = await fetch(cache.playableUri(url));
    expect(body, data);
    expect(origin.requests, 0);
  });

  test('evicts least recently used beyond the byte budget', () async {
    await cache.dispose();
    cache = SwipeCache.custom();
    await cache.init(config: config(maxBytes: 900 * 1024));
    origin.addRandom('e1.mp4', 500 * 1024, seed: 1);
    origin.addRandom('e2.mp4', 500 * 1024, seed: 2);
    await fetch(cache.playableUri(origin.url('e1.mp4')));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await fetch(cache.playableUri(origin.url('e2.mp4')));
    await eventually(() => !cache.isCached(origin.url('e1.mp4')),
        timeout: const Duration(seconds: 6));
    expect(cache.isCached(origin.url('e2.mp4')), isTrue);
    expect(cache.stats.diskBytes, lessThanOrEqualTo(900 * 1024));
  });

  test('protected entries are not evicted', () async {
    await cache.dispose();
    cache = SwipeCache.custom();
    await cache.init(config: config(maxBytes: 900 * 1024));
    origin.addRandom('q1.mp4', 500 * 1024, seed: 1);
    origin.addRandom('q2.mp4', 500 * 1024, seed: 2);
    cache.protect([origin.url('q1.mp4')]);
    await fetch(cache.playableUri(origin.url('q1.mp4')));
    await fetch(cache.playableUri(origin.url('q2.mp4')));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(cache.isCached(origin.url('q1.mp4')), isTrue);
  });

  test('HLS and unknown schemes bypass the proxy', () {
    expect(cache.playableUri('https://cdn/x/master.m3u8').host, 'cdn');
    expect(cache.playableUri('file:///tmp/a.mp4').scheme, 'file');
  });

  test('falls back to origin URL when not initialised', () {
    final fresh = SwipeCache.custom();
    expect(fresh.playableUri('https://cdn/v.mp4').toString(), 'https://cdn/v.mp4');
  });

  test('missing origin file gives an error status, not a hang', () async {
    final (status, _, _) =
        await fetch(cache.playableUri(origin.url('missing.mp4')));
    expect(status, 404);
  });

  test('stats report measured values', () async {
    origin.addRandom('st.mp4', 300 * 1024);
    final uri = cache.playableUri(origin.url('st.mp4'));
    await fetch(uri);
    await fetch(uri);
    final stats = cache.stats;
    // Second read is fully from disk; on the first read the probed first
    // chunk is already served from disk too.
    expect(stats.hitRatio, greaterThan(0.5));
    expect(stats.bytesFromCache + stats.bytesFromNetwork, 600 * 1024);
    expect(stats.entries, 1);
    expect(stats.networkBytesDownloaded, greaterThanOrEqualTo(300 * 1024));
  });

  test('empty file', () async {
    origin.files['z.mp4'] = Uint8List(0);
    origin.supportRanges = false;
    final (status, body, _) = await fetch(cache.playableUri(origin.url('z.mp4')));
    expect(status, 200);
    expect(body, isEmpty);
  });
}
