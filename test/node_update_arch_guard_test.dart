import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/arch_guard.dart';
import 'package:xveil/data/node/node_auto_update.dart';
import 'package:xveil/data/node/node_provisioner.dart';

import 'support/expect_before.dart';

/// The update script installs a binary as root, over a working one, and
/// restarts the service. The digest it checks proves the bytes are the ones the
/// release published — and says nothing at all about whether they are for THIS
/// machine. The app offers an arm64 target as readily as an x86_64 one, so the
/// wrong build arrives here as a perfectly genuine file: the digest matches,
/// `install` succeeds, and the service never comes back.
///
/// So the machine refuses it, and the refusal is a shell function. It is
/// exercised by a real shell rather than read.
void main() {
  final artifact = NodeReleaseArtifact(
    component: NodeComponent.veilCli,
    releaseUrl: 'https://example.invalid/veil-cli',
    expectedSha256: 'a' * 64,
  );

  /// The architecture check exactly as the generated script carries it, with
  /// `sudo` dropped — nothing here reads a root-owned file, and the comparison
  /// is what is under test.
  String guard() {
    final lines = buildNodeSoftwareUpdateScript([artifact]).split('\n');
    final start = lines.indexWhere((l) => l.startsWith(r'case "$(uname -m)"'));
    expect(start, isNot(-1), reason: 'the script no longer carries the guard');
    final end = lines.indexWhere((l) => l == '}', start);
    expect(end, isNot(-1));
    return lines.sublist(start, end + 1).join('\n').replaceAll('sudo ', '');
  }

  /// A file whose ELF header says it was built for [machine].
  ///
  /// Offset 18 is `e_machine`, little-endian on both architectures involved:
  /// 62 (0x3E) is x86-64, 183 (0xB7) is AArch64.
  File elf(int machine) {
    final bytes = Uint8List(64);
    bytes.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
    bytes[18] = machine;
    final dir = Directory.systemTemp.createTempSync('xveil-elf');
    addTearDown(() => dir.deleteSync(recursive: true));
    return File('${dir.path}/binary')..writeAsBytesSync(bytes);
  }

  /// Run the guard on [file] as if the server reported [machine] from
  /// `uname -m`. A shell function outranks the real binary, which is what lets
  /// this test ask about a machine it is not running on.
  ProcessResult check(String machine, File file) => Process.runSync('bash', [
    '-c',
    'uname() { echo "$machine"; }\n${guard()}\ncheck_machine "${file.path}"',
  ]);

  test('a build for this machine is accepted', () {
    expect(check('x86_64', elf(62)).exitCode, 0);
    expect(check('aarch64', elf(183)).exitCode, 0);
  });

  test('an x86_64 build is REFUSED on an arm64 server', () {
    // The exact shape of the bug: the fleet screen resolved one artifact for
    // everybody, and it was x86_64.
    final result = check('aarch64', elf(62));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('another architecture'));
  });

  test('an arm64 build is REFUSED on an x86_64 server', () {
    expect(check('x86_64', elf(183)).exitCode, isNot(0));
  });

  test('something that is not a binary at all is refused', () {
    final dir = Directory.systemTemp.createTempSync('xveil-elf');
    addTearDown(() => dir.deleteSync(recursive: true));
    final html = File('${dir.path}/binary')
      ..writeAsStringSync('<html>404 Not Found</html>');
    expect(check('x86_64', html).exitCode, isNot(0));
  });

  group('a machine name this script does not know', () {
    /// Like [check], but with a readable `/proc/self/exe` standing in: the
    /// host's real ELF machine, whatever `uname` chose to call it.
    ProcessResult checkVia(String machine, File reference, File file) {
      final stub = <String>[
        'uname() { echo "$machine"; }',
        'od() {',
        '  local a args=()',
        '  for a in "\$@"; do',
        '    [ "\$a" = "/proc/self/exe" ] && a="${reference.path}"',
        '    args+=("\$a")',
        '  done',
        '  command od "\${args[@]}"',
        '}',
      ].join('\n');
      return Process.runSync('bash', [
        '-c',
        '$stub\n${guard()}\ncheck_machine "${file.path}"',
      ]);
    }

    test('falls back to the machine of the running shell', () {
      // `uname -m` can answer anything - a stripped container, an alias
      // nobody listed, an architecture that did not exist when this shipped.
      // Waving the binary through there is how a genuine release lands on a
      // host that cannot execute it, and at first deployment there is nothing
      // to roll back to.
      expect(checkVia('sparc64', elf(62), elf(62)).exitCode, 0);

      final wrong = checkVia('sparc64', elf(62), elf(183));
      expect(wrong.exitCode, isNot(0));
      expect(wrong.stderr, contains('another architecture'));
    });

    /// Like [check], but on a host that cannot answer for itself either: the
    /// `/proc/self/exe` probe reads nothing.
    ///
    /// [check] stubs only `uname`, so the probe used to read the RUNNER's own
    /// binary — and that is a real answer. On macOS there is no
    /// `/proc/self/exe`, so the test passed locally and failed on the Linux
    /// runner, where the guard correctly refused a riscv64 build for an
    /// x86_64 host. The unanswerable host is now built rather than assumed.
    ProcessResult checkWithoutProc(String machine, File file) {
      final stub = <String>[
        'uname() { echo "$machine"; }',
        'od() {',
        '  local a',
        '  for a in "\$@"; do',
        '    [ "\$a" = "/proc/self/exe" ] && return 1',
        '  done',
        '  command od "\$@"',
        '}',
      ].join('\n');
      return Process.runSync('bash', [
        '-c',
        '$stub\n${guard()}\ncheck_machine "${file.path}"',
      ]);
    }

    test('and only a host that cannot answer at all is let through', () {
      // Last resort, and stated rather than accidental: a machine where
      // neither the name nor /proc says anything is one veil publishes no
      // build for.
      expect(checkWithoutProc('riscv64', elf(243)).exitCode, 0);
    });

    test('but a host that CAN answer refuses the same build', () {
      // The other half, and the one that matters: the last resort is a
      // last resort. Where the probe works — every Linux server this
      // deploys to — an unknown `uname -m` is not a way past the check.
      final refused = checkVia('riscv64', elf(62), elf(243));
      expect(refused.exitCode, isNot(0));
      expect(refused.stderr, contains('another architecture'));
    });
  });

  test('the refusal happens before anything is installed', () {
    // Order is the whole point: a check that runs after `install` has already
    // overwritten the working binary is not a check, it is a report.
    expectBefore(
      buildNodeSoftwareUpdateScript([artifact]),
      'check_machine "\$stage',
      'install -o root',
    );
  });

  group('and if the new binary is bad in some other way', () {
    final script = buildNodeSoftwareUpdateScript([artifact]);

    test('the previous binary is kept and restored', () {
      expect(script, contains('did not come back'));
      expectBefore(
        script,
        "cp -a '/usr/local/bin/veil-cli'",
        'install -o root',
      );
      expect(
        script,
        contains(
          "install -o root -g root -m 0755 '/usr/local/bin/veil-cli.previous'",
        ),
      );
    });

    test('a service that does not come back fails the run', () {
      // Reporting success over a dead node is worse than reporting failure:
      // the version gets remembered and nobody looks again.
      // Not a plain ordering: the FIRST `exit 1` in the script belongs to the
      // architecture refusal above. What matters is that one follows the
      // restore, so the run ends red rather than reporting a version nobody
      // installed.
      final said = script.indexOf('did not come back');
      expect(said, isNot(-1), reason: 'nothing detects a dead service');
      expect(
        script.indexOf('exit 1', said),
        isNot(-1),
        reason: 'a node that did not come back must fail the run',
      );
    });

    test('a service that was NOT running is not started by an update', () {
      expect(script, contains('active_veil_cli=0'));
      expect(script, contains(r'if [ "$active_veil_cli" = 1 ]'));
    });
  });

  group('the same refusal covers a first deployment', () {
    // Deployment is the worse of the two paths: the operator picks the
    // architecture from a dropdown, often for a machine they have not looked
    // at, and there is no previous binary to fall back to. The old script
    // downloaded, verified the digest, installed as root and moved on.
    String provision() => buildProvisionScript(
      const NodeProvisionConfig(
        releaseUrl: 'https://example.invalid/veil-cli-x86_64-linux-musl',
        expectedSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        obfs4PskB64: 'dGVzdC1maXh0dXJlLXBzay1ub3QtcmVhbC12YWx1ZSE=',
      ),
    );

    test('the machine is checked before the binary is installed', () {
      expectBefore(
        provision(),
        'check_machine "\$XVEIL_TMP/veil-cli"',
        'install -o root -g root -m 0755 "\$XVEIL_TMP/veil-cli"',
      );
    });

    test('and after the digest, so a truncated download fails as a digest', () {
      // Order between the two checks decides which message the operator reads.
      // A half-finished download is a broken file, not a wrong architecture.
      expectBefore(
        provision(),
        'sha256sum -c -',
        'check_machine "\$XVEIL_TMP/veil-cli"',
      );
    });

    test(
      'all THREE scripts carry the same refusal, not copies that drifted',
      () {
        // The bug this closes appeared twice for the same reason. Two copies
        // would let one of them be fixed alone again.
        //
        // Three, not two. This test named the deployment and fleet-update
        // scripts, and the SELF-UPDATER is the third script that installs a
        // release binary as root — the unattended one, where nobody is watching
        // at the moment it happens. It carried two inline copies of the
        // `uname -m` table instead, neither with the ELF fallback, and checked
        // nothing before installing. The test that exists to stop exactly that
        // drift did not look at it (report15 X15-M18).
        expect(provision(), contains(kArchGuardShell.trim()));
        expect(
          buildNodeSoftwareUpdateScript([artifact]),
          contains(kArchGuardShell.trim()),
        );
        expect(
          buildNodeAutoUpdateScript(enabled: true),
          contains(kArchGuardShell.trim()),
        );
      },
    );

    test('and the self-updater checks the machine before it installs', () {
      final script = buildNodeAutoUpdateScript(enabled: true);

      expectBefore(
        script,
        r'check_machine "$stage/veil-cli"',
        r'install -o root -g root -m 0755 "$stage/veil-cli"',
      );
      // After the digest, so a truncated download reads as a broken file
      // rather than as a wrong architecture.
      expectBefore(
        script,
        r'digest mismatch',
        r'check_machine "$stage/veil-cli"',
      );
    });

    test('and the name table lives ONLY inside the shared guard', () {
      // Both the enable-time refusal and the build selection come from the
      // machine the guard settled on. A `case $(uname -m)` of its own is the
      // shape that drifted, and it is what was here.
      //
      // Counted against the number of guard copies, not against one: this
      // script writes a SECOND script to disk, and those are two shells that
      // each need the guard. A first version of this assertion demanded one
      // table and failed on the honest second copy.
      final script = buildNodeAutoUpdateScript(enabled: true);
      final tables = RegExp(
        r'case "\$\(uname -m\)" in',
      ).allMatches(script).length;
      final guards = kArchGuardShell.trim().allMatches(script).length;

      expect(guards, greaterThan(0), reason: 'premise: the guard is included');
      expect(
        tables,
        guards,
        reason:
            'the self-updater reads the machine name in $tables places for '
            '$guards copies of the guard, so at least one table is its own',
      );
    });

    test('the self-updater is valid bash', () {
      final dir = Directory.systemTemp.createTempSync('xveil-auto');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/s.sh')
        ..writeAsStringSync(buildNodeAutoUpdateScript(enabled: true));
      final result = Process.runSync('bash', ['-n', file.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('the deployment script is valid bash', () {
      final dir = Directory.systemTemp.createTempSync('xveil-prov');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/s.sh')..writeAsStringSync(provision());
      final result = Process.runSync('bash', ['-n', file.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
  });

  test('the generated script is valid bash', () {
    final dir = Directory.systemTemp.createTempSync('xveil-upd');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/s.sh')
      ..writeAsStringSync(buildNodeSoftwareUpdateScript([artifact]));
    final result = Process.runSync('bash', ['-n', file.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
}
