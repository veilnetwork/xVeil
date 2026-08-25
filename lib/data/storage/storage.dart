import 'dart:typed_data';

import 'kv_log_store.dart' show SlotUtilization;
import '../../core/ids.dart';
import '../../domain/call_log.dart';
import '../../domain/chat.dart';
import '../../domain/event.dart';
import '../../domain/identity.dart';
import '../../domain/inline_custom_emoji.dart';
import '../../domain/roster.dart';

/// Settings key recording HOW this space's node identity came to be:
/// `'phrase'` — derived from the onboarding recovery phrase (P2), so the
/// phrase restores it; `'mined'` — minted at random (extra identities, or
/// builds without the native generator). ABSENT on spaces provisioned before
/// the marker existed (legacy) — treat as "no phrase". Local metadata only;
/// it never leaves the deniable container.
const kIdentityOriginSetting = 'identity.origin';

/// Domain-oriented persistence port.
///
/// The production adapter is backed by `hidden-volume`: a [open] call unlocks
/// one space with the user's password; identity/settings map to KV
/// namespaces (SETTINGS, CONTACTS) and ALL conversations' messages go into a
/// SINGLE shared MESSAGE_LOG append-log, each entry tagged with its
/// conversation id (there is NO per-conversation namespace today — see
/// doc/EVENT-LOG-SYNC-DESIGN.md §14.2). Keeping the port domain-shaped (not
/// KV-shaped) means the UI never sees namespace bytes or commit sequencing.
abstract interface class Storage {
  /// Unlock (or create on first run) the user's space with [password].
  /// Returns false if the password does not unlock any space.
  Future<bool> open({required String password, bool createIfMissing = false});

  bool get isOpen;

  /// Open a child space directly from its [keys] (master mode) — no password.
  /// Returns false if the keys match no space, or keys-based open isn't
  /// configured. Mirrors [open] but via stored `SpaceKeys`.
  Future<bool> openWithKeys(Uint8List keys);

  /// Export this open space's opaque `SpaceKeys` (64 bytes) so a master roster
  /// can store it and later reopen this space without a password. **Sensitive**
  /// — never log; lives only inside a master space. Async because the backing
  /// store now runs off the UI isolate (worker), so the keys cross an isolate
  /// boundary.
  Future<Uint8List> exportSpaceKeys();

  /// Persist the parts of the owner a person chose. NOT the node id — that
  /// belongs to this space's node config and is derived from it (audit XV-06).
  /// Writing it here as well gave the container two answers to "who am I".
  ///
  /// Also the marker that says "this space belongs to an identity", which the
  /// clash guards read before writing a roster over it. Written when the space
  /// is created, even if the person named nothing yet.
  Future<void> saveProfile(UserProfile profile);

  /// This space's profile record.
  ///
  /// Three outcomes, and callers MUST keep them apart (audit XV-13):
  ///  * a [UserProfile] — the record is there and readable;
  ///  * `null` — there is NO record. A fresh or erased space.
  ///  * throws [CorruptIdentityRecord] — a record EXISTS but will not parse.
  ///
  /// The last one used to come back as `null` too, so "damaged" was handled as
  /// "empty": the app minted a random identity and looked healthy, and the
  /// "is this space free to write into?" checks (roster conversion, decoy
  /// master) read the same `null` as "nothing here" and would have overwritten
  /// the damaged record. Whatever a caller does on `null`, it must not do on a
  /// throw.
  Future<UserProfile?> loadProfile();

  Future<void> putSetting(String key, String value);
  Future<String?> getSetting(String key);

  /// Persist this identity's veil node config (TOML from `veil_config_init`,
  /// carrying the node keypair) INSIDE the deniable space — so the private key
  /// never lives in a plaintext `config.toml` on disk. Loaded at unlock to boot
  /// the embedded node via deferred-init + apply-config.
  Future<void> saveNodeConfig(String configToml);

  /// The stored node config for this identity, or null if none is saved yet.
  Future<String?> loadNodeConfig();

