import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';

/// Drives VeilFlutterTransport against a live node (env-gated, skips in normal
/// `flutter test`). Sends a datagram addressed to our OWN node id on the shared
/// endpoint and receives it back — exercising send + the messages() stream +
/// the derived app_id routing on a real node, without needing two instances.
void main() {
  final sock = Platform.environment['XVEIL_TEST_VEIL_SOCK'];
  final skip = (sock == null || sock.isEmpty)
      ? 'set XVEIL_TEST_VEIL_SOCK + VEIL_FFI_DYLIB to a running node'
      : false;

  test('self-send round-trips through a live node', () async {
    final transport = await VeilFlutterTransport.connect(sock!);
    try {
      final me = await transport.nodeId();

      // Subscribe before sending so we don't miss the delivery.
      final received = Completer<InboundMessage>();
      final sub = transport.messages().listen((m) {
        if (!received.isCompleted) received.complete(m);
      });

      await transport.send(me, Uint8List.fromList(utf8.encode('ping self')));

      final msg = await received.future.timeout(const Duration(seconds: 8));
      expect(utf8.decode(msg.payload), 'ping self');
      expect(msg.src.bytes, me.bytes);
      await sub.cancel();
    } finally {
      await transport.dispose();
    }
  }, skip: skip);
}
