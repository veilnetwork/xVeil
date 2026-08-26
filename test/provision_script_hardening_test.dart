import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_provisioner.dart';

/// The provisioning script stages a deployment obfs4 PSK, a TLS private key,
/// a systemd unit and the node config in a temp directory, then hands each to
/// `sudo install`. It used to do that at fixed `/tmp/xveil-*` names under the
/// login umask.
///
/// On a server with more than one account that is three problems at once:
/// another local user can read the PSK and the TLS key during the window
/// before install moves them; it can pre-create or symlink any of those names
/// and have a root-privileged install follow it; and cleanup ran only on the
/// success path, so a failed run left the secrets behind.
void main() {
  String script() => buildProvisionScript(
    const NodeProvisionConfig(
      releaseUrl: 'https://example.com/releases/veil-cli-x86_64-linux-musl',
      expectedSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      obfs4PskB64: 'dGVzdC1maXh0dXJlLXBzay1ub3QtcmVhbC12YWx1ZSE=',
    ),
  );

  test('nothing is staged at a guessable path', () {
    // Comments are stripped first: the script's own preamble explains what it
    // replaced, and matching that prose would make this pass or fail on the
    // wording rather than on what the shell actually runs.
    final commands = script()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('#'))
        .join('\n');
    expect(
      commands,
      isNot(contains('/tmp/')),
      reason: 'a fixed name under /tmp is a name an attacker can occupy first',
    );
  });

  test('the scratch directory is private, unguessable and always removed', () {
    final s = script();
    expect(s, contains('umask 077'));
    expect(s, contains(r'XVEIL_TMP="$(mktemp -d)"'));
    expect(
      s,
      contains(r'''trap 'rm -rf -- "$XVEIL_TMP"' EXIT INT TERM'''),
      reason:
          'cleanup on success only leaves the PSK and the TLS key on disk '
          'exactly when the run went wrong',
    );
  });

  test('the umask is set before anything is written', () {
    final s = script();
    expect(
      s.indexOf('umask 077'),
      lessThan(s.indexOf('mktemp -d')),
      reason: 'a directory created before the umask keeps the login mode',
    );
    expect(
      s.indexOf('mktemp -d'),
      lessThan(s.indexOf('PSK_EOF')),
      reason: 'the PSK must not be written before the private dir exists',
    );
  });

  // The hardening above locked the scratch directory to 0700 root:root. The
  // config steps further down run as the unprivileged `veil` account and both
  // read and create files in that same directory, so the lock shut them out —
  // and the failure did not look like a permission problem. `veil-cli` cannot
  // distinguish "not there" from "not allowed to look", so it reported
  //
  //     config path `/tmp/tmp.XXXXXXXX/xveil-node.toml` does not exist
  //
  // for a file that was demonstrably there (1170 bytes, veil-owned). Every
  // deployment therefore installed both binaries, failed at the config step
  // and left the server with no node running. Proven on a real host: with the
  // directory at 0700 the command reports the file as missing; `chmod` the
  // directory and the identical command lists the listeners.
  test(
    'the scratch directory is opened to the veil account, and only to it',
    () {
      // Comments must go first. The fix's own explanation names `sudo -u veil`
      // and `$XVEIL_TMP`, so an ordering assertion over the raw text would be
      // satisfied by that prose and would pass with the fix deleted.
      final commands = script()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('#'))
          .join('\n');

      final grant = commands.indexOf(r'chown root:veil "$XVEIL_TMP"');
      expect(
        grant,
        isNot(-1),
        reason:
            'without this the veil account cannot enter the directory and the '
            'config step reports the staged config as missing',
      );

      expect(
        commands.indexOf(
          'useradd -r -s /usr/sbin/nologin -d /var/lib/veil veil',
        ),
        lessThan(grant),
        reason: 'chown to a group that does not exist yet fails',
      );

      final firstVeilUse = commands
          .split('\n')
          .indexWhere(
            (l) => l.contains('sudo -u veil') && l.contains(r'$XVEIL_TMP'),
          );
      expect(
        firstVeilUse,
        isNot(-1),
        reason: 'premise: the script does run as veil',
      );
      expect(
        commands
            .split('\n')
            .indexWhere((l) => l.contains(r'chown root:veil "$XVEIL_TMP"')),
        lessThan(firstVeilUse),
        reason: 'granted after the first use is granted too late',
      );

      // Group, not world: the PSK and the TLS key are staged in this directory
      // and stay unreadable to every other account on the machine.
      final mode = RegExp(r'chmod (\d+) "\$XVEIL_TMP"').firstMatch(commands);
      expect(mode, isNotNull, reason: 'the mode must be set explicitly');
      final bits = int.parse(mode!.group(1)!, radix: 8);
      expect(
        bits & 0x7,
        0,
        reason: 'world bits would expose the staged PSK to every local account',
      );
      expect(
        bits & 0x38,
        isNot(0),
        reason: 'the veil group needs access, which is the whole point',
      );
    },
  );

  // Step 6 claims to "reconcile listeners": delete what is configured, then
  // add what this deployment asked for. The delete half selected ids with
  // `$1 ~ /^[0-9]+$/`, and `listen list` prints them in hex — `0x00000001`.
  // The filter matched nothing, so the loop was dead code and every redeploy
  // APPENDED. Observed on a real server: after one redeploy the node carried
  // two obfs4 listeners on :5556 plus a `tcp://0.0.0.0:9000` inherited from an
  // earlier install, which this very step exists to remove.
  //
  // Run the filter rather than reading it: the bug was a pattern that looks
  // plausible in a diff and selects nothing in a shell.
  test(
    'the listener reconcile actually selects the ids veil-cli prints',
    () {
      final awkProgram = RegExp(
        r"listen list \| awk '([^']+)'",
      ).firstMatch(script())?.group(1);
      expect(
        awkProgram,
        isNotNull,
        reason: 'premise: the reconcile loop filters `listen list` with awk',
      );

      // Verbatim `veil-cli listen list` output, header and column padding
      // included — the format the filter has to survive.
      const listOutput =
          'listen_id   transport  tls_cert              tls_key               tls_ca_cert         \n'
          '0x00000001  obfs4-tcp://0.0.0.0:5556  -                     -                     -                   \n'
          '0x00000002  tcp://0.0.0.0:9000  -                     -                     -                   \n';

      // The program has to reach awk unmangled, so both it and the sample go
      // through the environment rather than through shell quoting.
      final piped = Process.runSync(
        'bash',
        ['-c', 'printf %s "\$LIST" | awk "\$PROG"'],
        environment: {'LIST': listOutput, 'PROG': awkProgram!},
      );

      expect(
        (piped.stdout as String).trim().split('\n'),
        ['0x00000001', '0x00000002'],
        reason:
            'a filter that selects no id turns "reconcile" into "append", and '
            'stale listeners from earlier deployments never go away',
      );
    },
    skip: Platform.isWindows ? 'POSIX shell only' : null,
  );

  // Everything above reads the script as TEXT, and text is what let the
  // staging path regress: `-o '$XVEIL_TMP/veil-cli'` looks right in a diff and
  // is inert in a shell, because single quotes suppress expansion. curl then
  // wrote to a literal relative path that does not exist, and `set -e` ended
  // provisioning before the hash, the install, the config and the service —
  // while an ordering assertion over the same text stayed green.
  //
  // So run the two lines that matter, with fake tools, and look at where the
  // bytes actually land.
  test(
    'the download really stages under the private scratch dir',
    () async {
      final s = script();
      final curlLine = s
          .split('\n')
          .firstWhere(
            (l) => l.contains('curl -fsSL') && l.contains('veil-cli'),
          );
      final verifyLine = s
          .split('\n')
          .firstWhere((l) => l.contains('sha256sum -c -'));

      final cwd = Directory.systemTemp.createTempSync('xveil-prov-cwd');
      addTearDown(() => cwd.deleteSync(recursive: true));
      final fakeBin = Directory('${cwd.path}/bin')..createSync();

      // curl writes whatever `-o` names; that is the whole behaviour under test.
      File('${fakeBin.path}/curl')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'while [ \$# -gt 0 ]; do\n'
          '  if [ "\$1" = "-o" ]; then shift; printf backend > "\$1"; exit 0; fi\n'
          '  shift\n'
          'done\n'
          'exit 9\n',
        )
        ..parent.createSync(recursive: true);
      Process.runSync('chmod', ['+x', '${fakeBin.path}/curl']);

      // sha256sum -c - reads "<digest>  <path>" and must find that path.
      File('${fakeBin.path}/sha256sum').writeAsStringSync(
        '#!/bin/sh\n'
        'read -r _digest path\n'
        '[ -f "\$path" ] || { echo "no such staged file: \$path" >&2; exit 1; }\n'
        'exit 0\n',
      );
      Process.runSync('chmod', ['+x', '${fakeBin.path}/sha256sum']);

      final run = Process.runSync(
        'bash',
        [
          '-c',
          'set -e\n'
              'umask 077\n'
              'XVEIL_TMP="\$(mktemp -d)"\n'
              'trap \'rm -rf -- "\$XVEIL_TMP"\' EXIT\n'
              '$curlLine\n'
              '$verifyLine\n'
              'ls "\$XVEIL_TMP"\n',
        ],
        workingDirectory: cwd.path,
        environment: {
          'PATH': '${fakeBin.path}:${Platform.environment['PATH']}',
        },
      );

      expect(
        run.exitCode,
        0,
        reason: 'download+verify must survive a real shell: ${run.stderr}',
      );
      expect(
        (run.stdout as String).trim(),
        'veil-cli',
        reason: 'the binary belongs in the private scratch dir, by that name',
      );
      expect(
        Directory('${cwd.path}/\$XVEIL_TMP').existsSync(),
        isFalse,
        reason:
            'a literal \$XVEIL_TMP directory in the cwd is what an unexpanded '
            'single-quoted path would have created',
      );
    },
    skip: Platform.isWindows ? 'POSIX shell only' : null,
  );
}
