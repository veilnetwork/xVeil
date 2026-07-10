// Loopback media server (video epic): range grammar + a live loopback
// round-trip with the exact request shapes ExoPlayer/AVPlayer issue.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/media_stream_server.dart';

void main() {
  test('parseRange grammar: closed, open, suffix, clamps, garbage', () {
    expect(parseRange('bytes=0-99', 1000), (start: 0, end: 99));
    expect(parseRange('bytes=200-', 1000), (start: 200, end: 999));
    expect(parseRange('bytes=-100', 1000), (start: 900, end: 999));
    expect(parseRange('bytes=0-5000', 1000), (start: 0, end: 999)); // clamp
    expect(parseRange('bytes=1000-', 1000), isNull); // unsatisfiable
    expect(parseRange('bytes=50-10', 1000), isNull); // inverted
    expect(parseRange('bytes=-', 1000), isNull);
    expect(parseRange('cats=0-1', 1000), isNull);
    expect(parseRange(null, 1000), isNull);
    expect(parseRange('bytes=0-10', 0), isNull); // empty body
  });

  test('mediaMimeFor maps containers, defaults to octet-stream', () {
    expect(mediaMimeFor('a.mp4'), 'video/mp4');
    expect(mediaMimeFor('A.MOV'), 'video/quicktime');
    expect(mediaMimeFor('x.webm'), 'video/webm');
    expect(mediaMimeFor('x.bin'), 'application/octet-stream');
    expect(mediaMimeFor(null), 'application/octet-stream');
  });

  test('serves full body, honors ranges, 416s past-the-end, guards token',
      () async {
    final srv = LocalMediaServer();
    final bytes = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));
    final url = await srv.serve(bytes, name: 'clip.mp4');
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await srv.stop();
    });

    Future<HttpClientResponse> get(Uri u, {String? range}) async {
      final req = await client.getUrl(u);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      return req.close();
    }

    // Full fetch.
    var res = await get(url);
    expect(res.statusCode, 200);
    expect(res.headers.value('accept-ranges'), 'bytes');
    expect(res.headers.contentType.toString(), startsWith('video/mp4'));
    var body = (await res.fold(<int>[], (a, b) => a..addAll(b)));
    expect(body.length, 1000);

    // ExoPlayer-style open range.
    res = await get(url, range: 'bytes=900-');
    expect(res.statusCode, 206);
    expect(res.headers.value('content-range'), 'bytes 900-999/1000');
    body = (await res.fold(<int>[], (a, b) => a..addAll(b)));
    expect(body.length, 100);
    expect(body.first, 900 & 0xff);

    // Closed range.
    res = await get(url, range: 'bytes=10-19');
    expect(res.statusCode, 206);
    body = (await res.fold(<int>[], (a, b) => a..addAll(b)));
    expect(body, List.generate(10, (i) => (10 + i) & 0xff));

    // Unsatisfiable → 416.
    res = await get(url, range: 'bytes=5000-');
    expect(res.statusCode, 416);
    expect(res.headers.value('content-range'), 'bytes */1000');

    // Wrong token → 404 (a co-resident process can't fish the blob out).
    res = await get(url.replace(path: '/m/deadbeef'));
    expect(res.statusCode, 404);

    // stop() kills the endpoint.
    await srv.stop();
    expect(
      () => get(url).timeout(const Duration(seconds: 2)),
      throwsA(anything),
    );
  });
}
