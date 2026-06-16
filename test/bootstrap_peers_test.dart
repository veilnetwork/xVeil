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
  });
}
