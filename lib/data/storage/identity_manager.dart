import 'dart:typed_data';

import '../../domain/roster.dart';
import 'hidden_volume_storage.dart';

/// Creates a fresh [HiddenVolumeStorage] wired to the same container's password
/// and keys openers — used by [IdentityManager] to open spaces one at a time.
typedef IdentityStorageFactory = HiddenVolumeStorage Function();

/// The requested password already opens the master or one of its children.
///
/// Its message deliberately says nothing about WHICH space it collided with,
/// and this is never thrown for a password outside the roster being edited —
/// see the boundary note on [IdentityManager.addIdentity].
class IdentitySpaceCollision implements Exception {
  const IdentitySpaceCollision();

  @override
  String toString() =>
      'that password already opens an identity in this master; nothing was '
      'written';
}

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
  /// Throws [IdentitySpaceCollision] when [childPassword] already opens the
  /// master or a space already in its roster.
  ///
  /// A space is DERIVED from its password, so `open(createIfMissing: true)`
  /// with a password already in use does not create anything — it opens the
  /// existing space. This method used to run `setup` and only afterwards read
  /// the keys back, so the provisioning write landed inside somebody else's
  /// storage before anything could notice. Re-using a child's password
  /// overwrote that child; re-using the MASTER's replaced the master's roster
  /// with child data, after which removing that "child" took the master's
  /// storage with it.
  ///
  /// The keys are read BEFORE the first write and compared. `AppController`
  /// carries the same rule through the same `identitySpaceCollides`; the audit
  /// found the two paths had diverged on exactly this check, and one shared
  /// predicate is the point.
  ///
  /// ⛔ DENIABILITY BOUNDARY: compared ONLY against the master we just opened
  /// and the entries in ITS roster — state this caller already legitimately
  /// sees. Never against the container at large. "Is this password used
  /// anywhere" is a password oracle against hidden identities, whose entire
  /// defence is that nothing outside them can tell they exist.
  Future<void> addIdentity({
    required String masterPassword,
    required String label,
    required String childPassword,
    Future<void> Function(HiddenVolumeStorage child)? setup,
  }) async {
    // One space at a time (the container's exclusive lock), so the master is
    // read and closed before the child is touched.
    final (masterKeys, existing) = await _masterView(
      masterPassword,
      createMaster: true,
    );

    final child = _make();
    if (!await child.open(password: childPassword, createIfMissing: true)) {
      throw StateError('could not create the child space for "$label"');
    }
    Uint8List keys;
    try {
      // Read the keys FIRST. Everything below this line is a write.
      keys = await child.exportSpaceKeys();
      if (identitySpaceCollides(
        masterKeys: masterKeys,
        roster: existing,
        candidateKeys: keys,
      )) {
        throw const IdentitySpaceCollision();
      }
      if (setup != null) await setup(child);
    } finally {
      await child.close();
    }
    await _updateRoster(masterPassword, createMaster: true, (roster) {
      roster
        ..removeWhere((e) => e.label == label) // replace a same-label entry
        ..add(RosterEntry(label: label, spaceKeys: keys));
    });
  }

  /// Open the master, read what this caller is allowed to compare against, and
  /// close it again. Returns `(masterKeys, roster)`.
  Future<(Uint8List?, List<RosterEntry>)> _masterView(
    String masterPassword, {
    required bool createMaster,
  }) async {
    final master = _make();
    if (!await master.open(
      password: masterPassword,
      createIfMissing: createMaster,
    )) {
      throw StateError('master password did not unlock a space');
    }
    try {
      return (
        await master.exportSpaceKeys(),
        await master.loadRoster() ?? const <RosterEntry>[],
      );
    } finally {
      await master.close();
    }
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
