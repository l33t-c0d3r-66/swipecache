/// HLS playlist and DASH manifest handling: detection, VOD/live
/// classification, parsing for prefetch, and rewriting so every
/// sub-resource is requested through the caching proxy.
library;

enum StreamKind { hls, dash }

/// How the proxy serves a URL referenced by a manifest.
enum ProxyMode {
  /// Stored on disk while streaming (VOD segments, playlists).
  cache,

  /// Streamed straight through, never stored (live segments, keys).
  passthrough,

  /// A playlist/manifest: fetched (or read from disk when static), then
  /// rewritten.
  manifest,
}

/// Builds the proxy URL for an absolute origin URL string.
typedef ProxyUrlBuilder = String Function(String absoluteUrl, ProxyMode mode);

const _hlsTypes = {
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
  'audio/mpegurl',
  'audio/x-mpegurl',
};

/// Detects a stream manifest from its URL, then its Content-Type, then its
/// first bytes.
StreamKind? streamKindFor(Uri url, {String? contentType, String? head}) {
  final path = url.path.toLowerCase();
  if (path.endsWith('.m3u8') || path.endsWith('.m3u')) return StreamKind.hls;
  if (path.endsWith('.mpd')) return StreamKind.dash;
  final type = contentType?.split(';').first.trim().toLowerCase();
  if (type != null) {
    if (_hlsTypes.contains(type)) return StreamKind.hls;
    if (type == 'application/dash+xml') return StreamKind.dash;
  }
  if (head != null) {
    final start = head.trimLeft();
    if (start.startsWith('#EXTM3U')) return StreamKind.hls;
    if (start.startsWith('<?xml') || start.startsWith('<MPD')) {
      if (start.contains('<MPD')) return StreamKind.dash;
    }
  }
  return null;
}

String manifestContentType(StreamKind kind) => switch (kind) {
      StreamKind.hls => 'application/vnd.apple.mpegurl',
      StreamKind.dash => 'application/dash+xml',
    };

/// `true` for manifests that never change: HLS master and VOD media
/// playlists, static DASH manifests. Live ones must always be refetched.
bool isStaticManifest(StreamKind kind, String body) => switch (kind) {
      StreamKind.hls => body.contains('#EXT-X-STREAM-INF') ||
          body.contains('#EXT-X-ENDLIST') ||
          body.contains('#EXT-X-PLAYLIST-TYPE:VOD'),
      StreamKind.dash => !_dynamicMpd.hasMatch(body),
    };

final _dynamicMpd = RegExp(r'''<MPD\b[^>]*\btype\s*=\s*["']dynamic["']''');

/// Turns [ref] (as found in a manifest) into an absolute URL string, or
/// `null` for non-HTTP references (`data:`, `skd:` keys...) that must be
/// left untouched.
String? _absolute(Uri base, String ref) {
  final trimmed = ref.trim();
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return trimmed;
  }
  if (RegExp(r'^[a-z][a-z0-9+.-]*:').hasMatch(lower)) return null;
  try {
    return base.resolve(trimmed).toString();
  } catch (_) {
    return null;
  }
}

// -----------------------------------------------------------------------------
// HLS
// -----------------------------------------------------------------------------

final _attribute = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

Map<String, String> parseHlsAttributes(String list) {
  final result = <String, String>{};
  for (final m in _attribute.allMatches(list)) {
    var value = m.group(2)!;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    result[m.group(1)!] = value;
  }
  return result;
}

/// Tags whose `URI` attribute references a playlist (served via the
/// manifest path, mode irrelevant) or live-only parts.
const _playlistUriTags = {
  '#EXT-X-MEDIA',
  '#EXT-X-I-FRAME-STREAM-INF',
  '#EXT-X-RENDITION-REPORT',
};
const _keyTags = {'#EXT-X-KEY', '#EXT-X-SESSION-KEY'};

