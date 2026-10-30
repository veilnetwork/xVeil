// Local deferred boot under a path that cannot be a Unix socket address.
// Only a public test-fixture identity, ephemeral ports, no seeds/meeting points.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/veil_stack.dart';

void main() {
  final library = Platform.environment['VEIL_FFI_DYLIB'];
  test(
    'long runtime boots admin and IPC over authenticated loopback',
    () async {
      final lib = DynamicLibrary.open(library!);
      final base = await Directory.systemTemp.createTemp(
        'xveil-long-endpoint-',
      );
      final dir = await Directory('${base.path}/${'r' * 120}').create();
      final plan = localEndpointPlanFor(
        Platform.operatingSystem,
        runtimeDir: dir.path,
      );
      expect(utf8.encode('${dir.path}/admin.sock').length, greaterThan(108));
      expect(plan.loopbackTcp, isTrue);
      final identity = await File(
        'test/native/fixtures/ratchet_state_identity_0.toml',
      ).readAsString();
      EmbeddedNodeController? controller;
      veil.VeilClient? client;
      try {
        final config = EmbeddedNode.composeConfig(
          identityToml: identity,
          listenTransport: 'quic://127.0.0.1:0',
          ipcSocket: plan.ipcEndpoint(dir.path),
          adminSocket: plan.adminEndpoint(dir.path),
          useBundledSeeds: false,
          meetingPoints: const [],
          lib: lib,
        );
        controller = EmbeddedNodeController(
          appSocketPath: plan.ipcSocket(dir.path),
          lib: lib,
          starter: () => createThenPromote(
            create: () => EmbeddedNode.startDeferred(
              plan.adminEndpoint(dir.path),
              lib: lib,
            ),
            promote: (node) => node.applyConfig(config),
            abandon: (node) => node.stop(),
          ),
        );
        await controller.start();
        expect(controller.current.phase, NodePhase.connected);
        for (final name in [
          'admin.port',
          'admin.token',
          'ipc.port',
          'ipc.token',
        ]) {
          expect(await File('${dir.path}/$name').exists(), isTrue);
        }
        client = await veil.VeilClient.connect(plan.ipcSocket(dir.path));
        expect(await client.nodeId(), hasLength(32));
        expect(await File('${dir.path}/admin.sock').exists(), isFalse);
        expect(await File('${dir.path}/app.sock').exists(), isFalse);
      } finally {
        await client?.close();
        await controller?.stop();
        for (final name in [
          'admin.port',
          'admin.token',
          'ipc.port',
          'ipc.token',
        ]) {
          expect(await File('${dir.path}/$name').exists(), isFalse);
        }
        await base.delete(recursive: true);
      }
    },
    skip: library == null ? 'set VEIL_FFI_DYLIB (node-embedded)' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
