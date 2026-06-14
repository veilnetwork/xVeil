import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';

/// Proves the EMBEDDED node path: the controller starts a veil node
/// in-process via the FFI (no subprocess) and reaches connected once its app
/// socket answers. Env-gated:
///   XVEIL_TEST_EMBED_CONFIG = an initialised, ipc-enabled config whose node
///                             is NOT already running
///   VEIL_FFI_DYLIB          = libveilclient_ffi built with --features
///                             node-embedded
void main() {
  final cfg = Platform.environment['XVEIL_TEST_EMBED_CONFIG'];
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (cfg == null || cfg.isEmpty || dylib == null || dylib.isEmpty)
      ? 'set XVEIL_TEST_EMBED_CONFIG + VEIL_FFI_DYLIB (node-embedded build)'
      : false;

  test('embedded controller starts a node in-process and connects', () async {
    final lib = DynamicLibrary.open(dylib!);
    final sock = '${File(cfg!).parent.path}/app.sock';
    final controller = EmbeddedNodeController(
      configPath: cfg,
      appSocketPath: sock,
      lib: lib,
    );
    try {
      await controller.start();
      expect(controller.current.phase, NodePhase.connected);
    } finally {
      await controller.stop();
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));
}
