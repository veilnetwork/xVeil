// What this device can offer a contact, and what it believes when a contact
// answers.
//
// The second half matters more than it looks: an offer list arrives from
// someone else, and every field in it is a claim. A path in particular is a
// claim about OUR filesystem, so nothing from the wire is ever used as one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/model_inventory.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/data/veil_bundle.dart';

void main() {
  late Directory tmp;
  late Directory translateRoot;
  late Directory speechRoot;

  void writePair(String id, {List<String>? omit}) {
    final dir = Directory('${translateRoot.path}/$id')..createSync(recursive: true);
    for (final name in kPairFiles) {
      if (omit != null && omit.contains(name)) continue;
      File('${dir.path}/$name').writeAsStringSync('$id/$name');
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xveil-inventory');
    translateRoot = Directory('${tmp.path}/translate')..createSync();
    speechRoot = Directory('${tmp.path}/support')..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('what this device has', () {
    test('nothing installed offers nothing', () async {
      expect(
        await localModelOffers(translateRoot: translateRoot, speechRoot: speechRoot),
        isEmpty,
      );
    });

    test('complete pairs and the speech model, sorted', () async {
      writePair('ru-en');
      writePair('en-ru');
      File('${speechRoot.path}/${kSpeechFiles.single}')
          .writeAsBytesSync(utf8.encode('ggml' * 10));

      final offers = await localModelOffers(
        translateRoot: translateRoot,
        speechRoot: speechRoot,
      );
      expect(offers.map((o) => o.label), equals(['en → ru', 'ru → en', 'speech']));
      expect(offers.every((o) => o.bytes > 0), isTrue);
    });

    test('an incomplete pair is not offered', () async {
      // Offering it would have a contact spend a transfer on something that
      // cannot translate, and the receiving end would refuse it anyway.
      writePair('de-en', omit: ['target.spm']);
      writePair('ru-en');

      final offers = await localModelOffers(
        translateRoot: translateRoot,
        speechRoot: speechRoot,
      );
      expect(offers.map((o) => o.label), equals(['ru → en']));
    });

    test('what goes on the wire carries no paths', () async {
      writePair('ru-en');
      final offer = (await localModelOffers(translateRoot: translateRoot)).single;
      final wire = offer.toWire();

      expect(wire['kind'], kBundleTranslate);
      expect(wire['from'], 'ru');
      expect(wire['to'], 'en');
      expect(wire['bytes'], isPositive);
      // A local path tells a contact about this device and nothing about the
      // model.
      expect(jsonEncode(wire), isNot(contains(tmp.path)));
      expect(wire.containsKey('sourceDir'), isFalse);
    });
  });

  group('handing one over', () {
    test('an exported pair installs on the other side', () async {
      writePair('ru-en');
      final offer = (await localModelOffers(translateRoot: translateRoot)).single;
      final file = await exportOffer(
        offer,
        out: File('${tmp.path}/${offer.suggestedFileName}'),
      );
      expect(file.path, endsWith('ru-en.veiltranslate'));

      final theirRoot = Directory('${tmp.path}/theirs')..createSync();
      final result = await installBundle(file, modelsRoot: theirRoot);
      expect(result.succeeded, isTrue, reason: result.error);
      for (final name in kPairFiles) {
        expect(File('${theirRoot.path}/ru-en/$name').existsSync(), isTrue);
      }
    });

    test('the speech model exports as its own kind', () async {
      File('${speechRoot.path}/${kSpeechFiles.single}')
          .writeAsBytesSync(utf8.encode('ggml weights' * 20));
      final offer = (await localModelOffers(speechRoot: speechRoot)).single;
      expect(offer.suggestedFileName, 'speech.veilaudio');

      final file = await exportOffer(
        offer,
        out: File('${tmp.path}/${offer.suggestedFileName}'),
      );
      final info = await inspectBundle(file);
      expect(info.kind, kBundleSpeech);
      expect(info.pair, isNull);
    });
  });

  group('believing a contact', () {
    late Directory nowhere;
    setUp(() => nowhere = Directory('${tmp.path}/nowhere'));

    test('a well-formed answer is read', () {
      final offers = offersFromWire([
        {'kind': 'translate', 'from': 'ru', 'to': 'en', 'bytes': 80000000},
        {'kind': 'speech', 'bytes': 59707625},
      ], placeholder: nowhere);

      expect(offers.map((o) => o.label), equals(['ru → en', 'speech']));
      expect(offers.first.bytes, 80000000);
    });

    test('nothing from the wire becomes a path on this device', () {
      final offers = offersFromWire([
        {
          'kind': 'translate',
          'from': 'ru',
          'to': 'en',
          'bytes': 10,
          'sourceDir': '/etc',
          'path': '../../..',
        },
      ], placeholder: nowhere);

      expect(offers, hasLength(1));
      // A path from a peer is a claim about OUR filesystem. It is not read at
      // all — the placeholder is what every remote offer gets.
      expect(offers.single.sourceDir.path, nowhere.path);
    });

    test('a malformed row is dropped, the rest survives', () {
      final offers = offersFromWire([
        {'kind': 'translate', 'from': 'ru', 'to': 'en', 'bytes': 10},
        'not a map',
        {'kind': 'nonsense', 'bytes': 10},
        {'kind': 'translate', 'from': 'ru', 'bytes': 10},
        {'kind': 'translate', 'from': 'ru', 'to': 'ru', 'bytes': 10},
        {'kind': 'translate', 'from': 'ru', 'to': 'en', 'bytes': -1},
        {'kind': 'speech', 'bytes': 5},
      ], placeholder: nowhere);

      // One bad row from a peer on a different version must not hide the rest
      // of what they have.
      expect(offers.map((o) => o.label), equals(['ru → en', 'speech']));
    });

    test('a speech offer claiming a language pair is dropped', () {
      final offers = offersFromWire([
        {'kind': 'speech', 'from': 'ru', 'to': 'en', 'bytes': 10},
      ], placeholder: nowhere);
      // Believing it would put a direction on a list a person then picks from.
      expect(offers, isEmpty);
    });

    test('an absurd size is dropped rather than shown', () {
      final offers = offersFromWire([
        {'kind': 'speech', 'bytes': 9007199254740991},
      ], placeholder: nowhere);
      expect(offers, isEmpty);
    });

    test('anything that is not a list is not an answer', () {
      expect(offersFromWire(null, placeholder: nowhere), isEmpty);
      expect(offersFromWire('nope', placeholder: nowhere), isEmpty);
      expect(offersFromWire({'kind': 'speech'}, placeholder: nowhere), isEmpty);
    });
  });
}
