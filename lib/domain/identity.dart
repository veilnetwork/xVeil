import '../core/ids.dart';

/// How the user chose to store their data at first run.
///
/// [hiddenSpace] = deniable hidden-volume container (default, recommended).
/// [plain] = unencrypted-at-rest local store (explicit opt-in, warned).
enum StorageMode { hiddenSpace, plain }

/// The local user's sovereign identity.
///
/// The recovery phrase / sovereign key itself is NEVER held here — it is
/// derived once, shown for backup, and then lives only inside the storage
/// container. This object carries the public, non-secret projection.
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
/// [Storage.loadIdentity]. Collapsing the two is what audit XV-13 found: an
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
