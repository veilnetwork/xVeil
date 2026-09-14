// The secret that unlocks a sovereign identity, read back the way it was
// written.
//
// This exists because a person pasted their recovery phrase into the sheet
// that mints a recovery certificate and was told the operation failed. The
// phrase was correct. The native side normalizes nothing — `current_secret`
// goes into the KDF as raw bytes — and three of the four places that ask for
// the phrase trimmed the ends and sent the rest, so anything a paste brings
// along was simply the wrong key, reported as a refusal with no cause.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/sovereign_secret.dart';

void main() {
  const phrase =
      'abandon ability able about above absent absorb abstract absurd abuse '
      'access accident account accuse achieve acid acoustic acquire across '
      'act action actor actress actual';

  group('a phrase is read as words', () {
    test('a paste that wrapped onto several lines is still the phrase', () {
      // What a notes app or a password manager hands over: the words are
      // right, the separators are newlines. Before the shared rule this was
      // the wrong key, and the only symptom was "could not complete".
      final pasted = phrase.replaceFirst(' above ', '\nabove\n');
      expect(
        normalizeSovereignSecret(pasted, isRecoveryCode: false),
        phrase,
      );
    });

    test('capitals a keyboard added on its own do not change the key', () {
      expect(
        normalizeSovereignSecret('Abandon ABILITY able', isRecoveryCode: false),
        'abandon ability able',
      );
    });

    test('a double space after a wrap is one separator', () {
      expect(
        normalizeSovereignSecret('abandon  ability', isRecoveryCode: false),
        'abandon ability',
      );
    });

    test('a tab, a newline and a space are the same separator', () {
      expect(
        normalizeSovereignSecret('abandon\tability\nable', isRecoveryCode: false),
        'abandon ability able',
      );
    });

    test('nothing typed is nothing sent', () {
      expect(normalizeSovereignSecret('   \n ', isRecoveryCode: false), '');
      expect(sovereignPhraseWordCount('   \n '), 0);
    });
  });

  group('a recovery code is not words', () {
    // `generateSovereignRecoveryCode` mints `xvrc-` + base64url. Case is
    // content there: reading it by the phrase rule destroys a correct code,
    // which is why the kind is a required argument rather than a default.
    const code = 'xvrc-KHx9HKpKI3zkzi9cSP9L_fr01A6HgyQ';

    test('its capitals survive', () {
      expect(normalizeSovereignSecret(code, isRecoveryCode: true), code);
    });

    test('only the ends are trimmed', () {
      expect(normalizeSovereignSecret('  $code\n', isRecoveryCode: true), code);
    });

    test('the phrase rule would have destroyed it', () {
      // The guard on the guard: if this ever stops differing, the `kind`
      // argument has stopped meaning anything and the test above proves
      // nothing.
      expect(
        normalizeSovereignSecret(code, isRecoveryCode: false),
        isNot(code),
      );
    });
  });

  group('the counter counts what will be sent', () {
    test('a full phrase counts its words', () {
      expect(sovereignPhraseWordCount(phrase), kSovereignPhraseWords);
    });

    test('a trailing newline does not become a twenty-fifth word', () {
      // The reason the count is taken AFTER normalization. A naive split on
      // ' ' turns a pasted phrase into 25 words and accuses a correct one.
      expect(sovereignPhraseWordCount('$phrase\n'), kSovereignPhraseWords);
    });

    test('a dropped word is visible as a smaller number', () {
      final short = phrase.split(' ').take(23).join(' ');
      expect(sovereignPhraseWordCount(short), kSovereignPhraseWords - 1);
    });
  });
}
