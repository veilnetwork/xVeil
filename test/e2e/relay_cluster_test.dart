@Timeout(Duration(minutes: 10))
library;

import 'package:flutter_test/flutter_test.dart';

import 'e2e_env.dart';
import 'relay_cluster.dart';

/// Smoke test for the island itself, separate from any case that uses it.
///
/// It exists because "the relays never came up" and "the devices did not
/// converge" are different failures that look identical from a case's
/// assertion. When this file is green and a case is red, the network is not
/// the suspect.
void main() {
  final gate = E2eGate.read();

  test('a sealed local relay island comes up and tears down', () async {
    final root = await e2eTempRoot('xveil-e2e-relays-');
    RelayCluster? cluster;
    addTearDown(() async {
      await cluster?.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    cluster = await RelayCluster.start(
      veilCliPath: gate.veilCli!,
      root: root,
    );

    expect(cluster.nodes, hasLength(3));
    for (final node in cluster.nodes) {
      expect(node.running, isTrue, reason: node.logTail());
      expect(node.nodeIdHex, hasLength(64));
      expect(await portAnswers(node.listenPort), isTrue,
          reason: '${node.label} is not accepting connections');
    }

    // Distinct identities: a fixture copied by mistake would give two relays
    // the same node id, and the island would silently be smaller than it looks.
    expect(
      cluster.nodes.map((n) => n.nodeIdHex).toSet(),
      hasLength(3),
      reason: 'two relays share a node id — check test/e2e/fixtures',
    );

    // The property that cannot be observed from inside a passing test.
    cluster.assertSealed();

    // Bootstrap peers are what the app devices are handed; a malformed one
    // fails much later as "the node never found the network".
    final peers = cluster.bootstrapPeers;
    expect(peers, hasLength(3));
    for (final peer in peers) {
      expect(peer.transport, startsWith('tcp://127.0.0.1:'));
      expect(peer.publicKey, isNotEmpty);
      expect(peer.nonce, isNotEmpty);
    }

    // Teardown really stops them: a leaked relay poisons every later run.
    final ports = [for (final n in cluster.nodes) n.listenPort];
    await cluster.dispose(removeFiles: false);
    for (final port in ports) {
      await waitUntil(
        () async => !await portAnswers(port),
        what: 'relay port $port to close after dispose()',
        timeout: const Duration(seconds: 20),
      );
    }
  }, skip: gate.skip);
}
