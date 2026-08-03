import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `debugPrint` is NOT compiled out of a release build.
///
/// It looks like it is — the name says debug, and next to `kDebugMode` and
/// `assert` it reads as one of the things that disappear. It does not. In a
/// release AOT build `debugPrint` is still called and still writes, to
/// `logcat` on Android, to whatever captured the process's stdout on desktop,
/// and into a crash-report pipe. For a messenger whose premise is that its
/// contents are deniable, "the log is off in release" has to be true and not
/// merely intended.
///
/// [devLog] is the one that really goes: its body sits behind a compile-time
/// `dart.vm.product`, so the branch is dead-code-eliminated and the message —
/// a thunk — is never even constructed. `lib/core/log.dart` explains the rest.
///
/// Fifteen sites had drifted back in by the time the audit found them (X-15).
/// None carried message bodies or identifiers; they were camera parameters,
/// frame counters and bind failures. That is why the finding was low, and
/// also why it is worth a check rather than a sweep: the next one is written
/// by someone reaching for the obvious name, and nothing was watching.
///
/// The headless daemon adds a second reason. `debugPrint` comes from
/// `package:flutter/foundation.dart`, and one Flutter import anywhere the
/// daemon reaches stops it compiling at all — see
/// `headless_is_flutter_free_test`. `devLog` is Flutter-free by construction.
void main() {
  test('nothing under lib/ logs through debugPrint', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Prose about the trap is not the trap. `lib/core/log.dart` names
        // `debugPrint` in the doc comment explaining why it is the wrong tool.
        if (line.trimLeft().startsWith('//')) continue;
        if (!line.contains('debugPrint')) continue;
        offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these still print in a RELEASE build, where this app promises it '
          'says nothing — use devLog() from lib/core/log.dart, which is '
          'compiled out:\n${offenders.join('\n')}',
    );
  });

  test('the check would notice if one came back', () {
    // A source scan that finds nothing proves nothing on its own: the same
    // empty list comes back from a walk that visited no files, or a match
    // that can never fire. So the scanner is pointed at a file that DOES
    // contain the word, and has to find it.
    final lines = File('lib/core/log.dart').readAsLinesSync();
    final mentions = [
      for (final line in lines)
        if (line.contains('debugPrint')) line,
    ];
    expect(
      mentions,
      isNotEmpty,
      reason: 'lib/core/log.dart documents why debugPrint is wrong; if that '
          'text is gone, so is the only thing proving this scan can match',
    );
    expect(
      mentions.every((l) => l.trimLeft().startsWith('//')),
      isTrue,
      reason: 'and every one of them must be prose, or the test above is '
          'passing because of the comment exemption rather than in spite '
          'of it',
    );
  });
}
