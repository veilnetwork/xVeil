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
