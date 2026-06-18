import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// CROSS-NODE rendezvous-ad resolve on the local dev mesh — validates the full
/// cross-node mailbox-relay discovery (2.1 STORE-accept "RA" + 2.2 replicate-on-
/// publish + 2.3 recursive resolve_replicas). F advertises R as its mailbox
/// relay (registerRendezvousPublisher); F's maintenance tick publishes AND
/// replicates the ad to its K-closest peers; then a DIFFERENT node (R) resolves
/// F's ad by F's node_id — `lookupRendezvousReplicas(F)` — over the DHT, which
/// only works if the ad replicated + the resolver walks recursively.
///
/// Bring up: scripts/dev-mailbox-onion.sh (rebuilt veil-cli WITH 2.1/2.2/2.3)
/// then run with the env it prints for mailbox_fetch_live_test (same vars):
///   F = SENDER sock + SEND_NODE_ID ; R = RELAY sock + RELAY_NODE_ID.
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockF = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockR = Platform.environment['XVEIL_TEST_SOCK_RELAY'];
  final fIdHex = Platform.environment['XVEIL_SEND_NODE_ID'];
  final rIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockF == null || sockF.isEmpty ||
          sockR == null || sockR.isEmpty || fIdHex == null || fIdHex.length != 64 ||
          rIdHex == null || rIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RELAY + XVEIL_SEND_NODE_ID + XVEIL_RELAY_NODE_ID (64hex)'
      : false;

  test('R resolves F\'s rendezvous ad cross-node on the local mesh',
      timeout: const Timeout(Duration(seconds: 220)), () async {
    DynamicLibrary.open(dylib!);
    final fId = _hex(fIdHex!);
    final rId = _hex(rIdHex!);

    final clientF = await VeilClient.connect(sockF!);
    final clientR = await VeilClient.connect(sockR!);
    try {
      final rKem = await clientR.getRelayX25519Pubkey();
      expect(rKem, isNotNull, reason: 'R not relay-capable');

      // F advertises R as its mailbox relay (a NON-ephemeral ad keyed by F's id).
      await clientF.registerRendezvousPublisher(
        rendezvousNodeId: rId,
        authCookie: Uint8List.fromList(List.filled(16, 0x5C)),
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: rKem!,
      );
      stderr.writeln('[rdv-xnode] F advertised R; waiting for F maintenance '
          'tick to publish+replicate, then R resolves cross-node…');

      // R resolves F's ads by F's node_id cross-node. F also has a
      // receive_anonymous ad (a different relay) that resolves immediately; we
      // wait for F's ~60s maintenance tick to publish+replicate OUR mailbox ad
      // (relay = R) and assert it appears among the resolved replicas.
      RendezvousReplica? mine;
      var attempts = 0;
      while (mine == null && attempts < 25) {
        attempts++;
        final replicas = await clientR.mailbox.lookupRendezvousReplicas(fId);
        for (final r in replicas) {
          if (_eq(r.relayNodeId, rId)) mine = r;
        }
        stderr.writeln('[rdv-xnode] attempt $attempts: ${replicas.length} '
            'replica(s) cross-node, foundR=${mine != null}');
        if (mine == null) await Future<void>.delayed(const Duration(seconds: 6));
      }
      expect(mine, isNotNull,
          reason: 'R must appear among F\'s resolved replicas cross-node after '
              'F\'s mailbox tick (the ad must replicate + resolver walk recursively)');
      expect(Uint8List.fromList(mine!.rendezvousKemPk), rKem,
          reason: 'resolved replica must carry R\'s KEM key');
      stderr.writeln('[rdv-xnode] ✓ cross-node rendezvous-ad resolved (relay R + KEM)');
    } finally {
      await clientF.close();
      await clientR.close();
    }
  }, skip: skip);
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
