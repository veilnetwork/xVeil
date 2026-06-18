import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/data/transport/veil_mailbox_network.dart';
import 'package:xveil/state/mailbox_orchestrator.dart';

/// STEP 2e — the FULL real-crypto offline round-trip with a distinct sender and
/// VERIFIED sender attribution. This is the acceptance test for the sealed-sender
/// fix: unlike STEP 2c/2d (which used [LoopbackMailboxCrypto] to isolate the
/// transport), this drives the real node-side E2E seal/open
/// ([VeilFlutterMailboxCrypto]) end to end and asserts the recipient recovers the
/// REAL sender from the blob's sidecar — not the all-zero wire hint.
///
/// Topology (scripts/dev-mailbox-onion.sh, 5 nodes):
///   R = mailbox relay, F = recipient, S = sender, M1/M2 = onion relays.
///   F advertises R as its mailbox relay.
///   S.stash(recipient=F)  → real seal (resolves F's ML-KEM cert cross-node +
///                           KEM-seals the sender sidecar) → cross-node ad
///                           resolve → sender-anonymous PUT at R over the onion.
///   F.drain(me=F)         → authenticated FETCH from R → real open: recovers S
///                           from the sidecar, resolves S's doc, verifies the
///                           auth-deliver → DrainedMessage with verified sender.
///
/// The headline assertion: `drained.sender == S` — proving anonymous offline
/// delivery attributes the message to the cryptographically-verified sender even
/// though the wire sender is 0.
///
/// ⚠️ CURRENTLY BLOCKED (2026-06-18) on a SEPARATE transport limit, not crypto:
/// the deposit uses `send_anonymous_direct`, which packs into a single 512-byte
/// onion cell (`max_payload_for_hops(1) = 429 B`, no fragmentation). A real
/// mailbox blob is ~2.5 KB (two ML-KEM-768 fan-out envelopes — the auth-deliver
/// + the sender sidecar), so the PUT is rejected `PAYLOAD_TOO_LARGE` (status 6).
/// The sealed-sender crypto is correct + unit-proven; this live test passes once
/// the deposit transport fragments KB-sized blobs. See the offline-delivery memo.
///
/// Bring the mesh up first:  scripts/dev-mailbox-onion.sh   (run the STEP 2d env
/// block it prints — this test reads the same vars).
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockS = Platform.environment['XVEIL_TEST_SOCK_SENDER']; // S (sender)
  final sockF = Platform.environment['XVEIL_TEST_SOCK_FETCH']; // F (recipient)
  final sockR = Platform.environment['XVEIL_TEST_SOCK_RELAY']; // R (mailbox relay)
  final sIdHex = Platform.environment['XVEIL_SEND_NODE_ID'];
  final fIdHex = Platform.environment['XVEIL_FETCH_NODE_ID'];
  final rIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty ||
          sockS == null || sockS.isEmpty || sockF == null || sockF.isEmpty ||
          sockR == null || sockR.isEmpty || sIdHex == null || sIdHex.length != 64 ||
          fIdHex == null || fIdHex.length != 64 || rIdHex == null || rIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/FETCH/RELAY + '
          'XVEIL_SEND_NODE_ID + XVEIL_FETCH_NODE_ID + XVEIL_RELAY_NODE_ID (64hex)'
      : false;

  // App routing target the sender binds into the (signed) auth-deliver.
  final inboxAppId = Uint8List.fromList(List.generate(32, (i) => (i * 3 + 1) & 0xff));
  const inboxEndpointId = 11;
  const replyEndpointId = 7;

  test('S deposits for offline F with REAL crypto; F drains + verifies sender',
      timeout: const Timeout(Duration(seconds: 300)), () async {
    DynamicLibrary.open(dylib!);
    final sId = NodeId(_hex(sIdHex!));
    final fId = NodeId(_hex(fIdHex!));
    final rId = _hex(rIdHex!);

    final clientS = await VeilClient.connect(sockS!);
    final clientF = await VeilClient.connect(sockF!);
    final clientR = await VeilClient.connect(sockR!);
    AppHandle? sSrc;
    AppHandle? sReply;
    AppHandle? fSrc;
    AppHandle? fReply;
    try {
      final rKem = await clientR.getRelayX25519Pubkey();
      expect(rKem, isNotNull, reason: 'R not relay_capable — no KEM key to advertise');
      await clientF.registerRendezvousPublisher(
        rendezvousNodeId: rId,
        authCookie: Uint8List.fromList(List.filled(16, 0x5C)),
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: rKem!,
      );
      print('[2e] F advertised R as its mailbox relay');

      // S must resolve F's ad cross-node before it can deposit.
      RendezvousReplica? viaS;
      for (var i = 0; i < 40 && viaS == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final replicas = await clientS.mailbox.lookupRendezvousReplicas(fId.bytes);
        for (final r in replicas) {
          if (_eq(r.relayNodeId, rId) && r.rendezvousKemPk.length == 32) viaS = r;
        }
      }
      expect(viaS, isNotNull, reason: 'S could not resolve F\'s mailbox ad cross-node');
      print('[2e] S resolved F\'s ad cross-node → relay=${_short(viaS!.relayNodeId)}');

      sSrc = await clientS.bind(namespace: 'xveil', name: 'mailbox-sender', endpointId: 0);
      sReply = await clientS.bind(
          namespace: 'xveil', name: 'mailbox-fetch', endpointId: replyEndpointId);
      final relayS = VeilNetworkMailboxRelay(
        client: clientS,
        fetchApp: sReply,
        srcAppId: sSrc.appId,
        replyEndpointId: replyEndpointId,
        putHopCount: 1,
      );
      // REAL crypto — node-side seal that resolves F's cert + builds the sidecar.
      final orchS = MailboxOrchestrator(VeilFlutterMailboxCrypto(clientS.mailbox), relayS);

      final data = Uint8List.fromList(utf8.encode('real-crypto-offline-S-to-F'));
      final contentId = Uint8List.fromList(List.filled(32, 0x2E));

      var stashed = false;
      Object? stashErr;
      for (var i = 0; i < 20 && !stashed; i++) {
        try {
          await orchS.stash(
            me: sId,
            recipient: fId,
            appId: inboxAppId,
            endpointId: inboxEndpointId,
            data: data,
            contentId: contentId,
          );
          stashed = true;
        } catch (e) {
          stashErr = e;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      print('[2e] S sealed + deposited at R: $stashed${stashed ? "" : " ($stashErr)"}');
      expect(stashed, isTrue, reason: 'S could not real-seal + deposit for F: $stashErr');

      fSrc = await clientF.bind(namespace: 'xveil', name: 'mailbox-sender', endpointId: 0);
      fReply = await clientF.bind(
          namespace: 'xveil', name: 'mailbox-fetch', endpointId: replyEndpointId);
      final relayF = VeilNetworkMailboxRelay(
        client: clientF,
        fetchApp: fReply,
        srcAppId: fSrc.appId,
        replyEndpointId: replyEndpointId,
        putHopCount: 1,
      );
      final orchF = MailboxOrchestrator(VeilFlutterMailboxCrypto(clientF.mailbox), relayF);

      List<DrainedMessage> drained = const [];
      for (var i = 0; i < 30 && drained.isEmpty; i++) {
        drained = await orchF.drain(
          me: fId,
          authCookie: Uint8List(0),
          ourCertVersion: 1, // fresh node's first published cert
          alreadyHave: (_) async => false,
        );
        if (drained.isEmpty) await Future<void>.delayed(const Duration(seconds: 2));
      }
      print('[2e] F drained ${drained.length} message(s)');
      expect(drained, isNotEmpty,
          reason: 'F drained nothing — real-crypto deposit never opened at F');

      final got = drained.first;
      expect(got.data, data, reason: 'decrypted plaintext must equal what S sent');
      expect(got.appId, inboxAppId, reason: 'verified app id must round-trip');
      expect(got.endpointId, inboxEndpointId);
      // THE headline assertion — verified sender recovered from the sidecar.
      expect(got.sender, sId,
          reason: 'F must attribute the message to the CRYPTO-VERIFIED sender S, '
              'not the all-zero wire hint');
      print('[2e] ✓ real-crypto offline round-trip: F recovered '
          '"${utf8.decode(got.data)}" and verified sender == S');
    } finally {
      sSrc?.close();
      sReply?.close();
      fSrc?.close();
      fReply?.close();
      await clientS.close();
      await clientF.close();
      await clientR.close();
    }
  }, skip: skip);
}

String _short(Uint8List id) =>
    id.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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
