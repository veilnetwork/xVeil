import 'dart:convert';
import 'dart:typed_data';

import '../../domain/inline_custom_emoji.dart';
import '../../domain/space_recommendation.dart';

/// Application message type carried in the transport payload.
/// - [request]: a connection request (body = greeting).
/// - [accept]: approval of a request (body unused).
/// - [message]: a normal chat message (body = text).
/// - [fileMeta]: start of a file transfer (body = JSON {tid,name,size,count}).
/// - [fileChunk]: one file chunk (body = JSON {tid,i,total,d=base64}).
/// - [ack]: delivery acknowledgement (id = the acked message's id, body unused).
/// - [edit]: edit of a previously-sent message (id = its id, body = new text).
/// - [del]: deletion of a previously-sent message (id = its id, body unused).
/// - [sync]: an event-log gap-fill beacon (body = JSON {hw,holes,ep}) — what the
///   sender holds per author, so the peer re-ships anything missing (§15, 3c).
/// - [voidSeq]: an inert seq placeholder (seq set, no id/body) advancing the
///   peer's high-water past a deleted/superseded slot so gap-fill never stalls
///   (R-VOID, §12.1 — id-less, no oracle).
/// - [fileQuery]: a gap-fill RE-SHIP PROBE for a file (body = the fileMeta JSON,
///   no chunks) — "I still hold file `<tid>`, tell me what you're missing." The
///   receiver answers with [fileNack]; the sender then re-sends only those chunks
///   (resumable, instead of re-pushing the whole blob each round).
/// - [fileNack]: the receiver's reply to a probe/transfer (body = JSON
///   {tid, m:[missing indices]}); `m` ABSENT means "send me everything" (a
///   receiver that holds no chunk yet, so it can't name them).
/// - [reconnect]: "we were connected — please re-establish" (body = greeting).
///   Sent when a message stays un-acked past a threshold (the peer may have
///   wiped its chat data and forgotten us, so our messages hit its consent gate
///   and drop). The receiver disambiguates by its OWN state — accepted → re-ack;
///   unknown/pending → surface as a pending re-intro; blocked → drop silently.
///   Offline-vs-wiped is deliberately indistinguishable (no presence oracle).
/// - [unknown]: a DECODE-ONLY sentinel for a structured (v:2) frame from a NEWER
///   build whose kind this build doesn't know — the dispatcher drops it instead
///   of rendering it as chat text (RULE WC). NEVER encoded onto the wire.
///
/// New kinds are APPENDED so existing wire indices (0..7) are unchanged; [sync]
/// onward carry a `v:2` structural marker (RULE WC). [unknown] stays LAST.
enum WireKind {
  request,
  accept,
  message,
  fileMeta,
  fileChunk,
  ack,
  edit,
  del,
  sync,
  voidSeq,
  fileQuery,
  fileNack,
  reconnect,

  /// RESERVED — never emitted. The push-stream prototype this belonged to was
  /// abandoned; large files use [contentManifestEnvelope] with a
  /// receiver-initiated, content-id-bound pull stream instead. The slot stays
  /// so later enum indices keep their wire values, and the inbound dispatcher
  /// decodes then drops the kind so an experimental old frame cannot be
  /// mistaken for anything. Do not build new behaviour on it; the builder that
  /// used to construct it was removed (audit P3-25).
  fileStream,
  contentManifest,
  pieceRequest,
  pieceChunk,
  clear,
  contentReoffer,
  contentGone,
  // Opt-in authorship attestation. signRequest: recipient → author, id=msgId,
  // body=the message text to attest. signResponse: author → recipient, body=JSON
  // {mid, sig, pk} (or {mid, refused:true}). Added before `unknown` so an older
  // decoder maps these (out-of-range) indices to `unknown` and ignores them.
  signRequest,
  signResponse,

  /// Call control plane (voice / video / screen share). Body = `CallSignal`
  /// JSON (offer/answer/reject/cancel/busy/end/renegotiate/transportInfo — see
  /// lib/domain/call_signal.dart). Added before [unknown] so an older decoder
  /// maps this out-of-range index to [unknown] and ignores it (RULE WC). The
  /// media itself flows on a separately-negotiated path; this only sets it up.
  callSignal,

  /// A reaction to a message. [id] = the target message id; [body] = the emoji,
  /// or EMPTY to remove this reactor's reaction. A side annotation (NOT an
  /// event-log event — no seq), delivered durably like edit/del. Added before
  /// [unknown] so an older decoder maps this out-of-range index to [unknown]
  /// and drops it (RULE WC).
  reaction,

  /// A group snapshot/delta (groups epic). Body = JSON of a group bundle
  /// {m: manifest, c: [control...], g: [message...]} the receiver INGESTS
  /// (idempotent — dedup by author+seq). Direct fanout in v1: the sender
  /// ships it durably to each member. Added before [unknown] so an older
  /// decoder maps this out-of-range index to [unknown] and drops it (RULE WC).
  groupEntry,

  /// ONE chunk of a group snapshot too large for a single [groupEntry] frame
  /// (groups media: an inline image pushes the bundle JSON past the
  /// auth_deliver cap MAX_AUTH_DELIVER_MSG_BYTES=6144). Body = JSON
  /// {tid, i, n, d:base64}; the receiver reassembles all `n` chunks of `tid`
  /// (a durable frame each, acked/deduped individually) and ingests the joined
  /// bundle exactly like a whole [groupEntry]. Added before [unknown] (RULE WC).
  groupEntryChunk,

