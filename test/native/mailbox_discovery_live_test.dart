import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// STEP 2b of the offline-mailbox harness — DISCOVERY-DRIVEN deposit.
///
/// B advertises itself as its own mailbox relay: it registers a v5
/// rendezvous-publisher carrying its relay X25519 KEM key. The maintenance tick
/// signs + publishes the ad. B then resolves its own ad and we assert the
/// returned replica carries the relay node id + KEM key end to end (register →
/// maintenance v5 sign → resolve → ReplicaWire → FFI ABI → Dart). Finally S
/// deposits a MailboxPut at the DISCOVERED relay+key over the anonymous onion,
/// and B's mailbox service stores it — closing the loop with the target+key
/// sourced from discovery rather than hard-coded.
///
/// (B resolves its OWN ad to avoid the separate cold-start cross-node
/// DHT-replication gap; the deposit still crosses the network S→B.)
///
/// Bring the mesh up first:  scripts/dev-mailbox-mesh.sh
/// then run with the env it prints (same vars as STEP 2a).
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockS = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockRelay = Platform.environment['XVEIL_TEST_SOCK_RELAY'];
  final relayIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final relayLog = Platform.environment['XVEIL_RELAY_LOG'];
  final skip = (dylib == null || dylib.isEmpty || sockS == null || sockS.isEmpty ||
          sockRelay == null || sockRelay.isEmpty || relayIdHex == null ||
          relayIdHex.length != 64 || relayLog == null || relayLog.isEmpty)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RELAY + XVEIL_RELAY_NODE_ID(64hex) + XVEIL_RELAY_LOG'
      : false;

  // BLAKE3("veil.mailbox.v1") — the well-known mailbox app id (service.rs).
  final mailboxAppId = Uint8List.fromList(const [
    0xd4, 0x17, 0xcf, 0x22, 0x72, 0x89, 0x07, 0x40, //
    0xe2, 0xe1, 0xb6, 0xb1, 0xb5, 0x74, 0x12, 0x95,
    0x6b, 0x3e, 0xfc, 0xc6, 0xfd, 0xd4, 0x95, 0x4f,
    0xc4, 0xd4, 0x9b, 0x1c, 0xee, 0x36, 0xf5, 0xbb,
  ]);
  const mailboxPutEndpointId = 1;

  test('B advertises a v5 ad with its relay KEM key; S deposits via discovery',
      () async {
    DynamicLibrary.open(dylib!);
    final relayId = _hex(relayIdHex!);
    final authCookie = Uint8List.fromList(List.filled(16, 0x5C));

    final clientS = await VeilClient.connect(sockS!);
    final clientRelay = await VeilClient.connect(sockRelay!);
    try {
      // B advertises itself as its own mailbox relay, carrying its KEM key.
      final relayX25519 = await clientRelay.getRelayX25519Pubkey();
      expect(relayX25519, isNotNull, reason: 'relay not relay_capable');
      await clientRelay.registerRendezvousPublisher(
        rendezvousNodeId: relayId,
        authCookie: authCookie,
        validityWindowSecs: 86400,
        relayKemAlgo: 0,
        relayKemPk: relayX25519!,
      );
      print('[discovery] B registered rendezvous publisher (self-relay, KEM advertised)');

      // Poll until the maintenance tick has published the ad and B resolves it.
      RendezvousReplica? replica;
      for (var i = 0; i < 40 && replica == null; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final replicas = await clientRelay.mailbox.lookupRendezvousReplicas(relayId);
        if (replicas.isNotEmpty) replica = replicas.first;
      }
      print('[discovery] resolved replica: '
          '${replica == null ? "NONE (ad not published / not found)" : replica}');
      expect(replica, isNotNull,
          reason: 'B could not resolve its own freshly-published ad');

      // The whole point: the resolved replica carries the relay id + KEM key.
      expect(replica!.relayNodeId, relayId, reason: 'replica relay id mismatch');
      expect(replica.rendezvousKemAlgo, 0);
      expect(Uint8List.fromList(replica.rendezvousKemPk), relayX25519,
          reason: 'resolved replica must carry B\'s relay KEM key end to end');
      print('[discovery] ✓ resolved replica carries the relay KEM key (${replica.rendezvousKemPk.length}B)');

      // Close the loop: S deposits at the DISCOVERED relay + key.
      final contentId = Uint8List.fromList(List.filled(32, 0xD2));
      final putBytes = _buildMailboxPut(
        receiverId: Uint8List.fromList(List.filled(32, 0x0B)),
        contentId: contentId,
        senderId: Uint8List(32),
        blob: Uint8List.fromList(utf8.encode('step2b-discovery-deposit')),
      );
      final srcApp = await clientS.bind(
        namespace: 'xveil',
        name: 'mailbox-sender',
        endpointId: 0,
      );
      await clientS.sendAnonymousDirect(
        targetNodeId: replica.relayNodeId,
        targetX25519Pk: Uint8List.fromList(replica.rendezvousKemPk),
        targetAppId: mailboxAppId,
        targetEndpointId: mailboxPutEndpointId,
        srcAppId: srcApp.appId,
        data: putBytes,
        hopCount: 1,
      );
      print('[discovery] S deposited at the discovered relay');

      const cidShort = 'cid=d2d2d2d2d2d2d2d2';
      var stored = false;
      for (var i = 0; i < 15 && !stored; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final log = File(relayLog!).readAsStringSync();
        stored = log.contains('PUT stored') && log.contains(cidShort);
      }
      print('[discovery] relay stored the discovery-routed deposit: $stored');
      expect(stored, isTrue,
          reason: 'relay log never showed the discovery-routed PUT stored');
    } finally {
      await clientS.close();
      await clientRelay.close();
    }
  }, skip: skip);
}

Uint8List _buildMailboxPut({
  required Uint8List receiverId,
  required Uint8List contentId,
  required Uint8List senderId,
  required Uint8List blob,
}) {
  final b = BytesBuilder();
  b.add(receiverId);
  b.add(contentId);
  b.add(senderId);
  final lenBe = ByteData(4)..setUint32(0, blob.length, Endian.big);
  b.add(lenBe.buffer.asUint8List());
  b.add(blob);
  b.add(Uint8List(2)); // push_envelope: absent
  b.add(Uint8List(2)); // capability_token: absent
  b.add(Uint8List(2)); // wake_hmac_envelope: absent
  return b.toBytes();
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
