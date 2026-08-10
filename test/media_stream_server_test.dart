// Loopback media server (video epic): range grammar + a live loopback
// round-trip with the exact request shapes ExoPlayer/AVPlayer issue.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/range_source.dart';
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

  /// A stop that lands while the socket is binding must not leave it bound.
  ///
  /// `stop` sweeps what the field holds and `serve` binds before it assigns,
  /// so a stop in that window found nothing to close and `serve` then
  /// published a listener nobody holds a reference to: an open loopback socket
  /// for the life of the process, answering on a token `stop` had already
  /// cleared (report9 X-12).
  ///
  /// If the refusal is missing, `serve` resolves with a URL — and the check
  /// below proves that URL is a LIVE orphan rather than merely reporting the
  /// wrong exception type.
  test('a stop while the socket is binding leaves nothing listening', () async {
    final srv = LocalMediaServer();
    final gate = Completer<void>();
    LocalMediaServer.debugBindGate = gate.future;
    addTearDown(() => LocalMediaServer.debugBindGate = null);

    final serving = srv.serve(
      bytesRangeSource(Uint8List.fromList(List.filled(8, 1))),
      name: 'clip.mp4',
    );
    // Let serve reach the gate: bound, not yet adopted.
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await srv.stop();
    gate.complete();

    Uri? published;
    try {
      published = await serving;
    } on StateError {
      // The refusal — nothing was published, nothing is listening.
    }
    if (published != null) {
      final socket = await Socket.connect(
        '127.0.0.1',
        published.port,
      ).timeout(const Duration(seconds: 2));
      await socket.close();
      fail(
        'stop() returned and a listener is still accepting on port '
        '${published.port}: nothing holds it and nothing will close it',
      );
    }
  });

  test(
    'serves full body, honors ranges, 416s past-the-end, guards token',
    () async {
      final srv = LocalMediaServer();
      final bytes = Uint8List.fromList(List.generate(1000, (i) => i & 0xff));
      final url = await srv.serve(bytesRangeSource(bytes), name: 'clip.mp4');
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
    },
  );

  group('P0-5: the server streams instead of holding the item', () {
    test('a range request decrypts only that range', () async {
      // The whole point: opening a large video must not cost an allocation its
      // size, and a viewer who watches ten seconds must not decrypt the film.
      final reads = <(int, int)>[];
      final srv = LocalMediaServer();
      final source = RangeSource(
        size: 100 * 1024 * 1024,
        read: (offset, length) async {
          reads.add((offset, length));
          return Uint8List(length);
        },
      );
      final url = await srv.serve(source, name: 'big.mp4');
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await srv.stop();
      });

      final req = await client.getUrl(url);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=1048576-1048591');
      final res = await req.close();
      final body = await res.fold<int>(0, (n, c) => n + c.length);

      expect(res.statusCode, HttpStatus.partialContent);
      expect(body, 16);
      expect(reads, [(1048576, 16)]);
      expect(
        reads.fold<int>(0, (n, r) => n + r.$2),
        16,
        reason: 'a 16-byte seek must not read more than 16 bytes',
      );
    });

    test('a full-body GET walks in bounded hops', () async {
      final asked = <int>[];
      final size = kRangeChunkBytes * 2 + 11;
      final srv = LocalMediaServer();
      final url = await srv.serve(
        RangeSource(
          size: size,
          read: (offset, length) async {
            asked.add(length);
            return Uint8List(length);
          },
        ),
        name: 'clip.webm',
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await srv.stop();
      });

      final res = await (await client.getUrl(url)).close();
      final body = await res.fold<int>(0, (n, c) => n + c.length);

      expect(res.statusCode, HttpStatus.ok);
      expect(body, size);
      expect(
        asked.every((n) => n <= kRangeChunkBytes),
        isTrue,
        reason: 'a hop larger than the chunk defeats the bound',
      );
      expect(asked.length, greaterThan(1));
    });

    test('a HEAD reports the size without reading a byte', () async {
      var reads = 0;
      final srv = LocalMediaServer();
      final url = await srv.serve(
        RangeSource(
          size: 4096,
          read: (_, length) async {
            reads++;
            return Uint8List(length);
          },
        ),
        name: 'clip.mp4',
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await srv.stop();
      });

      final res = await (await client.headUrl(url)).close();
      await res.drain<void>();

      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentLength, 4096);
      expect(reads, 0, reason: 'a HEAD must not decrypt anything');
    });

    test('stop disposes the source, releasing its handle', () async {
      var closed = false;
      final srv = LocalMediaServer();
      await srv.serve(
        RangeSource(
          size: 10,
          read: (_, length) async => Uint8List(length),
          close: () async => closed = true,
        ),
        name: 'clip.mp4',
      );

      await srv.stop();

      expect(closed, isTrue);
    });
  });
}
