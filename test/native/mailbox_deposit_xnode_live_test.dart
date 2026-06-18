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

/// STEP 2d — the headline offline-delivery round-trip with a DISTINCT sender.
///
/// Everything before this proved the parts in isolation: cross-node ad resolve
/// (rendezvous_xnode_local_test, R resolves F's ad), the deposit+fetch transport
/// (mailbox_orchestrator_live_test, but F self-deposits), and real seal/open
/// (STEP 1). This test composes them the way the real app does: a SEPARATE node
/// S — neither the recipient nor the relay — deposits a message for an OFFLINE
/// recipient F, having had to resolve F's mailbox ad over the DHT cross-node,
/// then F comes along and drains it.
///
/// Topology (scripts/dev-mailbox-onion.sh, now 5 nodes):
///   R = mailbox relay (stores + serves FETCH), F = recipient, S = sender,
///   M1/M2 = onion relays.
///   F advertises R as its mailbox relay (registerRendezvousPublisher).
///   S.stash(recipient=F)  → relay(client=S) resolves F's ad CROSS-NODE → seals
///                           + sender-anonymous PUT deposits at R over the onion.
///   F.drain(me=F)         → relay(client=F) resolves F's OWN ad → authenticated
///                           FETCH from R → opens + dedups → DrainedMessage.
///
/// Crypto is [LoopbackMailboxCrypto] (as in STEP 2c) so this isolates the new
/// cross-node + distinct-sender integration; real E2E seal/open is proven in
/// STEP 1 and layered into the full app path separately.
///
/// Bring the mesh up first:  scripts/dev-mailbox-onion.sh
/// then run with the STEP 2d env block it prints.
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

  // The destination app the loopback seal frames into the blob — round-tripped
  // verbatim by LoopbackMailboxCrypto and surfaced on DrainedMessage.
  final inboxAppId = Uint8List.fromList(List.generate(32, (i) => i + 7));
  const inboxEndpointId = 9;
  const replyEndpointId = 7;

  test('S deposits for offline F at R cross-node; F drains it over the onion',
      timeout: const Timeout(Duration(seconds: 240)), () async {
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
      // F advertises R as its mailbox relay, carrying R's KEM key so depositors
      // (here the distinct node S) can seal the sender-anonymous PUT to R.
      final rKem = await clientR.getRelayX25519Pubkey();
      expect(rKem, isNotNull, reason: 'R not relay_capable — no KEM key to advertise');
      await clientF.registerRendezvousPublisher(
        rendezvousNodeId: rId,
        authCookie: Uint8List.fromList(List.filled(16, 0x5C)),
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: rKem!,
      );
      print('[2d] F advertised R as its mailbox relay (KEM ${rKem.length}B)');

      // The crux: S — NOT F — must resolve F's ad over the DHT cross-node.
      // (F is "offline" in the sense that it never has to be reachable for the
      // deposit; only its published ad must replicate to where S can walk it.)
      RendezvousReplica? viaS;
      for (var i = 0; i < 40 && viaS == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final replicas = await clientS.mailbox.lookupRendezvousReplicas(fId.bytes);
        for (final r in replicas) {
          if (_eq(r.relayNodeId, rId) && r.rendezvousKemPk.length == 32) viaS = r;
        }
      }
      expect(viaS, isNotNull,
          reason: 'S could not resolve F\'s mailbox ad cross-node (needs the ad '
              'to replicate + S to walk recursively)');
      print('[2d] S resolved F\'s ad cross-node → relay=${_short(viaS!.relayNodeId)}');

      // S binds its PUT source app (anti-SPOOFED_SRC). The reply endpoint is
      // unused by the fire-and-forget PUT but the relay ctor requires one.
      sSrc = await clientS.bind(
          namespace: 'xveil', name: 'mailbox-sender', endpointId: 0);
      sReply = await clientS.bind(
          namespace: 'xveil', name: 'mailbox-fetch', endpointId: replyEndpointId);
      final relayS = VeilNetworkMailboxRelay(
        client: clientS,
        fetchApp: sReply,
        srcAppId: sSrc.appId,
        replyEndpointId: replyEndpointId,
        putHopCount: 1, // direct S->R; multi-hop anonymity validated separately
      );
      final orchS = MailboxOrchestrator(LoopbackMailboxCrypto(), relayS);

      final data = Uint8List.fromList(utf8.encode('xnode-offline-from-S-to-F'));
      final contentId = Uint8List.fromList(List.filled(32, 0x2D));

      // STASH from S for F — retry: circuits may still be forming after boot.
      var stashed = false;
      Object? stashErr;
      for (var i = 0; i < 15 && !stashed; i++) {
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
      print('[2d] S deposited at R: $stashed${stashed ? "" : " ($stashErr)"}');
      expect(stashed, isTrue, reason: 'S could not deposit for F at R: $stashErr');

      // Now F comes online and drains its mailbox.
      fSrc = await clientF.bind(
          namespace: 'xveil', name: 'mailbox-sender', endpointId: 0);
      fReply = await clientF.bind(
          namespace: 'xveil', name: 'mailbox-fetch', endpointId: replyEndpointId);
      final relayF = VeilNetworkMailboxRelay(
        client: clientF,
        fetchApp: fReply,
        srcAppId: fSrc.appId,
        replyEndpointId: replyEndpointId,
        putHopCount: 1,
      );
      final orchF = MailboxOrchestrator(LoopbackMailboxCrypto(), relayF);

      List<DrainedMessage> drained = const [];
      for (var i = 0; i < 30 && drained.isEmpty; i++) {
        drained = await orchF.drain(
          me: fId,
          authCookie: Uint8List(0), // ignored on the network path
          ourCertVersion: 0,
          alreadyHave: (_) async => false,
        );
        if (drained.isEmpty) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      print('[2d] F drained ${drained.length} message(s)');
      expect(drained, isNotEmpty,
          reason: 'F drained nothing — S\'s cross-node deposit never landed at R');

      final got = drained.first;
      expect(got.data, data, reason: 'drained plaintext must equal what S stashed');
      expect(got.contentId, contentId, reason: 'content id must round-trip');
      expect(got.appId, inboxAppId, reason: 'destination app id must round-trip');
      expect(got.endpointId, inboxEndpointId);
      print('[2d] ✓ offline round-trip: S → R → F recovered '
          '"${utf8.decode(got.data)}" via the cross-node mailbox path');
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
