// The .veiltranslate parser, tested the way input from a stranger deserves.
//
// A bundle can arrive as an ordinary file in a chat, so every check here has
// to hold against a file chosen by someone else — not against one this code
// produced. Most of these build hostile bundles by hand rather than through
// writeBundle(), because a writer and a reader that only ever meet each other
// agree on their own mistakes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/data/translation_model_store.dart';

const _magic = 'VEILTR1\n';

/// Assemble a bundle from a manifest and blobs, with no consistency enforced.
File _craft(
  Directory dir,
  String name, {
  required Map<String, Object?> manifest,
  required List<List<int>> blobs,
  String magic = _magic,
  int? declaredManifestLength,
  List<int> trailing = const [],
}) {
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  final length = ByteData(4)
    ..setUint32(0, declaredManifestLength ?? manifestBytes.length);
  final out = BytesBuilder()
    ..add(utf8.encode(magic))
    ..add(length.buffer.asUint8List())
    ..add(manifestBytes);
  for (final blob in blobs) {
    out.add(blob);
  }
  out.add(trailing);
  final file = File('${dir.path}/$name')..writeAsBytesSync(out.takeBytes());
  return file;
}

Map<String, Object?> _entry(String name, List<int> body) => {
      'name': name,
      'bytes': body.length,
      'sha256': sha256.convert(body).toString(),
    };

