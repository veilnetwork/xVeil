import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';

/// Real two-node chat: node A sends a message to node B over the overlay and B
/// receives it. Env-gated (skips in normal `flutter test`): set
/// XVEIL_TEST_SOCK_A / XVEIL_TEST_SOCK_B to two running, peered nodes' app
/// sockets and VEIL_FFI_DYLIB to libveilclient_ffi.
///
/// HARNESS — PENDING inter-node route bring-up. With two isolated local nodes
/// (B listening on tcp://127.0.0.1:9101, A holding B via BOTH `peers add` and a
/// `bootstrap join` `[[bootstrap_peers]]` entry), an A->B app send still logs
/// `route.discovery.miss dst=…`: A never opens a session to the peer and the
/// DHT route lookup misses (veil's known "DHT fallback ~0% with no relays").
/// Establishing a real session between two isolated nodes needs deeper veil
/// bring-up (a relay / a populated routing table) — covered by veil's own
/// SimNetworkBuilder cross-node IPC suite. xVeil's transport adapter is proven
/// by veil_transport_live_test (self-send through a real node); flip this on
/// once node-to-node routing is wired end to end.
void main() {
  final sockA = Platform.environment['XVEIL_TEST_SOCK_A'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_B'];
  final skip = (sockA == null || sockB == null || sockA.isEmpty || sockB.isEmpty)
      ? 'set XVEIL_TEST_SOCK_A + XVEIL_TEST_SOCK_B + VEIL_FFI_DYLIB'
      : false;

  test('A -> B message delivers over the overlay', () async {
    final a = await VeilFlutterTransport.connect(sockA!);
    final b = await VeilFlutterTransport.connect(sockB!);
    try {
      final bId = await b.nodeId();

      final received = Completer<InboundMessage>();
      final sub = b.messages().listen((m) {
        if (!received.isCompleted) received.complete(m);
      });

      // First send establishes the A->B session lazily; retry briefly until
      // the route comes up.
      const body = 'hello from A';
      final payload = Uint8List.fromList(utf8.encode(body));
      var attempts = 0;
      while (!received.isCompleted && attempts < 10) {
        try {
          await a.send(bId, payload);
        } catch (_) {/* route not ready yet */}
        attempts++;
        await Future.any([
          received.future,
          Future<void>.delayed(const Duration(seconds: 1)),
        ]);
      }

      final msg = await received.future.timeout(const Duration(seconds: 5));
      expect(utf8.decode(msg.payload), body);
      await sub.cancel();
    } finally {
      await a.dispose();
      await b.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));
}
