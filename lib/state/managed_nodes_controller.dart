import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/node/managed_node.dart';
import 'providers.dart';

const _kManagedNodesKey = 'managed_nodes';

/// The user's registry of managed nodes ("Мои узлы"), persisted as a JSON list
/// under one setting key INSIDE the encrypted container (via
/// [Storage.putSetting]/[Storage.getSetting]). Loaded lazily once the container
/// is open; mutations write through immediately.
class ManagedNodesController extends AsyncNotifier<List<ManagedNode>> {
  @override
  Future<List<ManagedNode>> build() async {
    try {
      final raw = await ref.read(storageProvider).getSetting(_kManagedNodesKey);
      return ManagedNode.decodeList(raw);
    } catch (_) {
      // Storage not open (tests / pre-unlock) — empty registry.
      return const [];
    }
  }

  Future<void> _persist(List<ManagedNode> nodes) async {
    state = AsyncData(nodes);
    try {
      await ref
          .read(storageProvider)
          .putSetting(_kManagedNodesKey, ManagedNode.encodeList(nodes));
    } catch (_) {
      // Best-effort; in-memory state still reflects the change this session.
    }
  }

  /// Add a new node, or replace the existing one with the same id.
  Future<void> upsert(ManagedNode node) async {
    final cur = state.value ?? const [];
    final idx = cur.indexWhere((n) => n.id == node.id);
    final next = [...cur];
    if (idx >= 0) {
      next[idx] = node;
    } else {
      next.add(node);
    }
    await _persist(next);
  }

  Future<void> remove(String id) async {
    final cur = state.value ?? const [];
    await _persist(cur.where((n) => n.id != id).toList());
  }
}

final managedNodesProvider =
    AsyncNotifierProvider<ManagedNodesController, List<ManagedNode>>(
        ManagedNodesController.new);