  /// A signed membership-authorized content-fetch request (groups content
  /// path, doc/GROUPS-CONTENT-PATH.md): body = GroupContentRequest JSON. The
  /// dispatcher does NOT contact-gate this kind — authorization is the signed
  /// membership proof itself, checked by the group layer (unauthorized ⇒
  /// silent drop). Added before [unknown] (RULE WC).
  groupContentRequest,

  /// OPT-IN farewell: the sender deleted this whole conversation on their
  /// device AND explicitly chose "notify the peer" in the delete dialog (the
  /// default delete stays silent — the no-oracle canon is relaxed only by
  /// that explicit choice, decision 2026-07-11). Body is empty; the receiver
  /// stores a local [kChatDeletedMarkerBody] marker message in the chat.
  /// Added before [unknown] so an older decoder maps this out-of-range index
  /// to [unknown] and drops it (RULE WC).
  chatDeleted,

  /// Signed shared-document invite/snapshot/delta. This is deliberately not a
  /// group frame: accepted-contact transport admission is followed by the
  /// document layer's own root/control/epoch verification.
  cloudDocument,

  /// One durable chunk of an oversized [cloudDocument] frame.
  cloudDocumentChunk,

  /// Ephemeral, epoch-encrypted and node-id-signed group-call control frame.
  /// It is separate from [groupEntry]: call lifecycle must never be persisted
  /// into or replayed from the group message log. Admission and decryption are
  /// performed by the group layer against its current membership epoch, so
  /// non-contact members can participate without bypassing group ACL.
  groupCallSignal,

  /// P2P direct-endpoint exchange (real-P2P epic). Body = JSON
  /// `{v:1, ts:<ms>, e:[<bootstrap URI>...]}` — the sender's CURRENT direct
  /// dial endpoints (LAN ip:port today; observed external later), each a full
  /// `veil:bootstrap?...` URI carrying pubkey+nonce so the receiver can redeem
  /// it via the standard join path. PRIVACY: sent only to an ACCEPTED contact
  /// and only when the local P2P policy allows that peer (mutual consent —
  /// the receiver applies its own policy before dialing and before replying
  /// with its endpoints); never published to DHT/ads. Contact-gated on receive
  /// like [callSignal]. Added before [unknown] (RULE WC) so older builds drop
  /// it silently.
  p2pEndpoints,

  /// Consent-first Space invitation. The body contains only the minimal
  /// proposal metadata; it never contains a roster, control log, messages or
  /// epoch keys. Accepted-contact gated on receive.
  spaceInvite,

  /// The invitee's explicit accept/decline decision. Acceptance is not a
  /// membership grant: the inviter must still append an authorized signed
  /// `addMember` entry and send the normal Space snapshot.
  spaceInviteDecision,

  /// Capability-bound request to join an active public Space. Unlike an
  /// invitation it may arrive from a non-contact, but contains only ticket and
  /// routing ids; the Space layer rate-limits and validates the locally issued
  /// bearer ticket before acknowledging it.
  spaceJoinRequest,

  /// Approver response to [spaceJoinRequest]. Acceptance is only progress UI;
  /// authority still comes exclusively from the signed membership snapshot.
  spaceJoinDecision,

  /// An explicitly shared public-Space recommendation card. It is a separate
  /// kind so older clients drop it instead of displaying structured metadata
  /// as user text. The receiver stores a typed body in the ordinary message
  /// event log, preserving ACK, deletion, retention and gap-fill semantics.
  spaceRecommendation,

  /// Signed, one-per-action moderation appeal addressed to the immutable Space
  /// owner. It may cross the contact boundary; the Space layer verifies the
  /// authenticated appellant, signature and exact retained action before ACK.
  spaceModerationAppeal,

  /// Signed owner review status for [spaceModerationAppeal]. A revocation
  /// outcome is informational until the ordinary signed control-log revocation
  /// arrives and folds successfully.
  spaceModerationAppealDecision,

  /// Live-only completion of one accepted [groupContentRequest]. The body is a
  /// [GroupContentReceipt]: it echoes the original signed request nonce only
  /// after verified durable storage. It is never ACKed, outboxed, stashed or
  /// written to a Space log; the holder accepts it only from the authenticated
  /// requester while the matching request remains in bounded RAM. Appended
  /// immediately before [unknown] so every prior wire index stays unchanged.
  groupContentReceipt,

  /// Live-only holder advertisement for one membership-scoped group content
  /// pull. Unlike [contentManifest], receiving it must never create a direct
  /// chat row, auto-download bytes, or emit an ACK/read oracle. Admission is
  /// the receiver's bounded `(peer, contentId)` pull scope established before
  /// its signed [groupContentRequest] leaves. Appended immediately before
  /// [unknown] so every prior wire index stays unchanged.
  groupContentManifest,

  /// Live-only signed request for one exact owner-committed public Space feed
  /// manifest/page hash. It may cross the contact boundary; the Space layer
  /// validates source binding, signature, freshness, quota and local cache.
  spacePublicFeedRequest,

  /// One live-only response slice for a pending [spacePublicFeedRequest].
  /// Unsolicited or wrong-source chunks are dropped before allocating
  /// reassembly state, and the complete object is verified by its committed
  /// hash. Neither direction is ACKed, outboxed or written to chat history.
  spacePublicFeedChunk,

  /// Live-only signed request to open the existing content stream for one CID
  /// committed by an exact verified public Space descriptor/feed pair. The
  /// Space layer validates the authenticated source, signature, freshness,
  /// replay/quota and public reference before minting a `(peer, CID)` grant.
  /// Appended immediately before [unknown]; all older indices stay unchanged.
  spacePublicMediaGrantRequest,

