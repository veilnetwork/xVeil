import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/ui_languages.dart';
import 'package:xveil/l10n/app_localizations.dart';

void main() {
  test('a language is named in itself, never in the reader\'s language', () {
    // The whole point: a translated list would need every language's name in
    // every other language — N² strings on top of the 1751 each translation
    // already costs — and an endonym is also the one label a person scanning
    // for their own language can actually find.
    expect(languageEndonym('de'), 'Deutsch');
    expect(languageEndonym('ru'), 'Русский');
    expect(languageEndonym('ja'), '日本語');
    expect(languageEndonym('ar'), 'العربية');
  });

  test('a script variant keeps its own name, and falls back to the base', () {
    expect(languageEndonym('zh-Hans'), '简体中文');
    expect(languageEndonym('zh-Hant'), '繁體中文');
    // A region variant nobody has named yet is still the language.
    expect(languageEndonym('pt-BR'), 'Português');
    expect(languageEndonym('de_AT'), 'Deutsch');
  });

  test('an unknown code shows itself rather than blocking the language', () {
    // Ugly beats absent: a translation must be shippable before someone
    // remembers to add its endonym here.
    expect(languageEndonym('xx'), 'xx');
    expect(hasEndonym('xx'), isFalse);
    expect(hasEndonym('pt-BR'), isTrue);
  });

  test('the list is ordered by the name shown, not by the hidden code', () {
    // Sorted by code this reads as unsorted, because the codes are invisible.
    // The order within is UTF-16 code unit — Dart has no collator — which
    // groups scripts: Latin, then Cyrillic, then CJK. Asserted exactly so the
    // grouping is a decision and not an accident.
    final sorted = sortedByEndonym(['ru', 'ja', 'de', 'en']);
    expect(sorted.map(languageEndonym).toList(), [
      'Deutsch',
      'English',
      'Русский',
      '日本語',
    ]);
    expect(sorted.first, 'de', reason: 'and it returns codes, not names');
  });

  test('right-to-left languages are known, including by variant', () {
    for (final code in ['ar', 'fa', 'he', 'ur', 'ps']) {
      expect(isRtlLanguage(code), isTrue, reason: '$code reads right-to-left');
    }
    expect(isRtlLanguage('ar-EG'), isTrue, reason: 'variants inherit');
    for (final code in ['en', 'ru', 'ja', 'tr']) {
      expect(isRtlLanguage(code), isFalse, reason: '$code does not');
    }
  });

  test('every language this build ships has a native name', () {
    // The picker lists exactly what is shipped, so a translation added without
    // an endonym would appear in the menu as a bare code. This is the check
    // that keeps that from reaching a person.
    for (final locale in AppL10n.supportedLocales) {
      final tag = locale.toLanguageTag();
      expect(
        hasEndonym(tag),
        isTrue,
        reason: 'shipped locale $tag has no entry in ui_languages.dart',
      );
    }
  });

  test('the shipped set is what the picker offers', () {
    // Guards the wiring the screen depends on: the menu is built from
    // supportedLocales, so an empty or single-entry set would silently make
    // the language choice unreachable.
    expect(AppL10n.supportedLocales, contains(const Locale('en')));
    expect(AppL10n.supportedLocales, contains(const Locale('ru')));
  });
}
