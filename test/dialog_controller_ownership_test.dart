import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A controller shown in a dialog must be owned by the widget that renders it.
///
/// This is a STRUCTURAL guard, not a timing test, because the failure is a race
/// with the route's exit transition: `showDialog`'s future completes when
/// `Navigator.pop` runs, and the route keeps its subtree mounted for another
/// ~200 ms. A caller that disposes on the next line hands a live `TextField` a
/// dead controller. Reproducing that by pumping frames would be a test that
/// passes on a fast machine — which is exactly the trap two places in this
/// repository had already fallen into, disposing after
/// `await Future.delayed(const Duration(milliseconds: 250))` with a comment
/// explaining the race they were sleeping through.
///
/// What it looked like on the cloud "open a private link" prompt: three
/// framework errors 0.15 s apart —
///
///   1. A TextEditingController was used after being disposed.
///   2. 'framework.dart': Failed assertion: '_dependents.isEmpty': is not true.
///   3. Tried to build dirty widget in the wrong build scope: _MaterialInterior
///
/// Only the third reaches the red screen, so the symptom points at the widget
/// tree and the cause is two errors upstream.
///
/// The rule is deliberately BROADER than "disposed in the wrong place": in a
/// file that opens dialogs, a `TextEditingController` must not be a local at
/// all. An undisposed local is not itself a crash, but it is the same
/// construction one edit away — and the obvious way to "fix the leak" is to
/// add `controller.dispose()` after the await, which creates the crash.
///
/// An earlier version of this test looked for a `dispose()` call within 80
/// lines of the declaration and classified anything else as harmless. Both
/// sleep-based workarounds sat 81 lines away and were reported as leaks. A
/// window is a guess about how long a function is; not having one is not.
void main() {
  test('a dialog controller is owned by a State, not by its caller', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsStringSync().split('\n');
      if (!lines.join('\n').contains('showDialog')) continue;

      for (var i = 0; i < lines.length; i++) {
        // A local declaration: indented into a function body. A controller
        // owned by a State is a field, which sits at two spaces.
        if (RegExp(
          r'^\s{4,}(?:final|var)\s+\w+\s*=\s*TextEditingController\(',
        ).hasMatch(lines[i])) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A TextEditingController declared inside a function in a file that '
          'opens dialogs outlives nothing and is owned by no one. Move it into '
          'a StatefulWidget that renders the dialog and dispose it there:\n'
          '  ${offenders.join('\n  ')}',
    );
  });

  /// No controller is disposed after a timed delay.
  ///
  /// Two places disposed their controllers after a hardcoded 250 ms delay,
  /// with a comment naming the exact race. A sleep is a bet on the machine: a
  /// slower one, a longer transition, or a different `pageTransitionsTheme`
  /// and the crash is back.
  ///
  /// Scoped to names the file declares as a `TextEditingController`: a delay
  /// followed by `something.dispose()` is an ordinary shape elsewhere — the
  /// debug hook records for N milliseconds and then releases the recorder —
  /// and a guard that cannot tell the two apart is a guard nobody keeps.
  test('no controller is disposed after a timed delay', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsStringSync().split('\n');

      final controllers = <String>{};
      for (final line in lines) {
        final m = RegExp(
          r'(?:final|var|late final)\s+(?:TextEditingController\s+)?(\w+)\s*=\s*TextEditingController\(',
        ).firstMatch(line);
        if (m != null) controllers.add(m.group(1)!);
      }
      if (controllers.isEmpty) continue;

      for (var i = 0; i < lines.length; i++) {
        if (!RegExp(
          r'Future<void>\.delayed|await Future\.delayed',
        ).hasMatch(lines[i])) {
          continue;
        }
        for (final after in lines.skip(i + 1).take(5)) {
          final d = RegExp(r'^\s*(\w+)\.dispose\(\);').firstMatch(after);
          if (d != null && controllers.contains(d.group(1))) {
            offenders.add('${entity.path}:${i + 1} — `${d.group(1)}`');
            break;
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Disposing a controller after a delay sleeps through the route '
          'transition instead of removing the race. Give the dialog its own '
          'State:\n  ${offenders.join('\n  ')}',
    );
  });
}
