// A real HTTP server, not a faked client — the same choice the speech model's
// tests make, for the same reason: the thing under test is a download, and a
// fake that hands over the right bytes proves only that the fake works.
//
// What is new here, and what most of these check, is that a pair is a SET.
// Half a pair on disk must not read as installed: an engine given the weights
// and no target.spm refuses to open, and an engine given MISMATCHED tokenisers
// does something worse than refuse — it translates, into nonsense.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/translation_model_store.dart';

/// Serves each file by its name, so a request for a name nobody published is
/// a 404 rather than the wrong bytes.
Future<HttpServer> _serveFiles(Map<String, List<int>> files) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final name = request.uri.pathSegments.last;
    final body = files[name];
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.contentLength = body.length;
    for (var i = 0; i < body.length; i += 7) {
      request.response.add(
        body.sublist(i, i + 7 > body.length ? body.length : i + 7),
      );
    }
    await request.response.close();
  });
  return server;
}

TranslationModelFile _describe(String name, List<int> body) =>
    TranslationModelFile(
      name: name,
      bytes: body.length,
      sha256: sha256.convert(body).toString(),
    );

void main() {
  late Directory dir;
  late TranslationModelStore store;
  late Map<String, List<int>> bodies;
  late TranslationModel model;
  late HttpServer server;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('xveil-translate-store');
    store = TranslationModelStore(supportDirectory: () async => dir);
    bodies = {
      'model.bin': utf8.encode('weights' * 200),
      'config.json': utf8.encode('{"layers":6}'),
      'source.spm': utf8.encode('source pieces' * 30),
      'target.spm': utf8.encode('target pieces' * 30),
    };
    server = await _serveFiles(bodies);
    model = TranslationModel(
      pair: const TranslationPair('ru', 'en'),
      baseUrl: 'http://${server.address.host}:${server.port}/models/ru-en',
      files: [for (final e in bodies.entries) _describe(e.key, e.value)],
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('installed', () {
    test('nothing at all is not installed', () async {
      expect(await store.isInstalled(model), isFalse);
      expect(await store.missingFiles(model), hasLength(4));
    });

    test('a complete download is installed', () async {
      final result = await store.download(model);
      expect(result.succeeded, isTrue, reason: result.error);
      expect(await store.isInstalled(model), isTrue);
      expect(await store.missingFiles(model), isEmpty);
    });

    test('the weights alone are NOT installed', () async {
      // The failure this exists for: the big file arrives, a one-megabyte
      // tokeniser does not, and the pair looks ready because the thing a
      // person watched download is there.
      await store.download(model);
      final target = await store.directoryFor(model.pair);
      File('${target.path}/target.spm').deleteSync();

      expect(await store.isInstalled(model), isFalse);
      expect(await store.missingFiles(model), equals(['target.spm']));
    });

    test('a file of the wrong size is not installed', () async {
      await store.download(model);
      final target = await store.directoryFor(model.pair);
      File('${target.path}/source.spm').writeAsStringSync('truncated');

      expect(await store.isInstalled(model), isFalse);
      expect(await store.missingFiles(model), equals(['source.spm']));
    });
  });

  group('download', () {
    test('every file lands, with the bytes that were served', () async {
      final result = await store.download(model);
      expect(result.succeeded, isTrue, reason: result.error);
      final target = Directory(result.path!);
      for (final entry in bodies.entries) {
        final on = File('${target.path}/${entry.key}');
        expect(on.existsSync(), isTrue, reason: entry.key);
        expect(on.readAsBytesSync(), equals(entry.value), reason: entry.key);
      }
    });

    test('progress covers the whole pair and never goes backwards', () async {
      final seen = <double>[];
      await store.download(model, onProgress: seen.add);

      expect(seen, isNotEmpty);
      expect(seen.first, greaterThan(0));
      expect(seen.last, closeTo(1, 0.001));
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i],
          greaterThanOrEqualTo(seen[i - 1] - 0.000001),
          reason: 'progress went backwards at $i: ${seen[i - 1]} -> ${seen[i]}',
        );
      }

      // The assertion that actually bites, and the reason the one above is not
      // enough: reporting each FILE's own fraction instead of the pair's would
      // send 1.0 three times before the download is finished, and a sequence of
      // 1.0, 1.0, 1.0, 1.0 never goes backwards. It is also not caught by
      // chunk-counting — the client coalesces these small bodies into a single
      // read, so there is exactly one progress call per file to compare.
      //
      // So: 100% may appear only when there is nothing left to fetch.
      expect(
        seen.sublist(0, seen.length - 1).every((p) => p < 1),
        isTrue,
        reason: 'progress claimed 100% while files remained: $seen',
      );
      expect(seen.every((p) => p <= 1), isTrue);
    });

    test('a missing file on the server fails, and says which one', () async {
      final broken = TranslationModel(
        pair: model.pair,
        baseUrl: model.baseUrl,
        files: [
          ...model.files,
          const TranslationModelFile(
            name: 'vocabulary.json',
            bytes: 10,
            sha256: 'whatever',
          ),
        ],
      );
      final result = await store.download(broken);
      expect(result.succeeded, isFalse);
      expect(result.error, contains('vocabulary.json'));
      expect(result.error, contains('404'));
      expect(await store.isInstalled(broken), isFalse);
    });

    test('wrong content is refused and left off disk', () async {
      final lying = TranslationModel(
        pair: model.pair,
        baseUrl: model.baseUrl,
        files: [
          TranslationModelFile(
            name: 'model.bin',
            bytes: bodies['model.bin']!.length,
            sha256: 'a' * 64,
          ),
        ],
      );
      final result = await store.download(lying);
      expect(result.succeeded, isFalse);
      expect(result.error, contains('checksum'));
      final target = await store.directoryFor(model.pair);
      expect(File('${target.path}/model.bin').existsSync(), isFalse);
    });

    test('files already correct are not fetched again', () async {
      await store.download(model);
      // Serving nothing at all now: a second download must be satisfied
      // entirely from disk, or it will 404.
      await server.close(force: true);
      server = await _serveFiles(const {});

      final again = await store.download(model);
      expect(again.succeeded, isTrue, reason: again.error);
    });

    test('cancelling stops the set and is not an error', () async {
      var calls = 0;
      final result = await store.download(
        model,
        isCancelled: () => ++calls > 1,
      );
      expect(result.wasCancelled, isTrue);
      expect(result.error, isNull);
      expect(await store.isInstalled(model), isFalse);
    });

    test('a pair describing no files fails rather than dividing by zero', () async {
      final empty = TranslationModel(
        pair: const TranslationPair('xx', 'yy'),
        baseUrl: model.baseUrl,
        files: const [],
      );
      final result = await store.download(empty);
      expect(result.succeeded, isFalse);
      expect(result.error, contains('no files'));
    });
  });

  group('removal', () {
    test('takes the whole pair', () async {
      await store.download(model);
      await store.remove(model.pair);
      expect(await store.isInstalled(model), isFalse);
      expect((await store.directoryFor(model.pair)).existsSync(), isFalse);
    });

    test('is fine when there is nothing to remove', () async {
      await store.remove(const TranslationPair('de', 'fr'));
    });

    test('one pair does not disturb another', () async {
      await store.download(model);
      final other = TranslationModel(
        pair: const TranslationPair('en', 'ru'),
        baseUrl: model.baseUrl,
        files: model.files,
      );
      await store.download(other);

      await store.remove(other.pair);
      expect(await store.isInstalled(model), isTrue);
      expect(await store.isInstalled(other), isFalse);
    });
  });
}
