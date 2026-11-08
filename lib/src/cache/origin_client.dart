import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../util/bandwidth_estimator.dart';
import 'cache_config.dart';

/// A streaming response from the origin server.
class OriginResponse {
  OriginResponse._(this._response, Duration idleTimeout)
      : _stream = _response.timeout(idleTimeout);

  final HttpClientResponse _response;

  final Stream<List<int>> _stream;
  bool _listened = false;

  /// Body bytes. Cancelling the subscription closes the connection.
  Stream<List<int>> get stream {
    _listened = true;
    return _stream;
  }

  int get statusCode => _response.statusCode;
  HttpHeaders get headers => _response.headers;
  List<RedirectInfo> get redirects => _response.redirects;
  int get contentLength => _response.contentLength;
  /// First value of [name]. (`HttpHeaders.value` throws when a server
  /// repeats a header, e.g. `Accept-Ranges` twice; that is common.)
  String? header(String name) {
    final values = _response.headers[name];
    return values == null || values.isEmpty ? null : values.first;
  }

  /// Releases the connection if the body was never consumed.
  void detach() {
    if (_listened) return;
    _listened = true;
    unawaited(_response.listen(null).cancel().catchError((Object _) {}));
  }
}

/// Issues ranged GET requests to origins.
///
/// Playback ("foreground") and prefetch ("background") use separate
/// connection pools, so a video the user is watching never queues behind
/// prefetch downloads for a connection slot.
class OriginClient {
  OriginClient(this.config, {HttpClient? foreground, HttpClient? background})
      : _foreground = _configure(foreground ?? HttpClient(), config, 8),
        // The prefetcher enforces the concurrency limit; the pool only needs
        // to be large enough for it.
        _background = _configure(background ?? HttpClient(), config,
            config.maxConcurrentDownloads ?? 4);

  static HttpClient _configure(
      HttpClient client, SwipeCacheConfig config, int maxPerHost) {
    return client
      ..connectionTimeout = config.connectTimeout
      ..idleTimeout = const Duration(seconds: 30)
      ..autoUncompress = false
      ..maxConnectionsPerHost = maxPerHost
      ..userAgent = config.userAgent;
  }

  final SwipeCacheConfig config;
  final HttpClient _foreground;
  final HttpClient _background;
  final BandwidthEstimator bandwidth = BandwidthEstimator();

  int networkBytes = 0;

  /// Ranged GET of `[start, end]` (inclusive).
  Future<OriginResponse> get(
    Uri url,
    Map<String, String> headers,
    int start,
    int end, {
    bool foreground = true,
  }) =>
      send(url, headers, range: 'bytes=$start-$end', foreground: foreground);

  /// GET with an optional raw `Range` header value.
  Future<OriginResponse> send(
    Uri url,
    Map<String, String> headers, {
    String? range,
    bool foreground = true,
  }) async {
    final http = foreground ? _foreground : _background;
    final request = await http.getUrl(url).timeout(config.connectTimeout);
    request.followRedirects = true;
    headers.forEach(request.headers.set);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    // Byte offsets must refer to the stored representation.
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(config.idleTimeout);
    return OriginResponse._(response, config.idleTimeout);
  }

  /// Downloads a small resource (a manifest) completely. Throws when the
  /// status is not 2xx or the body exceeds [maxBytes].
  Future<(Uint8List body, String? contentType, Uri finalUrl)> getWhole(
    Uri url,
    Map<String, String> headers, {
    required int maxBytes,
    bool foreground = true,
  }) async {
    final response = await send(url, headers, foreground: foreground);
    if (response.statusCode < 200 || response.statusCode > 299) {
      response.detach();
      throw HttpException('Status ${response.statusCode}', uri: url);
    }
    final builder = BytesBuilder(copy: false);
    await for (final piece in response.stream) {
      builder.add(piece);
      if (builder.length > maxBytes) {
        throw HttpException('Manifest larger than $maxBytes bytes', uri: url);
      }
    }
    networkBytes += builder.length;
    var finalUrl = url;
    for (final redirect in response.redirects) {
      finalUrl = finalUrl.resolveUri(redirect.location);
    }
    return (builder.takeBytes(), response.header('content-type'), finalUrl);
  }

  void reportThroughput(int bytes, Duration elapsed) {
    bandwidth.addSample(bytes, elapsed);
  }

  void close() {
    _foreground.close(force: true);
    _background.close(force: true);
  }
}
