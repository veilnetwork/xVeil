import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/node/fake_node_controller.dart';
import '../data/node/node_controller.dart';
import '../data/storage/in_memory_storage.dart';
import '../data/storage/storage.dart';
import '../data/transport/loopback_transport.dart';
import '../data/transport/veil_transport.dart';

/// --- Infrastructure providers -------------------------------------------
///
/// Every external dependency the app talks to is exposed here behind its
/// port. Today they resolve to fakes; the native swap (Milestone 2) only
/// re-points these three providers — nothing in the UI changes.

final prefsProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final storageProvider = Provider<Storage>((ref) {
  final storage = InMemoryStorage();
  ref.onDispose(storage.close);
  return storage;
});

final nodeControllerProvider = Provider<NodeController>((ref) {
  final node = FakeNodeController();
  ref.onDispose(node.stop);
  return node;
});

final veilTransportProvider = Provider<VeilTransport>((ref) {
  final transport = LoopbackTransport();
  ref.onDispose(transport.dispose);
  return transport;
});

/// Live node status, surfaced to the network UI. Seeds with the current
/// snapshot so the stream provider has data before the first event.
final nodeStatusProvider = StreamProvider<NodeStatus>((ref) {
  final node = ref.watch(nodeControllerProvider);
  return node.status();
});
