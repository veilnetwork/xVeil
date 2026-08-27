import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_lifecycle.dart';

/// Load, somebody else saves, Apply.
///
/// The config editor reads the whole file and writes the whole file back. So a
/// change made by a second administrator — or an automation, or the node's own
/// writer — between those two moments is not merged and not reported: it is
/// rolled back by whoever loaded first, and the only trace is that a revoked
/// allowlist id, a listener or a hardening setting is quietly back.
///
/// Run as shell, because the check has to happen on the far end at the moment
/// of the install, and reading the script cannot tell whether it does.
void main() {
  const digestOfEmpty =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// Run the guard the write script carries, against a file whose current
  /// contents are [onDisk], claiming it hashed to [expected] when read.
  ///
  /// Everything else the script does — staging, validating, installing,
  /// restarting a unit — needs a server, so only the guard is executed here.
  ProcessResult check({required String onDisk, required String? expected}) {
    final dir = Directory.systemTemp.createTempSync('xveil-cas');
    addTearDown(() => dir.deleteSync(recursive: true));
    final backup = File('${dir.path}/config.backup')..writeAsStringSync(onDisk);

    final script = buildWriteNodeConfigScript(
      NodeConfigTarget.veil,
      'irrelevant = true\n',
      expectedSha256: expected,
    );
    final lines = script.split('\n');
    final from = lines.indexWhere(
      (l) => l.startsWith('if [ "\$had_config" = 1 ]; then'),
    );
    final guard = from < 0
        // No digest was given, so the script carries no guard at all.
        ? '# nothing'
        : lines.sublist(from, lines.indexOf('fi', from) + 1).join('\n');

    return Process.runSync('bash', [
      '-c',
      'set -euo pipefail\n'
          'sudo() { "\$@"; }\n'
          'had_config=1\n'
          'backup="${backup.path}"\n'
          '$guard\n'
          'echo INSTALLED',
    ]);
  }

  test('the file it read is the file it replaces', () {
    final same = check(onDisk: '', expected: digestOfEmpty);

    expect(same.exitCode, 0, reason: '${same.stderr}');
    expect(same.stdout, contains('INSTALLED'));
  });

  test('a file somebody else changed is NOT overwritten', () {
    // The whole scenario: A loads, B saves, A applies. A's copy does not
    // contain B's change, and a full-file write would drop it.
    final changed = check(
      onDisk: 'b_was_here = true\n',
      expected: digestOfEmpty,
    );

    expect(changed.exitCode, isNot(0));
    expect(changed.stderr, contains('XVEIL_CONFIG_CHANGED'));
    expect(
      changed.stdout,
      isNot(contains('INSTALLED')),
      reason: 'the install ran anyway, so the check is a report not a guard',
    );
  });

  test('the digest compared is of the bytes about to be replaced', () {
    // Premise: the comparison must be against the file's CURRENT contents, not
    // against what the caller passed in. Staging the new contents and hashing
    // those would pass every time.
    final body = 'listen = "obfs4-tcp://0.0.0.0:5556"\n';
    final actual = sha256.convert(utf8.encode(body)).toString();

    expect(check(onDisk: body, expected: actual).exitCode, 0);
    expect(check(onDisk: body, expected: digestOfEmpty).exitCode, isNot(0));
  });

  group('what the read reports', () {
    const body = 'x = 1\n';
    final encoded = base64Encode(utf8.encode(body));

    test('a digest comes back with the contents', () {
      final read = parseReadNodeConfig(
        'XVEIL_CONFIG_SHA256: $digestOfEmpty\n'
        'XVEIL_CONFIG_BEGIN\n$encoded\n'
        'XVEIL_CONFIG_END\n',
      );

      expect(read!.contents, body);
      expect(read.sha256, digestOfEmpty);
    });

    test('a node whose script is too old reports none, and says so', () {
      // Null rather than a made-up value: it means "this save cannot check",
      // which is a narrower promise and not a different one.
      final read = parseReadNodeConfig(
        'XVEIL_CONFIG_BEGIN\n$encoded\n'
        'XVEIL_CONFIG_END\n',
      );

      expect(read!.contents, body);
      expect(read.sha256, isNull);
      // And the write it produces carries no guard, rather than one that
      // compares against nothing.
      expect(
        buildWriteNodeConfigScript(NodeConfigTarget.veil, 'a = 1\n'),
        isNot(contains('XVEIL_CONFIG_CHANGED')),
      );
    });

    test('the read script asks for the digest at all', () {
      expect(
        buildReadNodeConfigScript(NodeConfigTarget.veil),
        contains('sha256sum'),
      );
    });
  });

  test('a digest that is not one is refused before anything runs', () {
    for (final bad in ['', 'latest', 'g' * 64, '0' * 63]) {
      expect(
        () => buildWriteNodeConfigScript(
          NodeConfigTarget.veil,
          'a = 1\n',
          expectedSha256: bad,
        ),
        throwsArgumentError,
        reason: bad,
      );
    }
  });

  group('the staged copy is not readable by the machine', () {
    // The staged file is the CONTENTS of the target. For the veil target that
    // is `/var/lib/veil/node.toml`, which carries `[identity] private_key` —
    // and the real file is `0600` for exactly that reason.
    //
    // The staging area used to be `0711` with the file at `0644`, under a
    // fixed name, in `/tmp`. Any local account could poll for the directory
    // and read the key without sudo (report16 X16-H3).
    String script(NodeConfigTarget target) =>
        buildWriteNodeConfigScript(target, 'a = 1\n');

    test('no world bit is handed out anywhere', () {
      for (final target in NodeConfigTarget.values) {
        final text = script(target);
        expect(
          text,
          isNot(contains('chmod 711')),
          reason: '${target.name}: the staging directory is world-traversable',
        );
        expect(
          text,
          isNot(contains('chmod 0644')),
          reason: '${target.name}: the staged secret is world-readable',
        );
      }
    });

    test('the validator gets in by group, and only the validator', () {
      // veil and ogate are validated by a command running as `veil`, so that
      // account has to READ the staged file — through the group, never
      // through the world.
      for (final target in [NodeConfigTarget.veil, NodeConfigTarget.ogate]) {
        final text = script(target);
        expect(text, contains('chown root:veil "\$stage"'));
        expect(text, contains('chmod 0710 "\$stage"'));
        expect(text, contains('chown root:veil "\$temp"'));
        expect(text, contains('chmod 0640 "\$temp"'));
      }
    });

    test('and a target nothing reads is root-only', () {
      // oproxy is validated by starting its service, so nobody but root opens
      // the staged file. Handing `veil` a group it does not need is a wider
      // door for no reason.
      for (final target in [
        NodeConfigTarget.oproxyClient,
        NodeConfigTarget.oproxyServer,
      ]) {
        expect(script(target), contains('chown root:root'));
        expect(script(target), isNot(contains('root:veil')));
      }
    });

    test('and the staged file is still not writable by the validator', () {
      // The property the old comment was protecting, and it must survive:
      // `veil` reads the bytes, and cannot rewrite them between the validation
      // and the install.
      expect(script(NodeConfigTarget.veil), contains('chmod 0640'));
      expect(script(NodeConfigTarget.veil), isNot(contains('chmod 0660')));
      expect(script(NodeConfigTarget.veil), isNot(contains('chmod 0770')));
    });
  });

  group('a target that moved out from under the plan', () {
    // The guard only ran when the file was still there, so the ONE change it
    // could not see was the file being removed — and the copy this screen is
    // holding would have put a deleted config back without anybody deciding
    // to (report16 XV-19).
    ({int code, String stderr}) apply({required bool present}) {
      final dir = Directory.systemTemp.createTempSync('xveil-gone');
      addTearDown(() => dir.deleteSync(recursive: true));
      final backup = File('${dir.path}/config.backup');
      if (present) backup.writeAsStringSync('');

      final script = buildWriteNodeConfigScript(
        NodeConfigTarget.veil,
        'a = 1\n',
        expectedSha256: digestOfEmpty,
      );
      final lines = script.split('\n');
      final from = lines.indexWhere(
        (l) => l.startsWith('if [ "\$had_config" = 1 ]; then'),
      );
      expect(from, isNot(-1), reason: 'the guard moved');
      final guard = lines
          .sublist(from, lines.indexOf('fi', from) + 1)
          .join('\n');

      final result = Process.runSync('bash', [
        '-c',
        'set -euo pipefail\n'
            'sudo() { "\$@"; }\n'
            'had_config=${present ? 1 : 0}\n'
            'backup="${backup.path}"\n'
            '$guard\n'
            'echo INSTALLED',
      ]);
      return (code: result.exitCode, stderr: result.stderr.toString());
    }

    test('a file that is still there is compared, as before', () {
      expect(apply(present: true).code, 0);
    });

    test('a file that was REMOVED is a conflict, not a recreate', () {
      final gone = apply(present: false);

      expect(gone.code, isNot(0));
      expect(gone.stderr, contains('XVEIL_CONFIG_CHANGED'));
      expect(gone.stderr, contains('removed'));
    });
  });

  group('two applies at once', () {
    test('existence, copy, compare and install happen under one lock', () {
      // Two administrators can otherwise both read the same digest, both copy
      // the same bytes, both find their own backup unchanged and both install
      // — last one wins, and the other's change is gone with nothing having
      // said so. The window between the copy and the install is enough alone.
      final script = buildWriteNodeConfigScript(
        NodeConfigTarget.veil,
        'a = 1\n',
        expectedSha256: digestOfEmpty,
      );

      expect(script, contains('sudo flock -w'));
      expect(script, contains(kVeilConfigLockPath));
      // The whole sequence is INSIDE the section the lock runs, not merely
      // preceded by it.
      final critical = script.substring(
        script.indexOf("<<'XVEIL_APPLY'"),
        script.indexOf('XVEIL_APPLY\n', script.indexOf("<<'XVEIL_APPLY'") + 1),
      );
      expect(critical, contains('test -f'));
      expect(critical, contains('cp --preserve'));
      expect(critical, contains('sha256sum'));
      expect(critical, contains('install -o'));
    });

    test('activation and rollback are inside the same lock', () {
      // report17 XV17-M8. The lock used to end at the install. That leaves the
      // worse half outside it: A installs and starts the unit, B takes the
      // lock and installs its own config, then A's health check fails and A
      // restores its BACKUP — the config from before A, written over B's. B
      // was told its change applied, the file says otherwise, and nothing
      // reports it.
      //
      // A rollback is a WRITE of this file. Everything that can write it has
      // to be under the same lock.
      final script = buildWriteNodeConfigScript(
        NodeConfigTarget.veil,
        'a = 1\n',
        expectedSha256: digestOfEmpty,
      );
      final open = script.indexOf("<<'XVEIL_APPLY'");
      final critical = script.substring(
        open,
        script.indexOf('XVEIL_APPLY\n', open + 1),
      );
      final after = script.substring(script.indexOf('XVEIL_APPLY\n', open + 1));

      expect(
        critical,
        contains('systemctl enable --now'),
        reason: 'activation happens after the lock is released',
      );
      expect(
        critical,
        contains(r'sudo mv "$backup" "$path"'),
        reason:
            'the rollback writes this config from outside the lock, so it '
            'can land on somebody else\'s install',
      );
      expect(
        after.contains(r'sudo mv "$backup" "$path"'),
        isFalse,
        reason: 'a second, unlocked rollback survives outside the section',
      );
      // The outcome crosses the boundary as a FILE, because a non-zero status
      // from the locked section would end the outer script through `set -e`
      // before it could report anything.
      expect(critical, contains(r'> "$stage/outcome"'));
      expect(after, contains(r'$stage/outcome'));
    });
  });
}
