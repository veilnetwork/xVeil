import '../core/ids.dart';
import 'inline_custom_emoji.dart';
import 'p2p_policy.dart';

/// Relationship state with a peer — gates messaging so strangers can't write
/// without consent.
/// - [pendingOutgoing]: we sent a connection request, awaiting their approval.
/// - [pendingIncoming]: they requested us; we can accept / decline / block.
/// - [accepted]: mutual — free messaging.
/// - [blocked]: their messages are dropped.
enum ContactStatus { pendingOutgoing, pendingIncoming, accepted, blocked }

/// Sentinel "muted forever" instant for [Contact.mutedUntil] — far enough out
/// that it never expires in practice, and encodable as a plain ms-epoch.
final DateTime kMuteForever = DateTime.utc(9999);

/// Device-local delivery policy while a notification mute window is active.
/// [mentionsOnly] suppresses ordinary messages but still alerts when the
/// canonical mention token targets our node id; [none] suppresses everything.
enum NotificationMuteMode { all, mentionsOnly, none }

class NotificationMutePolicy {
  const NotificationMutePolicy({required this.mode, this.until});

  const NotificationMutePolicy.all()
    : mode = NotificationMuteMode.all,
      until = null;

  final NotificationMuteMode mode;
  final DateTime? until;

  bool activeAt(DateTime now) =>
      mode != NotificationMuteMode.all && until != null && now.isBefore(until!);

  NotificationMuteMode effectiveAt(DateTime now) =>
      activeAt(now) ? mode : NotificationMuteMode.all;
}

/// A remote party the user can message.
class Contact {
  const Contact({
    required this.nodeId,
    this.name,
    this.status = ContactStatus.accepted,
    this.mutedUntil,
    this.notificationMuteMode = NotificationMuteMode.none,
    this.pinned = false,
    this.archived = false,
    this.retentionDays,
    this.disappearingTtlSeconds,
    this.disappearingSetAtMs = 0,
    this.disappearingSetBy = '',
    this.allowPeerDelete = true,
    this.p2pOverride = kDefaultContactP2POverride,
  });

  final NodeId nodeId;
  final String? name;
  final ContactStatus status;

  /// Local notification-mute deadline for this conversation: null = not muted,
  /// [kMuteForever] = muted until manually unmuted, anything else = timed mute
  /// that silently expires when the instant passes (no unmute event needed —
  /// [muted] is computed against the clock). Stored in the encrypted contact
  /// record (never on the wire) — a per-peer flag is low-sensitivity but still
  /// belongs in the deniable store, not plaintext prefs (a muted-peer list
  /// would otherwise leak the contact set on a seized device).
  final DateTime? mutedUntil;

  /// What remains deliverable during [mutedUntil]. Old records had only a
  /// boolean/deadline and therefore decode as [NotificationMuteMode.none].
  final NotificationMuteMode notificationMuteMode;

  /// Whether notifications are muted RIGHT NOW (mute deadline in the future).
  bool get muted => mutedUntil != null && DateTime.now().isBefore(mutedUntil!);

  NotificationMuteMode notificationModeAt(DateTime now) =>
      NotificationMutePolicy(
        mode: notificationMuteMode,
        until: mutedUntil,
      ).effectiveAt(now);

  /// Local archive flag — archived conversations collapse into a separate
  /// section at the bottom of the chat list. Encrypted + local-only, same
  /// rationale as [mutedUntil].
  final bool archived;

  /// Local pin — pinned conversations sort to the top of the list. Encrypted
  /// + local-only, same rationale as [muted].
  final bool pinned;

  /// Whether THIS peer is allowed to delete-for-everyone (or clear) messages in
  /// OUR local copy of the conversation. Default true = the existing behavior (a
  /// peer's unsend/clear removes our copy too). When false, an incoming
  /// delete-for-everyone / clear from this peer is DECLINED — our copies stay,
  /// and we keep a local tombstone-block so a re-delivered delete never removes
  /// them either. Encrypted + local-only (a receiver-side policy — the peer is
  /// never told whether it was honored, matching the no-oracle model).
  final bool allowPeerDelete;

  /// Whether direct P2P transport is allowed for this peer on THIS device.
  /// Local-only and encrypted. It gates location-revealing direct paths for
  /// calls, large media/file transfer, and future device-to-device sync.
  final ContactP2POverride p2pOverride;

  /// Per-conversation message-retention window in DAYS, or null for unlimited
  /// (the default — never auto-delete). When set, a compaction pass forensically
  /// deletes messages whose ORIGINAL post time is older than this many days
  /// (edits do not refresh the clock — the original send time governs). Encrypted
  /// + local-only, same store rationale as [muted].
  final int? retentionDays;

