import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/storage.dart';
import '../data/node/managed_node.dart';
import 'providers.dart';

const _kManagedNodesKey = 'managed_nodes';

/// The user's registry of managed nodes ("Мои узлы"), persisted as a JSON list
/// under one setting key INSIDE the encrypted container (via
/// [Storage.putSetting]/[Storage.getSetting]). Loaded lazily once the container
/// is open; mutations write through immediately.
class ManagedNodesController extends AsyncNotifier<List<ManagedNode>> {
  /// The storage THIS build belongs to.
  ///
  /// Read at the moment of use before, and the notifier watched nothing — so
  /// after an all-online switch, which `AppController._activateOnline`
  /// performs with no teardown, the screen went on showing A's hosts, users
  /// and host-key fingerprints while a mutation wrote the whole registry into
  /// B's storage. A's server list is not something B is meant to know
  /// (report17 XV17-H3).
  late Storage _storage;

  @override
  Future<List<ManagedNode>> build() async {
    // WATCHED: a switch rebuilds this notifier against the identity now shown.
    _storage = ref.watch(storageProvider);
    // The instance survives a rebuild, so this cache must not. It records what
    // was last written to the PREVIOUS identity's storage, and B's disk holds
    // something else entirely: left standing, it would suppress a real write
    // to B as "unchanged on disk".
    _lastPersisted = null;
    try {
      final raw = await _storage.getSetting(_kManagedNodesKey);
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
    // The storage this build belongs to, not whichever is active by the time
    // a queued mutation reaches the front.
    final storage = _storage;
    try {
      await storage.putSetting(_kManagedNodesKey, json);
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

  /// Mutations run one at a time.
  ///
  /// Each one reads the list, changes it and writes the whole thing back. Two
  /// of them started together both read the list BEFORE either write lands,
  /// and the second write puts back a list that never saw the first change —
  /// on a different node, even. What is lost is whatever the other one was
  /// doing, and one of the things these writes carry is a TOFU host-key pin
  /// (report16 XV-09).
  ///
  /// A queue rather than a lock: the operations are short, ordering between
  /// them does not matter, and every caller already awaits its own answer.
  Future<void> _tail = Future<void>.value();

  Future<String?> _serialized(Future<String?> Function() mutate) {
    // The storage this mutation was ASKED for. A queued one can reach the
    // front after a switch, and a list read from A must not be written to B.
    final asked = _storage;
    final next = _tail.then((_) {
      if (!identical(_storage, asked)) return null;
      return mutate();
    });
    // The chain must not break on a failure, or one failed write stops every
    // later one. Errors reach the caller through `next`.
    _tail = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Add a new node, or replace the existing one with the same id. Null on
  /// success, the failure text otherwise — see [_persist] for why this is
  /// returned and not thrown.
  Future<String?> upsert(ManagedNode node) => _serialized(() async {
    final cur = state.value ?? const [];
    final idx = cur.indexWhere((n) => n.id == node.id);
    final next = [...cur];
    if (idx >= 0) {
      next[idx] = node;
    } else {
      next.add(node);
    }
    return _persist(next);
  });

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
  ) => _serialized(() async {
    final cur = state.value ?? const [];
    final idx = cur.indexWhere((n) => n.id == id);
    if (idx < 0) return null;
    final next = [...cur];
    next[idx] = change(cur[idx]);
    return _persist(next);
  });

  /// Drop the node with [id]. Null on success, the failure text otherwise.
  Future<String?> remove(String id) => _serialized(() async {
    final cur = state.value ?? const [];
    return _persist(cur.where((n) => n.id != id).toList());
  });
}

final managedNodesProvider =
    AsyncNotifierProvider<ManagedNodesController, List<ManagedNode>>(
      ManagedNodesController.new,
    );