  /// Persist this space's **master roster** — the list of child identities it
  /// manages (label + each child's opaque `SpaceKeys`). Stored as a KV blob
  /// inside the space, so it inherits the space's deniability; writing one is
  /// what makes a space a *master*. The keys are sensitive — they live only
  /// here, never logged.
  Future<void> saveRoster(List<RosterEntry> entries);

  /// The roster stored in this space, or null if it is a plain identity space
  /// (no roster blob). Null-vs-list is the master-vs-identity discriminator the
  /// app uses after unlock — there is no on-disk flag (deniability).
  Future<List<RosterEntry>?> loadRoster();

  Future<void> upsertContact(Contact contact);

  /// The stored contact for [nodeId], or null if we have no record of them.
  Future<Contact?> getContact(NodeId nodeId);

  Future<List<Conversation>> loadConversations();

  /// Mark [conversationId] read up to its latest message, so its unread count
  /// (the incoming messages since last read, surfaced as [Conversation.unread])
  /// resets to zero. Called when the user opens the conversation.
  Future<void> markRead(String conversationId);

  /// Millis of the latest message marked read in [conversationId]
  /// (0 = never read → every incoming message counts as unread).
  Future<int> readMarker(String conversationId);

  /// Advance the read watermark of [conversationId] to [tsMs]. Monotonic —
  /// an older mark never regresses it (multi-device readMark apply path).
  Future<void> setReadMarker(String conversationId, int tsMs);

  /// All messages of [conversationId], oldest-first. When [limit] is set,
  /// return only the most-recent [limit] (the tail) — the read side of chat
  /// pagination ("load the latest N, fetch earlier on demand"). Omitting
  /// [limit] returns the whole conversation (used by the internal
  /// find/dedup/flush paths that need every message).
  Future<List<Message>> loadMessages(String conversationId, {int? limit});

  /// ONE live message of [conversationId] by id, or null when there is none —
  /// deleted, unknown, or belonging to a different conversation.
  ///
  /// Scoped by BOTH ids for the same reason as the edit/delete path it shares a
  /// lookup with: a bare id is attacker-chosen, and resolving on it alone would
  /// name records in someone else's chat.
  ///
  /// Exists because [loadMessages] is the wrong shape for "is this id here":
  /// it projects the whole log, filters it to the conversation and SORTS the
  /// result into display order before the caller can look at one row. The
  /// authenticated file fetch did that on every call, for a message it could
  /// name exactly.
  Future<Message?> loadMessageById(String conversationId, String messageId);

  /// Persist [message] and return it AS STORED — with its event-log (author,
  /// seq) filled in (the caller passes seq for a wire-delivered event to keep
  /// the sender's; otherwise storage allocates the next gap-free one). The
  /// sender reads the returned seq to put it on the wire.
  Future<Message> appendMessage(Message message);

  /// The event-log sync state of [conversationId] (§15, RULE HW / RULE NH): per
  /// author seen in the local log, the contiguous high-water and the named holes
  /// (see [ConversationSync]). Derived from the durable (author, seq) the records
  /// carry — every post, edit, void, and delete tombstone consumes a seq, so a
  /// deleted message keeps its slot (R4) and high-water advances past it rather
  /// than stalling on a permanent gap. The sync layer advertises high-water as
  /// an ack + "ship me anything newer" and names holes for targeted re-request,
  /// so gap-fill self-heals the log over a best-effort transport.
  Future<ConversationSync> conversationSync(String conversationId);