  /// Shared disappearing-message window in SECONDS, or null for off.
  ///
  /// Unlike [retentionDays] this is not a private housekeeping preference: it
  /// is announced to the peer and an announcement from the peer applies here,
  /// because a window only one side honours is not a promise. See
  /// `domain/disappearing_messages.dart` for the arithmetic and the rule that
  /// decides which of two simultaneous announcements a conversation keeps.
  final int? disappearingTtlSeconds;

  /// When the held disappearing setting was made (ms since epoch), and by
  /// whose node id. Stored because the SETTING has to converge on both
  /// devices, not just be applied — see `DisappearingSetting.winner`.
  final int disappearingSetAtMs;
  final String disappearingSetBy;

  String get label => name ?? nodeId.short;

  /// Free messaging is only allowed once the relationship is accepted.
  bool get canMessage => status == ContactStatus.accepted;

  static const Object _unset = Object();

  Contact copyWith({
    String? name,
    ContactStatus? status,
    // Nullable-field update: distinguish "leave as is" (omitted) from
    // "clear the mute" (explicit null) via a sentinel default.
    Object? mutedUntil = _unset,
    NotificationMuteMode? notificationMuteMode,
    bool? pinned,
    bool? archived,
    int? retentionDays,
    // Nullable-field update, same sentinel reason as [mutedUntil]: turning
    // disappearing messages OFF is an explicit null, not an omission.
    Object? disappearingTtlSeconds = _unset,
    int? disappearingSetAtMs,
    String? disappearingSetBy,
    bool? allowPeerDelete,
    ContactP2POverride? p2pOverride,
  }) => Contact(
    nodeId: nodeId,
    name: name ?? this.name,
    status: status ?? this.status,
    mutedUntil: identical(mutedUntil, _unset)
        ? this.mutedUntil
        : mutedUntil as DateTime?,
    notificationMuteMode: notificationMuteMode ?? this.notificationMuteMode,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
    retentionDays: retentionDays ?? this.retentionDays,
    disappearingTtlSeconds: identical(disappearingTtlSeconds, _unset)
        ? this.disappearingTtlSeconds
        : disappearingTtlSeconds as int?,
    disappearingSetAtMs: disappearingSetAtMs ?? this.disappearingSetAtMs,
    disappearingSetBy: disappearingSetBy ?? this.disappearingSetBy,
    allowPeerDelete: allowPeerDelete ?? this.allowPeerDelete,
    p2pOverride: p2pOverride ?? this.p2pOverride,
  );
}

/// Direction of a message relative to the local user.
enum MessageDirection { outgoing, incoming }

/// Delivery state of an outgoing message.
///
/// Maps onto the transport lifecycle: queued locally → handed to the node →
/// delivered to peer (or stored in their mailbox) → failed.
enum MessageStatus { sending, sent, delivered, failed }

/// State of an opt-in authorship attestation for one message (the "request the
/// sender to sign" feature). Deniable-by-default: a message is [none] unless a
/// signature was explicitly requested. On the REQUESTER's incoming message:
/// [requested] → asked, waiting; [verified] → author signed and the signature
/// checks out; [refused] → author declined; [failed] → a response arrived but
/// the signature did not verify (tampered / wrong key). Never set on the
/// author's own outgoing copy.
enum MessageSignature { none, requested, verified, refused, failed }

/// How this device answers an incoming "please sign this message" request from a
/// peer (the author side of the attestation feature). [ask] prompts each time
/// (default); [auto] signs silently; [refuse] declines every request. A pure
/// author-side choice — it never affects our ability to REQUEST signatures.
enum SignaturePolicy { ask, auto, refuse }

/// How far ahead of the RECEIVING device's own clock a message may claim to
/// have been sent and still be stored at its own word.
///
/// Five minutes is the tolerance the rest of the project already applies to a
/// stranger's stamp (`kSpacePublicClockSkew`, and `kDeviceSyncClockSkew` after
/// it) — one skew convention here, not a third one.
const Duration kMessageClockSkew = Duration(minutes: 5);