  /// Reporter-signed complaint about one exact Space post or comment. It may
  /// cross the contact boundary, but is ACKed only after the current owner has
  /// verified the signature, content reference and bounded inbox quota.
  spaceAbuseReport,

  /// Owner-signed immutable review status for [spaceAbuseReport]. A content
  /// removal outcome references, but never replaces, the ordinary signed
  /// moderation action that performed the deletion.
  spaceAbuseReportDecision,

  /// "Which translation or speech models do you have?" Body is empty.
  ///
  /// The point of it is to work with no internet at all: a person on a network
  /// where the publisher is unreachable can still get a model from someone
  /// they already talk to. Accepted-contact gated on receive, and answering is
  /// a local choice — the set of languages a device holds says something about
  /// who is reading what, so a person can turn the answer off.
  ///
  /// Live-only and deliberately so: never durable, never ACKed, never written
  /// to chat history, and never re-driven. A query that is lost because the
  /// contact was offline is simply a question nobody heard, and a durable one
  /// would arrive days later to answer a question long since settled.
  /// Appended immediately before [unknown] (RULE WC).
  modelInventoryRequest,

  /// The answer to [modelInventoryRequest]: a JSON list of
  /// `{kind, from?, to?, bytes}` rows and nothing else — no paths, no hashes,
  /// nothing about the answering device. Same live-only, contact-gated
  /// treatment as the request. Appended immediately before [unknown] (RULE WC).
  modelInventoryOffer,

  /// The conversation's shared disappearing-message window changed. Body is
  /// `{v:1, ttl:<seconds, 0=off>, ts:<ms since epoch>}`.
  ///
  /// Announced rather than kept private because a window only one side honours
  /// is not a promise — the copy on the other device is exactly what the
  /// setting is about. The sender identity comes from the envelope, never the
  /// body, and the receiver keeps whichever of the two announcements is later
  /// (see `DisappearingSetting.winner`) so both sides converge on ONE window
  /// instead of each keeping its own.
  ///
  /// Contact-gated on receive like the other conversation-scoped kinds, and
  /// appended immediately before [unknown] (RULE WC) so an older build maps
  /// the out-of-range index to [unknown] and drops it.
  disappearingSet,
  unknown,
}

/// The canonical wire layout: name at position N occupies wire index N.
///
/// The envelope carries `kind.index`, so the enum's ORDER *is* the protocol.
/// Deleting a variant, inserting one anywhere but the end, or reordering two
/// silently renumbers everything after it — new senders then mean something
/// different to old receivers, with no error anywhere to notice it by. Pinning
/// one reserved slot's index (which is all that existed) only caught a change
/// adjacent to that slot; this registry catches drift ANYWHERE.
///
/// ## The rule
///
/// * A new kind is **appended immediately before [WireKind.unknown]** and its
///   name added here in the same commit.
/// * A retired kind is **never deleted**. Its slot moves to
///   [kReservedWireKinds] and stays, because the index belongs to the wire and
///   not to us.
/// * Removing a reserved slot — or any compatibility flag — is a MAJOR,
///   versioned migration: every peer must already refuse the old layout before
///   the slot can be reclaimed. There is no in-place way to do it, which is
///   precisely why the slot is cheaper to keep than to reason about.
///
/// Deliberately a list of NAMES rather than a length or a checksum: a
/// mismatched test then says which kind moved and where to, instead of "the
/// enum changed".
const List<String> kWireKindOrder = [
  'request',
  'accept',
  'message',
  'fileMeta',
  'fileChunk',
  'ack',
  'edit',
  'del',
  'sync',
  'voidSeq',
  'fileQuery',
  'fileNack',
  'reconnect',
  'fileStream',
  'contentManifest',
  'pieceRequest',
  'pieceChunk',
  'clear',
  'contentReoffer',
  'contentGone',
  'signRequest',
  'signResponse',
  'callSignal',
  'reaction',
  'groupEntry',
  'groupEntryChunk',
  'groupContentRequest',
  'chatDeleted',
  'cloudDocument',
  'cloudDocumentChunk',
  'groupCallSignal',
  'p2pEndpoints',
  'spaceInvite',
  'spaceInviteDecision',
  'spaceJoinRequest',
  'spaceJoinDecision',
  'spaceRecommendation',
  'spaceModerationAppeal',
  'spaceModerationAppealDecision',
  'groupContentReceipt',
  'groupContentManifest',
  'spacePublicFeedRequest',
  'spacePublicFeedChunk',
  'spacePublicMediaGrantRequest',
  'spaceAbuseReport',
  'spaceAbuseReportDecision',
  'modelInventoryRequest',
  'modelInventoryOffer',
  'disappearingSet',
  'unknown',
];

/// Slots that exist ONLY to hold their wire index, mapped to why they are dead.
///
/// A reserved kind is never emitted. Inbound it is still decoded — to its own
/// kind, not to [WireKind.unknown] — so a frame from some old experimental
/// build is recognised and dropped rather than being mistaken for whatever
/// kind now sits at a shifted index. Machine-readable so the rule is testable
/// instead of resting on a comment attached to one variant.
const Map<WireKind, String> kReservedWireKinds = {
  WireKind.fileStream:
      'abandoned push-stream prototype (audit P3-25); large files use '
      'contentManifest with a receiver-initiated, content-id-bound pull',
};

/// Stored body of the LOCAL marker message a [WireKind.chatDeleted] farewell
/// leaves in the receiver's chat. Never typed by a user (bodies are trimmed
/// user text; this exact token is produced only by the receive path), so the
/// UI can render it as a system notice instead of a peer bubble.
const kChatDeletedMarkerBody = 'sys:chat-deleted';

