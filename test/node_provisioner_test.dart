import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_provisioner.dart';

void main() {
  // A well-known 64-hex digest used purely as a fixture.
  const sha =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  const cfg = NodeProvisionConfig(
    releaseUrl: 'https://example.com/releases/veil-cli-x86_64-linux-musl',
    expectedSha256: sha,
    obfs4PskB64: 'CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI=',
    listenPort: 5556,
    runExit: true,
  );

  test('config validation', () {
    expect(cfg.isValid, isTrue);
    expect(
        const NodeProvisionConfig(
                releaseUrl: 'http://x', expectedSha256: sha, obfs4PskB64: 'a')
            .isValid,
        isFalse); // not https
    expect(
        const NodeProvisionConfig(
                releaseUrl: 'https://x', expectedSha256: sha, obfs4PskB64: '')
            .isValid,
        isFalse); // no psk
    // A missing / malformed checksum is rejected — provisioning must never run
    // an unverified root binary (PROVISION-RCE).
    expect(
        const NodeProvisionConfig(
                releaseUrl: 'https://x', expectedSha256: '', obfs4PskB64: 'a')
            .isValid,
        isFalse);
    expect(
        const NodeProvisionConfig(
                releaseUrl: 'https://x',
                expectedSha256: 'not-a-sha',
                obfs4PskB64: 'a')
            .isValid,
        isFalse);
  });

  test('script verifies the checksum BEFORE installing/running as root', () {
    final s = buildProvisionScript(cfg);
    expect(s, contains("curl -fsSL 'https://example.com/releases/"));
    // The checksum is verified against the download, and that check precedes
    // the `sudo install` — so a mismatched (tampered) binary aborts the script
    // before it is ever placed on PATH or executed as root.
    expect(s, contains("echo '$sha  /tmp/veil-cli' | sha256sum -c -"));
    final verifyAt = s.indexOf('sha256sum -c -');
    final installAt = s.indexOf('sudo install -o root -g root');
    expect(verifyAt, greaterThanOrEqualTo(0));
    expect(installAt, greaterThan(verifyAt),
        reason: 'checksum verification must come before sudo install');
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
        releaseUrl: cfg.releaseUrl,
        expectedSha256: sha,
        obfs4PskB64: cfg.obfs4PskB64,
        runExit: false));
    expect(s, isNot(contains('config set proxy.exit.enabled true')));
    expect(s, contains('# exit proxy disabled'));
  });
}
