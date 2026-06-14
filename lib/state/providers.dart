import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/node/fake_node_controller.dart';
import '../data/node/node_controller.dart';
import '../data/storage/fake_kv_log_store.dart';
import '../data/storage/hidden_volume_storage.dart';
import '../data/storage/kv_log_store.dart';
import '../data/storage/storage.dart';
import '../data/transport/loopback_transport.dart';
import '../data/transport/veil_transport.dart';
import '../data/veil_stack.dart';

/// --- Infrastructure providers -------------------------------------------
///
/// Every external dependency the app talks to is exposed here behind its
/// port. Today they resolve to fakes; the native swap (Milestone 2) only
/// re-points these three providers — nothing in the UI changes.

final prefsProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final storageProvider = Provider<Storage>((ref) {
  // Dev/test wiring: the real domain→namespace/log mapping runs over an
  // in-memory space that persists for the session (so lock→unlock keeps
  // data). Swapping to native is just a different SpaceOpener (HvSpace).
  // An empty password unlocks nothing — exercises the auth-fail path.
  final session = FakeKvLogStore();
  KvLogStore? opener({required Uint8List password, required bool create}) {
    return password.isEmpty ? null : session;
  }

  final storage = HiddenVolumeStorage(opener);
  ref.onDispose(storage.close);
  return storage;
});

/// The real veil stack, when running. Null by default (loopback mode); main()
/// overrides it with a started [RealVeilStack] only when the opt-in env flags
/// are set, so the default startup path is completely unchanged.
final realStackProvider = Provider<RealVeilStack?>((ref) => null);

final nodeControllerProvider = Provider<NodeController>((ref) {
  final stack = ref.watch(realStackProvider);
  if (stack != null) return stack.controller; // owned/disposed by the stack
  final node = FakeNodeController();
  ref.onDispose(node.stop);
  return node;
});

final veilTransportProvider = Provider<VeilTransport>((ref) {
  final stack = ref.watch(realStackProvider);
  if (stack != null) return stack.transport; // owned/disposed by the stack
  final transport = LoopbackTransport();
  ref.onDispose(transport.dispose);
  return transport;
});

/// This device's shareable invite URI for the contact-exchange sheet — only
/// available in real mode (null on loopback, which hides the QR).
final myInviteProvider = Provider<String?>(
  (ref) => ref.watch(realStackProvider)?.myInvite.toUri(),
);

/// Live node status, surfaced to the network UI. Seeds with the current
/// snapshot so the stream provider has data before the first event.
final nodeStatusProvider = StreamProvider<NodeStatus>((ref) {
  final node = ref.watch(nodeControllerProvider);
  return node.status();
});
