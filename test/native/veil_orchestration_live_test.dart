import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/veil_node.dart';
import 'package:xveil/data/transport/veil_flutter_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';

/// Full orchestration the app uses: SubprocessNodeController SPAWNS a real
/// `veil-cli node run`, reaches connected via the socket readiness probe, then
/// VeilFlutterTransport connects and a message round-trips. Env-gated (skips in
/// normal `flutter test`):
///   XVEIL_TEST_VEIL_CLI    = path to the veil-cli binary
///   XVEIL_TEST_VEIL_CONFIG = path to an initialised, ipc-enabled config.toml
///   VEIL_FFI_DYLIB         = path to libveilclient_ffi
void main() {
  final cli = Platform.environment['XVEIL_TEST_VEIL_CLI'];
  final config = Platform.environment['XVEIL_TEST_VEIL_CONFIG'];
  final skip = (cli == null || config == null || cli.isEmpty || config.isEmpty)
      ? 'set XVEIL_TEST_VEIL_CLI + XVEIL_TEST_VEIL_CONFIG + VEIL_FFI_DYLIB'
      : false;

  test('controller spawns a node and transport messages over it', () async {
    final sock = '${File(config!).parent.path}/app.sock';
    final controller = veilSubprocessController(
      veilCliPath: cli!,
      configPath: config,
      appSocketPath: sock,
    );

    await controller.start();
    expect(controller.current.phase, NodePhase.connected);

    final transport = await VeilFlutterTransport.connect(sock);
    try {
      final me = await transport.nodeId();
      final received = Completer<InboundMessage>();
      final sub = transport.messages().listen((m) {
        if (!received.isCompleted) received.complete(m);
      });
      await transport.send(me, Uint8List.fromList(utf8.encode('orchestrated')));
      final msg = await received.future.timeout(const Duration(seconds: 8));
      expect(utf8.decode(msg.payload), 'orchestrated');
      await sub.cancel();
    } finally {
      await transport.dispose();
      await controller.stop();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
