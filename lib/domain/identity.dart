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
