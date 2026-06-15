// Clean public param names are worth more than initializing-formal terseness
// for this small orchestration constructor.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../data/storage/hidden_volume_storage.dart';
import '../data/storage/multi_space_store.dart';
import '../data/storage/storage.dart';
import '../data/transport/veil_transport.dart';
import '../data/veil_stack.dart';
import '../domain/roster.dart';
import 'messaging.dart';

/// One identity's boot plan in an "all identities online" session: which hosted
/// space it uses, and the ephemeral, per-identity runtime endpoints (a distinct
/// runtime dir + listen port so the N nodes don't collide) and routing mode.
class IdentityBootSpec {
  const IdentityBootSpec({
    required this.label,
    required this.spaceId,
    required this.runtimeDir,
    required this.listenPort,
    required this.anonymous,
  });

  final String label;
  final int spaceId;
  final String runtimeDir;
  final int listenPort;
  final bool anonymous;
}

/// A booted identity node: its overlay [transport] (drives that identity's
/// messaging), the optional [stack] (for its invite/status — null in tests),
/// and a [dispose] to tear it down. Decouples the session from the concrete
/// (native) [RealVeilStack] so the orchestration is unit-testable.
class IdentityNode {
  const IdentityNode({
    required this.transport,
    required this.dispose,
    this.stack,
  });

  final VeilTransport transport;
  final Future<void> Function() dispose;
  final RealVeilStack? stack;
}

/// Plan the boots for a whole roster over a shared [backing]: open each
/// identity's space (hosting it) and assign it a distinct runtime dir + listen
/// port (offset by index) so N nodes can run at once on one host. Pure aside
/// from `backing.openSpace`, so it is unit-testable with a fake backing.
List<IdentityBootSpec> planIdentityBoots(
  List<RosterEntry> roster,
  MultiSpaceBacking backing, {
  required String runtimeDirBase,
  required int listenPortBase,
}) {
  return [
    for (var i = 0; i < roster.length; i++)
      IdentityBootSpec(
        label: roster[i].label,
        spaceId: backing.openSpace(roster[i].spaceKeys),
        runtimeDir: '$runtimeDirBase/${roster[i].label}',
        // Offset by 1 so all-online nodes never reuse [listenPortBase] — the
        // port a just-stopped one-active node held, whose lingering teardown
        // would otherwise stall the first identity's bind for ~90s.
        listenPort: listenPortBase + 1 + i,
        anonymous: roster[i].anonymous,
      ),
  ];
}

/// Boots an [IdentityNode] from [storage] for one [spec] — defaults to the real
/// deniable boot; injectable so the orchestration can be tested without a node.
typedef IdentityNodeBoot = Future<IdentityNode> Function(
    IdentityBootSpec spec, Storage storage);

Future<IdentityNode> _realBoot(IdentityBootSpec spec, Storage storage) async {
  final stack = await RealVeilStack.startDeniable(
    storage: storage,
    runtimeDir: spec.runtimeDir,
    listenPort: spec.listenPort,
    anonymous: spec.anonymous,
  );
  return IdentityNode(
      transport: stack.transport, stack: stack, dispose: stack.dispose);
}

/// Runs ALL of a master's identities at once. Every identity's space is hosted
/// open over one [MultiSpaceBacking] (one container/lock), its veil node runs
/// simultaneously (own port + runtime dir), AND it has its own
/// [MessagingService] wired to its node's transport + its storage — so EVERY
/// identity receives and persists messages concurrently, not just the active
/// one. The "active" identity is merely the one the UI shows; switching changes
/// the view without stopping any node, so nothing goes offline.
///
/// Trades anonymity for availability — co-located always-on nodes can be
/// correlated by an observer. Opt-in only; mark sensitive identities `anonymous`
/// to route them over onion and keep them uncorrelated even when always-on.
class MultiIdentitySession {
  MultiIdentitySession(
    this._backing, {
    required String runtimeDirBase,
    required int listenPortBase,
    IdentityNodeBoot boot = _realBoot,
  })  : _runtimeDirBase = runtimeDirBase,
        _listenPortBase = listenPortBase,
        _boot = boot;

  final MultiSpaceBacking _backing;
  final String _runtimeDirBase;
  final int _listenPortBase;
  final IdentityNodeBoot _boot;

  /// Per-identity node-boot ceiling (mining a fresh identity can take a few
  /// seconds; the deferred admin-connect retries up to ~90s, so cap well under
  /// that to fail fast on a stuck bind).
  static const _bootTimeout = Duration(seconds: 45);

  final _storages = <String, Storage>{};
  final _nodes = <String, IdentityNode>{};
  final _messaging = <String, MessagingService>{};

  List<String> get labels => _storages.keys.toList(growable: false);
  Storage? storageFor(String label) => _storages[label];
  RealVeilStack? stackFor(String label) => _nodes[label]?.stack;
  MessagingService? messagingFor(String label) => _messaging[label];

  /// Open every identity's space over the shared backing, boot its node, and
  /// wire its own messaging pipeline (transport + storage) so it receives
  /// concurrently. Best-effort per identity: a boot failure logs and skips that
  /// identity's node/messaging but keeps its storage view hosted.
  Future<void> bootAll(List<RosterEntry> roster) async {
    final specs = planIdentityBoots(roster, _backing,
        runtimeDirBase: _runtimeDirBase, listenPortBase: _listenPortBase);
    for (final spec in specs) {
      final storage = HiddenVolumeStorage.fromStore(
          MultiSpaceKvLogStore(_backing, spec.spaceId));
      _storages[spec.label] = storage;
      try {
        // Bound the boot: a node that can't bind its port (e.g. one just freed
        // by a previous mode) otherwise retries the admin-connect for ~90s and
        // would hang the whole unlock. On timeout we skip it (best-effort).
        final node = await _boot(spec, storage).timeout(_bootTimeout);
        _nodes[spec.label] = node;
        _messaging[spec.label] = MessagingService(node.transport, storage)
          ..start();
      } catch (_) {
        // Node didn't come up — keep the storage view so the UI shows history;
        // this identity just can't send/receive live until re-booted.
      }
    }
  }

  /// Tear down all messaging pipelines and nodes, then release the shared lock.
  Future<void> disposeAll() async {
    for (final m in _messaging.values) {
      await m.dispose();
    }
    for (final n in _nodes.values) {
      await n.dispose();
    }
    _messaging.clear();
    _nodes.clear();
    _storages.clear();
    _backing.close();
  }
}