/// True when a stored message body is the [WireKind.chatDeleted] marker.
bool isChatDeletedMarker(String body) => body == kChatDeletedMarkerBody;

/// Prefix of the LOCAL marker a disappearing-window change leaves in the chat,
/// followed by the new window in seconds (`0` = off).
///
/// The value is carried IN the marker rather than looked up when the row is
/// drawn, because the row has to keep saying what it said at the time: a chat
/// that went 1 hour → off → 1 hour must read as three events, not as three
/// copies of whatever the setting happens to be now.
const kDisappearingMarkerPrefix = 'sys:disappearing:';

/// Both halves of the policy a disappearing marker announces.
///
/// `ttlSeconds == 0` means the sender turned the post-time window off.
/// [hideAfterReadSeconds] is non-null when messages are also hidden that long
/// after this device first SHOWED them, which is a different clock and a
/// different promise.
typedef DisappearingMarker = ({int ttlSeconds, int? hideAfterReadSeconds});

/// The policy a disappearing marker announces, or null when [body] is not one.
///
/// The marker used to carry the TTL alone, and the read-window was simply lost
/// on the way to the screen: a setting of "hide 30 minutes after reading, no
/// post-time window" stored `…:0` and rendered as "Disappearing messages
/// turned off" — a false statement about a privacy setting that was ON. That
/// state is reachable from the wire, since an announcement may carry `ttl = 0`
/// with a read-window.
///
/// `<ttl>:r<seconds>` extends the old `<ttl>` rather than replacing it, so a
/// marker without a read-window is byte-identical to what was written before.
/// A build older than this one parses the extended form as "not a marker" and
/// would print the raw token, which is why the read-window is only ever
/// appended when there IS one — the older build cannot represent that setting
/// anyway.
DisappearingMarker? disappearingMarker(String body) {
  if (!body.startsWith(kDisappearingMarkerPrefix)) return null;
  final rest = body.substring(kDisappearingMarkerPrefix.length);
  final at = rest.indexOf(':r');
  if (at < 0) {
    final ttl = int.tryParse(rest);
    return ttl == null ? null : (ttlSeconds: ttl, hideAfterReadSeconds: null);
  }
  final ttl = int.tryParse(rest.substring(0, at));
  final read = int.tryParse(rest.substring(at + 2));
  if (ttl == null || read == null || read <= 0) return null;
  return (ttlSeconds: ttl, hideAfterReadSeconds: read);
}

/// The post-time window a disappearing marker announces, or null when [body] is
/// not one. `0` means the sender turned the window off.
///
/// Callers use a non-null answer as "this row is a system marker", so it must
/// stay non-null for the extended form too or those rows would be rendered as
/// ordinary messages — showing the token itself to the user.
int? disappearingMarkerSeconds(String body) =>
    disappearingMarker(body)?.ttlSeconds;

/// The loopback dev transport echoes every wire frame back prefixed with this,
/// so `↩︎ echo: {"t":..}` bodies land in the log. Echoes of CONTROL frames
/// (accept/sync/ack/…) are pure noise; only echoes of user content
/// ([WireKind.message] / [WireKind.fileMeta]) are the visible loopback copy.
const String _echoPrefix = '↩︎ echo:';

/// True when [body] is a loopback echo of a NON-content wire frame — noise that
/// must not appear as a chat message, a list preview, or an unread count.
/// Whitelist by inner `t`: an echo of `message`/`fileMeta` is real content and
/// returns false; every other echoed kind (and any malformed echo) is service
/// noise and returns true. A non-echo body always returns false.
bool isServiceEchoBody(String body) {
  final text = body.trimLeft();
  if (!text.startsWith(_echoPrefix)) return false;
  try {
    final decoded = jsonDecode(text.substring(_echoPrefix.length).trimLeft());
    if (decoded is! Map) return true;
    final t = decoded['t'];
    return t != WireKind.message.index &&
        t != WireKind.fileMeta.index &&
        t != WireKind.spaceRecommendation.index;
  } catch (_) {
    return true; // an echo we can't parse is not user content
  }
}

/// Typed wrapper over the raw transport payload, so the receiver can tell a
/// connection request from a chat message (the consent gate). Serialised as
/// compact JSON `{"t": <kind index>, "b": <body>, "i": <message id?>}`.
///
/// [id] (when set) is the sender's message id — it travels so the receiver can
/// **dedup** re-sent messages (the local outbox re-sends un-acked ones) and the
/// receiver can **ack** by referencing it.
class WireEnvelope {
  const WireEnvelope(
    this.kind,
    this.body, {
    this.id,
    this.sentAtMs,
    this.seq,
    this.replyTo,
    this.forwardedFrom,
    this.frameId,
    this.customEmoji = const [],
  });

  final WireKind kind;
  final String body;
  final String? id;

  /// For a [WireKind.message]: the id of the message this one REPLIES to (the
  /// quoted message). Ids already travel for dedup/ack, so the reference
  /// resolves identically on both sides. Optional JSON key — an older decoder
  /// simply ignores it (the message renders un-quoted), so no version bump.
  final String? replyTo;

  /// For a [WireKind.message]: display label of whom this message was
  /// FORWARDED from (free text, never a node id — see Message.forwardedFrom).
  /// Optional key ('fw'); older decoders ignore it.
  final String? forwardedFrom;

  /// Durable-outbox frame id ('fid'), present on frames sent via the durable
  /// pipeline. The receiver echoes it in a [WireKind.ack] so the sender can
  /// retire the frame from its persistent outbox, and dedups re-deliveries by
  /// it. Optional — older decoders ignore it.
  final String? frameId;
  final List<InlineCustomEmoji> customEmoji;

