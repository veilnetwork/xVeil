import 'dart:typed_data';

import '../../domain/roster.dart';
import 'hidden_volume_storage.dart';

/// Creates a fresh [HiddenVolumeStorage] wired to the same container's password
/// and keys openers — used by [IdentityManager] to open spaces one at a time.
typedef IdentityStorageFactory = HiddenVolumeStorage Function();

/// Manages several identities (spaces) hidden in ONE container, under the native
/// **exclusive per-file lock**: only one space is open at a time. Every method
/// therefore opens, acts, and closes; the single long-lived open handle is the
/// **active identity** returned by [openIdentity] (switching = close it, open
/// the next). This is the orchestration the lock requires and the
/// "one active identity + fast switch" model the design chose — it replaces the
/// earlier `MasterVault`, whose simultaneous-open model only worked against the
/// lock-free in-memory fake (see doc/MULTI-IDENTITY-DESIGN.md).
///
/// Keys-based: a **master space** stores each child's opaque `SpaceKeys`
/// (the `open_with_keys` primitive), never the child's password. References are
/// one-directional master → child.
class IdentityManager {
  IdentityManager(this._make);

  final IdentityStorageFactory _make;

  /// The roster recorded in the master space that [masterPassword] unlocks —
  /// empty if it has none (a master with no children yet). Opens, reads, and
  /// closes the master. Throws if the password unlocks nothing.
  Future<List<RosterEntry>> roster(String masterPassword) async {
    final master = _make();
    if (!await master.open(password: masterPassword)) {
      throw StateError('master password did not unlock a space');
    }
    try {
      return await master.loadRoster() ?? const [];
    } finally {
      await master.close();
    }
  }

  /// Create (or adopt) a child identity space under [childPassword], let [setup]
  /// provision it (e.g. mine + store its node identity) while it is the only
  /// open space, then record its keys under [label] in the master roster. The
  /// master is created on first add. Fully serialized: child open → setup →
  /// close, THEN master open → saveRoster → close (never two spaces at once).
  ///
  /// Adopting an existing space (same [childPassword]) is how an already-created
  /// single identity is folded into a new master — its data is preserved.
  Future<void> addIdentity({
    required String masterPassword,
    required String label,
    required String childPassword,
    Future<void> Function(HiddenVolumeStorage child)? setup,
  }) async {
    final child = _make();
    if (!await child.open(password: childPassword, createIfMissing: true)) {
      throw StateError('could not create the child space for "$label"');
    }
    Uint8List keys;
    try {
      if (setup != null) await setup(child);
      keys = await child.exportSpaceKeys();
    } finally {
      await child.close();
    }
    await _updateRoster(masterPassword, createMaster: true, (roster) {
      roster
        ..removeWhere((e) => e.label == label) // replace a same-label entry
        ..add(RosterEntry(label: label, spaceKeys: keys));
    });
  }

  /// Open one identity for use and return it OPEN — the active identity. The
  /// caller closes it (or calls this again for another identity after closing
  /// the current one). Reads the master roster first (master opened+closed),
  /// then opens the child by its keys — never both at once.
  Future<HiddenVolumeStorage> openIdentity(
      String masterPassword, String label) async {
    final entries = await roster(masterPassword); // opens + closes the master
    final entry = entries.firstWhere(
      (e) => e.label == label,
      orElse: () => throw StateError('no identity "$label" in this master'),
    );
    final child = _make();
    if (!await child.openWithKeys(entry.spaceKeys)) {
      throw StateError('identity "$label" keys no longer open a space');
    }
    return child;
  }

  /// Remove an identity from the master roster. Does NOT delete the child space
  /// — it stays openable by its own password and by any other master listing it.
  Future<void> removeIdentity(String masterPassword, String label) =>
      _updateRoster(masterPassword,
          (roster) => roster.removeWhere((e) => e.label == label));

  Future<void> _updateRoster(
    String masterPassword,
    void Function(List<RosterEntry> roster) mutate, {
    bool createMaster = false,
  }) async {
    final master = _make();
    if (!await master.open(
        password: masterPassword, createIfMissing: createMaster)) {
      throw StateError('master password did not unlock a space');
    }
    try {
      final roster = List<RosterEntry>.from(await master.loadRoster() ?? const []);
      mutate(roster);
      await master.saveRoster(roster);
    } finally {
      await master.close();
    }
  }
}
