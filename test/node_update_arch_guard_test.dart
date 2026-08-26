import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/arch_guard.dart';
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
    return lines
        .sublist(start, end + 1)
        .join('\n')
        .replaceAll('sudo ', '');
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

  test('an architecture nobody mapped does not block the update', () {
    // A machine this build says nothing about is not a reason to refuse an
    // update it may well run. The refusal is for a KNOWN mismatch.
    expect(check('riscv64', elf(243)).exitCode, 0);
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
      expectBefore(script, "cp -a '/usr/local/bin/veil-cli'", 'install -o root');
      expect(
        script,
        contains("install -o root -g root -m 0755 '/usr/local/bin/veil-cli.previous'"),
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
      expectBefore(provision(), 'check_machine "\$XVEIL_TMP/veil-cli"',
          'install -o root -g root -m 0755 "\$XVEIL_TMP/veil-cli"');
    });

    test('and after the digest, so a truncated download fails as a digest', () {
      // Order between the two checks decides which message the operator reads.
      // A half-finished download is a broken file, not a wrong architecture.
      expectBefore(provision(), 'sha256sum -c -', 'check_machine "\$XVEIL_TMP/veil-cli"');
    });

    test('both scripts carry the SAME refusal, not two that drifted', () {
      // The bug this closes appeared twice for the same reason. Two copies
      // would let one of them be fixed alone again.
      expect(provision(), contains(kArchGuardShell.trim()));
      expect(
        buildNodeSoftwareUpdateScript([artifact]),
        contains(kArchGuardShell.trim()),
      );
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
