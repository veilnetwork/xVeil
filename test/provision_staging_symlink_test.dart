// Root opening a name that an unprivileged account controls.
//
// The staged config lives in `$XVEIL_TMP/cfg`, which is `root:veil 0770` —
// deliberately, because `veil-cli` runs as the veil account and edits the file
// there. That makes every name in that directory one an unprivileged account
// can replace, and the deployment used to have root open two of them: a
// scratch file at `${file}.xveil.$$`, computable from a pid, removed and then
// written; and the config itself, read by `awk` and replaced by `install`
// (report17 XV17-H1).
//
// Both are driven here as the shell really runs them, with a `sudo` that can
// write where the test user cannot and an "attacker" that wins the race.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_provisioner.dart';

void main() {
  /// The helper functions exactly as the provisioning script carries them.
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
    final from = lines.indexWhere((l) => l.startsWith('require_staged_file()'));
    expect(from, isNot(-1), reason: 'the staged-file check moved');
    final edit = lines.indexWhere((l) => l.startsWith('set_toml_scalar()'));
    expect(edit, isNot(-1), reason: 'the helper moved');
    final to = lines.indexOf('}', edit);
    expect(to, isNot(-1));
    return lines.sublist(from, to + 1).join('\n');
  }

  /// The GNU `stat -c` the helper speaks, bridged for a BSD one.
  const statShim =
      'stat() {\n'
      '  if [ "\$1" = "-c" ]; then\n'
      '    command stat -c "\$2" "\$3" 2>/dev/null && return 0\n'
      '    case "\$2" in\n'
      '      %u) command stat -f %u "\$3" ;;\n'
      '      %g) command stat -f %g "\$3" ;;\n'
      '      %a) command stat -f %Lp "\$3" ;;\n'
      '    esac\n'
      '  else command stat "\$@"; fi\n'
      '}\n';

  late Directory root;
  late Directory cfg;
  late File config;
  late File victim;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xveil-staging');
    cfg = Directory('${root.path}/cfg')..createSync();
    config = File('${cfg.path}/node.toml')..writeAsStringSync('[transport]\n');
    victim = File('${root.path}/victim')..writeAsStringSync('untouched');
    addTearDown(() => root.deleteSync(recursive: true));
  });

  ProcessResult run(String body) => Process.runSync('bash', [
    '-c',
    'set -uo pipefail\n'
        'XVEIL_TMP="${root.path}"\n'
        'VICTIM="${victim.path}"\n'
        '$statShim'
        '${helper()}\n'
        '$body',
  ]);

  test('a symlink dropped in the scratch file\'s place writes nothing', () {
    // The attacker wins the race every time: whatever the helper removes, a
    // symlink to the victim takes its place immediately afterwards. The only
    // defence that survives that is a name the attacker cannot compute — one
    // made by `mktemp`, in a directory it cannot write.
    final out = run(
      'sudo() {\n'
      '  case "\$1" in\n'
      '    rm) shift; command rm "\$@"; ln -s "\$VICTIM" "\${@: -1}" ;;\n'
      '    *) "\$@" ;;\n'
      '  esac\n'
      '}\n'
      'set_toml_scalar transport obfs4_psk_file \'"/x"\' "${config.path}"\n',
    );

    expect(
      victim.readAsStringSync(),
      'untouched',
      reason:
          'root wrote through a symlink at a name anybody could compute '
          '(stderr: ${out.stderr})',
    );
    // And the edit it was asked for still happened.
    expect(out.exitCode, 0, reason: '${out.stderr}');
    expect(config.readAsStringSync(), contains('obfs4_psk_file = "/x"'));
  });

  test('a config replaced by a symlink is refused, not followed', () {
    // The other half: the file root READS. Following this one would put
    // whatever it points at into the node's config, which the veil account
    // can read.
    final secret = File('${root.path}/secret')
      ..writeAsStringSync('[transport]\nroot_only = "shadow"\n');
    config.deleteSync();
    Link(config.path).createSync(secret.path);

    final out = run(
      'sudo() { "\$@"; }\n'
      // Reports whether root ever OPENED the name. Refusing after reading it
      // still means root read a file chosen by somebody else — the check has
      // to come first, not merely happen.
      'awk() { echo OPENED >&2; command awk "\$@"; }\n'
      'set_toml_scalar transport obfs4_psk_file \'"/x"\' "${config.path}"\n',
    );

    expect(out.exitCode, isNot(0), reason: 'the symlink was followed');
    expect(
      out.stderr.toString(),
      isNot(contains('OPENED')),
      reason: 'root read the file behind the symlink before refusing it',
    );
    expect(
      secret.readAsStringSync(),
      isNot(contains('obfs4_psk_file')),
      reason: 'root wrote through the symlink into what it points at',
    );
  });

  test('and the staged config is checked before it is installed', () {
    // The same name, opened a third time — by the `install` that puts the
    // validated config into /var/lib/veil. Asserted on the script, because
    // that line runs `sudo install` on a real server and nothing else.
    final script = buildProvisionScript(
      const NodeProvisionConfig(
        releaseUrl: 'https://example.invalid/veil-cli',
        expectedSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        obfs4PskB64: 'dGVzdC1maXh0dXJlLXBzay1ub3QtcmVhbC12YWx1ZSE=',
      ),
    );
    final lines = script.split('\n');
    final install = lines.indexWhere(
      (l) => l.contains(r'$XVEIL_TMP/cfg/xveil-node.toml /var/lib/veil/'),
    );
    expect(install, isNot(-1), reason: 'the install moved');
    expect(
      lines[install - 1],
      contains(r'require_staged_file $XVEIL_TMP/cfg/xveil-node.toml'),
      reason: 'root installs a name the veil account can replace, unchecked',
    );
  });
}
