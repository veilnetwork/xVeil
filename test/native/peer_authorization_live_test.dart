// Real FFI + encrypted container restart. No peers or media hardware.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/identity_config_fields.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/peer_authorization.dart';
import 'package:xveil/features/onboarding/recovery_certificate_step.dart';
import 'package:xveil/state/peer_authorization_persistence.dart';
import 'package:xveil/data/veil_stack.dart';

typedef _ExportNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Size>,
      Pointer<Uint64>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ExportDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Size>,
      Pointer<Uint64>,
      Pointer<Pointer<Utf8>>,
    );

typedef _ConnectNative =
    Pointer<Void> Function(Pointer<Uint8>, Size, Pointer<Pointer<Utf8>>);
typedef _ConnectDart =
    Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

void _checkShortBuffer(
  DynamicLibrary lib,
  String ipc,
  PeerAuthorizationEntry entry,
) {
  final connect = lib.lookupFunction<_ConnectNative, _ConnectDart>(
    'veil_connect',
  );
  final close = lib.lookupFunction<_CloseNative, _CloseDart>('veil_close');
  final export = lib.lookupFunction<_ExportNative, _ExportDart>(
    'veil_peer_authorization_export',
  );
  final path = ipc.toNativeUtf8();
  final output = calloc<Uint8>(8);
  final length = calloc<Size>();
  final revision = calloc<Uint64>();
  final raw = connect(path.cast<Uint8>(), path.length, nullptr);
  try {
    expect(raw, isNot(nullptr));
    output.asTypedList(8).fillRange(0, 8, 0xab);
    expect(export(raw, output, 8, length, revision, nullptr), -40);
    expect(output.asTypedList(8), List.filled(8, 0xab));
    final required = length.value;
    expect(required, greaterThan(8));
    final full = calloc<Uint8>(required);
    try {
      expect(export(raw, full, required, length, revision, nullptr), 0);
      final decoded = PeerAuthorizationSnapshot.decode(
        revision.value,
        Uint8List.fromList(full.asTypedList(length.value)),
      );
      expect(decoded.entries.single.document, entry.document);
    } finally {
      calloc.free(full);
    }
  } finally {
    close(raw);
    calloc.free(path);
    calloc.free(output);
    calloc.free(length);
    calloc.free(revision);
  }
}

