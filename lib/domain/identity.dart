import '../core/ids.dart';

/// How the user chose to store their data at first run.
///
/// [hiddenSpace] = deniable hidden-volume container (default, recommended).
/// [plain] = unencrypted-at-rest local store (explicit opt-in, warned).
enum StorageMode { hiddenSpace, plain }

/// What a space stores ABOUT its owner: the parts a person chose, and nothing
/// else.
///
/// Deliberately holds no node id. The node id belongs to the node config that
/// lives in the same space, and that config is the only thing that can produce
/// it — deriving it is what a node boot does. A copy kept here would be a cache
/// of something already in the container, and audit XV-06 is the bill for that
/// cache: onboarding wrote a RANDOM id into the record before any node existed,
/// the node then minted its own, and the two never agreed again. The app hid it
/// (it displayed the node's id and never wrote it back) while headless compared
/// them and refused to start — the same profile, two answers.
///
/// There is no second copy to go stale now. See [Identity], which is composed
/// per session from a profile plus the node id the transport reports.
class UserProfile {
  const UserProfile({this.displayName, this.username});

  /// Self-chosen display name (local label until a username is claimed).
  final String? displayName;

  /// Network-wide claimed human-readable name (proof-of-work mined).
  /// Null until the user claims one. Anyone can mine a contested name.
  final String? username;

  UserProfile copyWith({String? displayName, String? username}) => UserProfile(
        displayName: displayName ?? this.displayName,
        username: username ?? this.username,
      );

  @override
  bool operator ==(Object other) =>
      other is UserProfile &&
      other.displayName == displayName &&
      other.username == username;

  @override
  int get hashCode => Object.hash(displayName, username);
}

/// The local user's sovereign identity AS THIS SESSION SEES IT: the running
/// node's id plus the profile stored beside it.
///
/// A composed, runtime-only view — never persisted as a unit. The recovery
/// phrase / sovereign key itself is NEVER held here either; it is derived once,
/// shown for backup, and then lives only inside the storage container. This
/// object carries the public, non-secret projection.
class Identity {
  const Identity({
    required this.nodeId,
    this.displayName,
    this.username,
  });

  final NodeId nodeId;

  /// Self-chosen display name (local label until a username is claimed).
  final String? displayName;

  /// Network-wide claimed human-readable name (proof-of-work mined).
  /// Null until the user claims one. Anyone can mine a contested name.
  final String? username;

  Identity copyWith({String? displayName, String? username}) => Identity(
        nodeId: nodeId,
        displayName: displayName ?? this.displayName,
        username: username ?? this.username,
      );
}

/// The space HOLDS an identity record, but it cannot be read back.
///
/// Distinct from "no identity record at all", which is a plain `null` from
/// `Storage.loadProfile`. Collapsing the two is what audit XV-13 found: an
/// unreadable record was reported as absent, so the caller minted a fresh
/// random identity and carried on into a normal, working-looking session —
/// while the damaged record was still sitting there, and the very next
/// roster/decoy write would have gone straight over it.
///
/// Carries only the SIZE of the unreadable blob and the parse error. The bytes
/// themselves are deliberately not held: they came out of a deniable container
/// and there is no recovery flow that would consume them, so copying them into
/// a long-lived exception object (which lands in logs and error reports) would
/// spread container plaintext for nothing.
class CorruptIdentityRecord implements Exception {
  CorruptIdentityRecord(this.byteLength, this.cause);

  /// Length of the stored blob that failed to parse.
  final int byteLength;

  /// What went wrong while decoding it (decode/JSON/hex error).
  final Object cause;

  @override
  String toString() =>
      'the space holds an identity record of $byteLength B that cannot be '
      'read ($cause) — it is damaged, not missing';
}
