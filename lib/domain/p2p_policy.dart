/// Device-wide preference for direct peer-to-peer transport.
///
/// The effective decision is still capped by the active identity posture:
/// anonymous/onion identities never allow P2P because a direct endpoint is a
/// location signal.
enum P2PGlobalPolicy { allowAll, contacts, selected, denied }

/// Per-contact override for [P2PGlobalPolicy].
enum ContactP2POverride { followGlobal, allow, deny }

const P2PGlobalPolicy kDefaultP2PGlobalPolicy = P2PGlobalPolicy.contacts;
const ContactP2POverride kDefaultContactP2POverride =
    ContactP2POverride.followGlobal;
const String kP2PGlobalPolicySettingKey = 'p2p.policy.v1';

P2PGlobalPolicy p2pGlobalPolicyFromName(String? raw) => P2PGlobalPolicy.values
    .firstWhere((p) => p.name == raw, orElse: () => kDefaultP2PGlobalPolicy);

bool p2pPolicyAllows({
  required P2PGlobalPolicy global,
  required ContactP2POverride override,
  required bool contactKnown,
  required bool contactAccepted,
  required bool contactBlocked,
  required bool localAnonymous,
}) {
  if (localAnonymous) return false;
  if (contactBlocked) return false;
  if (override == ContactP2POverride.deny) return false;
  if (override == ContactP2POverride.allow) return contactKnown;

  return switch (global) {
    P2PGlobalPolicy.allowAll => !contactBlocked,
    P2PGlobalPolicy.contacts => contactAccepted,
    P2PGlobalPolicy.selected => false,
    P2PGlobalPolicy.denied => false,
  };
}