  /// Raise the durable gap-fill FLOOR for [author]'s stream in
  /// [conversationId]: [conversationSync] then treats every seq ≤ [floor] as
  /// consumed (no hole, high-water starts there). Monotonic max-merge.
  ///
  /// TWO writers reach this, with DIFFERENT warrants, and the difference
  /// matters to anyone reasoning about what a floor means.
  ///
  /// 1. The author's own declaration, carried on its sync beacon: nothing
  ///    at/below it still exists AT THE SOURCE — its early history was
  ///    cleared/erased, so those seqs are unfillable by ANY re-request.
  ///    Without it, a receiver holding only the author's newer events named
  ///    the missing prefix as holes and re-triggered the same futile re-ship
  ///    on every beacon round, forever (the observed sync ping-pong).
  ///
  /// 2. The RECEIVER giving up on a hole nobody filled — see
  ///    `_MessagingPeerSync._giveUpOnStuckHoles`. That is a statement about
  ///    how long WE waited, not about what exists at the source, and it is
  ///    load-bearing for the same reason: a high-water is a claim of
  ///    contiguity, so one sequence nobody supplies pins it forever and the
  ///    peer re-ships the whole tail above it every round — measured at 316
  ///    frames and 1.4 MB per round between two idle devices.
  ///
  /// The consequence of (2) is worth stating plainly, because the first
  /// warrant does not imply it: those seqs are never REQUESTED again, and the
  /// peer re-ships from our high-water, so nothing offers them either. They
  /// are not refused — this floor is read only by [conversationSync], never on
  /// the store path, so a copy that arrives by any route is still stored.
  ///
  /// Collapsing the two into one monotonic integer is the compromise: a
  /// receiver-side timeout cannot be told from a source-side erasure once it
  /// is written. Separating them needs either sparse accepted-ranges or an
  /// explicit signed skip on the wire, which is a protocol change and not one
  /// this field can carry.
  Future<void> applyAuthorSyncFloor(
    String conversationId,
    String author,
    int floor,
  );

  /// The floor THIS device can honestly declare for its OWN stream ([author] =
  /// our identity hex) in [conversationId]: one below the lowest own event
  /// still stored, or the next-seq counter minus one when nothing is stored —
  /// i.e. exactly the prefix we can no longer re-ship. 0 = nothing to declare.
  Future<int> ownSyncFloor(String conversationId, String author);

