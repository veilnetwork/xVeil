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

  /// Commit [nodes], then show them. Null on success, the failure text
  /// otherwise.
  ///
  /// The order is the point. It used to set the state FIRST and swallow the
  /// write error, so the screen showed a node as saved that was never
  /// committed — the user found out at the next launch, when it was simply
  /// gone and nothing had ever said so (report9 X-05). Optimism is only
  /// honest where it can be taken back, and this could not: the caller had
  /// already been told it worked.
  ///
  /// A failure is REPORTED rather than thrown, because the fingerprint-pinning
  /// callers upsert from inside SSH flows that catch `SshException` and
  /// nothing else — making this throw would turn a settings write into an
  /// unhandled error in three places that have nothing to do with settings.
  Future<String?> _persist(List<ManagedNode> nodes) async {
    final json = ManagedNode.encodeList(nodes);
    if (json == _lastPersisted) {
      state = AsyncData(nodes); // unchanged on disk; still the current list
      return null; // skip a redundant commit
    }
    try {
      await ref.read(storageProvider).putSetting(_kManagedNodesKey, json);
    } catch (e) {
      _lastPersisted = null; // write failed — don't suppress the next attempt
      return '$e';
    }
    _lastPersisted = json;
    state = AsyncData(nodes);
    return null;
  }

  /// The last JSON we actually persisted, so a no-op upsert (e.g. a status probe
  /// re-reporting an unchanged node) does not re-commit — each settings write is
  /// its own padded log commit, so redundant writes are pure container bloat.
  String? _lastPersisted;

  /// Add a new node, or replace the existing one with the same id. Null on
  /// success, the failure text otherwise — see [_persist] for why this is
  /// returned and not thrown.
  Future<String?> upsert(ManagedNode node) async {
    final cur = state.value ?? const [];
    final idx = cur.indexWhere((n) => n.id == node.id);
    final next = [...cur];
    if (idx >= 0) {
      next[idx] = node;
    } else {
      next.add(node);
    }
    return _persist(next);
  }

  /// Change the node with [id] by applying [change] to the record as it stands
  /// NOW. Null on success, the failure text otherwise — and null when there is
  /// no such node any more, because a record somebody deleted is not a failure
  /// to write one.
  ///
  /// This exists because [upsert] takes a whole record, and every caller had
  /// one it captured earlier. The SSH dialog pins a host key on first contact
  /// and saves it; the callback that runs straight afterwards then wrote back
  /// the object it had been handed BEFORE that, wiping the pin. The next
  /// connection was first-contact again, so a key that had been confirmed once
  /// could be replaced by somebody else's and confirmed again — over a
  /// connection that carries a root-capable credential and a command.
  ///
  /// The same shape lost `autoUpdate` and `veilVersion`: an editor that
  /// rebuilt a record from a form silently turned off a switch that had
  /// started a root timer on a server, and the screen then said it was off.
  ///
  /// Take the current record, change what you mean to change, leave the rest.
  Future<String?> updateById(
    String id,
    ManagedNode Function(ManagedNode current) change,
  ) async {
    final cur = state.value ?? const [];
    final idx = cur.indexWhere((n) => n.id == id);
    if (idx < 0) return null;
    final next = [...cur];
    next[idx] = change(cur[idx]);
    return _persist(next);
  }

  /// Drop the node with [id]. Null on success, the failure text otherwise.
  Future<String?> remove(String id) async {
    final cur = state.value ?? const [];
    return _persist(cur.where((n) => n.id != id).toList());
  }
}

final managedNodesProvider =
    AsyncNotifierProvider<ManagedNodesController, List<ManagedNode>>(
        ManagedNodesController.new);