  /// The SENDER's send time (Unix ms). Travels so the receiver orders messages
  /// by when they were SENT, not when they happened to arrive — the live /
  /// mailbox / outbox-retry paths deliver with variable latency + reordering, so
  /// receive-order display scrambles a conversation. Null from older senders →
  /// the receiver falls back to its receive time.
  final int? sentAtMs;

  /// The SENDER's per-(conversation, author) event seq for this message/edit
  /// (event-log §15, R4). Travels so the receiver folds the event under the
  /// SAME (author, seq) the sender used — making the log convergent across
  /// devices and letting the receiver detect gaps (a missing seq) for gap-fill.
  /// Null from an older sender → the receiver allocates one locally (no gap
  /// detection for that peer until it upgrades).
  final int? seq;

  const WireEnvelope.request(String greeting, {String? id, int? sentAtMs})
    : this(WireKind.request, greeting, id: id, sentAtMs: sentAtMs);
  const WireEnvelope.accept() : this(WireKind.accept, '');
  const WireEnvelope.message(
    String text, {
    String? id,
    int? sentAtMs,
    int? seq,
    String? replyTo,
    String? forwardedFrom,
    List<InlineCustomEmoji> customEmoji = const [],
  }) : this(
         WireKind.message,
         text,
         id: id,
         sentAtMs: sentAtMs,
         seq: seq,
         replyTo: replyTo,
         forwardedFrom: forwardedFrom,
         customEmoji: customEmoji,
       );
  const WireEnvelope.ack(String id) : this(WireKind.ack, '', id: id);
  const WireEnvelope.edit(
    String id,
    String newText, {
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
  }) : this(WireKind.edit, newText, id: id, seq: seq, customEmoji: customEmoji);
  const WireEnvelope.del(String id, {int? seq})
    : this(WireKind.del, '', id: id, seq: seq);

  /// Event-log gap-fill beacon (§15, 3c): [body] is the JSON sync summary
  /// `{hw:{author:hw}, holes:{author:[[lo,hi]]}, ep:epoch}`.
  const WireEnvelope.sync(String body) : this(WireKind.sync, body);

  /// Inert seq placeholder (R-VOID): advances the peer's high-water past a
  /// deleted/superseded slot at [seq] with NO id/body (§12.1 — no oracle).
  const WireEnvelope.voidSeq(int seq) : this(WireKind.voidSeq, '', seq: seq);

  /// Clear-conversation event: [body] is the JSON watermark map `{authorHex: hw}`
  /// captured at clear time; [seq] is the clearing author's seq for this clear
  /// event. Carries NO cleared message id or text — only the per-author
  /// watermark (no oracle). v:2, so an un-upgraded peer drops it (RULE WC).
  const WireEnvelope.clear(String watermarkJson, {int? seq})
    : this(WireKind.clear, watermarkJson, seq: seq);

  /// "We were connected — please re-establish" (body = optional greeting). Sent
  /// when a message stays un-acked past a threshold; the receiver re-intros it if
  /// it no longer holds us as a contact (recovery handshake, §15.7).
  const WireEnvelope.reconnect(String greeting)
    : this(WireKind.reconnect, greeting);

  /// Opt-in attestation request: [id] is the message id to attest, [body] is
  /// the exact text the requester wants the author to sign (so the author can
  /// review it before consenting).
  const WireEnvelope.signRequest(String msgId, String body)
    : this(WireKind.signRequest, body, id: msgId);

  /// Attestation response: [body] is JSON `{mid, sig, pk}` (base64 sig+pubkey)
  /// when signed, or `{mid, refused:true}` when the author declined.
  const WireEnvelope.signResponse(String bodyJson)
    : this(WireKind.signResponse, bodyJson);

  /// Call control-plane frame: [body] is the `CallSignal` JSON (see
  /// lib/domain/call_signal.dart). Reliable/acked frames (ring/accept/reject/
  /// end) go via the durable pipeline; low-latency ones (transportInfo) may go
  /// via the plain live send.
  const WireEnvelope.callSignal(String bodyJson)
    : this(WireKind.callSignal, bodyJson);

  /// React to message [targetMsgId] with [emoji] (empty = remove the
  /// reaction). [sentAtMs] orders the reactor's own successive reactions:
  /// mailbox blobs are unordered by design, so without it a late-arriving
  /// older frame would resurrect a reaction the peer already removed.
  const WireEnvelope.reaction(String targetMsgId, String emoji, {int? sentAtMs})
    : this(WireKind.reaction, emoji, id: targetMsgId, sentAtMs: sentAtMs);

  /// A group snapshot ([bodyJson] = the bundle {m, c, g}) for the receiver to
  /// ingest. Delivered durably to each member (direct fanout, v1).
  const WireEnvelope.groupEntry(String bodyJson)
    : this(WireKind.groupEntry, bodyJson);

  /// One chunk of an oversized group snapshot — see [WireKind.groupEntryChunk].
  const WireEnvelope.groupEntryChunk(String bodyJson)
    : this(WireKind.groupEntryChunk, bodyJson);

  /// A signed group content-fetch request — see [WireKind.groupContentRequest].
  const WireEnvelope.groupContentRequest(String requestJson)
    : this(WireKind.groupContentRequest, requestJson);

  /// A live-only verified-store receipt — see [WireKind.groupContentReceipt].
  const WireEnvelope.groupContentReceipt(String receiptJson)
    : this(WireKind.groupContentReceipt, receiptJson);