  /// Update the delivery [status] of message [messageId] in conversation
  /// [conversationId] (e.g. `sent → delivered` on an ack). Folded over the
  /// append-log, so it never mutates history in place. Scoped by conversation
  /// for the same reason as [editMessage]: an ack is driven by a peer's wire
  /// envelope whose claimed id is attacker-chosen, so a status op only applies
  /// to a message that actually lives in that peer's conversation.
  Future<void> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  );

  /// Update the opt-in attestation state of a message (the "request signature"
  /// feature). Folded onto the message like a status op — latest wins.
  Future<void> markMessageSignature(
    String conversationId,
    String messageId,
    MessageSignature signature,
  );

  // ── Call journal ───────────────────────────────────────────────────────────
  // One immutable row per finished call, in its own tiny append-log namespace.
  // The journal must never be a single rewritten KV value: the at-rest store
  // bounds one commit's DataBatch (~4KB) and a hot key's accumulated versions
  // made whole-journal rewrites throw PayloadTooLarge after ~11 rows, silently
  // losing calls from the journal.

  /// Append one call-journal row. Idempotent by [CallLogEntry.id]. Keeps the
  /// newest [cap] rows by ring time ([CallLogEntry.atMs]) — the overflow is
  /// deleted in the same commit so the bounded per-namespace log index never
  /// accumulates dead journal slots. Returns false when [entry]'s id is
  /// already journaled (a mirrored duplicate), true otherwise — including the
  /// rare row older than a full journal, which is accepted then aged out.
  Future<bool> appendCallLogEntry(CallLogEntry entry, {required int cap});

  /// Every call-journal row, newest-first (by [CallLogEntry.atMs]).
  Future<List<CallLogEntry>> callLogEntries();

  // ── Durable frame outbox ───────────────────────────────────────────────────
  // Persist a control frame that MUST reach a peer so a flush re-drives it (live
  // + mailbox) across restarts until acked. Chat messages have their own durable
  // path; this covers everything else (sign, edit, delete, clear, accept, …).

  /// Persist [wire] addressed to [peerHex] under [frameId]. Idempotent on
  /// [frameId] — enqueueing the same id twice keeps one pending entry.
  Future<void> enqueueOutboxFrame(
    String frameId,
    String peerHex,
    Uint8List wire,
  );

  /// Mark [frameId] delivered (recipient acked) so the flush stops re-driving it.
  /// Retire the durable frame [frameId], but only if it was addressed to
  /// [fromPeerHex]. See `HiddenVolumeStorage.ackOutboxFrame` (audit XV-02).
  Future<void> ackOutboxFrame(String frameId, {required String fromPeerHex});

  /// The frames still awaiting delivery (enqueued and not yet acked).
  Future<List<OutboxFrame>> pendingOutboxFrames();

  /// Append a new edit event for message [messageId] in conversation
  /// [conversationId] with [newBody]; the fold collapses to the latest text and
  /// the prior versions stay as history until a scrub reclaims them. Scoped by
  /// [conversationId] because an edit can be driven by a peer's wire envelope
  /// whose claimed id is attacker-chosen — resolving on the bare id would let a
  /// peer rewrite a message in someone else's chat.
  ///
  /// Returns the per-(conv, author) seq the edit event was written under (so the
  /// caller can put it on the wire for the peer to fold under the SAME identity,
  /// §15 R4/R5), or null if the id is unknown in that conversation (a no-op).
  /// Pass [seq] when FOLDING a wire-delivered edit (keep the editor's seq, do not
  /// allocate); omit it for a locally-originated edit (allocate the next seq).
  Future<int?> editMessage(
    String conversationId,
    String messageId,
    String newBody, {
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
  });

  /// The forward log events authored by [author] in [conversationId] with seq
  /// strictly greater than [fromSeq], oldest-first, capped at [limit] (the
  /// gap-fill re-ship batch, §15 step 3c). Each is a [LogEvent]: a live post/edit
  /// carries its body; a deleted/superseded slot surfaces as an inert
  /// [EventKind.void_] (seq only, no id/body — §12.1) so the peer can advance its
  /// high-water past it without resurrecting anything. Drives the receiver-named
  /// gap-fill: ship the peer every event it is missing above its high-water.
  Future<List<LogEvent>> loadEventsSince(
    String conversationId,
    String author,
    int fromSeq, {
    int limit,
  });

  /// Record an inert void at (author=[author], [seq]) in [conversationId] (a
  /// gap-fill [WireKind.voidSeq] from the peer): occupies the seq slot so the
  /// per-author high-water advances past a deleted/superseded event the peer
  /// never delivered, without resurrecting any message (renders nothing).
  /// Idempotent — a slot already present is a no-op.
  Future<void> applyRemoteVoid(String conversationId, String author, int seq);

  /// The edit history of message [messageId] in [conversationId], oldest-first:
  /// the original post followed by each retained edit, with per-version
  /// metadata (author, seq, time). Empty if the message is unknown / deleted. In
  /// the "keep history" model the superseded versions live in the log until a
  /// clear-history scrub or retention pass reclaims them, so this returns just
  /// the current version when nothing prior was retained.
  Future<List<MessageVersion>> loadMessageHistory(
    String conversationId,
    String messageId,
  );

  /// Permanently remove message [messageId] in conversation [conversationId]
  /// (incl. a received one). Tombstones the SAME log record so the body no
  /// longer reads back, then the prior chunk is reclaimed by [scrubDeleted] for
  /// true (forensic) erasure. Legacy exclusive blobs are removed atomically;
  /// shared 64-hex content ids are quarantined for the global chat/cloud/group
  /// reachability collector. No-op if the id is unknown IN THAT CONVERSATION
  /// (scoped for the same reason as [editMessage]).
  Future<void> deleteMessage(String conversationId, String messageId);

  /// Whether [messageId] in conversation [conversationId] was deleted (a
  /// tombstone exists for it). Lets the messaging layer refuse to RESURRECT a
  /// deleted message if the sender re-delivers it (deniability: deleted stays
  /// deleted). Stays true forever — there is no un-delete.
  Future<bool> isMessageDeleted(String conversationId, String messageId);

  /// Remove a whole conversation with [peer]: forensically delete its messages,
  /// drop the contact record + its chat-list index entry, and scrub. Used to
  /// CANCEL a pending request (retract it locally) — afterwards the peer is
  /// unknown again, so a fresh request can be sent. Irreversible.
  Future<void> removeConversation(NodeId peer);

  /// Forensically delete every message of [peer]'s conversation whose ORIGINAL
  /// post time is older than [retentionDays] days (edits do NOT refresh the
  /// clock — the original send time governs, so a year-old message edited
  /// yesterday is still pruned under a 3-month policy). Tombstones the posts,
  /// retires their blob references, voids retained edit rows, then scrubs so no
  /// superseded text survives; globally shared hash-CIDs follow the delayed
  /// reachability collector. No-op when [retentionDays] <= 0
  /// (unlimited). Returns how many messages were pruned. Local-only.
  Future<int> pruneConversation(NodeId peer, int retentionDays);

  /// The same forensic prune as [pruneConversation], expressed as an INSTANT
  /// rather than a number of days.
  ///
  /// Disappearing messages needs a window measured in seconds, and "0 days"
  /// cannot say "thirty seconds ago". Both entry points share one
  /// implementation so a message that disappears and a message that ages out
  /// leave the store in exactly the same state — the same tombstones, the same
  /// voided edit rows, the same scrub. Returns how many messages were pruned.
  Future<int> pruneConversationBefore(NodeId peer, DateTime cutoff);

  /// Erase every message of the conversation with [peer] but KEEP the contact +
  /// chat-list entry — the chat stays, emptied. Tombstones + scrubs exactly like
  /// [removeConversation]; shared hash-CID blobs enter global GC quarantine.
  /// Cleared messages cannot resurrect if the peer re-delivers them.
  /// Local-only; the peer is not notified. Irreversible.
  Future<void> clearMessages(NodeId peer);

  /// Clear the conversation with [peer] AND emit a propagatable + replayable
  /// clear EVENT: a per-author seq watermark (= the current high-water) under
  /// [selfHex]'s next seq. Scrubs + tombstones locally like [clearMessages]; the
  /// watermark additionally lets ANOTHER device (the peer, or the author's own
  /// other device) reach the same emptied state on replay. Returns the event
  /// (author, seq, watermark) so the caller ships it on the wire. Only the
  /// watermark travels — no cleared id/text (no oracle).
  Future<({String author, int seq, Map<String, int> watermark})>
  emitClearConversation(NodeId peer, String selfHex);

  /// Apply a clear event received from [author] for [peer]'s conversation: record
  /// the [watermark], scrub + tombstone every local message at/below it (keep
  /// anything newer), and occupy the clear's own ([author], [seq]) slot so the
  /// per-author stream stays gap-free. Idempotent on (author, seq).
  ///
  /// The watermark names BOTH sides on purpose — "clear for everyone" that only
  /// erased the sender's half of a conversation would leave the other half
  /// behind. [selfHex] is our own author id, needed because the entry for OUR
  /// stream is bounded here by what we actually hold: a sender can ask for what
  /// exists to go, never for what has not happened yet.
  Future<void> applyRemoteClear(
    NodeId peer,
    String author,
    int seq,
    Map<String, int> watermark, {
    required String selfHex,
  });

  /// FORENSICALLY erase this whole space — every namespace (identity, contacts,
  /// messages, file blobs) — then scrub orphaned chunks, so the deleted
  /// identity's data can no longer be recovered even by a password-holder.
  /// Irreversible. The caller must have this space OPEN.
  Future<void> eraseSpace();

  /// Reclaim/overwrite chunks orphaned by edits and deletes so the prior
  /// plaintext is no longer recoverable from the container even by a
  /// password-holder. Backed by hidden-volume's vacuum/compact; a no-op on the
  /// in-memory fake (which never persists). MUST be run after edit/delete to
  /// make erasure deniable rather than merely rely on logical tombstones.
  Future<void> scrubDeleted();

  /// Bench/debug relief: erase the file-blob namespace WHOLESALE (every stored
  /// manifest, attachment and streamed piece), freeing its log-index slots —
  /// [deleteFile]-style scrubbing overwrites records in place and can never
  /// shrink the per-namespace index, so a long-running soak bench eventually
  /// hits the index cap (HvException.IndexFull) even though everything was
  /// "deleted". Erasing the namespace drops it from the commit roots entirely;
  /// the next store recreates it fresh. Stale `file:*` KV metadata is dropped by
  /// [sweepSettingsGarbage] (wholesale). Returns the number of erased entries.
  /// NOT for product UI.
  Future<int> purgeFileStore();

  /// How much of the container file is still live data, as this space sees it
  /// — or null when the backing cannot say (locked, in-memory fake, shared
  /// multi-space handle).
  ///
  /// The one number the maintenance UI was missing. Nothing else in this port
  /// distinguishes a 7 GB container holding 5 MB of messages from a 7 GB
  /// container holding 7 GB of them, so the app could only ever show a size
  /// and leave the user to guess whether compacting was worth a password and a
  /// reconnect. See [SlotUtilization] for why the file grows that way.
  ///
  /// Read-only and cheap: it reports, it never repacks.
  Future<SlotUtilization?> containerUtilization();

  /// Read the container's sticky hardening failure and, if there is one this
  /// store has not written down yet, KEEP it.
  ///
  /// The container holds that record in memory only, so a warning nobody read
  /// before the app closed is gone on the next open — and what it says is that
  /// a commit's size is readable to a multi-snapshot adversary, or that the
  /// slots it reused stand alone in a snapshot diff (report12 HV-L4). The
  /// durable copy is what survives the restart the in-memory one does not.
  ///
  /// Returns what is now on record, container-fresh or previously kept, and
  /// null when there is nothing and when the store cannot answer — a null is
  /// "not reported", never "there was none".
  ///
  /// It deliberately does NOT acknowledge the record to the container.
  /// Acknowledging means "I have shown this to the person", and writing it to
  /// a settings key shows it to nobody.
  Future<String?> retainHardeningWarning();

  /// Forget the kept warning — "I have shown this to the person".
  ///
  /// Clears BOTH copies: the container's own sticky record first, then this
  /// store's durable one. Acknowledging only one would leave the other to
  /// re-report it forever, and the container's contract for its half is
  /// exactly this sentence.
  ///
  /// THROWS if the container refuses, and then nothing is cleared: an
  /// acknowledgement that half happened must read as not having happened, or
  /// the app side hides a record the container is still holding.
  ///
  /// Clearing is not a tombstone. A later hardening failure — a padding, churn
  /// or sync step that fails next week — is a new record and is reported
  /// again; only THIS one is dismissed.
  Future<void> acknowledgeHardeningWarning();

  /// Bench/debug: entry counts per storage namespace, for diagnosing which
  /// namespace is approaching the log-index cap. Message-log diagnostics also
  /// split the total into legacy/sharded rows and report the active shard count.
  Future<Map<String, int>> namespaceCounts();

  /// Raw keys of the settings namespace (every key family: `set:*`, `file:*`,
  /// `conv_seq:*`, …), for diagnostics and garbage-collection audits.
  Future<List<String>> settingsKeys();

  /// Garbage-collect dead bookkeeping keys from the settings namespace. The
  /// namespace's B+ index has a hard entry budget (HvException.IndexFull), and
  /// several per-content key families (`set:saved:<cid>`, `set:served:<cid>`)
  /// outlive the data they describe, so an aged store wedges every new file
  /// piece write. Always drops `set:saved:<cid>` records whose content id no
  /// message references. With [wholesale] (after purgeFileStore+purgeMessageLog) also
  /// drops the file-store bookkeeping families (`file:*`, `filepiece:*`,
  /// `set:served:*`, `set:gone:*`) that describe the just-erased namespaces.
  /// Cursors (`conv_seq:*`, `set:sync_floor:*`, `msg_next_id`,
  /// `file_next_log`) and identity/config records are never touched.
  /// Returns the number of keys deleted.
  Future<int> sweepSettingsGarbage({bool wholesale = false});

  /// Bench/debug relief: erase the WHOLE message log (every conversation's
  /// rows) to free its log-index slots. Contacts and the per-author `conv_seq`
  /// cursors (settings KV) survive, so subsequent events keep gap-free,
  /// never-reused seqs and peers fold them normally. NOT for product UI.
  Future<int> purgeMessageLog();

  /// Persist a file deniably inside the container under [fileId].
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name});

  /// Load a previously stored file, or null if unknown / incomplete.
  ///
  /// THIS HOLDS THE WHOLE FILE IN RAM. [maxBytes], when given, is a hard
  /// ceiling enforced against the RECORDED SIZE before a byte is read: a file
  /// larger than it comes back null rather than being reassembled. Prefer
  /// [readFileRange] wherever the caller can stream.
  ///
  /// The ceiling lives here rather than at the call sites because here is where
  /// the size is actually KNOWN. A caller checking a size it was handed —
  /// `(media.size ?? 0) > limit` — passes an absent size as zero and reads a
  /// file of any size at all, which is exactly what a hostile sender omits
  /// (audit report8).
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes});

  /// Remove one stored blob from either encrypted tier. The implementation
  /// atomically scrubs its in-volume key/chunk metadata before best-effort
  /// ciphertext unlink. Call [scrubDeleted] afterwards to vacuum overwritten
  /// in-volume records. Higher layers must prove the cid is no longer shared
  /// by another logical reference before calling this deduplicated-blob API.
  Future<void> deleteStoredFile(String fileId);

  /// One fail-closed snapshot of the shared content-addressed blob namespace.
  /// [storedContentIds] contains every 64-hex payload with either payload or
  /// `mf:<cid>` metadata. [referencedContentIds] is the union of live personal
  /// chat and personal-cloud references. Group/Space references deliberately
  /// remain in GroupService, which is the only layer able to validate signed
  /// rows, decrypt protected channels, and apply retention correctly.
  ///
  /// When [complete] is false a caller MUST NOT delete anything: a malformed or
  /// unreadable durable root is uncertainty, not proof that its blobs are dead.
  Future<SharedContentReferenceSnapshot> sharedContentReferenceSnapshot();

  /// True iff a blob is already stored under [fileId] — a cheap existence check
  /// (no chunk reads). Content dedup: a received file whose contentId we already
  /// hold is referenced (a fresh filePost event), not re-fetched over the network.
  Future<bool> hasFile(String fileId);

  /// Store ONE piece of a STREAMED file incrementally (its own record-run), so a
  /// large file is never held whole in RAM and its size is bounded by disk, not
  /// [kMaxStoredFileBytes]. [hasFile] becomes true once all [pieceCount] pieces
  /// are stored. Idempotent per (fileId, pieceIndex).
  Future<void> storeFilePiece(
    String fileId,
    int pieceIndex,
    int pieceCount,
    int pieceSize,
    int totalSize,
    Uint8List bytes, {
    String? name,
  });

  /// Read [length] bytes at [offset] of a stored file WITHOUT loading it whole
  /// (reads only the covering records) — lets the sender serve a wire chunk
  /// straight from disk. Null if unknown / a needed record is missing.
  Future<Uint8List?> readFileRange(String fileId, int offset, int length);

  /// Byte length of a stored file, or null if unknown / incomplete.
  ///
  /// The missing half of [readFileRange]: a caller that wants to stream a blob
  /// needs its length to walk the ranges and to answer HTTP `Content-Length` /
  /// `Content-Range`, and without this the only way to learn it was
  /// [loadFile] — reading the whole blob into RAM to find out how big it is,
  /// which is exactly what streaming exists to avoid.
  Future<int?> fileSize(String fileId);

  // --- Ratchet sessions ---------------------------------------------------
  //
  // veil agrees the keys and advances the chains; it keeps none of it. Its one
  // database belongs to the mailbox and is reachable from neither the send path
  // nor the frame dispatcher, so the durable half of forward secrecy is the
  // host's, and in this app the host's durable store is the deniable container.
  //
  // The unit is one CONVERSATION, named by the 64-byte key veil hands out
  // (`our device ‖ their node ‖ their device`), and its value is an opaque blob
  // in which EVERY BYTE IS KEY MATERIAL: never parsed, never logged, never
  // diffed, never put in an error report.

  /// Every conversation key with state stored in this space.
  ///
  /// Read once at startup: each one has to be handed back to veil BEFORE
  /// traffic flows, because a frame for a conversation that was not restored
  /// cannot be opened and — unlike a dropped packet — the sender has already
  /// advanced its chain, so nothing will ever re-send it in a readable form.
  Future<List<Uint8List>> ratchetConversationKeys();

  /// The stored state of one conversation, or null when nothing complete is
  /// held under [conversationKey]. Never returns a partial blob: half a session
  /// is a session with the wrong keys.
  Future<Uint8List?> loadRatchetState(Uint8List conversationKey);

  /// Persist [entries] — the conversations veil has just named as changed.
  ///
  /// Called after every send and every receive, before the operation counts as
  /// finished. A write that is skipped is a message key that exists nowhere,
  /// and the message that needed it never opens and never says why.
  ///
  /// Each conversation lands atomically: a torn write would restore a session
  /// whose halves came from different points in the chain.
  Future<void> saveRatchetStates(List<RatchetStateEntry> entries);

  /// Drop the stored state of [conversationKeys]. Returns how many were held.
  ///
  /// Irreversible by nature — nothing public can rebuild a chain — so this is
  /// for a deleted chat, a forgotten contact or a device that is no longer
  /// ours, never for eviction.
  Future<int> forgetRatchetStates(Iterable<Uint8List> conversationKeys);

  /// Lock the space and zeroize in-memory key material.
  Future<void> close();
}

