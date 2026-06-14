import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_addressing.dart';

/// Live test against a running `veil-cli node run`. Set XVEIL_TEST_VEIL_SOCK to
/// its admin/IPC socket path and VEIL_FFI_DYLIB to libveilclient_ffi. Proves
/// VeilClient connects, reads the node id, and — critically — that our
/// Dart deriveAppId matches the native bindNamed app_id (routing correctness).
String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final sock = Platform.environment['XVEIL_TEST_VEIL_SOCK'];
  final skip = (sock == null || sock.isEmpty)
      ? 'set XVEIL_TEST_VEIL_SOCK + VEIL_FFI_DYLIB to a running node'
      : false;

  test('connects to a live node; deriveAppId == native bindNamed app_id',
      () async {
    final client = await VeilClient.connect(sock!);
    try {
      final nid = await client.nodeId();
      expect(nid.length, 32);

      final app = await client.bindNamed(
        namespace: veilChatNamespace,
        name: veilChatName,
        endpointId: veilChatEndpointId,
      );
      try {
        // The native app_id for our own named endpoint must equal the one
        // our pure-Dart derivation computes for the same node id.
        expect(_hex(app.appId), _hex(deriveAppId(NodeId(nid),
            veilChatNamespace, veilChatName)));
      } finally {
        await app.close();
      }
    } finally {
      await client.close();
    }
  }, skip: skip);
}
