import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_addressing.dart';

/// STAGE 2 — live onion round-trip: a SENDER reaches an ANONYMOUS receiver B
/// over the rendezvous relay. The sender calls `sendAnonymousAuthenticated`,
/// which resolves B's rendezvous ad from the DHT, seals an introduce, and sends
/// it to B's relay; the relay forwards it to B's bound endpoint. Proves the
/// receive-anonymous path end to end (registration is covered by Stage 1,
/// scripts/dev-onion-pair.sh).
///
/// Bring up the nodes first (relay R + anon receiver B):
///   scripts/dev-onion-pair.sh           # leaves R + B running
/// then run with R as the sender:
///   VEIL_FFI_DYLIB=.../libveilclient_ffi.dylib \
///   XVEIL_TEST_SOCK_SENDER=.dev-onion/relay/app.sock \
///   XVEIL_TEST_SOCK_RECV=.dev-onion/recv/app.sock \
///   XVEIL_RECV_NODE_ID=<64-hex from recv/node.log> \
///   flutter test test/native/onion_roundtrip_live_test.dart
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockS = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_RECV'];
  final recvIdHex = Platform.environment['XVEIL_RECV_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockS == null || sockS.isEmpty ||
          sockB == null || sockB.isEmpty || recvIdHex == null || recvIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER + XVEIL_TEST_SOCK_RECV + XVEIL_RECV_NODE_ID(64hex)'
      : false;

  test('sender -> anonymous receiver B delivers over the rendezvous', () async {
    DynamicLibrary.open(dylib!); // preload so process() lookups resolve
    final bId = NodeId(_hex(recvIdHex!));
    final bAppId = chatAppIdFor(bId);

    final clientB = await VeilClient.connect(sockB!);
    final appB = await clientB.bindNamed(
        namespace: veilChatNamespace, name: veilChatName, endpointId: veilChatEndpointId);
    final clientS = await VeilClient.connect(sockS!);
    final appS = await clientS.bindNamed(
        namespace: veilChatNamespace, name: veilChatName, endpointId: veilChatEndpointId);
    try {
      final received = Completer<Uint8List>();
      final sub = appB.messages().listen((m) {
        if (!received.isCompleted) received.complete(m.data);
      });

      const body = 'onion round-trip hello';
      final payload = Uint8List.fromList(utf8.encode(body));
      // Retry: the sender's first attempt may precede ad resolution / circuit.
      var attempts = 0;
      Object? lastSendError;
      var sendsOk = 0;
      while (!received.isCompleted && attempts < 30) {
        try {
          await appS.sendAnonymousAuthenticated(
            dstNodeId: bId.bytes,
            dstAppId: bAppId,
            dstEndpointId: veilChatEndpointId,
            data: payload,
          );
          sendsOk++;
        } catch (e) {
          lastSendError = e;
        }
        attempts++;
        await Future.any([
          received.future,
          Future<void>.delayed(const Duration(seconds: 2)),
        ]);
      }

      print('[roundtrip] attempts=$attempts sendsOk=$sendsOk '
          'received=${received.isCompleted} lastSendError=$lastSendError');
      expect(received.isCompleted, isTrue,
          reason: 'B did not receive over onion; sendsOk=$sendsOk '
              'lastSendError=$lastSendError');
      final got = await received.future;
      expect(utf8.decode(got), body);
      print('[roundtrip] B received the message over onion');
      await sub.cancel();
    } finally {
      await appB.close();
      await clientB.close();
      await appS.close();
      await clientS.close();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
}

Uint8List _hex(String h) => Uint8List.fromList(
    [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
