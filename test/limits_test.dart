import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/src/device/adaptive_policy.dart';
import 'package:swipecache/swipecache.dart';

import 'test_origin.dart';

const _gb = 1024 * 1024 * 1024;
const _mb = 1024 * 1024;
const low = SwipeDeviceProfile(totalRamBytes: 2 * _gb, cpuCores: 4);
const mid = SwipeDeviceProfile(totalRamBytes: 4 * _gb, cpuCores: 8);
const high = SwipeDeviceProfile(totalRamBytes: 8 * _gb, cpuCores: 8);

AdaptivePolicy policy(SwipeDeviceProfile device,
        {double? bps, SwipeCacheConfig config = const SwipeCacheConfig()}) =>
    AdaptivePolicy(config: config, device: device, bandwidth: () => bps);

void main() {
  group('device profile', () {
    test('tiers', () {
      expect(low.tier, SwipeDeviceTier.low);
      expect(mid.tier, SwipeDeviceTier.mid);
      expect(high.tier, SwipeDeviceTier.high);
      expect(SwipeDeviceProfile.unknown.tier, SwipeDeviceTier.mid);
      // A "3 GB" phone reports ~2.8 GB and should count as mid-range.
      expect(
          const SwipeDeviceProfile(totalRamBytes: 2900 * _mb, cpuCores: 8).tier,
          SwipeDeviceTier.mid);
    });

    test('parses /proc/meminfo', () {
      const sample = 'MemTotal:        3825740 kB\nMemFree:  100 kB\n';
      expect(SwipeDeviceProfile.parseMemInfo(sample), 3825740 * 1024);
      expect(SwipeDeviceProfile.parseMemInfo('garbage'), isNull);
    });

    test('detects the host device', () {
      final profile = SwipeDeviceProfile.detect();
      expect(profile.cpuCores, greaterThan(0));
      if (Platform.isMacOS || Platform.isLinux) {
        expect(profile.totalRamBytes, greaterThan(0));
      }
    });
  });

  group('automatic limits', () {
    test('scale with device class', () {
      final l = policy(low), m = policy(mid), h = policy(high);
      expect(l.maxCacheBytes, lessThan(m.maxCacheBytes));
      expect(m.maxCacheBytes, lessThan(h.maxCacheBytes));
      expect(l.maxCachedVideos, lessThan(h.maxCachedVideos));
      expect(l.maxAge, lessThan(h.maxAge));
      expect(l.preloadBehind(null), 0, reason: 'save decoders on low end');
      expect(m.preloadBehind(null), 1);
    });

    test('follow measured network speed', () {
      expect(policy(high, bps: 0.5e6).maxConcurrentDownloads, 1);
      expect(policy(high, bps: 3e6).maxConcurrentDownloads, 2);
      expect(policy(high, bps: 50e6).maxConcurrentDownloads, 4);
      expect(policy(low, bps: 50e6).maxConcurrentDownloads, 2,
          reason: 'weak devices are capped even on fast networks');
      expect(policy(high, bps: 0.5e6).prefetchHeadBytes(null),
          lessThan(policy(high, bps: 50e6).prefetchHeadBytes(null)));
      expect(policy(low, bps: 50e6).prefetchAhead(null),
          lessThanOrEqualTo(3));
    });

    test('re-evaluate as bandwidth changes', () {
      double? bps;
      final p = AdaptivePolicy(
          config: const SwipeCacheConfig(),
          device: high,
          bandwidth: () => bps);
      expect(p.networkTier, SwipeNetworkTier.unknown);
      bps = 0.5e6;
      expect(p.maxConcurrentDownloads, 1);
      bps = 50e6;
      expect(p.maxConcurrentDownloads, 4);
    });

    test('shrink after the disk ran full', () {
      final p = policy(high);
      p.onDiskFull(300 * _mb);
      expect(p.maxCacheBytes, 210 * _mb);
    });
  });

  group('fixed limits are followed strictly', () {
    const config = SwipeCacheConfig(
      maxCacheBytes: 1000 * _mb,
      maxCachedVideos: 7,
      maxAge: Duration(hours: 5),
      maxConcurrentDownloads: 6,
    );

    test('on every device and network', () {
      for (final device in [low, mid, high]) {
        for (final bps in [null, 0.2e6, 3e6, 100e6]) {
          final p = policy(device, bps: bps, config: config);
          expect(p.maxCacheBytes, 1000 * _mb);
          expect(p.maxCachedVideos, 7);
          expect(p.maxAge, const Duration(hours: 5));
          expect(p.maxConcurrentDownloads, 6);
          expect(p.preloadAhead(3), 3);
          expect(p.preloadBehind(0), 0);
          expect(p.prefetchAhead(9), 9);
          expect(p.prefetchHeadBytes(123456), 123456);
        }
      }
    });

    test('even after the disk ran full', () {
      final p = policy(low, config: config);
      p.onDiskFull(10 * _mb);
      expect(p.maxCacheBytes, 1000 * _mb);
    });

    test('resolved limits report which values are automatic', () {
      final limits = policy(mid,
              config: const SwipeCacheConfig(maxCachedVideos: 5))
          .resolve(preloadAhead: 1);
      expect(limits.maxCachedVideos, 5);
      expect(limits.autoFields, isNot(contains('maxCachedVideos')));
      expect(limits.autoFields, isNot(contains('preloadAhead')));
      expect(limits.autoFields, contains('maxCacheBytes'));
    });
  });

  group('cache cleanup', () {
    late TestOrigin origin;
    late Directory dir;
    late SwipeCache cache;

    Future<void> start(SwipeCacheConfig config) async {
      cache = SwipeCache.custom();
      await cache.init(config: config);
    }

    setUp(() async {
      origin = await TestOrigin.start();
      dir = await Directory.systemTemp.createTemp('swipecache_limits');
    });

    tearDown(() async {
      await cache.dispose();
      await origin.close();
      await dir.delete(recursive: true);
    });

    test('keeps at most maxCachedVideos, evicting least recently watched',
        () async {
      await start(SwipeCacheConfig(
          directoryPath: dir.path, chunkSize: 64 * 1024, maxCachedVideos: 2));
      for (var i = 0; i < 4; i++) {
        origin.addRandom('c$i.mp4', 100 * 1024, seed: i);
        await fetch(cache.playableUri(origin.url('c$i.mp4')));
        await eventually(() => cache.isCached(origin.url('c$i.mp4')) ||
            cache.stats.evicted > 0);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await eventually(
          () => cache.stats.cachedVideos <= 2 && cache.stats.evicted >= 2,
          timeout: const Duration(seconds: 6));
      expect(cache.isCached(origin.url('c3.mp4')), isTrue);
      expect(cache.isCached(origin.url('c0.mp4')), isFalse);
      expect(cache.stats.evicted, greaterThanOrEqualTo(2));
    });

    test('expires videos after maxAge while the app is running', () async {
      await start(SwipeCacheConfig(
        directoryPath: dir.path,
        chunkSize: 64 * 1024,
        maxAge: const Duration(milliseconds: 400),
        sweepInterval: const Duration(milliseconds: 100),
      ));
      origin.addRandom('t.mp4', 100 * 1024);
      final url = origin.url('t.mp4');
      await fetch(cache.playableUri(url));
      await eventually(() => cache.isCached(url));
      await eventually(() => !cache.isCached(url),
          timeout: const Duration(seconds: 3));
      // Files are deleted from disk, and nothing recreates them afterwards.
      bool noFiles() => dir
          .listSync()
          .whereType<File>()
          .every((f) => !f.path.endsWith('.data') && !f.path.endsWith('.meta'));
      await eventually(noFiles);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(noFiles(), isTrue);
    });

    test('closes idle file handles (no descriptor exhaustion)', () async {
      await start(SwipeCacheConfig(
        directoryPath: dir.path,
        chunkSize: 64 * 1024,
        sweepInterval: const Duration(milliseconds: 100),
      ));
      for (var i = 0; i < 20; i++) {
        origin.addRandom('f$i.mp4', 70 * 1024, seed: i);
        await fetch(cache.playableUri(origin.url('f$i.mp4')));
      }
      expect(cache.stats.openFiles, greaterThan(0));
      await eventually(() => cache.stats.openFiles == 0,
          timeout: const Duration(seconds: 3));
      // Files reopen transparently on the next read.
      final (_, body, _) = await fetch(cache.playableUri(origin.url('f3.mp4')));
      expect(body, origin.files['f3.mp4']);
    });

    test('respects the byte budget', () async {
      await start(SwipeCacheConfig(
          directoryPath: dir.path, chunkSize: 64 * 1024, maxCacheBytes: 500 * 1024));
      for (var i = 0; i < 5; i++) {
        origin.addRandom('b$i.mp4', 200 * 1024, seed: i);
        await fetch(cache.playableUri(origin.url('b$i.mp4')));
      }
      await eventually(() => cache.stats.diskBytes <= 500 * 1024,
          timeout: const Duration(seconds: 6));
    });

    test('clear() removes everything not in use', () async {
      await start(SwipeCacheConfig(directoryPath: dir.path, chunkSize: 64 * 1024));
      for (var i = 0; i < 3; i++) {
        origin.addRandom('x$i.mp4', 100 * 1024, seed: i);
        await fetch(cache.playableUri(origin.url('x$i.mp4')));
      }
      // Let the proxy finish its requests (videos being served are kept).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await cache.clear();
      expect(cache.stats.diskBytes, 0);
      expect(cache.stats.cachedVideos, 0);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    for (final limit in [1, 3]) {
      test('never exceeds $limit parallel background downloads', () async {
        await start(SwipeCacheConfig(
          directoryPath: dir.path,
          chunkSize: 64 * 1024,
          maxConcurrentDownloads: limit,
        ));
        origin
          ..delayPerPacket = const Duration(milliseconds: 2)
          ..packetSize = 8 * 1024;
        final urls = [
          for (var i = 0; i < 8; i++) origin.url('d$i.mp4'),
        ];
        for (var i = 0; i < 8; i++) {
          origin.addRandom('d$i.mp4', 400 * 1024, seed: i);
        }
        cache.prefetch(urls, headBytes: 256 * 1024);
        await eventually(() => cache.stats.prefetchesPending == 0,
            timeout: const Duration(seconds: 10));
        expect(origin.maxActive, lessThanOrEqualTo(limit));
        expect(cache.stats.prefetchesCompleted, 8);
      });
    }

    test('stats expose the limits in force', () async {
      await start(SwipeCacheConfig(
          directoryPath: dir.path, maxCachedVideos: 9, deviceProfile: low));
      final limits = cache.stats.limits;
      expect(limits.maxCachedVideos, 9);
      expect(limits.device, SwipeDeviceTier.low);
      expect(limits.maxCacheBytes, 200 * _mb);
    });
  });
}
