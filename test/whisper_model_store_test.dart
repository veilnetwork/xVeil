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

/// A server that honours `Range: bytes=N-`, recording what it was asked for.
/// Resuming is the point of the .part file, and a fake that ignores Range
/// would let a store that never sends the header pass.
Future<HttpServer> _serveRangeAware(
  List<int> body,
  List<String?> rangeHeaders, {
  bool honourRange = true,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    rangeHeaders.add(range);
    var from = 0;
    if (honourRange && range != null) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $from-${body.length - 1}/${body.length}',
      );
    }
    final slice = body.sublist(from);
    request.response.contentLength = slice.length;
    request.response.add(slice);
    await request.response.close();
  });
  return server;
}

/// A server that sends headers and then goes quiet, holding the socket open.
/// This is how a mobile connection actually fails: not with an error, but by
/// stopping.
Future<HttpServer> _serveThenStall(
  int declaredLength, {
  int firstChunk = 64 * 1024,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.contentLength = declaredLength;
    // A real chunk, not a token three bytes: anything smaller can sit in a
    // buffer and never reach the client, which makes "what arrived is kept"
    // look false when nothing arrived in the first place.
    request.response.add(List<int>.filled(firstChunk, 7));
    await request.response.flush();
    // Never closed: the socket stays open and no more bytes arrive.
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
      expect(result.error, isNotEmpty);
      expect(
        modelFile().existsSync(),
        isFalse,
        reason: 'a partial file must never be given the real name',
      );
      // ...but it IS kept as .part. That is the resume: 57 MiB should not
      // restart from zero because a phone changed cell.
      expect(partFile().existsSync(), isTrue);
      expect(partFile().lengthSync(), greaterThan(0));
      expect(await store.pendingBytes(), partFile().lengthSync());
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

        final seen = <double>[];
        await store.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
          onProgress: seen.add,
        );
        expect(seen, isNotEmpty);
        expect(seen.last, closeTo(1.0, 0.0001));
        expect(
          seen.every((p) => p >= 0 && p <= 1),
          isTrue,
          reason: 'a progress bar outside 0..1 is a bug people can see',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'progress is measured against the KNOWN size, not the server\'s',
      () async {
        // The size is pinned, so there is never a case where the app must guess
        // — and on a resume the server's content-length describes only the
        // remaining tail, so trusting it would show 0% when the transfer is
        // nearly done.
        final body = utf8.encode('x' * 500);
        final server = await _serve(body, declareLength: false);
        addTearDown(() => server.close(force: true));

        final seen = <double>[];
        await store.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
          onProgress: seen.add,
        );
        expect(seen, isNotEmpty);
        expect(seen.every((p) => p >= 0 && p <= 1), isTrue);
        expect(seen.last, lessThan(0.001), reason: '500 of 57 MiB is ~0%');
      },
    );
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

  group('resuming an interrupted download', () {
    // The reason the .part file survives a transport failure at all. This is
    // 57 MiB: a phone that loses its connection at 90% must not start again
    // from zero.

    test('the second attempt asks for the REST, and appends it', () async {
      final body = List<int>.generate(400, (i) => i % 251);
      final first = await _serve(body, cutOffEarly: true);
      addTearDown(() => first.close(force: true));
      await store.download(from: Uri.parse('http://127.0.0.1:${first.port}/m'));

      final stopped = await store.pendingBytes();
      expect(stopped, greaterThan(0));
      expect(stopped, lessThan(body.length));

      final ranges = <String?>[];
      final second = await _serveRangeAware(body, ranges);
      addTearDown(() => second.close(force: true));
      final result = await store.download(
        from: Uri.parse('http://127.0.0.1:${second.port}/m'),
      );

      expect(ranges.single, 'bytes=$stopped-', reason: 'it asked for the rest');
      // The body is not the real model, so verification refuses it — but the
      // refusal names the length, which is exactly what proves the remainder
      // was APPENDED rather than the whole thing fetched again.
      expect(result.error, contains('got ${body.length}'));
    });

    test(
      'a server that IGNORES Range makes it start over, not splice',
      () async {
        // Answering 200 to a Range request means the body begins at zero. The
        // leftover is not a prefix of it, and appending would glue two copies
        // together into something that could never verify.
        final body = List<int>.generate(400, (i) => i % 251);
        final first = await _serve(body, cutOffEarly: true);
        addTearDown(() => first.close(force: true));
        await store.download(
          from: Uri.parse('http://127.0.0.1:${first.port}/m'),
        );
        expect(await store.pendingBytes(), greaterThan(0));

        final ranges = <String?>[];
        final second = await _serveRangeAware(body, ranges, honourRange: false);
        addTearDown(() => second.close(force: true));
        final result = await store.download(
          from: Uri.parse('http://127.0.0.1:${second.port}/m'),
        );

        expect(ranges.single, isNotNull, reason: 'it still asked');
        expect(
          result.error,
          contains('got ${body.length}'),
          reason: 'exactly one copy on disk, not leftover + body',
        );
      },
    );

    test(
      'a restart reports progress from zero, not from the leftover',
      () async {
        // The count is the only thing the restart branch actually fixes — the
        // file is truncated either way. Left uncorrected it would show a
        // transfer beginning at 40% and then passing 100%, which is a bug a
        // person watches happen.
        final body = List<int>.generate(400, (i) => i % 251);
        final first = await _serve(body, cutOffEarly: true);
        addTearDown(() => first.close(force: true));
        await store.download(
          from: Uri.parse('http://127.0.0.1:${first.port}/m'),
        );
        final stopped = await store.pendingBytes();
        expect(stopped, greaterThan(0));

        final ranges = <String?>[];
        final second = await _serveRangeAware(body, ranges, honourRange: false);
        addTearDown(() => second.close(force: true));
        final seen = <double>[];
        await store.download(
          from: Uri.parse('http://127.0.0.1:${second.port}/m'),
          onProgress: seen.add,
        );

        expect(seen, isNotEmpty);
        expect(
          seen.last * WhisperModelStore.expectedBytes,
          closeTo(body.length.toDouble(), 1),
          reason: 'the count must reflect only what was actually written',
        );
      },
    );

    test('a leftover as long as the model is discarded, not trusted', () async {
      // A .part that already claims the full length cannot be resumed — there
      // is nothing to ask for — and trusting it would skip the hash entirely.
      partFile().writeAsBytesSync(
        List<int>.filled(WhisperModelStore.expectedBytes, 7),
      );
      final ranges = <String?>[];
      final server = await _serveRangeAware(utf8.encode('short'), ranges);
      addTearDown(() => server.close(force: true));

      await store.download(
        from: Uri.parse('http://127.0.0.1:${server.port}/m'),
      );
      expect(ranges.single, isNull, reason: 'nothing to resume from');
      expect(await store.isInstalled(), isFalse);
    });

    test(
      'verification failure DELETES the part — it can never verify later',
      () async {
        final body = List<int>.filled(WhisperModelStore.expectedBytes, 0);
        final server = await _serve(body);
        addTearDown(() => server.close(force: true));
        final result = await store.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
        );
        expect(result.error, contains('checksum'));
        expect(
          await store.pendingBytes(),
          0,
          reason: 'resuming bytes that are already wrong only fails again',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('a connection that stops rather than fails', () {
    test(
      'is abandoned, so the person is not left on a spinner',
      () async {
        // Without a stall timeout this test would hang forever — which is
        // exactly what the app did: no cancel, no retry, no way out.
        final stalling = WhisperModelStore(
          supportDirectory: () async => dir,
          stallTimeout: const Duration(milliseconds: 300),
        );
        final server = await _serveThenStall(WhisperModelStore.expectedBytes);
        addTearDown(() => server.close(force: true));

        final started = DateTime.now();
        final result = await stalling.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
        );
        final elapsed = DateTime.now().difference(started);

        expect(result.succeeded, isFalse);
        expect(
          elapsed,
          lessThan(const Duration(seconds: 5)),
          reason: 'it must give up on its own, not wait for the socket',
        );
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'and what arrived is kept, so the retry resumes',
      () async {
        // The pairing that makes the timeout worth having: giving up is only an
        // improvement if it does not throw away the megabytes already fetched.
        final stalling = WhisperModelStore(
          supportDirectory: () async => dir,
          stallTimeout: const Duration(milliseconds: 300),
        );
        final server = await _serveThenStall(WhisperModelStore.expectedBytes);
        addTearDown(() => server.close(force: true));

        await stalling.download(
          from: Uri.parse('http://127.0.0.1:${server.port}/m'),
        );
        expect(await stalling.pendingBytes(), greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });
}
