import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_provisioner.dart';

/// The deployment edits the staged config with a shell helper, and the staged
/// config lives in a directory the login user cannot write.
///
/// That is deliberate: the directory is `root:veil 0770` so a compromised
/// `veil` cannot replace the file in the window before root installs it. What
/// it means for the helper is that EVERY write has to happen on the privileged
/// side — and a shell redirect does not. `sudo awk … > "$temp"` is performed by
/// the shell before sudo runs, so the file was created as the login user, an
/// ordinary sudoer is not in group `veil`, and `set -e` ended the deployment
/// after the binaries were installed and before anything was started.
///
/// So the test models the asymmetry rather than the syntax: a directory this
/// process cannot write, and a `sudo` that can.
void main() {
  /// The helper exactly as the provisioning script carries it.
  String helper() {
    final script = buildProvisionScript(
      const NodeProvisionConfig(
        releaseUrl: 'https://example.invalid/veil-cli',
        expectedSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        obfs4PskB64: 'dGVzdC1maXh0dXJlLXBzay1ub3QtcmVhbC12YWx1ZSE=',
      ),
    );
    final lines = script.split('\n');
    final from = lines.indexWhere((l) => l.startsWith('set_toml_scalar()'));
    expect(from, isNot(-1), reason: 'the helper moved');
    final to = lines.indexOf('}', from);
    expect(to, isNot(-1));
    return lines.sublist(from, to + 1).join('\n');
  }

  /// Run the helper against a config in a directory the test user cannot
  /// write, with a `sudo` that can. Returns the resulting file, or null when
  /// the helper failed.
  ({int code, String stderr, String? contents}) edit(String section, String key,
      String value, String initial) {
    final dir = Directory.systemTemp.createTempSync('xveil-toml');
    addTearDown(() {
      Process.runSync('chmod', ['0700', '${dir.path}/cfg']);
      dir.deleteSync(recursive: true);
    });
    final cfg = Directory('${dir.path}/cfg')..createSync();
    final file = File('${cfg.path}/node.toml')..writeAsStringSync(initial);
    // Locked after the file exists, the way the deployment locks it after
    // staging.
    Process.runSync('chmod', ['0500', cfg.path]);

    final result = Process.runSync('bash', [
      '-c',
      // `sudo` here can write where the caller cannot — which is the whole
      // difference the helper has to respect. A redirect done by the shell
      // outside it lands on the wrong side of that line.
      'set -euo pipefail\n'
          'DIR="${cfg.path}"\n'
          // Raised only for the commands that WRITE. The helper's fixed form
          // is `sudo awk … | sudo tee …`, and a stub that raises and restores
          // on both sides of that pipeline has the two halves overlapping —
          // awk's restore landing between tee's raise and its open, which
          // failed under load and nowhere else.
          'sudo() {\n'
          '  case "\$1" in\n'
          '    tee|install|cp|rm|mv|mkdir)\n'
          '      chmod u+w "\$DIR"; "\$@"; local rc=\$?; chmod 0500 "\$DIR"; return \$rc ;;\n'
          '    *) "\$@" ;;\n'
          '  esac\n'
          '}\n'
          // The helper runs on a Linux server and speaks GNU coreutils. This
          // bridges `stat -c` for a BSD one so the suite can run the real
          // thing rather than a rewrite of it.
          'stat() {\n'
          '  if [ "\$1" = "-c" ]; then\n'
          '    command stat -c "\$2" "\$3" 2>/dev/null && return 0\n'
          '    case "\$2" in\n'
          '      %u) command stat -f %u "\$3" ;;\n'
          '      %g) command stat -f %g "\$3" ;;\n'
          '      %a) command stat -f %Lp "\$3" ;;\n'
          '    esac\n'
          '  else command stat "\$@"; fi\n'
          '}\n'
          '${helper()}\n'
          'set_toml_scalar $section $key $value "${file.path}"',
    ]);

    return (
      code: result.exitCode,
      stderr: result.stderr.toString(),
      contents: file.existsSync() ? file.readAsStringSync() : null,
    );
  }

  test('it edits a config in a directory only root can write', () {
    final out = edit('transport', 'obfs4_psk_file', "'\"/x\"'", '[transport]\n');

    expect(out.code, 0, reason: out.stderr);
    expect(out.contents, contains('obfs4_psk_file = "/x"'));
  });

  test('an existing key is replaced, not duplicated', () {
    final out = edit(
      'proxy.exit',
      'enabled',
      "'true'",
      '[proxy.exit]\nenabled = false\n',
    );

    expect(out.code, 0, reason: out.stderr);
    expect(out.contents, contains('enabled = true'));
    expect(out.contents, isNot(contains('enabled = false')));
  });

  test('a missing section is added', () {
    final out = edit('proxy.exit', 'allow_all', "'false'", '[transport]\n');

    expect(out.code, 0, reason: out.stderr);
    expect(out.contents, contains('[proxy.exit]'));
    expect(out.contents, contains('allow_all = false'));
  });

  test('no write is left for the login shell to do', () {
    // Structural, and narrow: a redirect anywhere in this helper is performed
    // before the `sudo` it appears to belong to, which is the whole defect.
    // Only `>/dev/null` may remain — that one discards.
    for (final line in helper().split('\n')) {
      if (line.trimLeft().startsWith('#')) continue;
      final redirects = RegExp(r'>\s*(?!/dev/null)\S').allMatches(line);
      expect(
        redirects,
        isEmpty,
        reason: 'the login shell writes here, and it may not: $line',
      );
    }
  });
}
