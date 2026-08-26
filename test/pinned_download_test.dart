import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/pinned_download.dart';

/// A `.part` exactly as long as the artifact is what a crash between the last
/// byte and the rename leaves behind. It used to be deleted on sight — under a
/// comment promising the opposite — so the next run re-fetched the whole model.
/// For a 57-150 MiB model on a metered or absent connection that is the
/// difference between installing and not.
void main() {
  late Directory dir;
  late File target;
  late List<int> body;
  late String digest;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xveil-pinned');
    target = File('${dir.path}/model.bin');
    body = List<int>.generate(4096, (i) => (i * 7) % 251);
    digest = sha256.convert(body).toString();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // The URL points at a port nothing listens on. Any attempt to fetch fails, so
  // a successful install is itself the proof that no request was made — a
  // stronger assertion than counting calls to the client factory, which is
  // constructed before the leftover is ever looked at.
  PinnedArtifact deadUrl(int bytes, String sha) => PinnedArtifact(
    url: 'http://127.0.0.1:1/unreachable',
    bytes: bytes,
    sha256: sha,
  );

  Future<PinnedDownload> run() => fetchPinned(
    target: target,
    artifact: deadUrl(body.length, digest),
    httpClient: HttpClient.new,
    stallTimeout: const Duration(seconds: 2),
    logTag: 'test',
  );

  test(
    'a complete leftover that verifies installs with no network at all',
    () async {
      File('${target.path}.part').writeAsBytesSync(body);

      final result = await run();

      expect(result.succeeded, isTrue, reason: 'error was ${result.error}');
      expect(target.existsSync(), isTrue);
      expect(
        target.readAsBytesSync(),
        body,
        reason: 'the leftover IS the file',
      );
      expect(
        File('${target.path}.part').existsSync(),
        isFalse,
        reason: 'the part is renamed into place, not left beside it',
      );
    },
  );

  test(
    'a complete leftover that does not verify is deleted, not trusted',
    () async {
      // Right length, wrong bytes: the case the old code was protecting against.
      // It must still be destroyed — verification, not length, is what decides.
      File(
        '${target.path}.part',
      ).writeAsBytesSync(List<int>.filled(body.length, 7));

      final result = await run();

      expect(
        result.succeeded,
        isFalse,
        reason: 'the port is closed; refetch must fail',
      );
      expect(
        File('${target.path}.part').existsSync(),
        isFalse,
        reason: 'bytes that failed the hash can never pass it later',
      );
      expect(target.existsSync(), isFalse);
    },
  );

  test(
    'a leftover LONGER than the artifact is discarded without hashing',
    () async {
      File('${target.path}.part').writeAsBytesSync([...body, 1, 2, 3]);

      final result = await run();

      expect(result.succeeded, isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    },
  );

  test('a short leftover is kept for the resume it exists for', () async {
    File('${target.path}.part').writeAsBytesSync(body.sublist(0, 1000));

    final result = await run();

    expect(result.succeeded, isFalse, reason: 'nothing is listening');
    expect(
      File('${target.path}.part').lengthSync(),
      1000,
      reason: 'a transport failure keeps the partial bytes',
    );
  });

  group('an origin that sends more than the pin says exists', () {
    // The size was compared only after the stream ENDED. An origin that keeps
    // sending fast never trips the stall timeout, so the `.part` file grew
    // until the disk was full — on a download whose exact length is known in
    // advance, because that is what a pinned artifact is (report16 XV-05).
    late HttpServer server;

    /// A server that serves the artifact and then keeps going for [extra] more
    /// chunks of a quarter megabyte each — large enough that the socket
    /// buffers fill, so the client giving up is something this side notices.
    Future<PinnedArtifact> serving({required int extra}) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        try {
          req.response.add(body);
          await req.response.flush();
          for (var i = 0; i < extra; i++) {
            req.response.add(List.filled(256 * 1024, 1));
            await req.response.flush();
          }
          await req.response.close();
        } catch (_) {
          // The client went away, which is the point.
        }
      });
      return PinnedArtifact(
        url: 'http://127.0.0.1:${server.port}/x',
        bytes: body.length,
        sha256: digest,
      );
    }

    Future<PinnedDownload> fetch(PinnedArtifact artifact) => fetchPinned(
      target: target,
      artifact: artifact,
      httpClient: HttpClient.new,
      stallTimeout: const Duration(seconds: 5),
      logTag: 'test',
    );

    test('is cut off near the pinned size, not at the end of the disk', () async {
      // The artifact is 4 KiB; the origin offers eight megabytes after it.
      final result = await fetch(await serving(extra: 32));

      expect(result.succeeded, isFalse);
      expect(result.error, contains('more than'));
      // WHERE it stopped, which is the quantity that matters. Counting what
      // the server managed to send does not work: `flush` on an HttpResponse
      // resolves once the bytes are handed on, so eight megabytes go out
      // whether or not anybody is reading them — measured, before this.
      expect(
        result.error,
        contains('stopped at ${body.length}'),
        reason: 'it kept writing past the pinned size; that is the disk',
      );
      expect(
        File('${target.path}.part').existsSync(),
        isFalse,
        reason: 'a partial with nothing to resume towards was kept',
      );
    });

    test('CONTROL: an origin that sends exactly what was pinned installs', () async {
      // Vacuity guard: a cap that fires one byte early would fail every
      // download there is.
      final result = await fetch(await serving(extra: 0));

      expect(result.succeeded, isTrue, reason: 'error was ${result.error}');
      expect(target.lengthSync(), body.length);
    });
  });
}
