import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'support/expect_before.dart';
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

  test('nothing writes into the scratch directory without sudo', () {
    // report17 XV17-M10. The directory is created by `sudo mktemp -d`, so it
    // is root-owned and an ordinary sudoer cannot delete from it. A final
    // `rm -f` of the staged files, without sudo, therefore failed — and under
    // `set -euo pipefail` its exit status became the SCRIPT's. A deployment
    // that had installed the binaries, written the config and brought the
    // service up ACTIVE reported failure, after changing the system.
    //
    // The trap at the top removes the directory whole, through sudo, on every
    // exit path; a second cleanup had nothing to add and one way to go wrong.
    final commands = script()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('#'))
        .toList();

    for (final line in commands) {
      final trimmed = line.trimLeft();
      if (!trimmed.startsWith('rm ')) continue;
      expect(
        trimmed.contains(r'$XVEIL_TMP'),
        isFalse,
        reason:
            'an un-sudoed rm reaches into the root-owned scratch '
            'directory, and its failure becomes the deployment\'s: $line',
      );
    }

    // And the trap that does the work is still there — otherwise the check
    // above is satisfied by a script that never cleans up at all.
    expect(
      script(),
      contains(r"""trap 'sudo rm -rf -- "$XVEIL_TMP"' EXIT INT TERM"""),
      reason:
          'nothing removes the scratch directory, so the staged PSK and '
          'TLS key outlive the run',
    );
  });

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
    // Through SUDO: the directory has to belong to root, or the login
    // account can rewrite what root is about to install (report16 X16-H1).
    expect(s, contains(r'XVEIL_TMP="$(sudo mktemp -d)"'));
    expect(
      s,
      contains(r'''trap 'sudo rm -rf -- "$XVEIL_TMP"' EXIT INT TERM'''),
      reason:
          'cleanup on success only leaves the PSK and the TLS key on disk '
          'exactly when the run went wrong',
    );
  });

  test('the umask is set before anything is written', () {
    final s = script();
    expectBefore(
      s,
      'umask 077',
      'mktemp -d',
      reason: 'a directory created before the umask keeps the login mode',
    );
    expectBefore(
      s,
      'mktemp -d',
      'PSK_EOF',
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
  test('the veil account gets one writable corner and no more', () {
    // Comments must go first. The fix's own explanation names `sudo -u veil`
    // and `$XVEIL_TMP`, so an ordering assertion over the raw text would be
    // satisfied by that prose and would pass with the fix deleted.
    final commands = script()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('#'))
        .join('\n');
    final lines = commands.split('\n');

    // 1. There IS a corner handed to the veil group, and it is a SUB-directory.
    final grantAt = lines.indexWhere(
      (l) => l.contains(r'chown root:veil "$XVEIL_TMP/'),
    );
    expect(
      grantAt,
      isNot(-1),
      reason:
          'without it the veil account cannot create or atomically rewrite its '
          'config, and veil-cli reports the staged file as missing',
    );
    expect(
      commands,
      isNot(contains(r'chown root:veil "$XVEIL_TMP"')),
      reason:
          'handing over the whole staging directory lets a compromised veil '
          'unlink and replace the PSK and the TLS key before root installs '
          'them — the split is the point',
    );

    // 2. Group, not world.
    final mode = RegExp(r'chmod (\d+) "\$XVEIL_TMP/cfg"').firstMatch(commands);
    expect(mode, isNotNull, reason: 'the corner needs an explicit mode');
    final bits = int.parse(mode!.group(1)!, radix: 8);
    expect(
      bits & 0x7,
      0,
      reason: 'world bits expose it to every local account',
    );
    expect(bits & 0x38, isNot(0), reason: 'the veil group needs access');

    // 3. The staging root itself is never made writable by anyone but root.
    final rootMode = RegExp(r'chmod (\d+) "\$XVEIL_TMP"').firstMatch(commands);
    expect(rootMode, isNotNull);
    final rootBits = int.parse(rootMode!.group(1)!, radix: 8);
    expect(
      rootBits & 0x12,
      0,
      reason:
          'group or other WRITE on the staging root is the exposure the '
          'corner exists to avoid',
    );

    // 4. Granted after the account exists, and before the first use as veil.
    expect(
      lines.indexWhere(
        (l) =>
            l.contains('useradd -r -s /usr/sbin/nologin -d /var/lib/veil veil'),
      ),
      lessThan(grantAt),
      reason: 'chown to a group that does not exist yet fails',
    );
    final firstVeilUse = lines.indexWhere(
      (l) => l.contains('sudo -u veil') && l.contains(r'$XVEIL_TMP'),
    );
    expect(
      firstVeilUse,
      isNot(-1),
      reason: 'premise: the script does run as veil',
    );
    expect(
      grantAt,
      lessThan(firstVeilUse),
      reason: 'granted too late is not granted',
    );

    // 5. The secrets are staged OUTSIDE the corner veil can write.
    final pskLine = lines.firstWhere((l) => l.contains('xveil-obfs4-psk.b64'));
    expect(
      pskLine,
      isNot(contains(r'$XVEIL_TMP/cfg/')),
      reason: 'the deployment PSK must not sit where veil can replace it',
    );
    // Premise: the config DOES live in the corner, so the check above is a
    // statement about where things are and not about an empty directory.
    expect(commands, contains(r'$XVEIL_TMP/cfg/xveil-node.toml'));
  });

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
              // Transparent: the lines under test now go through `sudo`
              // because the staging directory belongs to root, and what is
              // being checked is where the bytes land, not who wrote them.
              'sudo() { "\$@"; }\n'
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

  // Step 6 decides between PRESERVING the node's identity and minting a new
  // one, on whether the existing node.toml has an identity section. veil
  // renames that section to `Identity`, but it also accepts and deliberately
  // preserves a lowercase `[identity]` — veil-cfg carries a test called
  // `updates_existing_lowercase_identity_without_creating_uppercase_duplicate`
  // promising such a document never gains an uppercase one. A guard that knew
  // only the uppercase spelling read a perfectly good config as "no identity"
  // and took the mint branch: an UPDATE would have replaced the node's id and
  // every relationship hanging off it, on a server the operator asked to
  // update, with no error to show for it.
  //
  // Run the pattern rather than read it, and run it against the shapes veil
  // actually writes.
  test(
    'the identity guard sees every section spelling veil accepts',
    () {
      final pattern = RegExp(
        r"grep -qE '([^']+)'",
      ).firstMatch(script())?.group(1);
      expect(
        pattern,
        isNotNull,
        reason: 'premise: the branch is chosen by a grep over node.toml',
      );

      bool matches(String document) {
        final run = Process.runSync(
          'bash',
          ['-c', 'printf %s "\$DOC" | grep -qE "\$PAT"'],
          environment: {'DOC': document, 'PAT': pattern!},
        );
        return run.exitCode == 0;
      }

      const global = '[global]\nruntime_flavor = "multi_thread"\n\n';
      // What a node deployed by this script actually carries.
      expect(
        matches('$global[Identity]\npublic_key = "pub"\n'),
        isTrue,
        reason: 'the canonical spelling veil renames to',
      );
      // What veil-cfg promises to preserve rather than rewrite.
      expect(
        matches('$global[identity]\npublic_key = "pub"\n'),
        isTrue,
        reason:
            'reading this as "no identity" mints a new one over a live node',
      );
      // Hand-edited, still valid TOML.
      expect(matches('$global[ identity ]\npublic_key = "pub"\n'), isTrue);

      // And the negative the branch exists for — otherwise a guard that always
      // says yes would pass every assertion above.
      expect(
        matches('$global[transport]\nobfs4_psk_file = "x"\n'),
        isFalse,
        reason:
            'a config with no identity must still reach the branch that '
            'creates one',
      );
    },
    skip: Platform.isWindows ? 'POSIX shell only' : null,
  );

  // The script runs AS ROOT on the operator's server and interpolates values
  // they typed into single-quoted shell words. Every one of those values is
  // validated — but by `isValid`, which the deploy SCREEN consulted and this
  // generator did not. The guarantee therefore held only while that one caller
  // kept asking; a second caller got a root shell script built out of whatever
  // it passed.
  //
  // Demonstrated before it was closed: an advertise host of
  // `x'; touch /tmp/pwned; echo '` produced
  //   --advertise 'obfs4-tcp://x'; touch /tmp/pwned; echo ':5556'
  // — the apostrophe closing the word and `touch` becoming its own command.
  group('the generator refuses what the validator rejects', () {
    NodeProvisionConfig withHost(String host) => NodeProvisionConfig(
      releaseUrl: 'https://example.com/veil-cli',
      expectedSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      obfs4PskB64: 'dGVzdA==',
      advertiseHost: host,
    );

    test('a shell metacharacter in a host never reaches a root script', () {
      final evil = withHost("x'; touch /tmp/pwned; echo '");
      // Premise: the validator does its job. If this ever passes, the refusal
      // below is not what is keeping the quote out.
      expect(evil.isValid, isFalse);
      expect(
        () => buildProvisionScript(evil),
        throwsArgumentError,
        reason:
            'the boundary that runs as root is where the refusal belongs, not '
            'the screen in front of it',
      );
    });

    test('a legitimate host still builds and is advertised', () {
      // The negative above is worthless if the guard refuses everything.
      final ok = withHost('relay.example.com');
      expect(ok.isValid, isTrue);
      final s = buildProvisionScript(ok);
      expect(s, contains("--advertise 'obfs4-tcp://relay.example.com:5556'"));
    });

    test('every field the script quotes is covered by the same refusal', () {
      // Each of these is interpolated into a single-quoted shell word further
      // down the generated script.
      final cases = <String, NodeProvisionConfig>{
        'tls cert path': NodeProvisionConfig(
          releaseUrl: 'https://example.com/veil-cli',
          expectedSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
          obfs4PskB64: 'dGVzdA==',
          transports: const {NodeListenTransport.tls},
          tlsCertPath: "/etc/x'; id; echo '.pem",
          tlsKeyPath: '/etc/ok.pem',
        ),
        'acme e-mail': NodeProvisionConfig(
          releaseUrl: 'https://example.com/veil-cli',
          expectedSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
          obfs4PskB64: 'dGVzdA==',
          transports: const {NodeListenTransport.tls},
          tlsCertificateMode: NodeTlsCertificateMode.automatic,
          tlsDomain: 'relay.example.com',
          tlsEmail: "a'; id; echo '@example.com",
          tlsAgreeToTerms: true,
        ),
        'self-signed name': NodeProvisionConfig(
          releaseUrl: 'https://example.com/veil-cli',
          expectedSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
          obfs4PskB64: 'dGVzdA==',
          transports: const {NodeListenTransport.tls},
          tlsCertificateMode: NodeTlsCertificateMode.selfSigned,
          selfSignedName: "x'; id; echo '",
        ),
      };
      for (final entry in cases.entries) {
        expect(
          () => buildProvisionScript(entry.value),
          throwsArgumentError,
          reason: '${entry.key}: quoted into a root script',
        );
      }
    });
  });

  // veil reads an empty exit allowlist as NOBODY — deliberately, so that an
  // operator who enabled the exit and stopped there is not running an open
  // proxy under their own address. A deployment that turns the exit on and
  // names no one therefore installs an exit that refuses its own owner, which
  // is why the deploying device's node id travels with the request.
  //
  // Proven against a real server: the generated `set_toml_scalar` lines put
  // the array into `[proxy.exit]` and `veil-cli config validate` accepts it,
  // and a veil 0.8.0 that predates these keys ignores them rather than
  // refusing the file.
  group('the deployed exit is told who it carries', () {
    const owner =
        '50621577d8ee476c78c7c5d9039c20e24643627557fd33173044a9a1117d59b2';
    NodeProvisionConfig cfg({
      bool runExit = true,
      List<String> ids = const [owner],
    }) => NodeProvisionConfig(
      releaseUrl: 'https://example.com/veil-cli',
      expectedSha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      obfs4PskB64: 'dGVzdA==',
      runExit: runExit,
      exitAllowedNodeIds: ids,
    );

    test('the allowlist and the explicit allow_all reach the config', () {
      final s = buildProvisionScript(cfg());
      expect(s, contains('set_toml_scalar proxy.exit enabled \'true\''));
      expect(
        s,
        contains('set_toml_scalar proxy.exit allowed_node_ids \'["$owner"]\''),
      );
      expect(
        s,
        contains('set_toml_scalar proxy.exit allow_all \'false\''),
        reason:
            'writing the list without this leaves the meaning of "empty" to '
            'whatever the server already had',
      );
    });

    test('an exit that is not being enabled is left alone', () {
      final s = buildProvisionScript(cfg(runExit: false));
      expect(s, contains('set_toml_scalar proxy.exit enabled \'false\''));
      expect(s, isNot(contains('allowed_node_ids')));
    });

    test('a caller that named nobody writes nothing rather than guessing', () {
      // Not the same as writing an empty list: an older node then behaves as
      // it did, and a newer one stays closed and says so at startup. Writing
      // `[]` here would look like a decision nobody made.
      final s = buildProvisionScript(cfg(ids: const []));
      expect(s, isNot(contains('allowed_node_ids')));
      expect(s, isNot(contains('allow_all')));
      // Premise: the same config WITH an id does write them, so this is a
      // statement about the empty list and not about the group being inert.
      expect(buildProvisionScript(cfg()), contains('allowed_node_ids'));
    });

    test('a malformed id is refused, never written', () {
      expect(
        () => buildProvisionScript(cfg(ids: const ['not-a-node-id'])),
        throwsArgumentError,
        reason:
            'this list decides who may spend the operator bandwidth; a typo '
            'that reaches the file is a typo that decides it',
      );
    });
  });
}
