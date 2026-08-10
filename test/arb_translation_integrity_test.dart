// What a translation is allowed to change, and what it is not.
//
// A translator changes words. A placeholder is not a word: `{count}` is the
// name of a value the code passes in, and renaming it produces a string that
// either fails to generate or renders the brace text at the user. The same
// goes for the ICU `plural` / `select` keywords — they are grammar, not prose.
//
// The check is driven by the DECLARED placeholders in `@key.placeholders`, and
// that is the whole point of writing it that way. Reading every `{word}` out
// of the English string instead flags the body of a plural branch: the `=0`
// case of `cloudFolderItems` is literally `{empty}`, and its Russian `{пусто}`
// and Spanish `{vacía}` are correct translations of it. A check that calls
// those a defect is worse than no check — someone would "fix" them.
//
// Every shipped language, template excluded. Spanish was checked here while it
// still lived in `l10n_wip/`, before it was wired in — a file being filled in
// is exactly when this goes wrong, and finding it after it ships is late.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final template =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;

  final targets = <String, String>{
    'ru': 'lib/l10n/app_ru.arb',
    'es': 'lib/l10n/app_es.arb',
  };

  for (final entry in targets.entries) {
    final language = entry.key;
    final file = File(entry.value);
    if (!file.existsSync()) continue;
    final translated =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    test('$language keeps every placeholder the code passes in', () {
      final broken = <String>[];
      for (final key in template.keys) {
        if (key.startsWith('@')) continue;
        final source = template[key];
        if (source is! String) continue;
        final target = translated[key];
        if (target is! String) {
          broken.add('$key: absent');
          continue;
        }
        final meta = template['@$key'];
        final declared = meta is Map<String, dynamic>
            ? (meta['placeholders'] as Map<String, dynamic>? ?? const {}).keys
            : const <String>[];
        for (final name in declared) {
          // `{name}` for a plain substitution, `{name,` for the head of a
          // plural or select — both mean the value reached the string.
          if (!target.contains('{$name}') && !target.contains('{$name,')) {
            broken.add('$key: {$name} is gone');
          }
        }
      }
      expect(
        broken,
        isEmpty,
        reason:
            'these translations dropped or renamed a value the code passes '
            'in, which renders as brace text or fails to generate:\n'
            '  ${broken.join("\n  ")}',
      );
    });

    test('$language keeps the ICU grammar', () {
      final broken = <String>[];
      for (final key in template.keys) {
        if (key.startsWith('@')) continue;
        final source = template[key];
        final target = translated[key];
        if (source is! String || target is! String) continue;
        for (final keyword in ['plural', 'select']) {
          final head = RegExp(',\\s*$keyword\\s*,');
          if (head.hasMatch(source) && !head.hasMatch(target)) {
            broken.add('$key: lost the $keyword form');
          }
        }
      }
      expect(
        broken,
        isEmpty,
        reason:
            'a plural or select turned into flat text — the count-dependent '
            'forms of that language are gone:\n  ${broken.join("\n  ")}',
      );
    });

    test('$language answers every key and invents none', () {
      final source = template.keys.where((k) => !k.startsWith('@')).toSet();
      final target = translated.keys.where((k) => !k.startsWith('@')).toSet();
      expect(
        source.difference(target),
        isEmpty,
        reason: 'untranslated keys would fall back to English silently',
      );
      expect(
        target.difference(source),
        isEmpty,
        reason:
            'keys the template no longer has — deleting a string has to reach '
            'every language, or the next translator wonders what they are for',
      );
    });
  }
}
