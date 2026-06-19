import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_provisioner.dart';

void main() {
  const cfg = NodeProvisionConfig(
    releaseUrl: 'https://example.com/releases/veil-cli-x86_64-linux-musl',
    obfs4PskB64: 'CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI=',
    listenPort: 5556,
    runExit: true,
  );

  test('config validation', () {
    expect(cfg.isValid, isTrue);
    expect(
        const NodeProvisionConfig(releaseUrl: 'http://x', obfs4PskB64: 'a')
            .isValid,
        isFalse); // not https
    expect(
        const NodeProvisionConfig(releaseUrl: 'https://x', obfs4PskB64: '')
            .isValid,
        isFalse); // no psk
  });

  test('script pulls the binary, embeds the PSK, configures + starts', () {
    final s = buildProvisionScript(cfg);
    expect(s, contains("curl -fsSL 'https://example.com/releases/"));
    expect(s, contains('CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI='));
    expect(s, contains('/usr/local/bin/veil-cli'));
    expect(s, contains('/etc/systemd/system/veil.service'));
    expect(s, contains("obfs4-tcp://0.0.0.0:5556"));
    expect(s, contains('config set proxy.exit.enabled true'));
    expect(s, contains('systemctl restart veil'));
    expect(s, contains('NODE_ID:'));
    // Idempotent identity: only mines when node.toml lacks [Identity].
    expect(s, contains(r"grep -qE '^\[Identity\]'"));
  });

  test('exit can be disabled', () {
    final s = buildProvisionScript(NodeProvisionConfig(
        releaseUrl: cfg.releaseUrl, obfs4PskB64: cfg.obfs4PskB64, runExit: false));
    expect(s, isNot(contains('config set proxy.exit.enabled true')));
    expect(s, contains('# exit proxy disabled'));
  });
}
