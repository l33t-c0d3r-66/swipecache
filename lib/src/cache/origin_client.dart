import 'dart:async';
import 'dart:io';

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
  int get contentLength => _response.contentLength;
  String? header(String name) => _response.headers.value(name);

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

  Future<OriginResponse> get(
    Uri url,
    Map<String, String> headers,
    int start,
    int end, {
    bool foreground = true,
  }) async {
    final http = foreground ? _foreground : _background;
    final request = await http.getUrl(url).timeout(config.connectTimeout);
    request.followRedirects = true;
    headers.forEach(request.headers.set);
    request.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=$start-$end')
      // Byte offsets must refer to the stored representation.
      ..set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(config.idleTimeout);
    return OriginResponse._(response, config.idleTimeout);
  }

  void reportThroughput(int bytes, Duration elapsed) {
    bandwidth.addSample(bytes, elapsed);
  }

  void close() {
    _foreground.close(force: true);
    _background.close(force: true);
  }
}