  const WireEnvelope.spacePublicFeedRequest(String requestJson)
    : this(WireKind.spacePublicFeedRequest, requestJson);

  const WireEnvelope.spacePublicFeedChunk(String chunkJson)
    : this(WireKind.spacePublicFeedChunk, chunkJson);

  const WireEnvelope.spacePublicMediaGrantRequest(String requestJson)
    : this(WireKind.spacePublicMediaGrantRequest, requestJson);

  const WireEnvelope.groupCallSignal(String frameJson, {int? sentAtMs})
    : this(WireKind.groupCallSignal, frameJson, sentAtMs: sentAtMs);

  const WireEnvelope.cloudDocument(String frameJson)
    : this(WireKind.cloudDocument, frameJson);

  const WireEnvelope.cloudDocumentChunk(String bodyJson)
    : this(WireKind.cloudDocumentChunk, bodyJson);

  /// P2P direct-endpoint exchange frame — see [WireKind.p2pEndpoints].
  const WireEnvelope.p2pEndpoints(String bodyJson)
    : this(WireKind.p2pEndpoints, bodyJson);

  /// "What models have you got?" — see [WireKind.modelInventoryRequest]. The
  /// body is empty: the question has no parameters, and a version field would
  /// only invite a sender to put something in it.
  const WireEnvelope.modelInventoryRequest()
    : this(WireKind.modelInventoryRequest, '');

  /// The answer — see [WireKind.modelInventoryOffer].
  const WireEnvelope.modelInventoryOffer(String bodyJson)
    : this(WireKind.modelInventoryOffer, bodyJson);

  const WireEnvelope.spaceInvite(String bodyJson)
    : this(WireKind.spaceInvite, bodyJson);

  const WireEnvelope.spaceInviteDecision(String bodyJson)
    : this(WireKind.spaceInviteDecision, bodyJson);

  const WireEnvelope.spaceJoinRequest(String bodyJson)
    : this(WireKind.spaceJoinRequest, bodyJson);

  const WireEnvelope.spaceJoinDecision(String bodyJson)
    : this(WireKind.spaceJoinDecision, bodyJson);

  const WireEnvelope.spaceModerationAppeal(String bodyJson)
    : this(WireKind.spaceModerationAppeal, bodyJson);

  const WireEnvelope.spaceModerationAppealDecision(String bodyJson)
    : this(WireKind.spaceModerationAppealDecision, bodyJson);

  const WireEnvelope.spaceAbuseReport(String bodyJson)
    : this(WireKind.spaceAbuseReport, bodyJson);

  const WireEnvelope.spaceAbuseReportDecision(String bodyJson)
    : this(WireKind.spaceAbuseReportDecision, bodyJson);

  WireEnvelope.spaceRecommendation(
    SpaceRecommendationCard card, {
    String? id,
    int? sentAtMs,
    int? seq,
  }) : this(
         WireKind.spaceRecommendation,
         jsonEncode(card.toJson()),
         id: id,
         sentAtMs: sentAtMs,
         seq: seq,
       );

  /// The decode-only sentinel for a structured (v:2) frame whose kind this build
  /// does not know — the dispatcher drops it (RULE WC).
  static const unknown = WireEnvelope(WireKind.unknown, '');

  /// Frames from [WireKind.sync] onward carry a `v:2` structural marker so an
  /// un-upgraded decoder DROPS them (RULE WC) instead of mis-rendering as chat.
  bool get _isV2 => kind.index >= WireKind.sync.index;

  /// A copy carrying [fid] as its durable-outbox [frameId] (the id the receiver
  /// echoes in its ack). Used by the durable send pipeline.
  WireEnvelope withFrameId(String fid) => WireEnvelope(
    kind,
    body,
    id: id,
    sentAtMs: sentAtMs,
    seq: seq,
    replyTo: replyTo,
    forwardedFrom: forwardedFrom,
    frameId: fid,
    customEmoji: customEmoji,
  );

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        't': kind.index,
        'b': body,
        if (id != null) 'i': id,
        if (sentAtMs != null) 's': sentAtMs,
        if (seq != null) 'q': seq,
        if (replyTo != null) 'r': replyTo,
        if (forwardedFrom != null) 'fw': forwardedFrom,
        if (frameId != null) 'fid': frameId,
        if (customEmoji.isNotEmpty) 'ce': encodeInlineCustomEmoji(customEmoji),
        if (_isV2) 'v': 2,
      }),
    ),
  );

  /// Decode a payload. A well-formed frame whose `t` this build KNOWS decodes to
  /// that kind. A structured `v:2` frame from a NEWER build (a `t` out of range,
  /// or the [WireKind.unknown] sentinel index) decodes to [unknown] so the
  /// dispatcher drops it — it is NEVER mis-rendered as chat text (RULE WC). Any
  /// other unrecognised payload (legacy, non-JSON) falls back to a plain
  /// [WireKind.message] (forward/back compatibility, unchanged).
  static WireEnvelope decode(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map && decoded['t'] is int && decoded['b'] is String) {
        final t = decoded['t'] as int;
        // A known, real kind (never the unknown sentinel itself) — decode it.
        if (t >= 0 &&
            t < WireKind.values.length &&
            WireKind.values[t] != WireKind.unknown) {
          final body = decoded['b'] as String;
          return WireEnvelope(
            WireKind.values[t],
            body,
            id: decoded['i'] is String ? decoded['i'] as String : null,
            sentAtMs: decoded['s'] is int ? decoded['s'] as int : null,
            seq: decoded['q'] is int ? decoded['q'] as int : null,
            replyTo: decoded['r'] is String ? decoded['r'] as String : null,
            forwardedFrom: decoded['fw'] is String
                ? decoded['fw'] as String
                : null,
            frameId: decoded['fid'] is String ? decoded['fid'] as String : null,
            customEmoji: parseInlineCustomEmoji(body, decoded['ce']),
          );
        }
        // Out of this build's range. A structured v:2 frame (a kind a newer build
        // added) MUST be dropped, never shown as chat (RULE WC); a non-v2 unknown
        // t is legacy garble → fall through to the plain-message fallback.
        if (decoded['v'] == 2) return unknown;
      }
    } catch (_) {
      // fall through to plain-message fallback
    }
    return WireEnvelope(
      WireKind.message,
      utf8.decode(bytes, allowMalformed: true),
    );
  }
}

