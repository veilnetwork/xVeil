import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/headless/secret_file.dart';

/// What the daemon will and will not read a secret out of.
///
/// The Windows branch is the one that had no coverage and no check: a
/// `--password-file` there was accepted with nothing examined — not the owner,
/// not the ACL, not even a mode (audit X-10). `isWindows` is injected so that
/// branch is exercised from a POSIX host, which is the only place this suite
/// ever runs.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('xveil-secret-file-test');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<String> writeSecret(String name, String contents, String mode) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(contents);
    final chmod = await Process.run('chmod', [mode, file.path]);
    expect(chmod.exitCode, 0, reason: 'chmod $mode failed: ${chmod.stderr}');
    return file.path;
  }

  group('a platform that CAN check', () {
    test('an owner-only file is read', () async {
      final path = await writeSecret('ok', 'correct horse\n', '600');
      expect(
        await readSecretFile(path, 'password', isWindows: false),
        'correct horse',
      );
    });

    test('a group- or world-readable file is refused, and says how to fix it',
        () async {
      final path = await writeSecret('loose', 'secret', '644');
      await expectLater(
        readSecretFile(path, 'password', isWindows: false),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('readable beyond its owner'), contains('chmod 600')),
          ),
        ),
      );
    });

    test('the Windows escape hatch does NOT disable the POSIX check', () async {
      // The near miss: a flag added for the platform that cannot check must not
      // become a way to switch off the platform that can.
      final path = await writeSecret('loose2', 'secret', '644');
      final warnings = <String>[];
      await expectLater(
        readSecretFile(
          path,
          'password',
          isWindows: false,
          acceptUnchecked: true,
          warn: warnings.add,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('readable beyond its owner'),
          ),
        ),
      );
      expect(
        warnings.join('\n'),
        contains('has no effect on this platform'),
        reason: 'and it says so rather than looking like it worked',
      );
    });

    test('a symlink is refused rather than followed', () async {
      final target = await writeSecret('real', 'secret', '600');
      final link = Link('${dir.path}/link');
      await link.create(target);
      await expectLater(
        readSecretFile(link.path, 'password', isWindows: false),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('symlink'),
          ),
        ),
      );
    });

    test('an empty file is not a password', () async {
      final path = await writeSecret('empty', '   \n', '600');
      await expectLater(
        readSecretFile(path, 'password', isWindows: false),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('a platform that CANNOT check', () {
    test('names Windows as unable to verify, not as verified', () {
      expect(unverifiableSecretFileReason(isWindows: false), isNull);
      expect(
        unverifiableSecretFileReason(isWindows: true),
        allOf(contains('ACL'), contains('owner')),
      );
    });

    test('a secret file is REFUSED by default', () async {
      // Same file that passes on POSIX. The platform is the whole difference:
      // nothing here was examined, so nothing here may be trusted.
      final path = await writeSecret('winpw', 'correct horse', '600');
      final warnings = <String>[];
      await expectLater(
        readSecretFile(
          path,
          'password',
          isWindows: true,
          warn: warnings.add,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('cannot be verified'),
              // The refusal has to be actionable or it just moves the problem.
              contains('type the secret at the prompt'),
              contains(kAcceptUncheckedSecretFilesFlag),
              contains(kAcceptUncheckedSecretFilesEnv),
            ),
          ),
        ),
      );
      expect(
        warnings,
        isEmpty,
        reason: 'a refusal is not a warning — nothing was read',
      );
    });

    test('the operator can assert it, and is told that is all that happened',
        () async {
      final path = await writeSecret('winpw2', 'correct horse', '600');
      final warnings = <String>[];
      final value = await readSecretFile(
        path,
        'API token',
        isWindows: true,
        acceptUnchecked: true,
        warn: warnings.add,
      );
      expect(value, 'correct horse');
      expect(warnings, hasLength(1));
      expect(
        warnings.single,
        allOf(
          contains('UNCHECKED'),
          contains('API token'),
          contains('nothing here verified it'),
        ),
        reason: 'the assertion must not read like a clean bill of health',
      );
    });

    test('a symlink is still refused, flag or no flag', () async {
      final target = await writeSecret('winreal', 'secret', '600');
      final link = Link('${dir.path}/winlink');
      await link.create(target);
      await expectLater(
        readSecretFile(
          link.path,
          'password',
          isWindows: true,
          acceptUnchecked: true,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('symlink'),
          ),
        ),
      );
    });
  });
}
