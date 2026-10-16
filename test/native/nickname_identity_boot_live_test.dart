// Exercise the app's deferred native boot before the first nickname lookup.
// No external peers, seeds or meeting points; no identity keys are replaced.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/onboarding/recovery_certificate_step.dart';

void main() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = path == null || path.isEmpty
      ? 'set VEIL_FFI_DYLIB to a node-embedded library'
      : false;

  for (final kind in ['legacy', 'certificate', 'corrupt']) {
    final certificate = kind == 'certificate';
    test(
      'nickname owner after deferred boot ($kind)',
      () async {
        final lib = DynamicLibrary.open(path!);
        final dir = await Directory.systemTemp.createTemp('xveil-nickname-');
        final identity = await File(
          'test/native/fixtures/ratchet_state_identity_0.toml',
        ).readAsString();
        final minted = certificate ? mintSovereignIdentity() : null;
        final ipc = '${dir.path}/app.sock';
        final admin = '${dir.path}/admin.sock';
        EmbeddedNodeController? controller;
        veil.VeilClient? client;
        try {
          if (minted != null) {
            EmbeddedNode.provisionIdentityFromCertificate(
              minted.credential,
              minted.code,
              veilDir: dir.path,
              instanceLabel: 'nickname-regression',
              nodeConfigToml: identity,
              lib: lib,
            );
          }
          if (kind == 'corrupt') {
            await File(
              '${dir.path}/identity_document.bin',
            ).writeAsBytes([1, 2, 3]);
          }
          final config = EmbeddedNode.composeConfig(
            identityToml: identity,
            listenTransport: 'quic://127.0.0.1:0',
            ipcSocket: ipc,
            adminSocket: admin,
            identityDir: kind == 'legacy' ? null : dir.path,
            useBundledSeeds: false,
            meetingPoints: const [],
            lib: lib,
          );
          controller = EmbeddedNodeController(
            appSocketPath: ipc,
            lib: lib,
            starter: () {
              final node = EmbeddedNode.startDeferred(admin, lib: lib);
              try {
                node.applyConfig(config);
                return node;
              } catch (_) {
                node.stop();
                rethrow;
              }
            },
          );
          await controller.start();
          expect(controller.current.phase, NodePhase.connected);
          client = await veil.VeilClient.connect(ipc);
          final device = await client.nodeId();
          if (kind == 'corrupt') {
            expect(
              () => veil.nicknameOwnerNodeId(device),
              throwsA(isA<veil.VeilException>()),
            );
            expect(
              await File('${dir.path}/identity_document.bin').readAsBytes(),
              [1, 2, 3],
            );
            expect(
              await File('${dir.path}/device_identity_sk.bin').exists(),
              isFalse,
            );
            return;
          }
          final owner = veil.nicknameOwnerNodeId(device);
          expect(owner, minted?.nodeId.bytes ?? device);
          if (minted != null) expect(owner, isNot(device));
        } finally {
          await client?.close();
          await controller?.stop();
          expect(await File(ipc).exists(), isFalse);
          await dir.delete(recursive: true);
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
