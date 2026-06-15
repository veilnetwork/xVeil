import 'dart:typed_data';

import '../../domain/roster.dart';
import 'hidden_volume_storage.dart';

/// Creates a fresh [HiddenVolumeStorage] wired to the same container's password
/// and keys openers — used by [MasterVault] to open child identity spaces.
typedef ChildStorageFactory = HiddenVolumeStorage Function();

/// Orchestrates a **master space**: a roster of child identities, each openable
/// by its stored `SpaceKeys` without a password. Wraps an already-unlocked
/// master [HiddenVolumeStorage] (which holds the roster — see
/// [HiddenVolumeStorage.saveRoster]) plus a [ChildStorageFactory].
///
/// Keys-based, NOT password-based: the master stores each child's opaque
/// `SpaceKeys` (the intended hidden-volume primitive, `open_with_keys`), never
/// the child's password. References are one-directional master → child: a child
/// space records nothing about its master(s), so a child shared into a decoy
/// master reveals nothing about the hidden set (see doc/MULTI-IDENTITY-DESIGN).
///
/// ⚠️ EXCLUSIVE-LOCK CONSTRAINT (native): the real hidden-volume container takes
/// an exclusive per-file flock, so **only one space in a container can be open
/// at a time**. The current [addChild]/[openChild] open a child while the master
/// handle is still open — that works against the in-memory fake but raises
/// `HvException.Busy` on a real container. Before this drives the UI, the orches-
/// tration must serialize: close the master, open/create the child, then reopen
/// the master to persist the roster (the "one active identity + fast switch"
/// model). Tracked for the master-integration work; see the real-container test
/// `master roster + openWithKeys, one space open at a time`.
class MasterVault {
  MasterVault(this._master, this._makeChild);

  final HiddenVolumeStorage _master;
  final ChildStorageFactory _makeChild;

  /// The children this master manages (empty if the roster is empty).
  Future<List<RosterEntry>> children() async =>
      await _master.loadRoster() ?? const [];

  /// Create a new child identity space under [password], record it under
  /// [label] in the master roster, and return the OPEN child storage so the
  /// caller can provision its identity/node. Throws if the space can't be made.
  Future<HiddenVolumeStorage> addChild(String label, String password) async {
    final child = _makeChild();
    if (!await child.open(password: password, createIfMissing: true)) {
      throw StateError('could not create child space for "$label"');
    }
    await _record(label, child.exportSpaceKeys());
    return child;
  }

  /// Record an already-open identity [child] as a child of this master — the
  /// shared-child case (e.g. a real "relatives" identity also added to a decoy
  /// master so it shows genuine chats under duress). Stores only its keys.
  Future<void> linkChild(String label, HiddenVolumeStorage child) =>
      _record(label, child.exportSpaceKeys());

  /// Open a child by its roster entry — keys-based, no password prompt.
  Future<HiddenVolumeStorage> openChild(RosterEntry entry) async {
    final child = _makeChild();
    if (!await child.openWithKeys(entry.spaceKeys)) {
      throw StateError('child "${entry.label}" keys no longer open a space');
    }
    return child;
  }

  /// Drop a child from the roster. Does NOT delete the child space — it stays
  /// openable by its own password and by any other master that lists it.
  Future<void> removeChild(String label) async {
    final roster = List<RosterEntry>.from(await children())
      ..removeWhere((e) => e.label == label);
    await _master.saveRoster(roster);
  }

  Future<void> _record(String label, Uint8List keys) async {
    final roster = List<RosterEntry>.from(await children())
      ..removeWhere((e) => e.label == label) // replace a same-label entry
      ..add(RosterEntry(label: label, spaceKeys: keys));
    await _master.saveRoster(roster);
  }
}
