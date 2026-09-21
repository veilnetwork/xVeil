// Whose request to empty a conversation this device will honour.
//
// Clearing is the one destructive act in this app that ARRIVES from somebody
// else. "Clear history" does not stay on the device that pressed it: it goes
// out as a watermark, and the other side erases its own copy of the
// conversation — measured on the stand (2026-09-21), 37 messages gone in nine
// seconds, while the dialog told the person the act was local and unannounced.
//
// So the receiving side needs a say, and one bit was not enough to give it:
// "let this contact delete at me" could only mean always or never. What a
// person actually wants to express is closer to "ask me", and in a group it
// matters WHO is asking.
//
// The policy is READER-SIDE and never travels to the requester: the no-oracle
// rule that governs the rest of this layer applies here too — a peer is not
// told whether its request was honoured, declined, or is sitting unanswered.
// It does travel between this identity's OWN devices, because a decision about
// my own history is mine everywhere.

/// What this device does with somebody else's request to clear a conversation.
enum ClearRequestPolicy {
  /// Honour a request from any participant. This is what the app did before
  /// the setting existed, and it is the reason a peer could empty a
  /// conversation without the person ever seeing a word about it.
  anyone,

  /// Honour a request only from an administrator of that chat.
  ///
  /// A 1:1 chat has no administrators, so here this DECLINES — the same answer
  /// as [never], reached honestly rather than by pretending the sender has a
  /// rank they cannot have. It earns its keep in groups.
  admins,

  /// Do not act; record the request and let the person decide.
  ///
  /// The default, and the reason this enum exists. It is only honest while
  /// there is somewhere for an unanswered request to be seen — without that
  /// surface it is [never] wearing a different name.
  ask,

  /// Never honour anyone's request. What other people do with their own copy
  /// stays their business.
  never;

  static ClearRequestPolicy? fromName(String? value) {
    for (final policy in values) {
      if (policy.name == value) return policy;
    }
    return null;
  }
}

/// What a fresh chat starts with.
///
/// [ClearRequestPolicy.ask], and it could not be until the requests list
/// existed: a default of "ask" is a lie while an unanswered request has
/// nowhere to be seen, because it behaves as [never] and says otherwise. The
/// two arrived together for that reason.
///
/// It is a CHANGE of behaviour, chosen deliberately over keeping
/// [ClearRequestPolicy.anyone]: that one is what let a peer empty somebody's
/// conversation with nothing on screen to say so, measured on the stand at
/// thirty-seven messages in nine seconds.
const ClearRequestPolicy kDefaultClearRequestPolicy = ClearRequestPolicy.ask;

/// The policy a record written before this setting existed decodes to.
///
/// Only one bit survives from then — `allowPeerDelete`, which also gates a
/// single-message unsend and keeps doing that job. OFF was an explicit act by
/// the person and is preserved exactly; ON is the value every untouched record
/// carries, so it cannot be told apart from "never chose", and it becomes the
/// new default rather than the loudest of the four.
///
/// That costs somebody who deliberately switched it ON a prompt they did not
/// ask for. The alternative costs somebody who never touched it their history,
/// silently, which is the failure this whole setting exists to stop.
ClearRequestPolicy clearRequestPolicyFromLegacy({
  required bool allowPeerDelete,
}) => allowPeerDelete ? kDefaultClearRequestPolicy : ClearRequestPolicy.never;

/// What a chat's policy decides about one arriving request.
enum ClearRequestVerdict {
  /// Erase now.
  apply,

  /// Keep the messages, keep nothing about the request.
  decline,

  /// Keep the messages and REMEMBER the request, so a person can answer it.
  askThePerson,
}

/// The reader-side decision, whole and pure.
///
/// [requesterIsAdmin] is false for every 1:1 chat, because a 1:1 has no
/// administrators — see [ClearRequestPolicy.admins].
ClearRequestVerdict clearRequestVerdict({
  required ClearRequestPolicy policy,
  required bool requesterIsAdmin,
}) => switch (policy) {
  ClearRequestPolicy.anyone => ClearRequestVerdict.apply,
  ClearRequestPolicy.admins =>
    requesterIsAdmin ? ClearRequestVerdict.apply : ClearRequestVerdict.decline,
  ClearRequestPolicy.ask => ClearRequestVerdict.askThePerson,
  ClearRequestPolicy.never => ClearRequestVerdict.decline,
};
