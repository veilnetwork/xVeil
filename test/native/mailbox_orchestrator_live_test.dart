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

/// CHUNK 2 of the app-layer offline-delivery integration — drives the real
/// [MailboxOrchestrator] over the NETWORK-path [VeilNetworkMailboxRelay] against
/// a live onion mesh, proving the new transport end to end.
///
/// Topology (scripts/dev-mailbox-onion.sh): R = mailbox relay (stores + serves
/// FETCH), F = receiver, M1/M2 = onion relays. F advertises R as its mailbox
/// relay (registerRendezvousPublisher with R's KEM key), then:
///   stash(recipient = F)  → adapter resolves F's ad → sendAnonymousDirect PUT
///                           deposits the sealed blob at R over the onion.
///   drain(me = F)         → adapter resolves F's ad → authenticated-with-reply
///                           FETCH from R → opens + dedups → DrainedMessage.
///
/// A SELF-deposit (F stashes for F) keeps the discovery to F resolving its OWN
/// ad (STEP 2b-proven, sidesteps the separate cross-node cold-start gap) while
/// the deposit + fetch STILL cross the network to a distinct relay node (R).
/// Crypto is [LoopbackMailboxCrypto] so this isolates the new network transport;
/// real E2E seal/open ([VeilFlutterMailboxCrypto]) is proven separately (STEP 1)
/// and layered into the full app path later.
///
/// Bring the mesh up first:  scripts/dev-mailbox-onion.sh
/// then run with the env it prints for mailbox_fetch_live_test (same vars).
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockF = Platform.environment['XVEIL_TEST_SOCK_SENDER']; // F (receiver)
  final sockR = Platform.environment['XVEIL_TEST_SOCK_RELAY']; // R (mailbox relay)
  final fIdHex = Platform.environment['XVEIL_SEND_NODE_ID'];
  final rIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockF == null || sockF.isEmpty ||
          sockR == null || sockR.isEmpty || fIdHex == null || fIdHex.length != 64 ||
          rIdHex == null || rIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RELAY + XVEIL_SEND_NODE_ID + XVEIL_RELAY_NODE_ID (64hex)'
      : false;

  // The destination app the loopback seal frames into the blob — round-tripped
  // verbatim by LoopbackMailboxCrypto and surfaced on DrainedMessage.
  final inboxAppId = Uint8List.fromList(List.generate(32, (i) => i + 1));
  const inboxEndpointId = 5;
  const replyEndpointId = 7;

  test('orchestrator stashes for F at R and drains it back over the onion',
      timeout: const Timeout(Duration(seconds: 180)), () async {
    DynamicLibrary.open(dylib!);
    final fId = NodeId(_hex(fIdHex!));
    final rId = _hex(rIdHex!);

    final clientF = await VeilClient.connect(sockF!);
    final clientR = await VeilClient.connect(sockR!);
    AppHandle? srcApp;
    AppHandle? replyApp;
    try {
      // F advertises R as its mailbox relay, carrying R's KEM key so depositors
      // (here F itself) can seal the anonymous-direct PUT to R.
      final rKem = await clientR.getRelayX25519Pubkey();
      expect(rKem, isNotNull, reason: 'R not relay_capable — no KEM key to advertise');
      await clientF.registerRendezvousPublisher(
        rendezvousNodeId: rId,
        authCookie: Uint8List.fromList(List.filled(16, 0x5C)),
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: rKem!,
      );
      print('[orch] F advertised R as its mailbox relay (KEM ${rKem.length}B)');

      // Wait until F can resolve its OWN ad (= ad signed + published).
      RendezvousReplica? replica;
      for (var i = 0; i < 40 && replica == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final replicas = await clientF.mailbox.lookupRendezvousReplicas(fId.bytes);
        if (replicas.any((r) => r.rendezvousKemPk.length == 32)) {
          replica = replicas.firstWhere((r) => r.rendezvousKemPk.length == 32);
        }
      }
      expect(replica, isNotNull, reason: 'F could not resolve its own mailbox ad');
      expect(replica!.relayNodeId, rId, reason: 'resolved replica must point at R');
      print('[orch] F resolved its ad → relay=${_short(replica.relayNodeId)}');

      // Bind the PUT source app (anti-SPOOFED_SRC) and the FETCH reply endpoint.
      srcApp = await clientF.bind(
          namespace: 'xveil', name: 'mailbox-sender', endpointId: 0);
      replyApp = await clientF.bind(
          namespace: 'xveil', name: 'mailbox-fetch', endpointId: replyEndpointId);

      final relay = VeilNetworkMailboxRelay(
        client: clientF,
        fetchApp: replyApp,
        srcAppId: srcApp.appId,
        replyEndpointId: replyEndpointId,
        putHopCount: 1, // direct F->R; multi-hop anonymity validated separately
      );
      final orchestrator = MailboxOrchestrator(LoopbackMailboxCrypto(), relay);

      final data = Uint8List.fromList(utf8.encode('orchestrator-offline-payload'));
      final contentId = Uint8List.fromList(List.filled(32, 0x42));

      // STASH — retry: circuits may still be forming just after boot.
      var stashed = false;
      Object? stashErr;
      for (var i = 0; i < 15 && !stashed; i++) {
        try {
          await orchestrator.stash(
            me: fId,
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
      print('[orch] stash deposited at R: $stashed${stashed ? "" : " ($stashErr)"}');
      expect(stashed, isTrue, reason: 'could not deposit the stash at R: $stashErr');

      // DRAIN — retry until the deposited message comes back over the FETCH path.
      List<DrainedMessage> drained = const [];
      for (var i = 0; i < 30 && drained.isEmpty; i++) {
        drained = await orchestrator.drain(
          me: fId,
          authCookie: Uint8List(0), // ignored on the network path
          ourCertVersion: 0,
          alreadyHave: (_) async => false,
        );
        if (drained.isEmpty) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      print('[orch] drained ${drained.length} message(s)');
      expect(drained, isNotEmpty,
          reason: 'no message drained from R over the onion FETCH');

      final got = drained.first;
      expect(got.data, data, reason: 'drained plaintext must equal what we stashed');
      expect(got.contentId, contentId, reason: 'content id must round-trip');
      expect(got.appId, inboxAppId, reason: 'destination app id must round-trip');
      expect(got.endpointId, inboxEndpointId);
      print('[orch] ✓ round-trip: "${utf8.decode(got.data)}" recovered via the '
          'network mailbox transport');
    } finally {
      srcApp?.close();
      replyApp?.close();
      await clientF.close();
      await clientR.close();
    }
  }, skip: skip);
}

String _short(Uint8List id) =>
    id.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
