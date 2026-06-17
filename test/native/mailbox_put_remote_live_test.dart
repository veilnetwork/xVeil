import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// STEP 2a of the offline-mailbox harness — the NETWORK PUT path.
///
/// S deposits a `MailboxPutPayload` into B's built-in `veil.mailbox.v1`
/// app-service over the anonymous onion, using the EXISTING
/// `sendAnonymousDirect` egress (addressed to `MAILBOX_APP_ID` /
/// `PUT_ENDPOINT_ID = 1` on B). B's service stores the blob in its local
/// mailbox. This proves the network deposit + receive-service path end to end
/// — the relay receives a sender-anonymous PUT (`src_node_id = 0`) and stores
/// it — BEFORE any emit-productization or signed-`RendezvousAd` change is built.
///
/// Assertion: B's daemon log shows `veil-mailbox: PUT stored … cid=<ours>`
/// (a debug log — the harness runs the relay with veil_node_runtime=debug).
///
/// Bring the mesh up first:  scripts/dev-mailbox-mesh.sh
/// then run with the env it prints.
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

  test('S deposits a mailbox PUT into B over the anonymous onion; B stores it',
      () async {
    DynamicLibrary.open(dylib!); // preload so process() lookups resolve
    final relayId = _hex(relayIdHex!);

    // A recognisable content_id so we can grep the relay log unambiguously.
    // hex_short() logs the first 8 bytes → "a1a1a1a1a1a1a1a1".
    final contentId = Uint8List.fromList(List.filled(32, 0xA1));
    final receiverId = Uint8List.fromList(List.filled(32, 0x0B));
    final senderId = Uint8List(32); // 0 = anonymous (the wire hint, untrusted)
    final blob = Uint8List.fromList(utf8.encode('step2a-network-put-blob'));
    final putBytes = _buildMailboxPut(
      receiverId: receiverId,
      contentId: contentId,
      senderId: senderId,
      blob: blob,
    );

    final clientS = await VeilClient.connect(sockS!);
    final clientRelay = await VeilClient.connect(sockRelay!);
    try {
      // Relay's X25519 pubkey is the seal target for the anonymous deliver.
      final relayX25519 = await clientRelay.getRelayX25519Pubkey();
      print('[put-remote] relay X25519: '
          '${relayX25519 == null ? "UNAVAILABLE (not relay_capable)" : "${relayX25519.length} bytes"}');
      expect(relayX25519, isNotNull,
          reason: 'relay not relay_capable — cannot seal the deposit');

      // The daemon rejects an anonymous send whose src_app_id the client does
      // not own (SPOOFED_SRC). Bind an app on S and carry ITS app_id as the
      // source — the relay's mailbox service only routes on the TARGET
      // (MAILBOX_APP_ID, PUT_ENDPOINT), so the source app_id is free.
      final srcApp = await clientS.bind(
        namespace: 'xveil',
        name: 'mailbox-sender',
        endpointId: 0,
      );
      final srcAppId = srcApp.appId;

      // Fire the anonymous deposit. Retry: circuits may still be forming just
      // after boot. send is fire-and-forget (Ok = handed to first hop).
      Object? lastErr;
      var sent = false;
      for (var i = 0; i < 10 && !sent; i++) {
        try {
          await clientS.sendAnonymousDirect(
            targetNodeId: relayId,
            targetX25519Pk: relayX25519!,
            targetAppId: mailboxAppId,
            targetEndpointId: mailboxPutEndpointId,
            srcAppId: srcAppId,
            data: putBytes,
            // hop_count includes the target: 1 = direct S->B delivery. STEP 2a
            // validates the network deposit + receive-service store; multi-hop
            // sender-anonymity of the path is a separate property tested later.
            hopCount: 1,
          );
          sent = true;
        } catch (e) {
          lastErr = e;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      print('[put-remote] anonymous deposit: ${sent ? "handed to first hop" : "FAILED ($lastErr)"}');
      expect(sent, isTrue, reason: 'could not hand the deposit to a circuit: $lastErr');

      // Poll the relay log for the "PUT stored" line carrying our cid.
      const marker = 'PUT stored';
      const cidShort = 'cid=a1a1a1a1a1a1a1a1';
      var stored = false;
      for (var i = 0; i < 15 && !stored; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final log = File(relayLog!).readAsStringSync();
        stored = log.contains(marker) && log.contains(cidShort);
      }
      print('[put-remote] relay stored the blob: $stored');
      expect(stored, isTrue,
          reason: 'relay log never showed "$marker … $cidShort" — '
              'the network PUT did not land in the mailbox store');
    } finally {
      await clientS.close();
      await clientRelay.close();
    }
  }, skip: skip);
}

/// Encode a `MailboxPutPayload` (veil-proto ipc.rs) for the wire:
/// receiver_id(32) | content_id(32) | sender_id(32) | blob_len(u32 BE) | blob
/// | push_env_len(u16=0) | cap_token_len(u16=0) | wake_env_len(u16=0).
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
