import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A controller handed to a dialog must be owned by the widget that renders it.
///
/// This is a STRUCTURAL guard, not a timing test, because the failure is a race
/// with the route's exit transition: `showDialog`'s future completes when
/// `Navigator.pop` runs, and the route keeps its subtree mounted for another
/// ~200 ms. A caller that disposes on the next line — or in a `finally` — hands
/// a live `TextField` a dead controller. Reproducing that by pumping frames
/// would be a test that passes on a fast machine.
///
/// What it looked like in the wild, on the cloud "open a private link" prompt:
/// three framework errors 0.15 s apart —
///
///   1. A TextEditingController was used after being disposed.
///   2. 'framework.dart': Failed assertion: '_dependents.isEmpty': is not true.
///   3. Tried to build dirty widget in the wrong build scope: _MaterialInterior
///
/// Only the third reaches the red screen, so the symptom points at the widget
/// tree and the cause is two errors upstream.
///
/// The rule: inside a file that opens dialogs, a `TextEditingController` must
/// not be a LOCAL that the same function disposes. Make it a field of a
/// `State`, and it is disposed exactly when the widget using it goes away.
void main() {
  test('a dialog controller is owned by a State, not by its caller', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsStringSync().split('\n');
      final source = lines.join('\n');
      if (!source.contains('showDialog')) continue;

      for (var i = 0; i < lines.length; i++) {
        // A local declaration: indented into a function body, not a class
        // field (fields sit at two spaces).
        final match = RegExp(
          r'^\s{4,}(?:final|var)\s+(\w+)\s*=\s*TextEditingController\(',
        ).firstMatch(lines[i]);
        if (match == null) continue;
        final name = match.group(1)!;

        // Look ahead far enough to cover a dialog builder plus its teardown.
        final window = lines.skip(i).take(80).join('\n');
        final awaitsDialog =
            window.contains('await showDialog') ||
            window.contains('return showDialog') ||
            window.contains('await showModalBottomSheet');
        final disposedByCaller = RegExp(
          '^\\s*$name\\.dispose\\(\\);',
          multiLine: true,
        ).hasMatch(window);

        if (awaitsDialog && disposedByCaller) {
          offenders.add('${entity.path}:${i + 1} — `$name`');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These controllers are disposed by the caller while the dialog route '
          'is still animating out, so the TextField outlives its controller. '
          'Move each one into a State that renders the dialog and dispose it '
          'there:\n  ${offenders.join('\n  ')}',
    );
  });
}
