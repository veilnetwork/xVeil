import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/node_provisioner.dart';

void main() {
  const sha =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  test('inventory is read-only and reports every managed component', () {
    final script = buildNodeInventoryScript();
    expect(script, contains('veil-cli ogate oproxy-client oproxy-server'));
    expect(script, contains('node show'));
    expect(script, isNot(contains('rm -')));
  });

  test('service actions use fixed unit names', () {
    final script = buildNodeServiceActionScript(
      NodeManagedService.oproxyClient,
      NodeServiceAction.enable,
    );
    expect(script, contains("enable --now 'oproxy-client.service'"));
    expect(script, contains('ACTIVE:'));
  });

  test('inventory reads node ID through the release-compatible config API', () {
    final script = buildNodeInventoryScript();
    expect(script, contains('config get identity.node_id'));
    expect(script, contains('node id'));
  });

  test('software update authenticates all assets before first install', () {
    final script = buildNodeSoftwareUpdateScript(const [
      NodeReleaseArtifact(
        component: NodeComponent.veilCli,
        releaseUrl: 'https://example.com/veil-cli',
        expectedSha256: sha,
      ),
      NodeReleaseArtifact(
        component: NodeComponent.ogate,
        releaseUrl: 'https://example.com/ogate',
        expectedSha256: sha,
      ),
    ]);
    final secondVerify = script.lastIndexOf('sha256sum -c -');
    final firstInstall = script.indexOf('sudo install');
    expect(firstInstall, greaterThan(secondVerify));
    expect(script, contains('systemctl restart'));
  });

  test('remote config round-trips through framed base64', () {
    const config = '[proxy]\nname = "тест"\n# comments survive\n';
    final framed =
        'noise\nXVEIL_CONFIG_BEGIN\n${Uri.encodeComponent('ignored')}';
    expect(parseReadNodeConfig(framed), isNull);
    final encoded =
        'XVEIL_CONFIG_BEGIN\n${base64Encode(utf8.encode(config))}\nXVEIL_CONFIG_END\n';
    expect(parseReadNodeConfig(encoded)?.contents, config);
  });

  test('config apply validates and rolls back on activation failure', () {
    final script = buildWriteNodeConfigScript(
      NodeConfigTarget.veil,
      '[ipc]\nenabled = true\n',
    );
    expect(script, contains('config validate'));
    expect(script, contains('CONFIG_ROLLED_BACK'));
    expect(script, contains('cp --preserve'));
    expect(script, contains('/var/lib/veil/node.toml'));
  });

  test('uninstall preserves data while debootstrap wipes bounded paths', () {
    final uninstall = buildNodeUninstallScript({NodeManagedService.veil});
    expect(uninstall, contains('DATA_PRESERVED'));
    expect(uninstall, isNot(contains('rm -rf')));

    final wipe = buildNodeDebootstrapScript();
    expect(wipe, contains('/var/lib/veil'));
    expect(wipe, contains('/etc/ogate'));
    expect(wipe, contains('/etc/oproxy'));
    expect(wipe, isNot(contains(r'$HOME')));
  });

  test('every generated lifecycle command is valid bash', () async {
    final scripts = [
      buildNodeInventoryScript(),
      for (final service in NodeManagedService.values)
        for (final action in NodeServiceAction.values)
          buildNodeServiceActionScript(service, action),
      buildReadNodeConfigScript(NodeConfigTarget.veil),
      buildWriteNodeConfigScript(
        NodeConfigTarget.veil,
        '[ipc]\nenabled=true\n',
      ),
      buildNodeUninstallScript({NodeManagedService.veil}),
      buildNodeDebootstrapScript(),
    ];
    for (final script in scripts) {
      final result = await Process.run('bash', ['-n', '-c', script]);
      expect(result.exitCode, 0, reason: '${result.stderr}\n$script');
    }
  });

  group('privileged staging (audit X-04, X-09)', () {
    test('the config script stages in a root-made temp dir, not a fixed path', () {
      final script = buildWriteNodeConfigScript(
        NodeConfigTarget.veil,
        '[ipc]\nenabled = true\n',
      );
      // The backup used to be `<path>.xveil-backup` — a fixed sibling in a
      // directory the `veil` service user can write. A compromised `veil` could
      // pre-place a symlink under that name pointing at any root-owned file,
      // and the next administrative save had root write THROUGH it.
      // Asserted on the assignments, not on the word: the script carries a
      // comment naming the old scheme, and a test that matched the prose would
      // fail for explaining itself.
      expect(
        script,
        contains(r'backup="$stage/config.backup"'),
        reason: 'the backup belongs inside the root-only staging dir',
      );
      expect(
        script,
        contains(r'temp="$stage/config.toml"'),
        reason: 'a predictable staging path is pre-plantable',
      );
      expect(script, contains(r'stage="$(sudo mktemp -d)"'));
      expect(script, contains(r'trap ' "'" r'sudo rm -rf "$stage"' "'" r' EXIT'));
      // Staging is traversable-but-not-writable for the validator, and the
      // file stays root-owned until `install` sets the real owner.
      expect(script, contains(r'sudo chmod 0710 "$stage"'));
      // 0640 root:veil, not 0644: the staged file is the CONTENTS of the
      // target, and for the veil target that carries `[identity] private_key`
      // (report16 X16-H3). See node_config_cas_test for the rest.
      expect(script, contains(r'sudo chmod 0640 "$temp"'));
      expect(
        script,
        isNot(contains(r'sudo chown veil:veil "$temp"')),
        reason: 'handing the staged file to the service user before install '
            'lets it rewrite bytes that were already validated',
      );
    });

    test('the update script downloads and installs from the same root-only dir', () {
      final script = buildNodeSoftwareUpdateScript([
        NodeReleaseArtifact(
          component: NodeComponent.veilCli,
          releaseUrl: 'https://example.invalid/veil-cli',
          expectedSha256: 'a' * 64,
        ),
      ]);
      expect(
        script,
        isNot(contains('/tmp/xveil-update-')),
        reason: 'a process running as the same SSH user could swap the file '
            'between sha256sum -c and the sudo install that trusted it',
      );
      expect(script, contains(r'stage="$(sudo mktemp -d)"'));
      // Verify and install must name the SAME staged path.
      expect(script, contains(r'sudo sha256sum -c -'));
      expect(script, contains(r'"$stage/veil-cli"'));
    });
  });
}
