import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
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

  group('the read is bounded', () {
    // report9 X-04. Every check above is about WHO can read the file. None of
    // them is about how big it is, and `readAsString` read whatever was there
    // — so a correctly-owned 0600 file the operator pointed at by mistake
    // became the daemon's heap before the start had even finished.
    //
    // A secret is a password, a phrase or a token. None of them is 4 KiB.
    test('an oversized owner-only file is refused, not read', () async {
      final path = await writeSecret(
        'huge.txt',
        'x' * (kSecretFileMaxBytes + 1),
        '600',
      );
      await expectLater(
        readSecretFile(path, 'password'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('larger than'),
          ),
        ),
      );
    });

    test('a secret exactly at the ceiling is still read', () async {
      // The boundary in the other direction, so the refusal above cannot be
      // satisfied by a reader that refuses everything.
      final value = 'y' * kSecretFileMaxBytes;
      final path = await writeSecret('atlimit.txt', value, '600');
      expect(await readSecretFile(path, 'password'), value);
    });

    test('the Windows branch is bounded too', () async {
      // It reads through a different arm of the same function, and that arm
      // was the one with no coverage at all (audit X-10).
      final path = await writeSecret(
        'huge-win.txt',
        'x' * (kSecretFileMaxBytes + 1),
        '600',
      );
      await expectLater(
        readSecretFile(
          path,
          'password',
          isWindows: true,
          acceptUnchecked: true,
          warn: (_) {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

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

    test('a file owned by ANOTHER account is refused, 0600 or not', () async {
      // Mode 0600 on somebody else's file protects THEM. They can still
      // rewrite it under us, and FileStat carries no uid — so this was
      // documented as unchecked and unreachable. `lstat` carries st_uid and
      // libc carries geteuid, so it is reachable, and now checked.
      final path = await writeSecret('theirs', 'secret', '600');
      final euid = posixEuid();
      expect(euid, isNotNull, reason: 'no geteuid — this host cannot answer');
      // chown to another uid needs root. Rather than skip the assertion, take
      // the one file on the box that is 0600 and NOT ours if there is one;
      // otherwise assert the code path directly against a faked euid is not
      // possible, so verify the decision through a root-owned system file.
      final rootOwned = File('/etc/master.passwd');
      if (!rootOwned.existsSync() || posixLstat(rootOwned.path)?.uid == euid) {
        markTestSkipped('no other-owned 0600 file available on this host');
        return;
      }
      await expectLater(
        readSecretFile(rootOwned.path, 'password', isWindows: false),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not by this process'),
          ),
        ),
      );
      // And the control: our own file at the same mode is still read.
      expect(await readSecretFile(path, 'password', isWindows: false), 'secret');
    });

    test('a mid-read swap that preserves size AND mtime is REFUSED', () async {
      // The whole reason the comparison moved to (device, inode). Size and
      // modification time are both writable by anyone who can write the file,
      // so a detector made of those two is one `touch -r` from blind. An inode
      // is not something the attacker gets to pick.
      final ours = await writeSecret('mine', 'realsecret', '600');
      final planted = await writeSecret('theirs2', 'FAKEsecret', '600');
      expect(
        File(ours).lengthSync(),
        File(planted).lengthSync(),
        reason: 'the swap is only interesting at equal size',
      );
      // BOTH set, to an explicit value: `setLastModified` truncates to whole
      // seconds, so copying one file's stamp onto the other leaves the
      // original's sub-second part behind and the two would differ for a
      // reason that has nothing to do with the check.
      final stamp = DateTime.utc(2020, 1, 1, 12);
      File(ours).setLastModifiedSync(stamp);
      File(planted).setLastModifiedSync(stamp);
      expect(File(ours).statSync().size, File(planted).statSync().size);
      expect(
        File(ours).statSync().modified,
        File(planted).statSync().modified,
        reason: 'a size+mtime detector would call these two identical',
      );

      // An async body runs synchronously to its first await, and the first
      // await here is the read — so by this line the "before" lstat and every
      // check are already done, and the swap lands in exactly the window the
      // detection exists for.
      final reading = readSecretFile(ours, 'password', isWindows: false);
      File(ours).deleteSync();
      File(planted).renameSync(ours);

      await expectLater(
        reading,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('changed while it was being read'),
          ),
        ),
        reason:
            'same name, same size, same mtime, different inode — refusing is '
            'the only safe answer, because the bytes may be the planted ones',
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

  /// The SHARED-secret path: the obfs4 PSK, which every APK already carries.
  ///
  /// It cannot demand owner-only permissions the way [readSecretFile] does —
  /// the value is public by construction — but the two things that have nothing
  /// to do with secrecy still apply, and did not: `headless_runtime` read this
  /// with a bare `readAsString`, no type check and no ceiling, AFTER unlocking
  /// the container.
  group('a shared deployment secret', () {
    test('an ordinary file is read and trimmed', () async {
      final path = await writeSecret('psk', 'AAAABBBBCCCC=\n', '644');
      expect(await readSharedSecretFile(path, 'obfs4 PSK'), 'AAAABBBBCCCC=');
    });

    test('group- and world-readable is FINE here — the key ships in every APK',
        () async {
      final path = await writeSecret('psk666', 'shared-key', '666');
      expect(await readSharedSecretFile(path, 'obfs4 PSK'), 'shared-key');
    });

    test('a named pipe is refused rather than waited on', () async {
      final fifo = '${dir.path}/psk.fifo';
      final mk = await Process.run('mkfifo', [fifo]);
      expect(mk.exitCode, 0, reason: 'mkfifo failed: ${mk.stderr}');
      // Nothing ever opens the write end. The old bare `readAsString` would
      // still be sitting here when the test timed out; this has to come back.
      await expectLater(
        readSharedSecretFile(fifo, 'obfs4 PSK').timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError('BLOCKED on the fifo'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('not a regular file'), isNot(contains('BLOCKED'))),
          ),
        ),
      );
    });

    test('a directory is refused', () async {
      final sub = Directory('${dir.path}/psk.d');
      await sub.create();
      await expectLater(
        readSharedSecretFile(sub.path, 'obfs4 PSK'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not a regular file'),
          ),
        ),
      );
    });

    test('a file past the ceiling is refused, not loaded', () async {
      final path = await writeSecret('big', 'x' * (64 + 1), '600');
      await expectLater(
        readSharedSecretFile(path, 'obfs4 PSK', maxBytes: 64),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('larger than 64 bytes'),
          ),
        ),
      );
    });

    test('exactly at the ceiling is not over it', () async {
      final path = await writeSecret('exact', 'x' * 64, '600');
      expect(
        await readSharedSecretFile(path, 'obfs4 PSK', maxBytes: 64),
        'x' * 64,
      );
    });

    test('the default ceiling is small enough to matter', () async {
      expect(kSharedSecretFileMaxBytes, lessThanOrEqualTo(64 * 1024));
      final path = await writeSecret(
        'huge',
        'y' * (kSharedSecretFileMaxBytes + 1),
        '600',
      );
      await expectLater(
        readSharedSecretFile(path, 'obfs4 PSK'),
        throwsA(isA<StateError>()),
      );
    });

    test('an empty file is still empty', () async {
      final path = await writeSecret('blank', '   \n', '600');
      await expectLater(
        readSharedSecretFile(path, 'obfs4 PSK'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('is empty'),
          ),
        ),
      );
    });
  });
}
