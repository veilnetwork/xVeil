import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hv_container.dart';

void main() {
  group('the password the repack is handed is the one that opened the space', () {
    /// A non-ASCII password truncated to UTF-16 code units opens nothing.
    ///
    /// This is what made report27 X29 a defect rather than a style note. The
    /// probe opens the space through `utf8.encode`; the compaction dialog
    /// recorded `password.codeUnits`, which is UTF-16 — the same thing only
    /// for ASCII. A Cyrillic character is one code unit above 255, and the
    /// `Uint8List.fromList` those bytes pass through on the way to
    /// `compact_known` truncates it. The identity had already been ticked off
    /// the roster as covered by then.
    test('code units are not the bytes that open a Cyrillic password', () async {
      const pw = 'пароль-хранилища';
      final opening = utf8.encode(pw);
      final asCodeUnits = Uint8List.fromList(pw.codeUnits);
      expect(
        asCodeUnits,
        isNot(opening),
        reason: 'premise: the two encodings differ for this password',
      );

      final container = FakeHvContainer();
      final storage = container.storage();
      expect(
        await storage.open(password: pw, createIfMissing: true),
        isTrue,
        reason: 'premise: the password opens its space through UTF-8',
      );
      await storage.close();

      // What the repack would have been given.
      expect(
        container.passwordOpener(password: asCodeUnits, create: false),
        isNull,
        reason:
            'the truncated bytes open the space after all, so nothing about '
            'this encoding mismatch would ever be visible',
      );
      // And the honest bytes still do.
      final reopened = container.passwordOpener(
        password: Uint8List.fromList(opening),
        create: false,
      );
      expect(reopened, isNotNull);
      reopened!.close();
    });

    /// And the dialog uses that encoding.
    ///
    /// Source-level: the recorded bytes are only observable at the moment the
    /// repack runs, which needs a native container. What can be checked
    /// exactly is which encoding the one line uses (report27 X29).
    test('the compaction dialog records the password as UTF-8', () {
      final src = File(
        'lib/features/settings/compaction_offer_dialog.dart',
      ).readAsStringSync();
      final at = src.indexOf('passwordBytes:');
      expect(at, greaterThan(0), reason: 'the roster entry moved');
      final line = src.substring(at, src.indexOf('\n', at));
      expect(
        line,
        contains('utf8.encode(password)'),
        reason:
            'the dialog records $line — every other boundary in this path is '
            'UTF-8, and `codeUnits` is UTF-16',
      );
      expect(
        src,
        isNot(contains('password.codeUnits')),
        reason: 'a UTF-16 password encoding is back in this file',
      );
    });
  });
}