/// The timestamp a message claiming [claimedMs] is STORED under when it is
/// received at [nowMs]: its own word, unless that word is further ahead than
/// [kMessageClockSkew], in which case the moment of receipt.
///
/// A message's display time is the sender's send time, because that is what
/// makes the conversation read in send order on every device the owner has.
/// Nothing authenticates that number — no signature makes a clock honest, and
/// there is no time authority in this network — so a sender (or a compromised
/// linked device re-mirroring one) can stamp itself years ahead. Such a row
/// then owns the bottom of the chat, the conversation-list preview, and the
/// top of the chat list for as long as that stamp lasts. Worse, `markRead`
/// takes the conversation's newest timestamp as the read watermark and
/// `setReadMarker` only ever moves forward, so ONE such row silently retires
/// the unread badge for that conversation until the future arrives.
///
/// The rule is deliberately NOT the deferral used for device-sync events
/// (`deviceSyncEffectiveAt`). That one exists to keep a fold CONVERGENT: a
/// deferred row must be able to win its key later, so it may not be rewritten.
/// A message wins nothing — it is deduplicated by id and suppresses no other
/// row — so there is no convergence to protect, only an order to display, and
/// the simplest honest answer for an unusable number is the one fact the
/// receiver actually knows: when it arrived.
///
/// Applied ONCE, where the value enters storage, and the result is what is
/// persisted. Computing it on every read would move the row every time the
/// chat is opened; stamped once, it never moves again.
///
/// One-sided on purpose: a stamp in the PAST is left alone. A device offline
/// for a week receives a mirror of last Tuesday's message and must keep last
/// Tuesday. A past stamp cannot float above anything either — the
/// author-monotone effective-ts floor in `loadMessages` already raises it back
/// into its own author's causal place.
int messageTsOnReceipt(int claimedMs, int nowMs) =>
    claimedMs > nowMs + kMessageClockSkew.inMilliseconds ? nowMs : claimedMs;

/// The largest per-(conversation, author) event sequence this build accepts
/// from a peer.
///
/// A sequence is a slot in one author's stream inside one conversation, handed
/// out one at a time — every post, edit, void and tombstone takes exactly one.
/// Four billion of them is a message a second, without a pause, for over a
/// century, in a single conversation; no honest client comes near it, and
/// nothing in the format needs the room above.
const int kMaxWireSeq = 1 << 32;

/// Whether a sequence number that arrived from a peer may be used at all.
///
/// Null is "the sender did not say" (an older build) and stays allowed —
/// storage then allocates locally. Anything else must be a real slot within
/// [kMaxWireSeq]; watermarks may also be zero, meaning "nothing of this
/// author's".
///
/// Out of range the FRAME IS DROPPED, never clamped, and this is the whole
/// point of the function. A timestamp is a quantity we show, so pulling an
/// absurd one back to the moment of receipt loses nothing. A sequence is an
/// IDENTITY — which slot in whose stream — so folding two different numbers
/// onto one slot would merge two unrelated events, silently discard whichever
/// arrived second, and make the "have I already applied this?" checks in
/// `applyRemoteVoid` / `applyRemoteClear` answer yes for something they never
/// saw. Dropping costs nothing instead: the wire is best-effort by design, and
/// anything genuinely missing comes back through gap-fill.
bool isAcceptableWireSeq(int? seq) =>
    seq == null || (seq >= 0 && seq <= kMaxWireSeq);

