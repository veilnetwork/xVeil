import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A sheet that scrolls may not start under the clock.
///
/// `isScrollControlled: true` lifts the height cap Flutter puts on a modal
/// bottom sheet, which is what the long ones need — the conversation menu grew
/// to eleven entries and the short sheet reported "bottom overflowed by 243px"
/// with its tail unreachable. What it also does is let the sheet reach the very
/// top of the screen, and there it lies under the status bar: on a phone the
/// first row of the conversation menu ("Rename") sat behind the clock and the
/// battery icon (device screenshot, 2026-09-05).
///
/// A `SafeArea` around the CONTENT does not fix it. That pads the child inside
/// a sheet which is already the full height; the intrusion is the sheet's own
/// top edge, and `useSafeArea: true` on the route is what insets it.
///
/// So the rule is a pair: wherever the cap comes off, the inset goes on.
void main() {
  test('every scroll-controlled sheet is inset from the system bars', () {
    final offenders = <String>[];
    var checked = 0;

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('isScrollControlled: true')) continue;
        checked++;
        // The same argument list: look a few lines either way rather than at
        // the whole file, so an unrelated sheet's flag cannot excuse this one.
        final from = i - 6 < 0 ? 0 : i - 6;
        final to = i + 6 >= lines.length ? lines.length - 1 : i + 6;
        final near = lines.sublist(from, to + 1).join('\n');
        if (!near.contains('useSafeArea: true')) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    // Vacuity guard: this passes trivially on a tree with no such sheets, and
    // then it would be reporting health for a rule it can no longer see.
    expect(
      checked,
      greaterThanOrEqualTo(15),
      reason:
          'only $checked scroll-controlled sheet(s) found — either they moved '
          'behind a helper this test cannot see, or it is checking nothing',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'these sheets can reach the top of the screen and sit under the '
          'status bar; pass useSafeArea: true beside isScrollControlled',
    );
  });
}
