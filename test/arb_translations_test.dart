import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every shipped translation, checked against the English template.
///
/// Translations arrive in bulk — 1751 strings a language — and the ways they
/// go wrong are mechanical: a key quietly dropped (the app falls back and the
/// screen is half in English), or a placeholder renamed, translated, or lost.
/// A lost `{count}` is not a typo, it is a runtime failure in a string nobody
/// looked at, in a language the author does not read. This is the gate that
/// keeps that from reaching a person, and it costs one test run.
void main() {
  final dir = Directory('lib/l10n');
  final template = _load('${dir.path}/app_en.arb');
  final templateKeys = _messageKeys(template);

  final others = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.arb') && !f.path.endsWith('app_en.arb'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the template itself is well formed', () {
    expect(templateKeys, isNotEmpty);
    expect(template['@@locale'], 'en');
    // Metadata must describe a message that exists, or gen-l10n silently
    // ignores the placeholder types and the generated API loses its arguments.
    for (final k in template.keys.where(
      (k) => k.startsWith('@') && k != '@@locale',
    )) {
      expect(
        templateKeys,
        contains(k.substring(1)),
        reason: '$k describes a message that is not in the template',
      );
    }
  });

  test('a translation ships every key, or the screen goes half-English', () {
    for (final file in others) {
      final arb = _load(file.path);
      final keys = _messageKeys(arb);
      final missing = templateKeys.difference(keys);
      final extra = keys.difference(templateKeys);
      expect(
        missing,
        isEmpty,
        reason: '${file.path} is missing ${missing.length} key(s): '
            '${missing.take(5).join(", ")}',
      );
      expect(
        extra,
        isEmpty,
        reason: '${file.path} has ${extra.length} key(s) the template does '
            'not: ${extra.take(5).join(", ")}',
      );
    }
  });

  test('a translation keeps every placeholder the template names', () {
    for (final file in others) {
      final arb = _load(file.path);
      for (final key in templateKeys) {
        final message = arb[key] as String? ?? '';
        final declared = _declared(template, key);
        if (declared.isNotEmpty) {
          // The metadata is the authority: a plural's branches are prose, and
          // no regex can tell `=0{empty}` from a placeholder called "empty".
          for (final name in declared) {
            expect(
              message.contains(RegExp('\\{\\s*$name\\b')),
              isTrue,
              reason: '${file.path}: "$key" never uses the declared '
                  'placeholder {$name} — the value it should show is missing '
                  'from the translated string',
            );
          }
        } else {
          // No metadata: every brace group in such a message IS a placeholder,
          // so the two sides must name the same ones.
          final want = _placeholders(template[key] as String);
          final got = _placeholders(message);
          expect(
            got,
            want,
            reason: '${file.path}: "$key" should use $want but uses $got — a '
                'renamed or dropped placeholder fails at runtime',
          );
        }
      }
    }
  });

  test('a translation declares its own locale', () {
    for (final file in others) {
      final arb = _load(file.path);
      final tag = file.uri.pathSegments.last
          .replaceFirst('app_', '')
          .replaceFirst('.arb', '');
      expect(
        arb['@@locale'],
        tag,
        reason: '${file.path} declares "${arb["@@locale"]}" but its name says '
            '"$tag" — gen-l10n believes the FILE NAME, so the two disagreeing '
            'is a translation shipped under the wrong language',
      );
    }
  });
}

Map<String, dynamic> _load(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// Variable names an ICU message refers to.
///
/// Catches both the plain `{name}` form and the leading name of a plural or
/// select (`{count, plural, …}`); a nested `{count}` inside a branch collapses
/// into the same name, which is what makes this comparable as a SET.
///
/// The name must be followed by `}` or `,` — that is what separates a
/// placeholder from the first word of a plural BRANCH. Without it `=0{No
/// comments}` reads as a placeholder called "No", and then every correctly
/// translated plural looks broken while the actually broken ones hide in the
/// noise. (Found exactly that way: the first version of this test failed on 16
/// sound Russian plurals.)
Set<String> _placeholders(String message) => RegExp(r'\{\s*([A-Za-z_]\w*)\s*\}')
    .allMatches(message)
    .map((m) => m.group(1)!)
    .toSet();

/// Placeholders the template DECLARES for a message, from its `@key` metadata.
///
/// gen-l10n reads these to type the generated arguments, so they are the
/// authority on what a message takes — and the only way to tell a placeholder
/// from the first word of a plural branch.
Set<String> _declared(Map<String, dynamic> arb, String key) {
  final meta = arb['@$key'];
  if (meta is Map && meta['placeholders'] is Map) {
    return (meta['placeholders'] as Map).keys.map((k) => '$k').toSet();
  }
  return const {};
}
