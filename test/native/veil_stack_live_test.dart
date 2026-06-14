import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/veil_stack.dart';

/// Exercises the composed RealVeilStack end-to-end (env-gated):
/// start() spawns the node, connects the transport, and exposes this device's
/// invite; a self-send round-trips; addContact() redeems an invite without
/// error.
///   XVEIL_TEST_VEIL_CLI    = veil-cli path
///   XVEIL_TEST_VEIL_CONFIG = initialised, listener+ipc config
///   VEIL_FFI_DYLIB         = libveilclient_ffi
void main() {
  final cli = Platform.environment['XVEIL_TEST_VEIL_CLI'];
  final config = Platform.environment['XVEIL_TEST_VEIL_CONFIG'];
  final skip = (cli == null || config == null || cli.isEmpty || config.isEmpty)
      ? 'set XVEIL_TEST_VEIL_CLI + XVEIL_TEST_VEIL_CONFIG + VEIL_FFI_DYLIB'
      : false;

  test('RealVeilStack starts, exposes an invite, messages, adds a contact',
      () async {
    final sock = '${File(config!).parent.path}/app.sock';
    final stack = await RealVeilStack.start(
      veilCliPath: cli!,
      configPath: config,
      appSocketPath: sock,
    );
    try {
      // The stack's own invite resolves to its node id.
      expect(stack.myInvite.nodeId.hex.length, 64);

      final me = await stack.transport.nodeId();
      expect(me.hex, stack.myInvite.nodeId.hex);

      final received = Completer<InboundMessage>();
      final sub = stack.transport.messages().listen((m) {
        if (!received.isCompleted) received.complete(m);
      });
      await stack.transport
          .send(me, Uint8List.fromList(utf8.encode('stacked')));
      final msg = await received.future.timeout(const Duration(seconds: 8));
      expect(utf8.decode(msg.payload), 'stacked');
      await sub.cancel();

      // Redeeming our own invite is a harmless idempotent no-op (dedup).
      await stack.addContact(stack.myInvite);
    } finally {
      await stack.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
