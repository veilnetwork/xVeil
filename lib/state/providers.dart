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

/// Parameters for the in-process deniable boot, set by main() when the
/// node-embedded dylib is loaded. Null disables it (loopback / legacy paths).
class DeniableBootConfig {
  const DeniableBootConfig({required this.runtimeDir, this.listenPort = 9000});

  /// Directory for the ephemeral, identity-free node sockets (admin + app IPC).
  final String runtimeDir;

  /// This instance's listener port (give two instances on one host distinct
  /// ports so they don't collide).
  final int listenPort;
}

/// Present (non-null) when the app should boot the node in-process from the
/// in-space identity post-unlock. main() overrides it only when the embedded
/// FFI is available; otherwise the default startup path is unchanged.
final deniableBootProvider = Provider<DeniableBootConfig?>((ref) => null);

/// The real veil stack, when running. Null until built: main() overrides the
/// initial value for the legacy env-config path, or [AppController] sets it
/// post-unlock for the deniable path. The node/transport/invite providers below
/// rebuild when it changes.
final realStackProvider = StateProvider<RealVeilStack?>((ref) => null);

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

/// Live node status, surfaced to the network UI. Emits the controller's current
/// snapshot FIRST, then its event stream — so a screen that subscribes after the
/// node already reached `connected` (e.g. the deniable boot finished before the
/// network tab was opened) shows the real status instead of being stuck on the
/// stream's pre-subscription default ("connecting").
final nodeStatusProvider = StreamProvider<NodeStatus>((ref) async* {
  final node = ref.watch(nodeControllerProvider);
  yield node.current;
  yield* node.status();
});