/// Byte length of a conversation key: `our device (16) ‖ their node (32) ‖
/// their device (16)`. Mirrors `VEIL_RATCHET_KEY_LEN`.
///
/// Flat and reversible rather than a digest, deliberately: a host dropping a
/// removed device or a forgotten contact decides what to drop by READING the
/// key, instead of keeping a side table back to peers. Nothing in it is secret
/// — all three identifiers already travel on the wire.
const int kRatchetKeyLen = 64;

/// Offset of the peer's 32-byte node id inside a conversation key.
const int kRatchetKeyPeerNodeOffset = 16;

/// Upper bound on one conversation's exported state. Mirrors
/// `VEIL_RATCHET_MAX_STATE_LEN`.
///
/// An established session is about 1.4 kB. The rest is the skipped-message-key
/// cache — 68 bytes per key banked for a frame that has not arrived yet — and
/// the ratchet caps that, so a store sized to this never sees a short write.
const int kRatchetMaxStateLen = 256 * 1024;

/// One conversation's persisted ratchet state.
///
/// [blob] is opaque and wholly secret. It is produced by `veil_ratchet_export`
/// and consumed by `veil_ratchet_import`, and nothing between the two may look
/// inside it.
final class RatchetStateEntry {
  const RatchetStateEntry(this.conversationKey, this.blob);

