import 'dart:typed_data';

/// One child identity managed by a **master** space.
///
/// A master space holds a roster of these: a human [label] plus the child
/// space's opaque [spaceKeys] (64 bytes — the per-space decryption root from
/// `HvSpace.spaceKeys`). The master opens any child via
/// `HvSpace.openWithKeys(keys: spaceKeys)` — no per-child password prompt.
///
/// **Sensitive.** [spaceKeys] bypasses Argon2 on reopen, so it lives ONLY
/// inside the (encrypted, deniable) master space — never logged or persisted in
/// the clear. References are one-directional (master → child): a child space
/// never records which master(s) list it, so a shared decoy child reveals
/// nothing about the hidden set. Only add genuinely safe-to-reveal children to
/// a decoy/duress master.
class RosterEntry {
  const RosterEntry({
    required this.label,
    required this.spaceKeys,
    this.anonymous = false,
  });

  final String label;
  final Uint8List spaceKeys;

  /// Route this identity's node through veil's anonymizing overlay (onion /
  /// multi-hop) so its network activity is not linkable to the user's other
  /// identities or main account. Set for identities that must stay unlinkable;
  /// the default (false) uses direct routing (lower latency).
  final bool anonymous;

  RosterEntry copyWith({String? label, Uint8List? spaceKeys, bool? anonymous}) =>
      RosterEntry(
        label: label ?? this.label,
        spaceKeys: spaceKeys ?? this.spaceKeys,
        anonymous: anonymous ?? this.anonymous,
      );
}

/// Whether [candidateKeys] names a space this master already knows.
///
/// A space is derived from its password, so two identities entered under the
/// same password resolve to byte-identical keys. Adding one on top of the other
/// is not a duplicate ROW — it is one space with two names, and the second
/// write lands inside the first identity's storage. When the collision is with
/// the master itself, the master's roster is replaced by child data, after
/// which deleting that "child" deletes the master's storage.
///
/// ## Deniability boundary
///
/// This compares ONLY against the master the caller has already unlocked and
/// the entries in that master's own roster — state this session legitimately
/// sees. It must never grow into "is this password used anywhere in the
/// container": a hidden identity's whole defence is that nothing outside it can
/// tell it exists, and a check that answered for spaces beyond the current
/// roster would be a password oracle against exactly that.
///
/// Callers surface a collision as the same generic failure a duplicate label
/// already produces, so the answer never distinguishes "in use" from "rejected
/// for some other reason".
bool identitySpaceCollides({
  required Uint8List? masterKeys,
  required List<RosterEntry> roster,
  required Uint8List candidateKeys,
}) {
  bool same(Uint8List? a) {
    if (a == null || a.length != candidateKeys.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != candidateKeys[i]) return false;
    }
    return true;
  }

  return same(masterKeys) || roster.any((e) => same(e.spaceKeys));
}
