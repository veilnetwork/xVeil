import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
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

  group('EmbeddedNode.withBootstrapPeers', () {
    test('no-op for an empty peer list (relies on builtin seeds)', () {
      const toml = 'listen = "tcp://127.0.0.1:9000"\n';
      expect(EmbeddedNode.withBootstrapPeers(toml, const []), toml);
    });

    test('appends one [[bootstrap_peers]] table per peer, leaving prior TOML intact', () {
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
    });

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
      final out = EmbeddedNode.withObfs4PskFile('listen = "x"\n', '/tmp/psk.b64');
      expect(out, contains('[transport]'));
      expect(out, contains('obfs4_psk_file = "/tmp/psk.b64"'));
    });

    test('inserts into an existing [transport] table (no duplicate header)', () {
      const toml = '[transport]\nfoo = 1\n';
      final out = EmbeddedNode.withObfs4PskFile(toml, '/tmp/psk.b64');
      expect('[transport]'.allMatches(out).length, 1);
      expect(out, contains('obfs4_psk_file = "/tmp/psk.b64"'));
      expect(out, contains('foo = 1'));
    });

    test('idempotent when obfs4_psk_file already present', () {
      const toml = '[transport]\nobfs4_psk_file = "/x"\n';
      expect(EmbeddedNode.withObfs4PskFile(toml, '/tmp/psk.b64'), toml);
    });
  });
}
