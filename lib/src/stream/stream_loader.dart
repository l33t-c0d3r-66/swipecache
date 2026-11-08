import 'dart:async';
import 'dart:convert';

import '../cache/cache_config.dart';
import '../cache/cache_store.dart';
import '../cache/origin_client.dart';
import '../util/logger.dart';
import 'stream_manifest.dart';

/// A manifest ready to be parsed or rewritten.
class LoadedManifest {
  const LoadedManifest({
    required this.kind,
    required this.body,
    required this.base,
    required this.fromCache,
  });

  final StreamKind kind;
  final String body;

  /// URL relative references resolve against (after redirects).
  final Uri base;
  final bool fromCache;

  bool get isStatic => isStaticManifest(kind, body);
}

/// Loads HLS playlists and DASH manifests for the proxy and the prefetcher.
///
/// Static manifests (VOD) are stored with their video and served from disk
/// afterwards, so a cached stream starts without any network round trip.
/// Live manifests are always fetched fresh and never stored.
class StreamLoader {
  StreamLoader(this.store, this.client, this.config);

  final CacheStore store;
  final OriginClient client;
  final SwipeCacheConfig config;

  final Map<String, Map<String, String>> _headers = {};
  final Map<String, Future<LoadedManifest>> _loading = {};

  /// Videos found to be live: nothing of them is stored (a master playlist
  /// looks static even when its variants are live).
  final Set<String> _liveGroups = {};

  /// Origin headers (auth...) for every resource of the video [group].
  void registerHeaders(String group, Map<String, String>? headers) {
    if (headers != null && headers.isNotEmpty) _headers[group] = headers;
  }

  Map<String, String> headersFor(String group) => _headers[group] ?? const {};

  Future<LoadedManifest> load(Uri url, String group, {bool foreground = true}) {
    final key = store.keyFor(url);
    // The callback must not return the removed future: whenComplete would
    // wait for it, i.e. for itself.
    return _loading[key] ??=
        _load(url, group, foreground).whenComplete(() {
      _loading.remove(key);
    });
  }

  Future<LoadedManifest> _load(Uri url, String group, bool foreground) async {
    final headers = headersFor(group);
    final entry = store.obtain(url, headers: headers, group: group);
    entry.touch();
    if (entry.isComplete && (entry.totalLength ?? 0) > 0) {
      try {
        final body = utf8.decode(await entry.readAll(), allowMalformed: true);
        final kind =
            streamKindFor(url, contentType: entry.contentType, head: body);
        if (kind != null && isStaticManifest(kind, body)) {
          return LoadedManifest(
            kind: kind,
            body: body,
            base: entry.resolvedUrl ?? url,
            fromCache: true,
          );
        }
      } catch (error) {
        SwipeLog.v('Cached manifest unreadable for $url: $error');
      }
    }
    final (bytes, contentType, finalUrl) = await client.getWhole(
      url,
      headers,
      maxBytes: config.maxManifestBytes,
      foreground: foreground,
    );
    final body = utf8.decode(bytes, allowMalformed: true);
    final kind = streamKindFor(url, contentType: contentType, head: body);
    if (kind == null) {
      throw FormatException('Not an HLS/DASH manifest', url.toString());
    }
    if (!isStaticManifest(kind, body)) {
      if (_liveGroups.add(group)) {
        SwipeLog.v('Live stream, not stored: $url');
        await store.removeGroup(group);
      }
    } else if (!_liveGroups.contains(group)) {
      if (finalUrl != url) entry.resolvedUrl = finalUrl;
      await entry.storeWhole(bytes, manifestContentType(kind));
    }
    return LoadedManifest(
        kind: kind, body: body, base: finalUrl, fromCache: false);
  }
}
