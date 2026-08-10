// Installing a model that arrived as a file, whichever kind it is.
//
// The point of these: the decision is made from the MANIFEST, not the file
// name. A sender types the name, and a .veilaudio carrying a language pair is
// not a broken speech model — it is a translation model with a misleading
// name, and it must install as one.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/state/model_import.dart';
import 'package:xveil/state/translation_model_controller.dart';

void main() {
  late Directory tmp;
  late Directory translateRoot;
  late Directory pairSource;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('xveil-import');
    translateRoot = Directory('${tmp.path}/translate')..createSync();
    pairSource = Directory('${tmp.path}/src')..createSync();
    for (final name in kPairFiles) {
      File('${pairSource.path}/$name').writeAsStringSync('$name payload');
    }
    container = ProviderContainer(
      overrides: [
        translationModelsRootProvider.overrideWithValue(() async => translateRoot),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> pairBundle({String name = 'ru-en.veiltranslate'}) async {
    final out = File('${tmp.path}/$name');
    await writeBundle(
      sourceDir: pairSource,
      pair: const TranslationPair('ru', 'en'),
      out: out,
    );
    return out;
  }

  test('a translation bundle installs and says which kind it was', () async {
    final result = await installReceivedModel(
      await pairBundle(),
      into: targetsFromContainer(container),
    );
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.kind, kBundleTranslate);
    expect(Directory('${translateRoot.path}/ru-en').existsSync(), isTrue);
  });

  test('the MANIFEST decides, not the extension', () async {
    // Named as a speech model, carrying a language pair. Handing this to the
    // speech importer would refuse it — correctly, but for a reason that would
    // read to a person as "this model is broken" when it is fine.
    final result = await installReceivedModel(
      await pairBundle(name: 'speech.veilaudio'),
      into: targetsFromContainer(container),
    );
    expect(result.succeeded, isTrue, reason: result.error);
    expect(result.kind, kBundleTranslate);
    expect(Directory('${translateRoot.path}/ru-en').existsSync(), isTrue);
  });

  test('a file that is not a bundle fails with a reason, and does not throw',
      () async {
    final junk = File('${tmp.path}/holiday.jpg')..writeAsStringSync('nope');
    final result = await installReceivedModel(
      junk,
      into: targetsFromContainer(container),
    );
    expect(result.succeeded, isFalse);
    expect(result.error, isNotEmpty);
    expect(result.kind, isNull, reason: 'nothing was readable to name a kind');
  });

  test('a failure carries the reason the controller gave', () async {
    // Sizes honest, hash a lie: past every length check, caught by hashing.
    final body = utf8.encode('weights');
    final manifest = utf8.encode(
      jsonEncode({
        'format': 1,
        'kind': 'translate',
        'from': 'ru',
        'to': 'en',
        'files': [
          for (final n in kPairFiles)
            {'name': n, 'bytes': body.length, 'sha256': 'a' * 64},
        ],
      }),
    );
    final head = ByteData(4)..setUint32(0, manifest.length);
    final file = File('${tmp.path}/lying.veiltranslate')
      ..writeAsBytesSync([
        ...utf8.encode('VEILTR1\n'),
        ...head.buffer.asUint8List(),
        ...manifest,
        for (var i = 0; i < kPairFiles.length; i++) ...body,
      ]);

    final result = await installReceivedModel(
      file,
      into: targetsFromContainer(container),
    );
    expect(result.succeeded, isFalse);
    expect(result.error, contains('hash'));
    expect(result.kind, kBundleTranslate);
    expect(Directory('${translateRoot.path}/ru-en').existsSync(), isFalse);
  });

  group('materialising', () {
    test('bytes become a file the reader can stream', () async {
      final bundle = await pairBundle();
      final bytes = bundle.readAsBytesSync();

      final written = await materialiseBundle(bytes, name: 'ru-en.veiltranslate');
      addTearDown(() => written.parent.deleteSync(recursive: true));

      expect(written.readAsBytesSync(), equals(bytes));
      // Not beside the models: a crash mid-install must not leave something
      // that looks like a half-installed pair.
      expect(written.path, isNot(contains(translateRoot.path)));

      final info = await inspectBundle(written);
      expect(info.pair!.id, 'ru-en');
    });
  });
}
