// Recognising a model bundle arriving as a file.
//
// The name is a CLAIM chosen by whoever sent it. These tests pin what that
// claim may and may not do: it picks which card to show, and it never decides
// what gets installed — the bundle reader does that, from the manifest and the
// hashes.
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/state/model_message.dart';

void main() {
  test('what an export is named is what a receiver recognises', () {
    // The exporter and the receiver used to hold separate copies of these
    // strings. A bundle nobody recognises is a bundle nobody installs, so the
    // names now come from one place — and this asserts the round trip rather
    // than the constant.
    for (final kind in kVeilBundleKinds) {
      final named = 'whatever${kBundleExtensions[kind]}';
      expect(modelBundleKind(named), kind, reason: named);
    }
  });

  group('what a file name claims', () {
    test('the two extensions are recognised, by kind', () {
      expect(modelBundleKind('ru-en.veiltranslate'), kBundleTranslate);
      expect(modelBundleKind('speech.veilaudio'), kBundleSpeech);
      expect(isModelBundleFileName('ru-en.veiltranslate'), isTrue);
      expect(isModelBundleFileName('speech.veilaudio'), isTrue);
    });

    test('case does not matter — a sender chose the name', () {
      expect(modelBundleKind('RU-EN.VeilTranslate'), kBundleTranslate);
      expect(modelBundleKind('SPEECH.VEILAUDIO'), kBundleSpeech);
    });

    test('anything else is an ordinary file', () {
      for (final name in [
        null,
        '',
        'holiday.jpg',
        'notes.txt',
        'pack.stkpack',
        'veiltranslate',
        'ru-en.veiltranslate.exe',
        'ru-en.veiltranslatex',
      ]) {
        expect(
          isModelBundleFileName(name),
          isFalse,
          reason: 'should not be taken for a model: $name',
        );
      }
    });
  });

  group('the direction a name hints at', () {
    test('a well-formed pair name is read', () {
      expect(pairHintFromFileName('ru-en.veiltranslate'), 'ru-en');
      expect(pairHintFromFileName('/tmp/downloads/en-uk.veiltranslate'), 'en-uk');
    });

    test('a name that is not a pair hints at nothing', () {
      // Silence rather than a guess: a card that invents "xx → yy" from a
      // filename would be stating something about the model it has not read.
      for (final name in [
        'model.veiltranslate',
        'ru_en.veiltranslate',
        'russian-english.veiltranslate',
        'ru-en-extra.veiltranslate',
        '../../etc.veiltranslate',
      ]) {
        expect(pairHintFromFileName(name), isNull, reason: name);
      }
    });

    test('a speech bundle has no direction to hint at', () {
      expect(pairHintFromFileName('speech.veilaudio'), isNull);
      expect(pairHintFromFileName('ru-en.veilaudio'), isNull);
    });
  });
}
