import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/l10n/app_localizations_en.dart';
import 'package:xveil/l10n/app_localizations_es.dart';
import 'package:xveil/l10n/app_localizations_ru.dart';

/// The first-run screen used to promise the identity proof-of-work takes "up to
/// a minute". MEASURED on a BV6600Pro (8-core, mid-range): tapped at 04:15:22,
/// done by 04:25:47 — about TEN minutes, with every core saturated the whole
/// time. It is not a hang: the difficulty is 24 leading zero bits and each
/// candidate is SIGNED rather than merely hashed, so an iteration costs a
/// signature, and `DEFAULT_POW_TIMEOUT_SECS` is an hour.
///
/// The wait is the cost of the design; the promise was the defect. Someone told
/// "a minute" waits one, decides the app has hung, and kills it during the one
/// step that must not be interrupted.
void main() {
  final locales = {
    'en': AppL10nEn().preparingFirstRunBody,
    'ru': AppL10nRu().preparingFirstRunBody,
    'es': AppL10nEs().preparingFirstRunBody,
  };

  test('no locale promises the first run is over in a minute', () {
    // The exact claims that were there, per locale.
    const retired = {
      'en': 'up to a minute',
      'ru': 'до минуты',
      'es': 'hasta un minuto',
    };
    for (final entry in locales.entries) {
      expect(
        entry.value,
        isNot(contains(retired[entry.key])),
        reason:
            '${entry.key}: measured ~10 minutes on a mid-range phone — the '
            'copy has to survive the slowest device it ships to',
      );
    }
  });

  test('every locale still explains what the wait is and that it is once', () {
    // A guard that only forbids is satisfied by an empty string. These say the
    // replacement still carries the two things the screen exists to say.
    expect(locales['en'], contains('proof-of-work'));
    expect(locales['ru'], contains('proof-of-work'));
    expect(locales['es'], contains('prueba de trabajo'));

    expect(locales['en']!.toLowerCase(), contains('first time'));
    expect(locales['ru'], contains('первом запуске'));
    expect(locales['es']!.toLowerCase(), contains('primera vez'));

    // And that it names the phone, which is the device the promise broke on.
    expect(locales['en']!.toLowerCase(), contains('phone'));
    expect(locales['ru']!.toLowerCase(), contains('телефон'));
    expect(locales['es']!.toLowerCase(), contains('teléfono'));
  });
}
