import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/swipecache.dart';

import 'test_origin.dart';

/// ExoPlayer resets connections (RST) on every swipe. That must never
/// surface as an unhandled SocketException (seen on a real Android device).
void main() {
  test('player hang-ups mid-stream produce no unhandled errors', () async {
    final errors = <Object>[];
    final origin = await TestOrigin.start();
    final dir = await Directory.systemTemp.createTemp('swipecache_rst');
    final done = Completer<void>();

    // ignore: unawaited_futures
    runZonedGuarded(() async {
      final cache = SwipeCache.custom();
      await cache.init(config: SwipeCacheConfig(directoryPath: dir.path));
      origin.addRandom('big.mp4', 6 * 1024 * 1024);
      final uri = cache.playableUri(origin.url('big.mp4'));
      // Warm the cache so the proxy writes from disk as fast as it can.
      await fetch(uri);
      for (var i = 0; i < 60; i++) {
        final socket = await Socket.connect(uri.host, uri.port);
        socket.write('GET ${uri.path} HTTP/1.1\r\nHost: x\r\n'
            'Range: bytes=${(i % 6) * 100000}-\r\n\r\n');
        await socket.flush();
        // Never read: the proxy keeps writing into full buffers, then the
        // close with unread data makes the kernel send RST mid-write.
        await Future<void>.delayed(Duration(milliseconds: 5 + (i % 7) * 15));
        socket.destroy();
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await cache.dispose();
      done.complete();
    }, (error, stack) => errors.add(error));

    await done.future.timeout(const Duration(seconds: 20));
    await origin.close();
    await dir.delete(recursive: true);
    expect(errors, isEmpty);
  });
}
