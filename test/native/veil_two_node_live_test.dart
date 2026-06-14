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
/// PASSES with the correct two-node topology (verified 2026-06-14):
///   1. EACH node has its own listener: `listen add tcp://127.0.0.1:<port>`.
///   2. The nodes mutually `bootstrap join` each other's `bootstrap invite`.
/// The session then forms in the direction veil's *directional dedup* accepts
/// (lower node_id listens / accepts inbound, higher node_id dials). Get this
/// wrong — e.g. only the callee has a listener — and the dialer's own session
/// is "duplicate session rejected", the link drops with EOF, and every app
/// send loops `route.discovery.miss`. With both listeners + mutual bootstrap
/// the session stays `active`, route discovery resolves over it, and A->B
/// delivers. See test/native/README or memory for the exact CLI recipe.
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
