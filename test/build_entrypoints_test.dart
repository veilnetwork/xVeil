import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The build entry points carry a distribution-safety decision.
///
/// `builder.py android --release` is where the signing check lives: the
/// difference between an APK a tester can be given and one that can never be
/// updated over. That check moved out of a shell script so it would also run
/// on Windows, which means a regression in this Python is a regression in
/// what gets handed to people — and nothing else in this repository would
/// notice.
///
/// These run the scripts in --dry-run, which executes nothing, so the suite
/// stays a suite. They assert the shape of the plan, not the wording of it.
void main() {
  final python = _python();

  group('build entry points', () {
    ProcessResult run(List<String> args) => Process.runSync(
      python!,
      args,
      workingDirectory: Directory.current.path,
    );

    test('an unknown target is refused, not guessed at', () {
      final result = run(['builder.py', 'nonsense', '--dry-run']);
      expect(result.exitCode, 2);
      expect(result.stderr.toString(), contains('unknown target'));
    });

    test('a target this host cannot build is refused BEFORE any work', () {
      // Written twice. The first version asserted only an exit code of 2 and
      // the word "host" somewhere in stderr — and removing the check did not
      // fail it, because the run then went ahead, built the native libraries,
      // and died in `flutter build linux` with an exit code of 2 and a message
      // that also says "host". Refusing late is the failure this guards
      // against, so the assertion has to be that nothing ran at all.
      final elsewhere = Platform.isMacOS ? 'linux' : 'macos';
      final result = run(['builder.py', elsewhere]);

      expect(result.exitCode, 2);
      expect(result.stderr.toString(), contains('needs a'));
      expect(
        result.stdout.toString(),
        isNot(contains('[1/')),
        reason:
            'the first step must never start — a twenty-minute native '
            'build before the refusal is the whole problem',
      );
    });

    test('...but a DRY run still shows its plan', () {
      // Deliberate: reviewing the Windows plan from a Mac is otherwise
      // impossible, and printing it executes nothing.
      final elsewhere = Platform.isMacOS ? 'windows' : 'macos';
      final result = run(['builder.py', elsewhere, '--dry-run']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('dry run'));
    });

    test('the android release plan keeps its two hard-won details', () {
      final result = run(['builder.py', 'android', '--release', '--dry-run']);
      expect(result.exitCode, 0);
      final plan = result.stdout.toString();

      expect(
        plan,
        contains('--split-per-abi'),
        reason: 'the universal APK is 136 MB against 33 MB for one ABI',
      );
      expect(
        plan,
        contains('XVEIL_VERSION=${_pubspecVersion()}'),
        reason: 'a report saying "dev" cannot be tied to a build a tester has',
      );
      expect(
        plan,
        contains('signing check'),
        reason:
            'without it a debug-signed APK can be handed out, and an '
            'update can never be shipped over it',
      );
    });

    test('a debug android build does NOT claim to check signing', () {
      // The check belongs to the build that gets distributed. Running it on a
      // debug build would train people to ignore it.
      final result = run(['builder.py', 'android', '--debug', '--dry-run']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), isNot(contains('signing check')));
    });

    test('prepare names the target it prepares for', () {
      final result = run(['prepare.py', 'android', '--dry-run']);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('target: android'));
    });
  }, skip: python == null ? 'no python3 on PATH' : null);
}

String? _python() {
  for (final candidate in ['python3', 'python']) {
    final result = Process.runSync(candidate, ['--version']);
    if (result.exitCode == 0) return candidate;
  }
  return null;
}

String _pubspecVersion() {
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    if (line.startsWith('version:')) return line.split(':')[1].trim();
  }
  fail('pubspec.yaml has no version');
}