/// Parsed body of a [WireKind.fileMeta] frame: the start of a file transfer.
/// [seq] is the SENDER's event seq for the file message (filePost, §15) — it
/// travels so the receiver folds the file under the same (author, seq) and
/// gap-fill can detect/heal a missing file. [sentAtMs] is the file message's
/// send-time, carried so it folds under the SENDER's time (like a text message's
/// `s`) — otherwise the receiver would stamp its receive time and the convergent
/// (effective_ts, author, seq) display order would diverge across devices. Both
/// null from an older sender.
typedef FileMetaFrame = ({
  String transferId,
  String? name,
  int? size,
  int? count,
  int? seq,
  int? sentAtMs,
});

/// Parsed body of a [WireKind.fileChunk] frame: one piece of a transfer.
typedef FileChunkFrame = ({
  String transferId,
  int index,
  int total,
  Uint8List data,
});

/// The file-transfer frame wire format (key names, base64 of chunk bytes)
/// lives here as the single source of truth, so the send and receive sides
/// cannot drift apart. [parseFileMeta]/[parseFileChunk] throw on a body that
/// is missing a required field or has the wrong type — the caller is expected
/// to drop such (hostile/corrupt) datagrams.
WireEnvelope fileMetaEnvelope({
  required String transferId,
  String? name,
  int? size,
  int? count,
  int? seq,
  int? sentAtMs,
}) => WireEnvelope(
  WireKind.fileMeta,
  jsonEncode({
    'tid': transferId,
    'name': ?name,
    'size': ?size,
    'count': ?count,
    'seq': ?seq,
    's': ?sentAtMs,
  }),
);

FileMetaFrame parseFileMeta(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    transferId: j['tid'] as String,
    name: j['name'] as String?,
    size: j['size'] is int ? j['size'] as int : null,
    count: j['count'] is int ? j['count'] as int : null,
    seq: j['seq'] is int ? j['seq'] as int : null,
    sentAtMs: j['s'] is int ? j['s'] as int : null,
  );
}

// ── Content layer (decentralized, hash-verified file transfer §CONTENT) ──────

/// Advertise a content manifest (the "torrent file"). [manifestJson] is
/// [ContentManifest.toJson]'d — it carries the self-authenticating contentId, so
/// the receiver verifies it on arrival and then requests pieces. Sized to fit
/// one datagram (adaptive piece size keeps the manifest small).
WireEnvelope contentManifestEnvelope(String manifestJson) =>
    WireEnvelope(WireKind.contentManifest, manifestJson);

/// Advertise a holder only inside an already-authorized group content pull.
/// The body uses the same full-manifest/compact-ref representation as
/// [contentManifestEnvelope], while the distinct kind keeps it out of the
/// direct-chat file-offer and automatic-download path.
WireEnvelope groupContentManifestEnvelope(String manifestJson) =>
    WireEnvelope(WireKind.groupContentManifest, manifestJson);

/// Ask the sender to RE-ADVERTISE [contentId]'s manifest — the receiver has the
/// OFFER (synced via the event log) but lost the in-memory manifest handle (app
/// restart / the one-shot manifest was never re-sent). The sender re-sends its
/// manifest iff it is still serving that content.
WireEnvelope contentReofferEnvelope(String contentId) =>
    WireEnvelope(WireKind.contentReoffer, contentId);

/// The honest NEGATIVE reply to [contentReofferEnvelope]: this peer no longer
/// HAS [contentId] (the file message was deleted / the source file vanished
/// and no stored blob remains) — the receiver should stop retrying against
/// this peer and, once no other holder is known, tell the user to ask for a
/// re-send. Sent only on an explicit reoffer request, so it leaks nothing a
/// serve attempt wouldn't (offline-vs-wiped stays ambiguous for silence; this
/// is an EXPLICIT statement by a peer that chose to answer).
WireEnvelope contentGoneEnvelope(String contentId) =>
    WireEnvelope(WireKind.contentGone, contentId);

/// Request content the receiver lacks. Two granularities, both optional:
///   `idx:[pieces]`  — whole pieces (absent ⇒ "all pieces"); used for the FIRST
///                     request and as a coarse fallback.
///   `bm:{p:base64}` — per-piece MISSING-CHUNK bitmaps; the sender serves only
///                     the chunks whose bit is set. This is the chunk-granular
///                     re-request that lets a transfer converge over a lossy path
///                     (each round re-sends only the gaps, not whole pieces).
/// When `bm` is present it takes precedence; `idx` is ignored for those pieces.
typedef PieceRequestFrame = ({
  String contentId,
  List<int>? indices,
  Map<int, Uint8List>? bitmaps,
});

