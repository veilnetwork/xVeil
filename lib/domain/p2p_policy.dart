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

/// Whether this identity's node listener may bind beyond loopback.
///
/// Separates the two ways the setting can be missing, which collapsing them
/// gets wrong in opposite directions:
///
///  * ABSENT (`storedPolicy == null`, `readFailed == false`) — never set, so
///    the default applies. Denying here would break every fresh install.
///  * UNREADABLE (`readFailed == true`) — a transient storage error. Falling
///    back to the default is permissive, so a failed read would bind a LAN
///    listener for someone who had explicitly denied P2P. The setting exists
///    precisely to stop that, and an open LAN port is not something to grant
///    on a guess.
///
/// Here rather than on the app controller because BOTH boot paths need it and
/// there must not be two answers: the always-online path had none at all, so
/// every node in an all-online session bound loopback and could not be dialled
/// by anybody.
bool lanListenAllowed({
  required String? storedPolicy,
  required bool readFailed,
}) {
  if (readFailed) return false;
  if (storedPolicy == null) {
    return kDefaultP2PGlobalPolicy != P2PGlobalPolicy.denied;
  }
  return p2pGlobalPolicyFromName(storedPolicy) != P2PGlobalPolicy.denied;
}

/// Whether MESSAGING may run the direct-connection ladder toward this contact.
///
/// `followGlobal` FOLLOWS THE GLOBAL POLICY, which is what the option is
/// called and therefore what it has to do. It did not until 2026-09-20: this
/// predicate ignored [P2PGlobalPolicy] entirely and read `followGlobal` as a
/// flat no, so a person who had set the global policy to "all" or "contacts"
/// still got `messaging ladder not allowed (override=followGlobal)` on every
/// conversation and no screen anywhere said why.
///
/// The reasoning that stood behind the old behaviour is worth keeping in view,
/// because it is not wrong about the risk: placing a call is an act of reaching
/// out to one named person and the media path exposes the address to them
/// anyway, while a chat message is not, and people send those to everyone they
/// know. So following the global policy here DOES widen who can learn this
/// node's direct address — to exactly the set the global policy already names.
/// That is the setting's own promise; a per-contact `deny` still overrides it,
/// and `selected`/`denied` still mean no.
///
/// Every veto is kept: an anonymous identity, a blocked contact and an unknown
/// contact are refused before the policy is consulted at all.
///
/// The mailbox path is unaffected either way. A denial here costs latency, not
/// delivery.
bool p2pMessagingAllows({
  required P2PGlobalPolicy global,
  required ContactP2POverride override,
  required bool contactKnown,
  required bool contactAccepted,
  required bool contactBlocked,
  required bool localAnonymous,
}) {
  // An anonymous identity must never emit a direct endpoint — same veto as
  // [p2pPolicyAllows], repeated rather than delegated so neither can be
  // relaxed without the other being looked at.
  if (localAnonymous) return false;
  if (contactBlocked) return false;
  if (!contactKnown) return false;
  if (override == ContactP2POverride.deny) return false;
  if (override == ContactP2POverride.allow) return true;
  // followGlobal — the default — now means what it says.
  return switch (global) {
    P2PGlobalPolicy.allowAll => true,
    P2PGlobalPolicy.contacts => contactAccepted,
    P2PGlobalPolicy.selected => false,
    P2PGlobalPolicy.denied => false,
  };
}

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