void main() {
  late Directory tmp;
  late Directory pairDir;
  late Directory models;
  late Map<String, List<int>> bodies;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xveil-bundle');
    models = Directory('${tmp.path}/models')..createSync();
    pairDir = Directory('${tmp.path}/ru-en')..createSync();
    bodies = {
      for (final name in kPairFiles) name: utf8.encode('$name payload' * 11),
    };
    for (final e in bodies.entries) {
      File('${pairDir.path}/${e.key}').writeAsBytesSync(e.value);
    }
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> goodBundle() async {
    final out = File('${tmp.path}/ru-en.veiltranslate');
    await writeBundle(
      sourceDir: pairDir,
      pair: const TranslationPair('ru', 'en'),
      out: out,
    );
    return out;
  }

  group('round trip', () {
    test('what goes in comes out, byte for byte', () async {
      final bundle = await goodBundle();
      final info = await inspectBundle(bundle);
      expect(info.pair!.id, 'ru-en');
      expect(info.files.map((f) => f.name).toSet(), kPairFiles.toSet());

      final result = await installBundle(bundle, modelsRoot: models);
      expect(result.succeeded, isTrue, reason: result.error);
      expect(result.pair!.id, 'ru-en');
      for (final e in bodies.entries) {
        expect(
          File('${result.path}/${e.key}').readAsBytesSync(),
          equals(e.value),
          reason: e.key,
        );
      }
    });

    test('the offset the reader validated is the offset it hands on', () async {
      // installBundle used to find the body by reading the header a SECOND
      // time, so validation and extraction could apply to different bytes of a
      // file somebody else supplied. The hashes would have caught a swap, but
      // a parser for untrusted input should not hold two answers to one
      // question.
      final bundle = await goodBundle();
      final info = await inspectBundle(bundle);
      final raw = bundle.readAsBytesSync();
      final declared =
          ByteData.sublistView(Uint8List.fromList(raw), 8, 12).getUint32(0);

      expect(info.bodyOffset, 8 + 4 + declared);
      expect(
        info.bodyOffset + info.totalBytes,
        raw.length,
        reason: 'the body must run from that offset to the end of the file',
      );
    });

    test('progress runs to one and never exceeds it', () async {
      final seen = <double>[];
      await installBundle(
        await goodBundle(),
        modelsRoot: models,
        onProgress: seen.add,
      );
      expect(seen, isNotEmpty);
      expect(seen.last, closeTo(1, 0.0001));
      expect(seen.every((p) => p <= 1 && p > 0), isTrue);
    });
  });

  group('refusing what it should', () {
    test('a file that is not a bundle at all', () async {
      final junk = File('${tmp.path}/photo.jpg')
        ..writeAsBytesSync(List<int>.filled(4096, 0xff));
      expect(
        () => inspectBundle(junk),
        throwsA(isA<VeilBundleException>()),
      );
    });

    test('the right length but the wrong header', () async {
      final file = _craft(
        tmp,
        'wrong.veiltranslate',
        magic: 'NOTVEIL\n',
        manifest: {'format': 1, 'kind': 'translate', 'from': 'ru', 'to': 'en', 'files': []},
        blobs: const [],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>().having(
            (e) => e.message,
            'message',
            contains('bad header'),
          ),
        ),
      );
    });

    test('a name outside the five, however it is spelled', () async {
      for (final hostile in ['../../evil', '/etc/passwd', 'model.bin.exe', '..']) {
        final body = utf8.encode('payload');
        final file = _craft(
          tmp,
          'evil.veiltranslate',
          manifest: {
            'format': 1,
            'kind': 'translate',
            'from': 'ru',
            'to': 'en',
            'files': [_entry('model.bin', body)..['name'] = hostile],
          },
          blobs: [body],
        );
        await expectLater(
          inspectBundle(file),
          throwsA(
            isA<VeilBundleException>().having(
              (e) => e.message,
              'message for $hostile',
              contains('unexpected file'),
            ),
          ),
        );
      }
    });

    test('an incomplete pair, which is the whole point of the format', () async {
      final kept = kPairFiles.where((n) => n != 'target.spm').toList();
      final file = _craft(
        tmp,
        'partial.veiltranslate',
        manifest: {
          'format': 1,
          'kind': 'translate',
          'from': 'ru',
          'to': 'en',
          'files': [for (final n in kept) _entry(n, bodies[n]!)],
        },
        blobs: [for (final n in kept) bodies[n]!],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>().having(
            (e) => e.message,
            'message',
            contains('target.spm'),
          ),
        ),
      );
    });

    test('the same file twice', () async {
      final body = bodies['model.bin']!;
      final file = _craft(
        tmp,
        'dup.veiltranslate',
        manifest: {
          'format': 1,
          'kind': 'translate',
          'from': 'ru',
          'to': 'en',
          'files': [_entry('model.bin', body), _entry('model.bin', body)],
        },
        blobs: [body, body],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('twice')),
        ),
      );
    });

    test('trailing bytes nothing would ever check', () async {
      final bundle = await goodBundle();
      final grown = File('${tmp.path}/grown.veiltranslate')
        ..writeAsBytesSync([...bundle.readAsBytesSync(), 1, 2, 3, 4]);
      await expectLater(
        inspectBundle(grown),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('should be')),
        ),
      );
    });

    test('a truncated bundle', () async {
      final bytes = (await goodBundle()).readAsBytesSync();
      final cut = File('${tmp.path}/cut.veiltranslate')
        ..writeAsBytesSync(bytes.sublist(0, bytes.length - 20));
      await expectLater(
        inspectBundle(cut),
        throwsA(isA<VeilBundleException>()),
      );
    });

    test('a manifest length that would have us allocate', () async {
      final file = _craft(
        tmp,
        'huge.veiltranslate',
        manifest: {'format': 1, 'kind': 'translate', 'from': 'ru', 'to': 'en', 'files': []},
        blobs: const [],
        declaredManifestLength: 500 * 1024 * 1024,
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('not credible')),
        ),
      );
    });

    test('a pair that translates nothing', () async {
      final file = _craft(
        tmp,
        'same.veiltranslate',
        manifest: {
          'format': 1,
          'kind': 'translate',
          'from': 'ru',
          'to': 'ru',
          'files': [for (final n in kPairFiles) _entry(n, bodies[n]!)],
        },
        blobs: [for (final n in kPairFiles) bodies[n]!],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('translates nothing')),
        ),
      );
    });

    test('a future format is refused by name, not misread', () async {
      final file = _craft(
        tmp,
        'future.veiltranslate',
        manifest: {'format': 2, 'from': 'ru', 'to': 'en', 'files': []},
        blobs: const [],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('format 2')),
        ),
      );
    });
  });

  group('the speech kind', () {
    late Directory speechDir;
    late List<int> speechBody;

    setUp(() {
      speechDir = Directory('${tmp.path}/speech')..createSync();
      speechBody = utf8.encode('ggml weights' * 40);
      File('${speechDir.path}/${kSpeechFiles.single}')
          .writeAsBytesSync(speechBody);
    });

    Future<File> speechBundle() async {
      final out = File('${tmp.path}/speech.veilaudio');
      await writeBundle(sourceDir: speechDir, kind: kBundleSpeech, out: out);
      return out;
    }

    test('round-trips and lands as one file in the root', () async {
      final info = await inspectBundle(await speechBundle());
      expect(info.kind, kBundleSpeech);
      // No direction: one model transcribes every language it knows, so a
      // pair would be a claim the artifact cannot support.
      expect(info.pair, isNull);
      expect(info.files.single.name, kSpeechFiles.single);

      final result = await installBundle(await speechBundle(), modelsRoot: models);
      expect(result.succeeded, isTrue, reason: result.error);
      expect(result.pair, isNull);
      expect(
        File('${models.path}/${kSpeechFiles.single}').readAsBytesSync(),
        equals(speechBody),
      );
      expect(models.listSync().where((e) => e.path.contains('incoming')), isEmpty);
    });

    test('a speech bundle that names a language pair is refused', () async {
      final file = _craft(
        tmp,
        'mislabelled.veilaudio',
        manifest: {
          'format': 1,
          'kind': 'speech',
          'from': 'ru',
          'to': 'en',
          'files': [_entry(kSpeechFiles.single, speechBody)],
        },
        blobs: [speechBody],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('must not name')),
        ),
      );
    });

    test('each kind accepts only its own files', () async {
      // A speech bundle carrying model.bin, or a translation bundle carrying
      // the ggml file: the allowlist is per kind, so neither can smuggle the
      // other's names past it.
      final asSpeech = _craft(
        tmp,
        'wrongfiles.veilaudio',
        manifest: {
          'format': 1,
          'kind': 'speech',
          'files': [_entry('model.bin', speechBody)],
        },
        blobs: [speechBody],
      );
      await expectLater(
        inspectBundle(asSpeech),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('unexpected file')),
        ),
      );

      final asTranslate = _craft(
        tmp,
        'wrongfiles.veiltranslate',
        manifest: {
          'format': 1,
          'kind': 'translate',
          'from': 'ru',
          'to': 'en',
          'files': [_entry(kSpeechFiles.single, speechBody)],
        },
        blobs: [speechBody],
      );
      await expectLater(
        inspectBundle(asTranslate),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('unexpected file')),
        ),
      );
    });

    test('a bundle that does not say what it is', () async {
      final file = _craft(
        tmp,
        'nokind.veiltranslate',
        manifest: {
          'format': 1,
          'from': 'ru',
          'to': 'en',
          'files': [_entry('model.bin', speechBody)],
        },
        blobs: [speechBody],
      );
      await expectLater(
        inspectBundle(file),
        throwsA(
          isA<VeilBundleException>()
              .having((e) => e.message, 'message', contains('what kind')),
        ),
      );
    });

    test('the writer refuses to produce a mismatch', () async {
      await expectLater(
        writeBundle(
          sourceDir: speechDir,
          kind: kBundleSpeech,
          pair: const TranslationPair('ru', 'en'),
          out: File('${tmp.path}/nope'),
        ),
        throwsA(isA<VeilBundleException>()),
      );
      await expectLater(
        writeBundle(sourceDir: pairDir, out: File('${tmp.path}/nope2')),
        throwsA(isA<VeilBundleException>()),
      );
    });
  });

  group('installing', () {
    test('content that does not match its hash installs nothing', () async {
      // Sizes are honest, so this survives every length check and is caught
      // only by hashing — which is the case that matters, because it is what a
      // substitution looks like.
      final swapped = {...bodies};
      swapped['model.bin'] = utf8.encode('different weights entirely!!');
      final file = _craft(
        tmp,
        'swapped.veiltranslate',
        manifest: {
          'format': 1,
          'kind': 'translate',
          'from': 'ru',
          'to': 'en',
          'files': [
            {
              'name': 'model.bin',
              'bytes': swapped['model.bin']!.length,
              'sha256': sha256.convert(bodies['model.bin']!).toString(),
            },
            for (final n in kPairFiles.where((n) => n != 'model.bin'))
              _entry(n, bodies[n]!),
          ],
        },
        blobs: [
          swapped['model.bin']!,
          for (final n in kPairFiles.where((n) => n != 'model.bin')) bodies[n]!,
        ],
      );

      final result = await installBundle(file, modelsRoot: models);
      expect(result.succeeded, isFalse);
      expect(result.error, contains('model.bin'));
      expect(result.error, contains('hash'));
      expect(Directory('${models.path}/ru-en').existsSync(), isFalse);
      expect(
        models.listSync().where((e) => e.path.contains('incoming')),
        isEmpty,
        reason: 'staging must not be left behind',
      );
    });

    test('a second install replaces the first', () async {
      await installBundle(await goodBundle(), modelsRoot: models);
      File('${pairDir.path}/config.json').writeAsStringSync('{"v":2}');
      final again = await installBundle(
        await goodBundle(),
        modelsRoot: models,
      );
      expect(again.succeeded, isTrue, reason: again.error);
      expect(
        File('${models.path}/ru-en/config.json').readAsStringSync(),
        '{"v":2}',
      );
    });

    test('a real model survives the round trip', () async {
      // Everything above runs on hundred-byte stand-ins. This runs on a real
      // pair — 79 MB of int8 weights — because a format that only ever carries
      // toys has not been shown to carry the thing it exists for. Streaming,
      // the offset arithmetic and the hashing are all size-sensitive in a way
      // small fixtures cannot exercise.
      final source = Platform.environment['VEIL_TRANSLATE_REAL_PAIR'];
      final dir = Directory(source!);
      final out = File('${tmp.path}/real.veiltranslate');
      final id = dir.path.split(Platform.pathSeparator).last;

      await writeBundle(
        sourceDir: dir,
        pair: TranslationPair(id.split('-').first, id.split('-').last),
        out: out,
      );
      final info = await inspectBundle(out);
      expect(info.pair!.id, id);

      final result = await installBundle(out, modelsRoot: models);
      expect(result.succeeded, isTrue, reason: result.error);
      for (final name in kPairFiles) {
        expect(
          File('${result.path}/$name').lengthSync(),
          File('${dir.path}/$name').lengthSync(),
          reason: name,
        );
      }
    },
        skip: Platform.environment['VEIL_TRANSLATE_REAL_PAIR'] == null
            ? 'NOT CHECKED: set VEIL_TRANSLATE_REAL_PAIR to a converted pair '
                'directory to carry a real 79 MB model through the format.'
            : null);

    test('a file that is not there is refused, not thrown', () async {
      // dart:io raises PathNotFoundException, which is not a
      // VeilBundleException — so it went straight past the handler and
      // out through the caller. Picking a file that has since been moved is an
      // ordinary thing a person does; it must produce a sentence, not a crash.
      final result = await installBundle(
        File('${tmp.path}/never-existed.veiltranslate'),
        modelsRoot: models,
      );
      expect(result.succeeded, isFalse);
      expect(result.error, contains('cannot read the file'));

      await expectLater(
        inspectBundle(File('${tmp.path}/never-existed.veiltranslate')),
        throwsA(isA<VeilBundleException>()),
      );
    });

    test('a failed install leaves the model that was already there', () async {
      final first = await installBundle(await goodBundle(), modelsRoot: models);
      expect(first.succeeded, isTrue);

      final bad = File('${tmp.path}/bad.veiltranslate')
        ..writeAsBytesSync(utf8.encode('not a bundle'));
      final second = await installBundle(bad, modelsRoot: models);
      expect(second.succeeded, isFalse);

      // The one that worked must still be there, whole.
      for (final e in bodies.entries) {
        expect(
          File('${models.path}/ru-en/${e.key}').readAsBytesSync(),
          equals(e.value),
          reason: e.key,
        );
      }
    });
  });
}
