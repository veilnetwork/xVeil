import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// STEP 2c of the offline-mailbox harness — the receiver-side NETWORK FETCH.
///
/// A blob is stored in B's mailbox for receiver S. S then retrieves it OVER THE
/// NETWORK: S binds a reply endpoint and sends an authenticated-with-reply FETCH
/// request to B's mailbox FETCH endpoint. B's service verifies S's identity
/// (src_node_id), gathers S's blobs, and replies over the one-time reply path.
/// S decodes the MailboxFetchResp and asserts it got the stored blob back.
///
/// This closes the loop: the deposit half is STEP 2a/2b; this is the retrieval
/// half — authorized by cryptographic identity, no cookie.
///
/// Bring the mesh up first:  scripts/dev-mailbox-mesh.sh  (rebuilt veil-cli)
/// then run with the env it prints (S + RELAY=B sockets + node ids).
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockS = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_RELAY'];
  final sIdHex = Platform.environment['XVEIL_SEND_NODE_ID'];
  final bIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockS == null || sockS.isEmpty ||
          sockB == null || sockB.isEmpty || sIdHex == null || sIdHex.length != 64 ||
          bIdHex == null || bIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RELAY + XVEIL_SEND_NODE_ID + XVEIL_RELAY_NODE_ID (64hex)'
      : false;

  final mailboxAppId = Uint8List.fromList(const [
    0xd4, 0x17, 0xcf, 0x22, 0x72, 0x89, 0x07, 0x40, //
    0xe2, 0xe1, 0xb6, 0xb1, 0xb5, 0x74, 0x12, 0x95,
    0x6b, 0x3e, 0xfc, 0xc6, 0xfd, 0xd4, 0x95, 0x4f,
    0xc4, 0xd4, 0x9b, 0x1c, 0xee, 0x36, 0xf5, 0xbb,
  ]);
  const mailboxFetchEndpointId = 2;
  const replyEndpointId = 7;

  test('B stores a blob for S; S retrieves it over the network FETCH', timeout: const Timeout(Duration(seconds: 120)), () async {
    DynamicLibrary.open(dylib!);
    final sId = _hex(sIdHex!);
    final blob = Uint8List.fromList(utf8.encode('offline-fetch-payload'));

    final clientS = await VeilClient.connect(sockS!);
    final clientB = await VeilClient.connect(sockB!);
    AppHandle? app;
    try {
      // B stores a blob addressed to receiver S (locally, in B's mailbox).
      await clientB.mailbox.put(
        receiverId: sId,
        contentId: Uint8List.fromList(List.filled(32, 0xF7)),
        senderId: Uint8List.fromList(List.filled(32, 0xAB)),
        blob: blob,
      );
      print('[fetch] B stored a blob for S');

      // S binds a reply endpoint and listens for the FETCH reply. The relay's
      // reply is TERMINAL (carries no further reply block), so it surfaces as a
      // plain inbound message on this endpoint.
      app = await clientS.bind(
        namespace: 'xveil',
        name: 'mailbox-fetch',
        endpointId: replyEndpointId,
      );
      final re=Completer<IncomingMessage>();
      final sub = app.messages().listen((m) {
        if (!re.isCompleted) re.complete(m);
      });

      // Send the authenticated-with-reply FETCH at the relay's mailbox FETCH
      // endpoint, RETRYING until the reply arrives — the first attempts may
      // precede the sender's ad-resolution / circuit build (onion path).
      final bId = _hex(bIdHex!);
      var attempts = 0;
      var sendsOk = 0;
      Object? lastErr;
      while (!re.isCompleted && attempts < 30) {
        try {
          await app.sendAnonymousAuthenticatedWithReply(
            dstNodeId: bId,
            dstAppId: mailboxAppId,
            dstEndpointId: mailboxFetchEndpointId,
            replyEndpointId: replyEndpointId,
            data: Uint8List(0), // body unused — identity is the request
          );
          sendsOk++;
        } catch (e) {
          lastErr = e;
        }
        attempts++;
        await Future.any([
          re.future,
          Future<void>.delayed(const Duration(seconds: 2)),
        ]);
      }
      print('[fetch] FETCH attempts=$attempts sendsOk=$sendsOk '
          'received=${re.isCompleted} lastErr=$lastErr');
      expect(re.isCompleted, isTrue,
          reason: 'no FETCH reply over onion; sendsOk=$sendsOk lastErr=$lastErr');
      final reply = await re.future;
      await sub.cancel();
      print('[fetch] S got reply: replyId=${reply.replyId}, ${reply.data.length} bytes');

      final got = _firstBlobOfFetchResp(reply.data);
      print('[fetch] decoded blob: ${got == null ? "NONE" : utf8.decode(got)}');
      expect(got, isNotNull, reason: 'reply carried no blob');
      expect(got, blob, reason: 'fetched blob must equal what B stored for S');
    } finally {
      app?.close();
      await clientS.close();
      await clientB.close();
    }
  }, skip: skip);
}

/// Decode the first blob from a `MailboxFetchRespPayload` wire buffer:
/// count(u16 BE) then entries [sender(32) content(32) deposited_at(u64 BE)
/// blob_len(u32 BE) blob].
Uint8List? _firstBlobOfFetchResp(Uint8List buf) {
  final d = ByteData.sublistView(buf);
  if (buf.length < 2) return null;
  final count = d.getUint16(0, Endian.big);
  if (count == 0) return null;
  const entryHeader = 32 + 32 + 8 + 4;
  if (buf.length < 2 + entryHeader) return null;
  final blobLen = d.getUint32(2 + 72, Endian.big);
  final start = 2 + entryHeader;
  if (buf.length < start + blobLen) return null;
  return Uint8List.fromList(buf.sublist(start, start + blobLen));
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
