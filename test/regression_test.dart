import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';

import 'test_origin.dart';

const chunk = 64 * 1024;

void main() {
  late TestOrigin origin;
  late Directory dir;
  late SwipeCache cache;

  setUp(() async {
    origin = await TestOrigin.start();
    dir = await Directory.systemTemp.createTemp('swipecache_regression');
    cache = SwipeCache.custom();
    await cache.init(
      config: SwipeCacheConfig(
        directory: dir,
        chunkSize: chunk,
        maxRunChunks: 32,
      ),
    );
  });

  tearDown(() async {
    await cache.dispose();
    await origin.close();
    await dir.delete(recursive: true);
  });

  test('generic origin content types are served as video for AVPlayer',
      () async {
    origin.addRandom('a.mp4', 100 * 1024);
    origin.addRandom('b.mov', 100 * 1024);
    origin.contentType = ContentType('application', 'octet-stream');
    final (_, _, h1) = await fetch(cache.playableUri(origin.url('a.mp4')));
    expect(h1.contentType?.mimeType, 'video/mp4');
    final (_, _, h2) = await fetch(cache.playableUri(origin.url('b.mov')));
    expect(h2.contentType?.mimeType, 'video/quicktime');
  });

  test('a changed file at the same URL is not mixed with old bytes', () async {
    final url = origin.url('v.mp4');
    origin.addRandom('v.mp4', 300 * 1024, seed: 1);
    await fetch(cache.playableUri(url), range: 'bytes=0-${chunk - 1}');
    expect(cache.isCached(url, bytes: chunk), isTrue);

    final updated = origin.addRandom('v.mp4', 280 * 1024, seed: 2);
    // The request that discovers the change has already sent headers with
    // the old length, so it aborts (players simply re-request).
    try {
      await fetch(cache.playableUri(url), range: 'bytes=${2 * chunk}-');
    } on HttpException {
      // expected
    }
    final (_, body, _) = await fetch(cache.playableUri(url));
    expect(body, updated);
  });

  test('a stalled reader does not block others (claim stealing)', () async {
    final data = origin.addRandom('s.mp4', 4 * 1024 * 1024);
    final uri = cache.playableUri(origin.url('s.mp4'));

    // Reader A: opens the whole file and never reads (a paused player).
    final stalled = await Socket.connect(uri.host, uri.port);
    stalled.write('GET ${uri.path} HTTP/1.1\r\nHost: x\r\nRange: bytes=0-\r\n\r\n');
    await stalled.flush();
    final sub = stalled.listen(null)..pause();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Reader B wants bytes inside A's claimed run.
    final watch = Stopwatch()..start();
    const start = 30 * chunk + 100;
    final (status, body, _) = await fetch(uri, range: 'bytes=$start-${start + 9999}')
        .timeout(const Duration(seconds: 8));
    expect(status, 206);
    expect(body, data.sublist(start, start + 10000));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));

    await sub.cancel();
    stalled.destroy();
  });

  test('proxy recovers after the OS reclaims its socket', () async {
    final data = origin.addRandom('r.mp4', 200 * 1024);
    final uri = cache.playableUri(origin.url('r.mp4'));
    await cache.debugSimulateSocketReclaim();
    await expectLater(fetch(uri), throwsA(anything));

    await cache.ensureHealthy();
    final (_, body, _) = await fetch(uri);
    expect(body, data, reason: 'same port, so existing URLs keep working');
  });

  test('prefetch never takes connections needed for playback', () async {
    origin
      ..delayPerPacket = const Duration(milliseconds: 3)
      ..packetSize = 8 * 1024;
    final urls = [
      for (var i = 0; i < 6; i++) origin.url('p$i.mp4'),
    ];
    for (var i = 0; i < 6; i++) {
      origin.addRandom('p$i.mp4', 1024 * 1024, seed: i);
    }
    final playing = origin.addRandom('play.mp4', 128 * 1024, seed: 99);
    cache.prefetch(urls, headBytes: 1024 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final watch = Stopwatch()..start();
    final (_, body, _) = await fetch(cache.playableUri(origin.url('play.mp4')));
    expect(body, playing);
    // 128KB at 8KB/3ms is ~50ms of transfer; it must not wait for prefetches.
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    cache.cancelPrefetch();
  });

  test('duplicate chunk writers do not inflate disk accounting', () async {
    origin
      ..delayPerPacket = const Duration(milliseconds: 1)
      ..packetSize = 8 * 1024;
    origin.addRandom('d.mp4', 512 * 1024);
    final uri = cache.playableUri(origin.url('d.mp4'));
    await Future.wait([for (var i = 0; i < 4; i++) fetch(uri)]);
    cache.prefetch([origin.url('d.mp4')], headBytes: 512 * 1024);
    await eventually(() => cache.stats.prefetchesPending == 0);
    expect(cache.stats.diskBytes, 512 * 1024);
  });

  test('cached video plays offline', () async {
    final data = origin.addRandom('o.mp4', 300 * 1024);
    final url = origin.url('o.mp4');
    await fetch(cache.playableUri(url));
    await eventually(() => cache.isCached(url));
    await origin.close();
    final (_, body, _) = await fetch(cache.playableUri(url));
    expect(body, data);
    origin = await TestOrigin.start();
  });
}

