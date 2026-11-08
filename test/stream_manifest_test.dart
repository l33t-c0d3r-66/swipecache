import 'package:flutter_test/flutter_test.dart';
import 'package:swipecache/src/stream/stream_manifest.dart';
import 'package:swipecache/swipecache.dart';

String proxy(String url, ProxyMode mode) => 'P[${mode.name}]$url';

void main() {
  final base = Uri.parse('https://cdn.example.com/v/42/master.m3u8?token=a');

  group('streamKindFor', () {
    test('detects by extension, content type and content', () {
      expect(streamKindFor(Uri.parse('https://x/a.m3u8')), StreamKind.hls);
      expect(streamKindFor(Uri.parse('https://x/a.mpd?x=1')), StreamKind.dash);
      expect(streamKindFor(Uri.parse('https://x/a.mp4')), isNull);
      expect(
          streamKindFor(Uri.parse('https://x/play?id=1'),
              contentType: 'application/x-mpegURL; charset=utf-8'),
          StreamKind.hls);
      expect(
          streamKindFor(Uri.parse('https://x/play'), head: '#EXTM3U\n'),
          StreamKind.hls);
      expect(
          streamKindFor(Uri.parse('https://x/play'),
              head: '<?xml version="1.0"?>\n<MPD type="static">'),
          StreamKind.dash);
    });
  });

  group('HLS', () {
    const master = '#EXTM3U\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,URI="audio/en.m3u8"\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="fr",URI="audio/fr.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"\n'
        'low/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="aud"\n'
        'https://other.example.com/high/index.m3u8\n';

    test('rewrites variants and renditions as manifests', () {
      final out = rewriteHls(master, base, proxy);
      expect(out,
          contains('P[manifest]https://cdn.example.com/v/42/low/index.m3u8\n'));
      expect(out,
          contains('P[manifest]https://other.example.com/high/index.m3u8'));
      expect(out,
          contains('URI="P[manifest]https://cdn.example.com/v/42/audio/en.m3u8"'));
      expect(out, startsWith('#EXTM3U\n'));
    });

    test('parses variants, default audio and picks a start variant', () {
      final p = HlsPlaylist.parse(master, base);
      expect(p.isMaster, isTrue);
      expect(p.variants, hasLength(2));
      expect(p.variants.first.bandwidth, 800000);
      expect(p.defaultAudio['aud'].toString(),
          'https://cdn.example.com/v/42/audio/en.m3u8');
      expect(p.startVariant(firstListed: true)!.bandwidth, 800000);
      expect(p.startVariant(firstListed: false, bitsPerSecond: 20e6)!.bandwidth,
          5000000);
      expect(p.startVariant(firstListed: false, bitsPerSecond: 1e6)!.bandwidth,
          800000);
    });

    const vod = '#EXTM3U\r\n'
        '#EXT-X-PLAYLIST-TYPE:VOD\r\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="/keys/k1",IV=0x1\r\n'
        '#EXT-X-MAP:URI="init.mp4",BYTERANGE="700@0"\r\n'
        '#EXTINF:4.0,\r\n'
        '#EXT-X-BYTERANGE:1000@700\r\n'
        'media.mp4\r\n'
        '#EXTINF:4.0,\r\n'
        '#EXT-X-BYTERANGE:500\r\n'
        'media.mp4\r\n'
        '#EXT-X-ENDLIST\r\n';

    test('VOD: segments cached, keys pass through, CRLF kept', () {
      final out = rewriteHls(vod, base, proxy);
      expect(out, contains('URI="P[passthrough]https://cdn.example.com/keys/k1"'));
      expect(out, contains('URI="P[cache]https://cdn.example.com/v/42/init.mp4"'));
      expect(out, contains('\r\nP[cache]https://cdn.example.com/v/42/media.mp4\r\n'));
      expect(isStaticManifest(StreamKind.hls, vod), isTrue);
    });

    test('parses byte ranges, continuing ranges without offset', () {
      final p = HlsPlaylist.parse(vod, base);
      expect(p.isStatic, isTrue);
      expect(p.initSection!.start, 0);
      expect(p.initSection!.length, 700);
      expect(p.segments.map((s) => (s.start, s.length)), [(700, 1000), (1700, 500)]);
    });

    test('live: segments pass through, FairPlay keys untouched', () {
      const live = '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:5\n'
          '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key42"\n'
          '#EXTINF:2,\nseg5.ts\n';
      expect(isStaticManifest(StreamKind.hls, live), isFalse);
      final out = rewriteHls(live, base, proxy);
      expect(out, contains('P[passthrough]https://cdn.example.com/v/42/seg5.ts'));
      expect(out, contains('URI="skd://key42"'));
    });
  });

  group('DASH', () {
    final mpdBase = Uri.parse('https://cdn.example.com/dash/bbb/manifest.mpd');

    test('inserts an MPD-level BaseURL for relative templates', () {
      const mpd = '<?xml version="1.0"?>\n'
          '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">'
          '<Period><AdaptationSet>'
          r'<SegmentTemplate initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/$Number%05d$.m4s"/>'
          '<Representation id="v1"/></AdaptationSet></Period></MPD>';
      final out = rewriteDash(mpd, mpdBase, proxy);
      expect(out,
          contains('<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">'
              '<BaseURL>P[cache]https://cdn.example.com/dash/bbb/</BaseURL>'));
      expect(out, contains(r'media="$RepresentationID$/$Number%05d$.m4s"'));
    });

    test('rewrites absolute and root-relative references', () {
      const mpd = '<MPD type="static"><BaseURL>https://media.example.com/x/</BaseURL>'
          '<Period><BaseURL>sub/</BaseURL><AdaptationSet>'
          r'<SegmentTemplate media="/abs/$Number$.m4s?a=1&amp;b=2"/>'
          '</AdaptationSet></Period></MPD>';
      final out = rewriteDash(mpd, mpdBase, proxy);
      expect(out, contains('<BaseURL>P[cache]https://media.example.com/x/</BaseURL>'));
      expect(out, contains('<BaseURL>sub/</BaseURL>'));
      expect(out,
          contains(r'media="P[cache]https://cdn.example.com/abs/$Number$.m4s?a=1&amp;b=2"'));
      // An MPD-level BaseURL exists: nothing inserted.
      expect('<BaseURL>'.allMatches(out), hasLength(2));
    });

    test('dynamic manifests pass segments through', () {
      const mpd = '<MPD type="dynamic" minimumUpdatePeriod="PT2S">'
          '<Location>https://cdn.example.com/live.mpd</Location><Period/></MPD>';
      expect(isStaticManifest(StreamKind.dash, mpd), isFalse);
      final out = rewriteDash(mpd, mpdBase, proxy);
      expect(out, contains('<BaseURL>P[passthrough]https://cdn.example.com/dash/bbb/'));
      expect(out, contains('<Location>P[manifest]https://cdn.example.com/live.mpd'));
    });
  });

  test('simulator profiles use the simulated model', () {
    expect(SwipeDeviceProfile.forAppleModel('iPhone18,1').tier,
        SwipeDeviceTier.high);
    expect(SwipeDeviceProfile.forAppleModel('iPhone12,8').tier,
        SwipeDeviceTier.mid); // SE 2nd gen
    expect(SwipeDeviceProfile.forAppleModel('iPhone10,1').tier,
        SwipeDeviceTier.low); // iPhone 8
    expect(SwipeDeviceProfile.forAppleModel('iPad16,3').tier,
        SwipeDeviceTier.high);
    expect(SwipeDeviceProfile.forAppleModel('weird').tier, SwipeDeviceTier.mid);
  });
}