WireEnvelope pieceRequestEnvelope({
  required String contentId,
  List<int>? indices,
  Map<int, Uint8List>? bitmaps,
}) => WireEnvelope(
  WireKind.pieceRequest,
  jsonEncode({
    'cid': contentId,
    'idx': ?indices,
    if (bitmaps != null && bitmaps.isNotEmpty)
      'bm': {
        for (final e in bitmaps.entries)
          e.key.toString(): base64.encode(e.value),
      },
  }),
);

PieceRequestFrame parsePieceRequest(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  final idx = j['idx'];
  final bm = j['bm'];
  Map<int, Uint8List>? bitmaps;
  if (bm is Map) {
    bitmaps = {
      for (final e in bm.entries)
        if (e.value is String && int.tryParse('${e.key}') != null)
          int.parse('${e.key}'): base64.decode(e.value as String),
    };
  }
  return (
    contentId: j['cid'] as String,
    indices: idx is List ? idx.whereType<int>().toList() : null,
    bitmaps: bitmaps,
  );
}

/// One wire chunk of one PIECE: body `{cid, p:pieceIdx, c:chunkIdx, n:chunkCount,
/// d:base64}`. A piece is split into chunks small enough to fit the auth_deliver
/// cap; the receiver reassembles a piece from its chunks, then verifies the
/// piece against the manifest hash and re-requests on failure.
typedef PieceChunkFrame = ({
  String contentId,
  int pieceIndex,
  int chunkIndex,
  int chunkCount,
  Uint8List data,
});

WireEnvelope pieceChunkEnvelope({
  required String contentId,
  required int pieceIndex,
  required int chunkIndex,
  required int chunkCount,
  required Uint8List data,
}) => WireEnvelope(
  WireKind.pieceChunk,
  jsonEncode({
    'cid': contentId,
    'p': pieceIndex,
    'c': chunkIndex,
    'n': chunkCount,
    'd': base64.encode(data),
  }),
);

PieceChunkFrame parsePieceChunk(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    contentId: j['cid'] as String,
    pieceIndex: j['p'] as int,
    chunkIndex: j['c'] as int,
    chunkCount: j['n'] as int,
    data: base64.decode(j['d'] as String),
  );
}

/// A gap-fill RE-SHIP PROBE for a file (§15 3c, resumable). Same body shape as
/// [fileMetaEnvelope] (so the receiver parses it with [parseFileMeta]) but with
/// NO chunks following — carries the seq + send-time so the receiver can fold the
/// completed file convergently. The receiver replies with [fileNackEnvelope].
WireEnvelope fileQueryEnvelope({
  required String transferId,
  String? name,
  int? seq,
  int? sentAtMs,
}) => WireEnvelope(
  WireKind.fileQuery,
  jsonEncode({'tid': transferId, 'name': ?name, 'seq': ?seq, 's': ?sentAtMs}),
);

/// Parsed body of a [WireKind.fileNack]: which chunks of [transferId] the
/// receiver still needs. [missing] == null means "send me ALL of them" — a
/// receiver that holds no chunk yet (so cannot enumerate the gaps).
typedef FileNackFrame = ({String transferId, List<int>? missing});

/// The receiver's reply listing the chunks it still needs (or null = all).
WireEnvelope fileNackEnvelope({
  required String transferId,
  required List<int>? missing,
}) => WireEnvelope(
  WireKind.fileNack,
  jsonEncode({'tid': transferId, 'm': ?missing}),
);

FileNackFrame parseFileNack(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  final m = j['m'];
  return (
    transferId: j['tid'] as String,
    missing: m is List ? m.whereType<int>().toList() : null,
  );
}

WireEnvelope fileChunkEnvelope({
  required String transferId,
  required int index,
  required int total,
  required Uint8List data,
}) => WireEnvelope(
  WireKind.fileChunk,
  jsonEncode({
    'tid': transferId,
    'i': index,
    'total': total,
    'd': base64.encode(data),
  }),
);

FileChunkFrame parseFileChunk(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    transferId: j['tid'] as String,
    index: j['i'] as int,
    total: j['total'] as int,
    data: base64.decode(j['d'] as String),
  );
}

// ── Group snapshot chunking (groups media over the wire) ─────────────────────

/// Parsed body of a [WireKind.groupEntryChunk]: one [data] slice (index
/// [index] of [count]) of the group bundle JSON identified by [transferId].
typedef GroupEntryChunkFrame = ({
  String transferId,
  int index,
  int count,
  Uint8List data,
});

/// One chunk of an oversized group snapshot: body `{tid, i, n, d:base64}`. The
/// bundle's UTF-8 bytes are split so each chunk frame fits under the
/// auth_deliver cap; the receiver reassembles [count] chunks by [transferId],
/// concatenates the bytes, and ingests the joined bundle like a whole snapshot.
WireEnvelope groupEntryChunkEnvelope({
  required String transferId,
  required int index,
  required int count,
  required Uint8List data,
}) => WireEnvelope.groupEntryChunk(
  jsonEncode({
    'tid': transferId,
    'i': index,
    'n': count,
    'd': base64.encode(data),
  }),
);

GroupEntryChunkFrame parseGroupEntryChunk(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return (
    transferId: j['tid'] as String,
    index: j['i'] as int,
    count: j['n'] as int,
    data: base64.decode(j['d'] as String),
  );
}

/// Document chunks use the same bounded `{tid,i,n,d}` representation as group
/// snapshots, but a distinct wire kind keeps the authorization paths separate.
WireEnvelope cloudDocumentChunkEnvelope({
  required String transferId,
  required int index,
  required int count,
  required Uint8List data,
}) => WireEnvelope.cloudDocumentChunk(
  jsonEncode({
    'tid': transferId,
    'i': index,
    'n': count,
    'd': base64.encode(data),
  }),
);
