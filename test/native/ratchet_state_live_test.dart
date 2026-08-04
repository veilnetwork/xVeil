import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/storage.dart' show kRatchetKeyLen;

/// The ABI half of the ratchet store, which nothing else can check.
///
/// Every other test in this area runs against a faithful Dart model of veil's
/// store, and a model cannot be wrong about a `size_t` written where an
/// `intptr_t` was expected — it just reads back whatever the wrong slot held.
/// Six functions with eleven out-parameters between them is exactly the shape
/// where a typedef that does not match `veil_ffi.h` is silent, plausible, and
/// corrupts the one thing here that cannot be rebuilt.
///
/// Env-gated:
///   VEIL_FFI_DYLIB = libveilclient_ffi built with `--features node-embedded`
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (dylib == null || dylib.isEmpty)
      ? 'set VEIL_FFI_DYLIB to a node-embedded libveilclient_ffi'
      : false;

  test('the ratchet door answers over the real ABI', () async {
    final lib = DynamicLibrary.open(dylib!);
    expect(
      ratchetStateAvailable(lib: lib),
      isTrue,
      reason: 'this dylib was built without the ratchet FFI',
    );

    final dir = await Directory.systemTemp.createTemp('xveil-ratchet-abi');
    final ipcSock = '${dir.path}/app.sock';
    final adminSock = '${dir.path}/admin.sock';
    final identityToml = EmbeddedNode.mineConfig(0, lib: lib);
    final config = EmbeddedNode.composeConfig(
      identityToml: identityToml,
      listenTransport: 'quic://127.0.0.1:9174',
      ipcSocket: ipcSock,
      adminSocket: adminSock,
      lib: lib,
    );
    final controller = EmbeddedNodeController(
      appSocketPath: ipcSock,
      starter: () {
        final node = EmbeddedNode.startDeferred(adminSock, lib: lib);
        node.applyConfig(config);
        return node;
      },
    );
    RatchetStateHandle? ratchet;
    try {
      await controller.start();
      expect(controller.current.phase, NodePhase.connected);

      // The connection this reaches the store through is an IPC CLIENT handle.
      // Passing the node handle from `startDeferred` — which is what the first
      // version of this code did — fails every call with "use-after-close or
      // unknown handle", and no amount of Dart-side modelling can catch that.
      final door = FfiRatchetStateHandle.connect(ipcSock, lib: lib);
      expect(door, isNotNull);
      ratchet = door!;

      // A node that has done nothing has committed nothing. If the u64 out-slot
      // were mis-typed this reads back stack garbage rather than zero.
      expect(ratchet.stateVersion(), 0);

      final dirty = ratchet.takeDirty(8);
      expect(dirty.keys, isEmpty);
      expect(dirty.remaining, 0);
      expect(ratchet.list(), isEmpty);

      final unknown = Uint8List(kRatchetKeyLen)..fillRange(0, kRatchetKeyLen, 7);
      // VEIL_ERR_RATCHET_NO_CONVERSATION (-20) on both, decoded as "nothing
      // held" rather than thrown — the two calls the cleanup paths lean on.
      expect(ratchet.export(unknown), isNull);
      expect(ratchet.forget(unknown), isFalse);

      // "Rejects a blob it does not fully understand rather than salvaging part
      // of one." A partially-understood session is a session with the wrong
      // keys, and this is the answer the startup import treats as "drop it".
      expect(
        ratchet.import(unknown, Uint8List.fromList([1, 2, 3, 4])),
        isFalse,
      );
      expect(ratchet.list(), isEmpty);
      // Nothing above committed anything, so the counter still has not moved —
      // which is the property that lets a host tell "nothing happened" from
      // "something happened and I read it twice".
      expect(ratchet.stateVersion(), 0);

      expect(
        () => door.export(Uint8List(8)),
        throwsArgumentError,
        reason: 'a short key must never reach a 64-byte read',
      );
    } finally {
      ratchet?.close();
      await controller.stop();
      await dir.delete(recursive: true);
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
}