void main() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = path == null || path.isEmpty || !ensureHiddenVolumeLoaded()
      ? 'set VEIL_FFI_DYLIB and XVEIL_HV_DYLIB to matching native libraries'
      : false;
  test(
    'signed revocation floor survives native and encrypted storage restart',
    () async {
      final lib = DynamicLibrary.open(path!);
      final dir = await Directory.systemTemp.createTemp('xveil-auth-');
      final stage = await Directory('${dir.path}/source').create();
      final containerPath = '${dir.path}/protected.store';
      final identity = await File(
        'test/native/fixtures/ratchet_state_identity_0.toml',
      ).readAsString();
      final minted = mintSovereignIdentity();
      try {
        EmbeddedNode.provisionIdentityFromCertificate(
          minted.credential,
          minted.code,
          veilDir: stage.path,
          instanceLabel: 'peer-floor-fixture',
          nodeConfigToml: identity,
          lib: lib,
        );
        expect(
          EmbeddedNode.revokeIdentityDevice(
            secret: minted.code,
            credential: minted.credential,
            veilDir: stage.path,
            deviceId: Uint8List(32)..fillRange(0, 32, 0xd1),
            lib: lib,
          ),
          isTrue,
        );
        final document = await File(
          '${stage.path}/identity_document.bin',
        ).readAsBytes();
        final entry = PeerAuthorizationEntry(minted.nodeId.hex, document);
        // The source keys are never needed for persistence or verification.
        await stage.delete(recursive: true);
        for (var run = 0; run < 2; run++) {
          final storage = HiddenVolumeStorage(
            hvSpaceOpener(containerPath, argon: hv.ArgonPreset.min),
          );
          final runtime = await Directory('${dir.path}/runtime-$run').create();
          final ipc = '${runtime.path}/app.sock';
          final admin = '${runtime.path}/admin.sock';
          final config = EmbeddedNode.composeConfig(
            identityToml: identity,
            listenTransport: 'quic://127.0.0.1:0',
            ipcSocket: ipc,
            adminSocket: admin,
            useBundledSeeds: false,
            meetingPoints: const [],
            lib: lib,
          );
          EmbeddedNodeController? controller;
          FfiRatchetStateHandle? door;
          PeerAuthorizationPersistence? owner;
          try {
            expect(
              await storage.open(
                password: 'test-only-password',
                createIfMissing: run == 0,
              ),
              isTrue,
            );
            if (run == 0) await storage.replacePeerAuthorization([entry]);
            final stored = await storage.loadPeerAuthorization();
            expect(stored.single.document, document);
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
            door = FfiRatchetStateHandle.connect(ipc, lib: lib);
            expect(door, isNotNull);
            // Invalid signatures do not consume the one allowed restore or
            // replace the state. The valid durable snapshot remains importable.
            expect(
              () => door!.restorePeerAuthorization(
                PeerAuthorizationSnapshot(0, [
                  PeerAuthorizationEntry(
                    entry.peer,
                    Uint8List.fromList([1, 2, 3]),
                  ),
                ]),
              ),
              throwsA(isA<CorruptPeerAuthorizationState>()),
            );
            owner = PeerAuthorizationPersistence(
              native: door!,
              storage: storage,
            );
            owner.restore(stored);
            await owner.flush();
            _checkShortBuffer(lib, ipc, entry);
            final snapshot = door.exportPeerAuthorization();
            expect(snapshot.entries.single.document, document);
            expect(snapshot.entries.single.peer, entry.peer);
            expect(
              () => door!.restorePeerAuthorization(
                PeerAuthorizationSnapshot(0, []),
              ),
              throwsA(isA<CorruptPeerAuthorizationState>()),
            );
            expect(
              () => door!.acknowledgePeerAuthorization(snapshot.revision + 1),
              throwsStateError,
            );
            await owner.close();
            door.close();
            door = null;
            await controller.stop();
            controller = null;
            expect(await File(ipc).exists(), isFalse);
            await storage.close();
            // No plaintext peer snapshot is written beside the node sockets.
            expect(
              await runtime
                  .list(recursive: true)
                  .where(
                    (f) =>
                        f.path.endsWith('peer_identity_floors.json') ||
                        f.path.endsWith('peer_mlkem_certs.json'),
                  )
                  .isEmpty,
              isTrue,
            );
          } finally {
            await owner?.close();
            door?.close();
            await controller?.stop();
            if (storage.isOpen) await storage.close();
          }
        }
        // Drive the production boot composition too: restore happens before the
        // application transport binds, and teardown checkpoints before closing
        // the shared ratchet handle or the encrypted storage.
        final composed = HiddenVolumeStorage(
          hvSpaceOpener(containerPath, argon: hv.ArgonPreset.min),
        );
        RealVeilStack? stack;
        try {
          expect(await composed.open(password: 'test-only-password'), isTrue);
          await composed.saveNodeConfig(identity);
          stack = await RealVeilStack.startDeniable(
            storage: composed,
            runtimeDirBase: dir.path,
            lib: lib,
            listenPort: 0,
            useBundledSeeds: false,
            meetingPoints: const [],
          );
          expect(stack.peerAuthorization, isNotNull);
          final live = stack.ratchetState! as PeerAuthorizationStateHandle;
          expect(
            live.exportPeerAuthorization().entries.single.document,
            document,
          );
          await stack.dispose();
          stack = null;
          expect(
            (await composed.loadPeerAuthorization()).single.document,
            document,
          );
        } finally {
          await stack?.dispose();
          await composed.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'device authorization is scoped to its node when two nodes stay online',
    () async {
      final lib = DynamicLibrary.open(path!);
      final dir = await Directory.systemTemp.createTemp('xveil-auth-scope-');
      final controllers = <EmbeddedNodeController>[];
      final handles = <FfiRatchetStateHandle>[];
      try {
        final configs = await Future.wait([
          for (var i = 0; i < 2; i++)
            File(
              'test/native/fixtures/ratchet_state_identity_$i.toml',
            ).readAsString(),
        ]);
        final deviceKey = identityConfigFields(configs[1])!.publicKey;
        final device = blake3Hash(deviceKey);
        final minted = mintSovereignIdentity();
        final source = await Directory('${dir.path}/source').create();
        EmbeddedNode.provisionIdentityFromCertificate(
          minted.credential,
          minted.code,
          veilDir: source.path,
          instanceLabel: 'per-node-proof',
          nodeConfigToml: configs[0],
          lib: lib,
        );
        EmbeddedNode.delegateDevice(
          secret: minted.code,
          credential: minted.credential,
          veilDir: source.path,
          devicePubkey: deviceKey,
          lib: lib,
        );
        final active = await File(
          '${source.path}/identity_document.bin',
        ).readAsBytes();
        expect(
          EmbeddedNode.revokeIdentityDevice(
            secret: minted.code,
            credential: minted.credential,
            veilDir: source.path,
            deviceId: device,
            lib: lib,
          ),
          isTrue,
        );
        final revoked = await File(
          '${source.path}/identity_document.bin',
        ).readAsBytes();
        await source.delete(recursive: true);
        for (var i = 0; i < 2; i++) {
          final runtime = await Directory('${dir.path}/runtime-$i').create();
          final ipc = '${runtime.path}/app.sock';
          final admin = '${runtime.path}/admin.sock';
          final config = EmbeddedNode.composeConfig(
            identityToml: configs[i],
            listenTransport: 'quic://127.0.0.1:0',
            ipcSocket: ipc,
            adminSocket: admin,
            useBundledSeeds: false,
            meetingPoints: const [],
            lib: lib,
          );
          final controller = EmbeddedNodeController(
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
          controllers.add(controller);
          await controller.start();
          final handle = FfiRatchetStateHandle.connect(ipc, lib: lib)!;
          handles.add(handle);
          handle.restorePeerAuthorization(
            PeerAuthorizationSnapshot(0, [
              PeerAuthorizationEntry(
                minted.nodeId.hex,
                i == 0 ? active : revoked,
              ),
            ]),
          );
          handle.acknowledgePeerAuthorization(
            handle.peerAuthorizationVersion(),
          );
        }
        // The newest registered runtime must not supply the first handle's
        // verdict. Conversely the first runtime must not authorize the second.
        for (var i = 0; i < 3; i++) {
          expect(
            handles[0].peerDeviceProofAllowed(minted.nodeId.bytes, device),
            isTrue,
          );
          expect(
            handles[1].peerDeviceProofAllowed(minted.nodeId.bytes, device),
            isFalse,
          );
        }
        expect(
          handles[0].peerDeviceProofAllowed(Uint8List(32), device),
          isFalse,
        );
        expect(
          () => handles[0].peerDeviceProofAllowed(Uint8List(31), device),
          throwsArgumentError,
        );
        handles[0].close();
        expect(
          () => handles[0].peerDeviceProofAllowed(minted.nodeId.bytes, device),
          throwsStateError,
        );
      } finally {
        for (final handle in handles.reversed) {
          handle.close();
        }
        for (final controller in controllers.reversed) {
          await controller.stop();
        }
        await dir.delete(recursive: true);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
