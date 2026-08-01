import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production seeds contain no operator-owned UDP reflector endpoint',
    () async {
      final decoded =
          jsonDecode(await rootBundle.loadString('assets/prod/seeds.json'))
              as List<dynamic>;
      expect(decoded, isNotEmpty);
      expect(
        decoded.whereType<Map<dynamic, dynamic>>().every(
          (entry) =>
              !entry.containsKey('udp_reflector') &&
              !entry.containsKey('udp_reflectors'),
        ),
        isTrue,
      );
    },
  );

  group('BootstrapPeerCfg.listFromJson', () {
    test('parses the inventory shape, defaulting algo', () {
      final peers = BootstrapPeerCfg.listFromJson([
        {
          'transport': 'obfs4-tcp://10.0.0.1:5556',
          'public_key': 'AAA=',
          'nonce': 'BBB=',
          'algo': 'ed25519',
        },
        {
          // algo omitted -> default ed25519
          'transport': 'obfs4-tcp://10.0.0.2:5556',
          'public_key': 'CCC=',
          'nonce': 'DDD=',
        },
      ]);
      expect(peers, hasLength(2));
      expect(peers[0].transport, 'obfs4-tcp://10.0.0.1:5556');
      expect(peers[1].algo, 'ed25519');
    });
  });

  group('mergeBootstrapPeers', () {
    const alt = BootstrapPeerCfg(
      transport: 'obfs4-tcp://10.0.0.9:5556',
      publicKey: 'ALT=',
      nonce: 'NA=',
    );
    const seed1 = BootstrapPeerCfg(
      transport: 'obfs4-tcp://10.0.0.1:5556',
      publicKey: 'PK1=',
      nonce: 'N1=',
    );
    const seed2 = BootstrapPeerCfg(
      transport: 'obfs4-tcp://10.0.0.2:5556',
      publicKey: 'PK2=',
      nonce: 'N2=',
    );

    test('an operator-supplied entry point does not drop the bundled seeds', () {
      // The regression: the env file REPLACED the bundled seeds, so naming one
      // alternative cost the node every production seed.
      final merged = mergeBootstrapPeers(const [alt], const [seed1, seed2]);
      expect(merged.map((p) => p.publicKey), ['ALT=', 'PK1=', 'PK2=']);
    });

    test('the same node listed in both sources is dialed once', () {
      final merged = mergeBootstrapPeers(const [seed1], const [seed1, seed2]);
      expect(merged.map((p) => p.publicKey), ['PK1=', 'PK2=']);
    });

    test('deduplicates by public key, not by transport', () {
      // Same node reached over a second transport is still one dial target.
      const sameNodeOtherTransport = BootstrapPeerCfg(
        transport: 'tls://relay.example:9906',
        publicKey: 'PK1=',
        nonce: 'N1=',
      );
      final merged = mergeBootstrapPeers(const [sameNodeOtherTransport], const [
        seed1,
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.transport, 'tls://relay.example:9906');
    });

    test('either side may be empty', () {
      expect(mergeBootstrapPeers(const [], const [seed1]), hasLength(1));
      expect(mergeBootstrapPeers(const [alt], const []), hasLength(1));
      expect(mergeBootstrapPeers(const [], const []), isEmpty);
    });
  });

  group('EmbeddedNode.withBootstrapPeers', () {
    test('no-op for an empty peer list (relies on builtin seeds)', () {
      const toml = 'listen = "tcp://127.0.0.1:9000"\n';
      expect(EmbeddedNode.withBootstrapPeers(toml, const []), toml);
    });

    test(
      'appends one [[bootstrap_peers]] table per peer, leaving prior TOML intact',
      () {
        const toml = 'listen = "tcp://127.0.0.1:9000"\n';
        final out = EmbeddedNode.withBootstrapPeers(toml, const [
          BootstrapPeerCfg(
            transport: 'obfs4-tcp://10.0.0.1:5556',
            publicKey: 'PK1=',
            nonce: 'N1=',
          ),
          BootstrapPeerCfg(
            transport: 'obfs4-tcp://10.0.0.2:5556',
            publicKey: 'PK2=',
            nonce: 'N2=',
            algo: 'ed25519',
          ),
        ]);

        // Original config preserved.
        expect(out, startsWith(toml));
        // One table header per peer, top-level (matches veil's rendered node.toml).
        expect('[[bootstrap_peers]]'.allMatches(out).length, 2);
        // Fields rendered with the exact veil keys.
        expect(out, contains('transport = "obfs4-tcp://10.0.0.1:5556"'));
        expect(out, contains('public_key = "PK2="'));
        expect(out, contains('nonce = "N1="'));
        expect(out, contains('algo = "ed25519"'));
        // Not nested under [network] — veil flattens these at the root.
        expect(out, isNot(contains('[[network.bootstrap_peers]]')));
      },
    );

    test('skips an entry that would break/inject the TOML (fail-closed)', () {
      const toml = 'listen = "x"\n';
      final out = EmbeddedNode.withBootstrapPeers(toml, const [
        // Injection attempt: a quote+newline in transport breaking out of the
        // string. Must be skipped entirely.
        BootstrapPeerCfg(
          transport: 'tcp://1.2.3.4:5556"\n[evil]\nx = 1',
          publicKey: 'PK=',
          nonce: 'N=',
        ),
        // A good entry alongside it still renders.
        BootstrapPeerCfg(
          transport: 'obfs4-tcp://10.0.0.9:5556',
          publicKey: 'GOOD=',
          nonce: 'N9=',
        ),
      ]);
      expect(out, isNot(contains('[evil]')));
      expect('[[bootstrap_peers]]'.allMatches(out).length, 1);
      expect(out, contains('transport = "obfs4-tcp://10.0.0.9:5556"'));
    });
  });

  group('EmbeddedNode.withObfs4PskFile', () {
    test('no-op when no PSK path given', () {
      const toml = 'listen = "x"\n';
      expect(EmbeddedNode.withObfs4PskFile(toml, null), toml);
      expect(EmbeddedNode.withObfs4PskFile(toml, ''), toml);
    });

    test('appends a [transport] table pointing at the PSK file', () {
      final out = EmbeddedNode.withObfs4PskFile(
        'listen = "x"\n',
        '/tmp/psk.b64',
      );
      expect(out, contains('[transport]'));
      expect(out, contains('obfs4_psk_file = "/tmp/psk.b64"'));
    });

    test(
      'inserts into an existing [transport] table (no duplicate header)',
      () {
        const toml = '[transport]\nfoo = 1\n';
        final out = EmbeddedNode.withObfs4PskFile(toml, '/tmp/psk.b64');
        expect('[transport]'.allMatches(out).length, 1);
        expect(out, contains('obfs4_psk_file = "/tmp/psk.b64"'));
        expect(out, contains('foo = 1'));
      },
    );

    test('idempotent when obfs4_psk_file already present', () {
      const toml = '[transport]\nobfs4_psk_file = "/x"\n';
      expect(EmbeddedNode.withObfs4PskFile(toml, '/tmp/psk.b64'), toml);
    });
  });

  group('EmbeddedNode.withUdpReflectors', () {
    test('is a no-op when direct UDP traversal is not configured', () {
      const toml = '[nat]\nenabled = true\nudp_reflectors = []\n';
      expect(EmbeddedNode.withUdpReflectors(toml, const []), toml);
    });

    test('replaces the rendered empty key without duplicating nat', () {
      const toml = '[nat]\nenabled = true\nudp_reflectors = []\n';
      final out = EmbeddedNode.withUdpReflectors(toml, const [
        '203.0.113.7:39999',
        '[2001:db8::7]:39999',
      ]);
      expect('[nat]'.allMatches(out), hasLength(1));
      expect('udp_reflectors'.allMatches(out), hasLength(1));
      expect(
        out,
        contains(
          'udp_reflectors = ["203.0.113.7:39999", "[2001:db8::7]:39999"]',
        ),
      );
    });

    test(
      'appends nat when absent and rejects non-numeric or unsafe values',
      () {
        final out = EmbeddedNode.withUdpReflectors('listen = "x"\n', const [
          'reflector.example:39999',
          '127.0.0.1:0',
          '127.0.0.1:39999"\n[evil]',
          '127.0.0.1:39999',
          '127.0.0.1:39999',
        ]);
        expect(out, contains('[nat]\nudp_reflectors = ["127.0.0.1:39999"]'));
        expect(out, isNot(contains('[evil]')));
      },
    );
  });

  group('EmbeddedNode.withDebugMetrics', () {
    test('no-op without a port', () {
      const toml = 'listen = "x"\n';
      expect(EmbeddedNode.withDebugMetrics(toml, null), toml);
      expect(EmbeddedNode.withDebugMetrics(toml, 0), toml);
      expect(EmbeddedNode.withDebugMetrics(toml, -1), toml);
    });

    test('appends a loopback-only [metrics] table', () {
      final out = EmbeddedNode.withDebugMetrics('listen = "x"\n', 39997);
      expect(out, contains('[metrics]'));
      expect(out, contains('listen = "tcp://127.0.0.1:39997"'));
      expect(out, contains('path = "/metrics"'));
    });

    test('idempotent when a [metrics] table already exists', () {
      const toml = '[metrics]\nlisten = "tcp://127.0.0.1:1"\n';
      expect(EmbeddedNode.withDebugMetrics(toml, 39997), toml);
    });
  });
}
