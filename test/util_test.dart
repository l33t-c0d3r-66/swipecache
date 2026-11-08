import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/src/cache/chunk_bitmap.dart';
import 'package:swipecache/src/util/bandwidth_estimator.dart';
import 'package:swipecache/src/util/hash.dart';
import 'package:swipecache/src/util/http_range.dart';
import 'package:swipecache/src/util/mp4_inspector.dart';

import 'test_origin.dart';

void main() {
  group('fnv1a64Hex', () {
    test('matches reference vectors', () {
      expect(fnv1a64Hex(''), 'cbf29ce484222325');
      expect(fnv1a64Hex('a'), 'af63dc4c8601ec8c');
      expect(fnv1a64Hex('foobar'), '85944171f73967e8');
    });

    test('distinguishes similar urls', () {
      expect(fnv1a64Hex('https://x/a.mp4'), isNot(fnv1a64Hex('https://x/b.mp4')));
    });
  });

  group('parseRangeHeader', () {
    RangeParseResult p(String? h) => parseRangeHeader(h, 1000);

    test('no header', () => expect(p(null), isA<FullContent>()));
    test('open ended', () {
      expect((p('bytes=100-') as PartialContent).range, const ByteRange(100, 999));
    });
    test('closed and clamped', () {
      expect((p('bytes=0-1') as PartialContent).range, const ByteRange(0, 1));
      expect((p('bytes=990-5000') as PartialContent).range, const ByteRange(990, 999));
    });
    test('suffix', () {
      expect((p('bytes=-100') as PartialContent).range, const ByteRange(900, 999));
      expect((p('bytes=-5000') as PartialContent).range, const ByteRange(0, 999));
    });
    test('unsatisfiable', () {
      expect(p('bytes=1000-'), isA<UnsatisfiableRange>());
    });
    test('malformed falls back to full', () {
      expect(p('bytes=abc'), isA<FullContent>());
      expect(p('items=0-1'), isA<FullContent>());
      expect(p('bytes=50-10'), isA<FullContent>());
    });
    test('content-range', () {
      final r = parseContentRange('bytes 10-19/100')!;
      expect([r.start, r.end, r.total], [10, 19, 100]);
      expect(parseContentRange('bytes 0-1/*')!.total, isNull);
    });
  });

  group('inspectMp4Head', () {
    test('detects moov at end', () {
      final file = buildMp4(mdatPayload: 50000, moovPayload: 500);
      final layout = inspectMp4Head(Uint8List.sublistView(file, 0, 4096),
          totalLength: file.length);
      expect(layout.moovAtStart, isFalse);
      expect(layout.moovOffset, 24 + 50008);
    });

    test('detects fast start', () {
      final file = buildMp4(mdatPayload: 50000, moovPayload: 500, moovFirst: true);
      expect(inspectMp4Head(Uint8List.sublistView(file, 0, 4096)).moovAtStart, isTrue);
    });

    test('non mp4 data is unknown', () {
      expect(inspectMp4Head(Uint8List.fromList(List.filled(64, 7))).moovAtStart, isTrue);
    });
  });

  test('ChunkBitmap round trip', () {
    final bitmap = ChunkBitmap(13)
      ..set(0)
      ..set(12)
      ..set(12);
    expect(bitmap.completedCount, 2);
    final decoded = ChunkBitmap.decode(13, bitmap.encode());
    expect(decoded.has(0) && decoded.has(12) && !decoded.has(5), isTrue);
    expect(decoded.completedCount, 2);
    expect(decoded.hasAll(0, 1), isFalse);
  });

  test('BandwidthEstimator ignores tiny samples and smooths', () {
    final e = BandwidthEstimator();
    e.addSample(100, const Duration(milliseconds: 1));
    expect(e.bitsPerSecond, isNull);
    e.addSample(1000000, const Duration(seconds: 1));
    expect(e.bitsPerSecond, 8e6);
    e.addSample(1000000, const Duration(seconds: 2));
    expect(e.bitsPerSecond, closeTo(0.3 * 4e6 + 0.7 * 8e6, 1));
  });
}
