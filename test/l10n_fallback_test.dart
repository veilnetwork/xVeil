// An unsupported system language must not be an exception.
//
// The app ships three translations and `lookupAppL10n` THROWS on a fourth.
// Inside the widget tree that never shows, because `MaterialApp` resolves the
// OS locale against `supportedLocales` before any delegate is asked. Outside
// it there is no such step — and three places call the lookup from outside:
// the desktop tray, and the two call-notification paths.
//
// What that cost, per site: the tray's menu refresh died, and a call threw
// BEFORE `VeilBackground.start`, so the foreground service never came up. The
// comment at that site says what follows — the OS takes the mic capture and
// then the process. It surfaced first as locale `C` in a bare container, which
// made it look like a container curiosity. It is every user whose system is
// not English, Spanish or Russian.

import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/locale_controller.dart';

void main() {
  test('a language with no translation resolves to English, not an exception', () {
    // `C` is the one observed, and it is not special: the assertion is about
    // every language the app does not ship, so the list is long enough that
    // passing by accident is not available.
    for (final code in [
      'C', 'de', 'fr', 'zh', 'pt', 'ar', 'hi', 'ja', 'ko', 'it', 'pl', 'tr',
      'uk', 'nl', 'sv', 'he', 'th', 'vi', 'id', 'fa',
    ]) {
      final got = resolveSupportedLocale(Locale(code));
      expect(
        got,
        const Locale('en'),
        reason: '"$code" resolved to $got instead of falling back',
      );
      expect(
        () => l10nFor(Locale(code)),
        returnsNormally,
        reason: 'the lookup still throws for "$code"',
      );
    }
  });

  test('a supported language is kept, region and script and all', () {
    for (final supported in AppL10n.supportedLocales) {
      expect(resolveSupportedLocale(supported), supported);
      // A region or script variant is the same translation, not a miss.
      expect(
        resolveSupportedLocale(
          Locale.fromSubtags(
            languageCode: supported.languageCode,
            countryCode: 'XX',
          ),
        ),
        supported,
        reason: '${supported.languageCode}_XX fell back instead of matching',
      );
    }
  });

  test('no locale at all is English rather than a crash', () {
    expect(resolveSupportedLocale(null), const Locale('en'));
    expect(() => l10nFor(null), returnsNormally);
  });

  /// The positive control: the fallback must be real strings, not an empty
  /// object that merely fails to throw.
  test('the fallback answers with actual English text', () {
    final l = l10nFor(const Locale('C'));
    expect(l.localeName, 'en');
    expect(l.appName, isNotEmpty);
  });

  /// And nothing in `lib/` may reach the throwing lookup again.
  ///
  /// This is the half that keeps the fix: the three call sites were each
  /// written by someone who knew there was no `Localizations` in scope and did
  /// not know the lookup refuses a fourth language. A fourth such site would
  /// be written the same way. Tests are free to call it directly — they pass
  /// literals.
  test('production code reaches the lookup only through the resolver', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The generated file DEFINES it; the resolver is the one door to it.
      if (entity.path.endsWith('l10n/app_localizations.dart')) continue;
      if (entity.path.endsWith('state/locale_controller.dart')) continue;
      final src = entity.readAsStringSync();
      for (final line in src.split('\n')) {
        if (line.contains('lookupAppL10n(')) {
          offenders.add('${entity.path}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'these call the throwing lookup directly; use `l10nFor` so an '
          'unsupported system language falls back instead of throwing:\n'
          '${offenders.join('\n')}',
    );
  });
}