  /// 64 bytes; see [kRatchetKeyLen].
  final Uint8List conversationKey;

  /// The exported session. EVERY BYTE IS KEY MATERIAL.
  final Uint8List blob;

  /// The peer's node id — the 32 bytes in the middle of the key.
  ///
  /// The one field a host is meant to read: it is what makes "forget everything
  /// belonging to this contact" answerable without a side table.
  Uint8List get peerNodeId => Uint8List.sublistView(
    conversationKey,
    kRatchetKeyPeerNodeOffset,
    kRatchetKeyPeerNodeOffset + 32,
  );
}

/// Storage-owned half of a global MediaObject reachability scan.
final class SharedContentReferenceSnapshot {
  const SharedContentReferenceSnapshot({
    required this.storedContentIds,
    required this.referencedContentIds,
    required this.complete,
  });

  final Set<String> storedContentIds;
  final Set<String> referencedContentIds;
  final bool complete;
}

/// One persisted, not-yet-delivered control frame in the durable outbox.
class OutboxFrame {
  const OutboxFrame({
    required this.frameId,
    required this.peerHex,
    required this.wire,
    this.enqueuedAtMs,
  });

  /// Caller-chosen id (e.g. `sigreq:<msgId>`); also the ack key.
  final String frameId;

  /// Recipient node-id hex.
  final String peerHex;

  /// The exact bytes to (re-)send / (re-)stash.
  final Uint8List wire;

  /// When this frame was queued, if the record carries it.
  ///
  /// `null` for rows written before frames were stamped. Age-based retention
  /// must therefore treat null as "unknown", never as "ancient" — the whole
  /// point of the queue is that a peer away for a day still finds its frames,
  /// and a migration is no reason to drop them.
  final int? enqueuedAtMs;
}
