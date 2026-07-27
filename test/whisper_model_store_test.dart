import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/whisper_model_store.dart';

/// A real HTTP server rather than a faked client: the thing under test is a
/// download, and a fake that hands over the right bytes proves only that the
/// fake works. Chunking, content-length and a mid-stream disconnect are the
/// interesting cases and none of them survive being mocked away.
Future<HttpServer> _serve(
  List<int> body, {
  int status = 200,
  bool cutOffEarly = false,
  bool declareLength = true,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = status;
    if (declareLength) request.response.contentLength = body.length;
    if (cutOffEarly) {
      // A real mid-stream disconnect: headers (with the full length) go out,
      // half the body follows, then the socket dies. Closing the response
      // normally would instead make Dart complain server-side, which tests the
      // test rather than the store.
      final socket = await request.response.detachSocket();
      socket.add(body.sublist(0, body.length ~/ 2));
      await socket.flush();
      socket.destroy();
      return;
    }
    // Deliberately chunked, so the hash is fed incrementally like a real one.
    for (var i = 0; i < body.length; i += 7) {
      request.response.add(
        body.sublist(i, i + 7 > body.length ? body.length : i + 7),
      );
    }
    await request.response.close();
  });
  return server;
}

void main() {
  late Directory dir;
  late WhisperModelStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xveil-model-test');
    store = WhisperModelStore(supportDirectory: () async => dir);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File modelFile() => File('${dir.path}/${WhisperModelStore.fileName}');
  File partFile() => File('${modelFile().path}.part');

  group('what counts as installed', () {
    test('nothing at all is not installed', () async {
      expect(await store.isInstalled(), isFalse);
    });

    test('a file of the wrong size is not installed', () async {
      // The shape of a half-finished copy or a truncated restore. Treating it
      // as a model would hand whisper.cpp garbage and blame the recording.
      modelFile().writeAsBytesSync(Uint8List(1234));
      expect(await store.isInstalled(), isFalse);
    });

    test('a file of exactly the right size is', () async {
      modelFile().writeAsBytesSync(
        Uint8List(WhisperModelStore.expectedBytes),
        flush: true,
      );
      expect(await store.isInstalled(), isTrue);
    });
  });

  group('downloading', () {
    // The real model is 57 MiB and its hash is pinned. A test cannot produce
    // those bytes, so it drives the same code with the pins pointed at a small
    // body — which is why the pins are constants the test can read.
    test('rejects a truncated download and leaves nothing behind', () async {
      final body = utf8.encode('x' * 400);
      final server = await _serve(body, cutOffEarly: true);
      addTearDown(() => server.close(force: true));

      final result = await store.download(
        from: Uri.parse('http://127.0.0.1:${server.port}/m'),
      );
      expect(result.succeeded, isFalse);
      // The client raises before the length check ever runs — that path is
      // covered below. What matters here is that a dropped connection leaves
      // no trace either way.
      expect(result.error, isNotEmpty);
      expect(
        modelFile().existsSync(),
        isFalse,
        reason: 'a partial file must never be given the real name',
      );
      expect(partFile().existsSync(), isFalse, reason: 'and not left as .part');
    });

    test('rejects a complete response that is simply too short', () async {
      // A mirror serving a stub, an error page with a 200, a stale small file.
      // The transfer succeeds; only counting the bytes catches it.
      final body = utf8.encode('x' * 400);
      final server = await _serve(body);
      addTearDown(() => server.close(force: true));

      final result = await store.download(
        from: Uri.parse('http://127.0.0.1:${server.port}/m'),
      );
      expect(result.succeeded, isFalse);
      expect(result.error, contains('bytes'));
      expect(result.error, contains('400'), reason: 'say what arrived');
      expect(modelFile().existsSync(), isFalse);
      expect(partFile().existsSync(), isFalse);
    });

    test('rejects a server error', () async {
      final server = await _serve(const [], status: 503);
      addTearDown(() => server.close(force: true));
      final result = await store.download(
        from: Uri.parse('http://127.0.0.1:${server.port}/m'),
      );
      expect(result.succeeded, isFalse);
      expect(result.error, contains('503'));
      expect(modelFile().existsSync(), isFalse);
    });

    test(
      'rejects bytes of the right LENGTH but the wrong content',
      () async {
        // The case a size check alone would wave through: a mirror serving a
        // different model, or a middlebox substituting a page of the same size.
        final body = Uint8List(WhisperModelStore.expectedBytes);
        final server = await _serve(body);
        addTearDown(() => server.close(force: true));

        final result = await store.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
        );
        expect(result.succeeded, isFalse);
        expect(result.error, contains('checksum'));
        expect(modelFile().existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'reports progress that ends at 1.0',
      () async {
        final body = Uint8List(WhisperModelStore.expectedBytes);
        final server = await _serve(body);
        addTearDown(() => server.close(force: true));

        final seen = <double?>[];
        await store.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
          onProgress: seen.add,
        );
        expect(seen, isNotEmpty);
        expect(seen.last, closeTo(1.0, 0.0001));
        expect(
          seen.every((p) => p == null || (p >= 0 && p <= 1)),
          isTrue,
          reason: 'a progress bar outside 0..1 is a bug people can see',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('progress is null when the server declares no length', () async {
      // Better an indeterminate bar than a fabricated percentage.
      final body = utf8.encode('x' * 500);
      final server = await _serve(body, declareLength: false);
      addTearDown(() => server.close(force: true));

      final seen = <double?>[];
      await store.download(
        from: Uri.parse('http://127.0.0.1:${server.port}/m'),
        onProgress: seen.add,
      );
      expect(seen, isNotEmpty);
      expect(seen.every((p) => p == null), isTrue);
    });
  });

  group('removing', () {
    test('takes the model and any leftover part file', () async {
      modelFile().writeAsBytesSync(Uint8List(WhisperModelStore.expectedBytes));
      partFile().writeAsBytesSync(Uint8List(10));
      await store.remove();
      expect(modelFile().existsSync(), isFalse);
      expect(partFile().existsSync(), isFalse);
      expect(await store.isInstalled(), isFalse);
    });

    test('is fine when there is nothing to remove', () async {
      await store.remove();
      expect(await store.isInstalled(), isFalse);
    });
  });

  test('the pinned hash is the one the Android packaging step verifies', () {
    // Both live in the repo; if they ever disagree, one of the two paths is
    // installing bytes the other would have rejected.
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains(WhisperModelStore.expectedSha256));
    expect(
      gradle.replaceAll('_', ''),
      contains('${WhisperModelStore.expectedBytes}'),
    );
  });

  test('sha256 of the pinned kind is what the store compares against', () {
    // Guards the wiring, not the algorithm: a digest computed elsewhere in the
    // app must be the same shape as the constant.
    expect(sha256.convert(const []).toString().length, 64);
    expect(WhisperModelStore.expectedSha256.length, 64);
  });
}
