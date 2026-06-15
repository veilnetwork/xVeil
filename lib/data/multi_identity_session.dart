// Clean public param names (runtimeDirBase/listenPortBase/boot) are worth more
// than initializing-formal terseness for this small orchestration constructor.
// ignore_for_file: prefer_initializing_formals

import '../domain/roster.dart';
import 'storage/hidden_volume_storage.dart';
import 'storage/multi_space_store.dart';
import 'storage/storage.dart';
import 'veil_stack.dart';

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
        listenPort: listenPortBase + i,
        anonymous: roster[i].anonymous,
      ),
  ];
}

/// Boots [stack] from [storage] for one [spec] — defaults to the real deniable
/// boot; injectable so the session's orchestration can be tested without the
/// native node.
typedef IdentityNodeBoot = Future<RealVeilStack> Function(
    IdentityBootSpec spec, Storage storage);

Future<RealVeilStack> _realBoot(IdentityBootSpec spec, Storage storage) =>
    RealVeilStack.startDeniable(
      storage: storage,
      runtimeDir: spec.runtimeDir,
      listenPort: spec.listenPort,
      anonymous: spec.anonymous,
    );

/// Runs ALL of a master's identities at once: every identity's space is hosted
/// open over one [MultiSpaceBacking] (one container/lock), and every identity's
/// veil node runs simultaneously (its own port + runtime dir). The "active"
/// identity (what the UI shows) is just one of them; switching changes the view
/// without tearing any node down, so no identity goes offline.
///
/// This trades anonymity for availability — running every identity's node from
/// one device/IP lets a network observer correlate them. Opt-in only; mark
/// individual identities `anonymous` to route them over onion (uncorrelated).
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

  final _storages = <String, Storage>{};
  final _stacks = <String, RealVeilStack>{};

  List<String> get labels => _storages.keys.toList(growable: false);
  Storage? storageFor(String label) => _storages[label];
  RealVeilStack? stackFor(String label) => _stacks[label];

  /// Open every identity's space over the shared backing and boot its node.
  /// Best-effort per identity: a node-boot failure logs and skips that identity
  /// rather than aborting the whole session (its storage view is still hosted).
  Future<void> bootAll(List<RosterEntry> roster) async {
    final specs = planIdentityBoots(roster, _backing,
        runtimeDirBase: _runtimeDirBase, listenPortBase: _listenPortBase);
    for (final spec in specs) {
      final storage = HiddenVolumeStorage.fromStore(
          MultiSpaceKvLogStore(_backing, spec.spaceId));
      _storages[spec.label] = storage;
      try {
        _stacks[spec.label] = await _boot(spec, storage);
      } catch (_) {
        // Node didn't come up for this identity — keep its storage hosted so
        // the UI still shows its history; it just can't send/receive live.
      }
    }
  }

  /// Tear down all nodes and release the shared container lock.
  Future<void> disposeAll() async {
    for (final s in _stacks.values) {
      await s.dispose();
    }
    _stacks.clear();
    _storages.clear();
    _backing.close();
  }
}