/// Rewrites every URI of an HLS playlist to go through the proxy.
///
/// Segments and init sections of VOD playlists are cached; those of live
/// playlists, and all encryption keys, pass through without being stored.
String rewriteHls(String body, Uri base, ProxyUrlBuilder proxy) {
  final static = isStaticManifest(StreamKind.hls, body);
  final master = body.contains('#EXT-X-STREAM-INF');
  final media = master
      ? ProxyMode.manifest
      : static
          ? ProxyMode.cache
          : ProxyMode.passthrough;
  final out = StringBuffer();
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    final cr = line.endsWith('\r');
    if (cr) line = line.substring(0, line.length - 1);
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      out.write(line);
    } else if (!trimmed.startsWith('#')) {
      final abs = _absolute(base, trimmed);
      out.write(abs == null ? line : proxy(abs, media));
    } else if (trimmed.contains('URI="')) {
      final tag = trimmed.split(':').first;
      final mode = _keyTags.contains(tag)
          ? ProxyMode.passthrough
          : _playlistUriTags.contains(tag)
              ? ProxyMode.manifest
              : tag == '#EXT-X-MAP'
                  ? (static ? ProxyMode.cache : ProxyMode.passthrough)
                  : ProxyMode.passthrough; // parts, preload hints, data
      out.write(line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (m) {
        final abs = _absolute(base, m.group(1)!);
        return abs == null ? m.group(0)! : 'URI="${proxy(abs, mode)}"';
      }));
    } else {
      out.write(line);
    }
    if (cr) out.write('\r');
    if (i < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

class HlsVariant {
  const HlsVariant(this.uri, {this.bandwidth, this.audioGroup});
  final Uri uri;
  final int? bandwidth;
  final String? audioGroup;
}

/// A byte range of a resource (`EXT-X-BYTERANGE`), inclusive.
class HlsResource {
  const HlsResource(this.uri, {this.start, this.length});
  final Uri uri;
  final int? start;
  final int? length;
}

/// The parts of an HLS playlist needed to prefetch the start of a video.
class HlsPlaylist {
  HlsPlaylist._({
    required this.isMaster,
    required this.isStatic,
    required this.variants,
    required this.defaultAudio,
    required this.initSection,
    required this.segments,
  });

  final bool isMaster;
  final bool isStatic;
  final List<HlsVariant> variants;

  /// Default audio rendition playlist per `GROUP-ID`.
  final Map<String, Uri> defaultAudio;
  final HlsResource? initSection;
  final List<HlsResource> segments;

  static HlsPlaylist parse(String body, Uri base) {
    final variants = <HlsVariant>[];
    final audio = <String, Uri>{};
    final segments = <HlsResource>[];
    HlsResource? init;
    Map<String, String>? pendingVariant;
    (int?, int)? pendingRange;
    var nextOffset = 0;
    Uri? lastUri;

    Uri? resolve(String ref) {
      final abs = _absolute(base, ref);
      return abs == null ? null : Uri.tryParse(abs);
    }

    (int?, int)? parseRange(String value) {
      final parts = value.split('@');
      final length = int.tryParse(parts[0].trim());
      if (length == null) return null;
      final offset = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
      return (offset, length);
    }

    for (final raw in body.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingVariant = parseHlsAttributes(line.substring(18));
      } else if (line.startsWith('#EXT-X-MEDIA:')) {
        final a = parseHlsAttributes(line.substring(13));
        final group = a['GROUP-ID'];
        final uri = a['URI'] == null ? null : resolve(a['URI']!);
        if (a['TYPE'] == 'AUDIO' && group != null && uri != null) {
          if (a['DEFAULT'] == 'YES' || !audio.containsKey(group)) {
            audio[group] = uri;
          }
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final a = parseHlsAttributes(line.substring(11));
        final uri = a['URI'] == null ? null : resolve(a['URI']!);
        if (uri != null && init == null) {
          final range = a['BYTERANGE'] == null ? null : parseRange(a['BYTERANGE']!);
          init = HlsResource(uri, start: range?.$1 ?? (range == null ? null : 0),
              length: range?.$2);
        }
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        pendingRange = parseRange(line.substring(17));
      } else if (!line.startsWith('#')) {
        final uri = resolve(line);
        final variant = pendingVariant;
        pendingVariant = null;
        if (uri == null) continue;
        if (variant != null) {
          variants.add(HlsVariant(uri,
              bandwidth: int.tryParse(variant['BANDWIDTH'] ?? ''),
              audioGroup: variant['AUDIO']));
        } else {
          final range = pendingRange;
          pendingRange = null;
          if (range == null) {
            segments.add(HlsResource(uri));
          } else {
            // Without an offset the range continues the previous one.
            final start = range.$1 ?? (uri == lastUri ? nextOffset : 0);
            segments.add(HlsResource(uri, start: start, length: range.$2));
            nextOffset = start + range.$2;
          }
          lastUri = uri;
        }
      }
    }
    return HlsPlaylist._(
      isMaster: variants.isNotEmpty,
      isStatic: isStaticManifest(StreamKind.hls, body),
      variants: variants,
      defaultAudio: audio,
      initSection: init,
      segments: segments,
    );
  }

  /// The variant a player is expected to start with: AVPlayer (iOS/macOS)
  /// always starts with the first listed one; ExoPlayer (Android) picks by
  /// bandwidth, so the best variant fitting ~70% of [bitsPerSecond].
  HlsVariant? startVariant({required bool firstListed, double? bitsPerSecond}) {
    if (variants.isEmpty) return null;
    if (firstListed) return variants.first;
    final budget = (bitsPerSecond ?? 2.5e6) * 0.7;
    final sorted = [...variants]
      ..sort((a, b) => (a.bandwidth ?? 0).compareTo(b.bandwidth ?? 0));
    var pick = sorted.first;
    for (final v in sorted) {
      if ((v.bandwidth ?? 0) <= budget) pick = v;
    }
    return pick;
  }
}

// -----------------------------------------------------------------------------
// DASH
// -----------------------------------------------------------------------------

final _baseUrlElement =
    RegExp(r'<BaseURL(\s[^>]*)?>([^<]*)</BaseURL>', caseSensitive: true);
final _locationElement = RegExp(r'<(Location|PatchLocation)(\s[^>]*)?>([^<]*)</\1>');
final _urlAttribute =
    RegExp(r'''(\s(?:media|initialization|sourceURL|index))=(["'])([^"']*)\2''');
final _mpdOpen = RegExp(r'<MPD\b[^>]*>');

String _xmlDecode(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _xmlEncode(String s) => s.replaceAll('&', '&amp;');

/// Rewrites a DASH manifest so all segment requests go through the proxy.
///
/// An MPD-level `<BaseURL>` pointing at the proxied manifest directory is
/// inserted when there is none, so relative segment URLs (the common case,
/// including `SegmentTemplate`s) resolve to the proxy; absolute and
/// root-relative URLs are rewritten in place. Segments of dynamic (live)
/// manifests pass through without being stored.
String rewriteDash(String body, Uri base, ProxyUrlBuilder proxy) {
  final mode = isStaticManifest(StreamKind.dash, body)
      ? ProxyMode.cache
      : ProxyMode.passthrough;

  String? rewriteRef(String raw, ProxyMode m, {bool onlyRooted = true}) {
    final ref = _xmlDecode(raw.trim());
    final lower = ref.toLowerCase();
    final rooted = lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        ref.startsWith('/');
    if (onlyRooted && !rooted) return null;
    // Templates ($Number%05d$...) are not valid URIs: only the scheme and
    // authority are resolved, the rest is copied verbatim.
    final String abs;
    if (lower.startsWith('http')) {
      abs = ref;
    } else if (ref.startsWith('//')) {
      abs = '${base.scheme}:$ref';
    } else if (ref.startsWith('/')) {
      abs = '${base.scheme}://${base.authority}$ref';
    } else {
      final resolved = _absolute(base, ref);
      if (resolved == null) return null;
      abs = resolved;
    }
    return _xmlEncode(proxy(abs, m));
  }

  final firstPeriod = body.indexOf('<Period');
  var hasTopBaseUrl = false;
  var result = body.replaceAllMapped(_baseUrlElement, (m) {
    final topLevel = firstPeriod < 0 || m.start < firstPeriod;
    if (topLevel) hasTopBaseUrl = true;
    // MPD-level relative BaseURLs resolve against the manifest URL.
    final rewritten = rewriteRef(m.group(2)!, mode, onlyRooted: !topLevel);
    if (rewritten == null) return m.group(0)!;
    return '<BaseURL${m.group(1) ?? ''}>$rewritten</BaseURL>';
  });
  result = result.replaceAllMapped(_locationElement, (m) {
    final rewritten =
        rewriteRef(m.group(3)!, ProxyMode.manifest, onlyRooted: false);
    if (rewritten == null) return m.group(0)!;
    return '<${m.group(1)}${m.group(2) ?? ''}>$rewritten</${m.group(1)}>';
  });
  result = result.replaceAllMapped(_urlAttribute, (m) {
    final rewritten = rewriteRef(m.group(3)!, mode);
    if (rewritten == null) return m.group(0)!;
    return '${m.group(1)}=${m.group(2)}$rewritten${m.group(2)}';
  });
  if (!hasTopBaseUrl) {
    final open = _mpdOpen.firstMatch(result);
    if (open != null) {
      final dir = base.resolve('.').toString();
      result = result.replaceRange(open.end, open.end,
          '<BaseURL>${_xmlEncode(proxy(dir, mode))}</BaseURL>');
    }
  }
  return result;
}
