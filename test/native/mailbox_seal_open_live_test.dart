import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// STEP 1 of the offline-mailbox harness — the seal/open CRYPTO round-trip on
/// real nodes. S seals a message for B (its node resolves B's ML-KEM cert over
/// the DHT and fan-out-encrypts); B opens it (its node resolves S's document and
/// verifies the auth-deliver). The blob is handed S->B directly here — the relay
/// put/fetch transport + the private-cookie auth gate are validated in later
/// steps. Proves the entire seal/open stack (IPC -> FFI -> Dart -> runtime ->
/// cert resolution -> ML-KEM crypto) end to end.
///
/// Bring the nodes up first:  scripts/dev-mailbox-pair.sh
/// then run with the env it prints.
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockS = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_RECV'];
  final sIdHex = Platform.environment['XVEIL_SEND_NODE_ID'];
  final bIdHex = Platform.environment['XVEIL_RECV_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockS == null || sockS.isEmpty ||
          sockB == null || sockB.isEmpty || sIdHex == null || sIdHex.length != 64 ||
          bIdHex == null || bIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RECV + XVEIL_SEND/RECV_NODE_ID(64hex)'
      : false;

  test('S seals for B over the DHT; B opens + verifies', () async {
    DynamicLibrary.open(dylib!); // preload so process() lookups resolve
    final sId = _hex(sIdHex!);
    final bId = _hex(bIdHex!);
    final appId = Uint8List.fromList(List.filled(32, 0xCC));
    const endpointId = 7;
    final data = Uint8List.fromList(utf8.encode('offline mailbox hello'));

    final clientS = await VeilClient.connect(sockS!);
    final clientB = await VeilClient.connect(sockB!);
    try {
      // S resolves B's ML-KEM cert (DHT) + seals. Retry: the cert may not have
      // propagated to S's view immediately after boot.
      Uint8List? blob;
      Object? lastSealError;
      for (var i = 0; i < 15 && blob == null; i++) {
        try {
          blob = await clientS.mailbox.seal(
            recipient: bId,
            appId: appId,
            endpointId: endpointId,
            data: data,
          );
        } catch (e) {
          lastSealError = e;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      print('[mailbox] seal: ${blob == null ? "FAILED ($lastSealError)" : "${blob.length} bytes"}');
      expect(blob, isNotNull, reason: 'S could not seal for B: $lastSealError');

      // B opens — the sender (S) is recovered from the blob's sidecar, not
      // supplied. our current cert version = 1 for a fresh node.
      final opened = await clientB.mailbox.open(
        blob: blob!,
        ourCertVersion: 1,
      );
      print('[mailbox] B opened: sender=${opened.senderNodeId.sublist(0, 4)} '
          'endpoint=${opened.endpointId} data="${utf8.decode(opened.data)}"');
      expect(opened.data, data);
      expect(opened.appId, appId);
      expect(opened.endpointId, endpointId);
      expect(opened.senderNodeId, sId, reason: 'recovered sender must equal S');
      print('[mailbox] seal/open round-trip OK');
    } finally {
      await clientS.close();
      await clientB.close();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
}

Uint8List _hex(String h) => Uint8List.fromList(
    [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