class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.direction,
    required this.body,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.fileId,
    this.fileName,
    this.fileSize,
    this.fileContentId,
    this.fileExternal = false,
    this.thumb,
    this.edited = false,
    this.author,
    this.seq,
    this.replyToId,
    this.forwardedFrom,
    this.signature = MessageSignature.none,
    this.customEmoji = const [],
  });

  final String id;
  final String conversationId;
  final MessageDirection direction;
  final String body;
  final DateTime timestamp;
  final MessageStatus status;

  /// True once the body has been replaced via an edit. Surfaced in the UI as
  /// an "edited" marker; never reveals the prior text (which is scrubbed).
  final bool edited;

  /// When set, this message carries a stored file (see Storage.loadFile);
  /// [body] holds a human label and [fileName] the original name.
  final String? fileId;
  final String? fileName;

  /// Total size of the file in bytes — known from the OFFER descriptor BEFORE the
  /// blob is downloaded, so the receiver can show "name (size)" and decide whether
  /// to fetch (opt-in / anti-spam). Null for inline / legacy file messages.
  final int? fileSize;

  /// The content hash (manifest contentId) used to REQUEST the blob on demand.
  /// Set on a large file that was OFFERED but not yet downloaded; after download
  /// the blob lands under [fileId]. So `fileContentId != null && fileId == null`
  /// is the "offered, not downloaded" state. Null for small/inline files.
  final String? fileContentId;

  /// Micro-thumbnail of an IMAGE file message: base64 of a tiny PNG embedded in
  /// the message itself (travels in the manifest advert, budget-bound so the
  /// advert still fits one datagram). Renders instantly on the receiver BEFORE
  /// the blob is downloaded; null for non-images / older senders.
  final String? thumb;

  /// True for a LARGE file whose blob lives in the external encrypted blob store
  /// (the on-disk blob store, keyed by fileId) instead of the in-container
  /// FileStore — sent /
  /// received over a reliable veil stream. False (default) = small file in the
  /// deniable container. Drives which store loadFile / delete / gap-fill touch.
  final bool fileExternal;

  /// Event-log fields (doc/EVENT-LOG-SYNC-DESIGN.md §15). [author] is the node-id
  /// hex of the message's originator, bound from the authenticated sender on
  /// receive (R1) — NOT inferred from [direction]. [seq] is the per-(conversation,
  /// author) gap-free Lamport counter (R4/R5/R10) used for the deterministic
  /// cross-device fold + stable display order. Null on legacy rows written before
  /// the event-log foundation (they fold in the reserved legacy conv-slot).
  final String? author;
  final int? seq;

  /// The id of the message this one replies to, or null for a plain message.
  /// Message ids travel on the wire (dedup/ack already rely on that), so both
  /// sides hold the SAME id for the quoted message — the reference resolves
  /// identically on sender and receiver. Renders as a quoted block; a reference
  /// to a deleted/cleared message degrades to a generic "quoted message" stub.
  final String? replyToId;

  /// Display label of whom this message was FORWARDED from, or null for an
  /// original message. Free text (the forwarder's local alias for the source,
  /// or "you"), deliberately NOT a node id: attaching the source's routable
  /// identity to a forward would leak more than the user chose to share.
  /// Renders as a "Forwarded from X" caption on the bubble.
  final String? forwardedFrom;

  /// Opt-in authorship-attestation state (see [MessageSignature]).
  final MessageSignature signature;

  /// Small inline images anchored to ordinary `☺` fallback characters in
  /// [body]. Additive metadata: older clients ignore it and keep readable text.
  final List<InlineCustomEmoji> customEmoji;

  /// A file message — whether already downloaded ([fileId]) or merely OFFERED
  /// ([fileContentId], awaiting an opt-in download).
  bool get isFile => fileId != null || fileContentId != null;

  /// The blob is present locally (downloaded / stored), not just offered.
  bool get isDownloaded => fileId != null;

  Message copyWith({
    MessageStatus? status,
    String? body,
    bool? edited,
    String? fileId,
    MessageSignature? signature,
    List<InlineCustomEmoji>? customEmoji,
  }) => Message(
    id: id,
    conversationId: conversationId,
    direction: direction,
    body: body ?? this.body,
    timestamp: timestamp,
    status: status ?? this.status,
    fileId: fileId ?? this.fileId,
    fileName: fileName,
    fileSize: fileSize,
    fileContentId: fileContentId,
    fileExternal: fileExternal,
    thumb: thumb,
    edited: edited ?? this.edited,
    author: author,
    seq: seq,
    replyToId: replyToId,
    forwardedFrom: forwardedFrom,
    signature: signature ?? this.signature,
    customEmoji: customEmoji ?? this.customEmoji,
  );
}

/// One version of a message in its edit history (event-log §15): the original
/// post and each subsequent edit, with metadata. Surfaced by
/// [Storage.loadMessageHistory] for the "view edit history" UI. Held only until
/// a clear-history scrub / retention pass reclaims the superseded rows.
class MessageVersion {
  const MessageVersion({
    required this.body,
    required this.timestamp,
    required this.isOriginal,
    this.author,
    this.seq,
  });

  /// The text of this version.
  final String body;

  /// When this version was written (the post's send time, or the edit's time).
  final DateTime timestamp;

  /// True for the original post, false for an edit.
  final bool isOriginal;

  /// Node-id hex of the author of this version (R1).
  final String? author;

  /// The version's per-(conv,author) seq.
  final int? seq;
}

/// A 1:1 conversation. (Group chats are a later milestone.)
///
/// Identified by the peer node id hex so it is stable across restarts; it tags
/// entries in the SINGLE shared MESSAGE_LOG append-log (NOT a per-conversation
/// namespace partition — see doc/EVENT-LOG-SYNC-DESIGN.md §14.2).
class Conversation {
  const Conversation({required this.peer, this.lastMessage, this.unread = 0});

  final Contact peer;
  final Message? lastMessage;
  final int unread;

  String get id => peer.nodeId.hex;
}
