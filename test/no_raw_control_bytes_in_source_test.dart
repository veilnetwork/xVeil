import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A control byte belongs in source as an ESCAPE, never as itself.
///
/// git decides a file is binary by looking for a NUL in its first 8000 bytes.
/// A test that feeds `'nul\x00'` to a sanitiser, written with the byte itself,
/// crosses that line — and from then on **its changes do not appear in any
/// diff**. Measured on this repository: `test/app_profile_test.dart` and
/// `test/received_name_is_not_a_path_test.dart` were both binary to git, which
/// is a poor place for it, since what they pin is name sanitisation and path
/// traversal.
///
/// The escaped form is the same bytes to Dart and plain ASCII to everything
/// else: git diffs it, an editor will not eat it, and nothing downstream
/// truncates at the NUL.
///
/// A doc pays a different price. `doc/EVENT-LOG-IMPL-PLAN.md` described a
/// composite key as `conv<0x1f>id` with the separator raw, so the rendered page
/// read `convid` — the very thing the sentence was explaining, invisible.
void main() {
  test('no tracked text file carries a raw control byte', () {
    final listed = Process.runSync('git', ['ls-files']);
    expect(listed.exitCode, 0, reason: 'not a git checkout?');

    const textExtensions = {
      '.dart', '.md', '.yaml', '.yml', '.arb', '.json', '.gradle', '.kts',
      '.sh', '.py', '.toml', '.txt', '.rs', '.xml', '.properties',
    };
    // TAB, LF and CR are ordinary whitespace; everything else below 0x20, plus
    // DEL, is a byte nobody types on purpose.
    bool isRawControl(int b) => (b < 9) || (b > 13 && b < 32) || b == 127;

    final offenders = <String>[];
    for (final path in (listed.stdout as String).split('\n')) {
      if (path.isEmpty) continue;
      final dot = path.lastIndexOf('.');
      if (dot < 0 || !textExtensions.contains(path.substring(dot))) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      final found = bytes.where(isRawControl).toSet();
      if (found.isEmpty) continue;
      final names = found
          .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
          .join(', ');
      offenders.add('$path ($names)');
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'write these as escapes (\\x00, \\x07, \\x1b) instead of the byte '
          'itself:\n  ${offenders.join('\n  ')}',
    );
  });

  test('the check would notice one', () {
    // Vacuity guard: the sweep above passes trivially if the predicate never
    // fires or the extension filter matches nothing.
    bool isRawControl(int b) => (b < 9) || (b > 13 && b < 32) || b == 127;

    expect(isRawControl(0x00), isTrue);
    expect(isRawControl(0x07), isTrue);
    expect(isRawControl(0x1b), isTrue);
    expect(isRawControl(0x7f), isTrue);
    // Whitespace and ordinary text must not trip it, or the check is noise
    // people learn to silence.
    expect(isRawControl(0x09), isFalse);
    expect(isRawControl(0x0a), isFalse);
    expect(isRawControl(0x0d), isFalse);
    expect(isRawControl(0x41), isFalse);
  });
}
