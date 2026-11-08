import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Local origin server used by the tests. Serves registered byte arrays with
/// (optional) Range support and records what was downloaded.
class TestOrigin {
  TestOrigin._(this._server) {
    _server.listen(_handle);
  }

  static Future<TestOrigin> start() async =>
      TestOrigin._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final Map<String, Uint8List> files = {};
  bool supportRanges = true;
  ContentType contentType = ContentType('video', 'mp4');

  /// Bytes per write; with [delayPerPacket] simulates a slow network.
  int packetSize = 16 * 1024;
  Duration delayPerPacket = Duration.zero;

  int requests = 0;
  int bytesSent = 0;

  /// Requests being served right now / the most ever served at once.
  int active = 0;
  int maxActive = 0;

  String url(String name) => 'http://127.0.0.1:${_server.port}/$name';

  Uint8List addRandom(String name, int length, {int seed = 1}) {
    final random = Random(seed);
    final data = Uint8List(length);
    for (var i = 0; i < length; i++) {
      data[i] = random.nextInt(256);
    }
    files[name] = data;
    return data;
  }

  void resetCounters() {
    requests = 0;
    bytesSent = 0;
  }

  Future<void> _handle(HttpRequest request) async {
    requests++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await _serve(request);
    } finally {
      active--;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final data = files[request.uri.pathSegments.join('/')];
    if (data == null) {
      response.statusCode = 404;
      await response.close();
      return;
    }
    var start = 0;
    var end = data.length - 1;
    final range = request.headers.value('range');
    if (supportRanges && range != null) {
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range)!;
      start = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) end = min(end, int.parse(m.group(2)!));
      if (start >= data.length) {
        response.statusCode = 416;
        response.headers.set('content-range', 'bytes */${data.length}');
        await response.close();
        return;
      }
      response.statusCode = 206;
      response.headers.set('content-range', 'bytes $start-$end/${data.length}');
    }
    response.headers.contentType = contentType;
    response.contentLength = end - start + 1;
    try {
      for (var pos = start; pos <= end; pos += packetSize) {
        final stop = min(end + 1, pos + packetSize);
        response.add(Uint8List.sublistView(data, pos, stop));
        bytesSent += stop - pos;
        if (delayPerPacket > Duration.zero) {
          await Future<void>.delayed(delayPerPacket);
        }
        await response.flush();
      }
      await response.close();
    } catch (_) {
      // Client went away.
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// Builds a minimal non fast-start MP4: ftyp, a large mdat, then moov.
Uint8List buildMp4({required int mdatPayload, required int moovPayload, bool moovFirst = false}) {
  Uint8List box(String type, int payload) {
    final size = payload + 8;
    final b = Uint8List(size);
    ByteData.sublistView(b).setUint32(0, size);
    b.setRange(4, 8, type.codeUnits);
    for (var i = 8; i < size; i++) {
      b[i] = i & 0xff;
    }
    return b;
  }

  final ftyp = box('ftyp', 16);
  final mdat = box('mdat', mdatPayload);
  final moov = box('moov', moovPayload);
  final builder = BytesBuilder()..add(ftyp);
  if (moovFirst) {
    builder
      ..add(moov)
      ..add(mdat);
  } else {
    builder
      ..add(mdat)
      ..add(moov);
  }
  return builder.takeBytes();
}

/// Reads [uri] fully (optionally with a Range header).
Future<(int status, Uint8List body, HttpHeaders headers)> fetch(
  Uri uri, {
  String? range,
  int? abortAfter,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set('range', range);
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await for (final piece in response) {
      builder.add(piece);
      if (abortAfter != null && builder.length >= abortAfter) break;
    }
    return (response.statusCode, builder.takeBytes(), response.headers);
  } finally {
    client.close(force: true);
  }
}

/// Polls [condition] until it holds or [timeout] passes.
Future<void> eventually(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
