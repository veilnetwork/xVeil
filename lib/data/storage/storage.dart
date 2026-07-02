import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../domain/event.dart';
import '../../domain/identity.dart';
import '../../domain/roster.dart';

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

  Future<void> saveIdentity(Identity identity);
  Future<Identity?> loadIdentity();

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

  /// All messages of [conversationId], oldest-first. When [limit] is set,
  /// return only the most-recent [limit] (the tail) — the read side of chat
  /// pagination ("load the latest N, fetch earlier on demand"). Omitting
  /// [limit] returns the whole conversation (used by the internal
  /// find/dedup/flush paths that need every message).
  Future<List<Message>> loadMessages(String conversationId, {int? limit});

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
  /// true (forensic) erasure. No-op if the id is unknown IN THAT CONVERSATION
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
  /// reclaims their file blobs AND voids their retained edit rows, then scrubs —
  /// so no superseded plaintext survives. No-op when [retentionDays] <= 0
  /// (unlimited). Returns how many messages were pruned. Local-only.
  Future<int> pruneConversation(NodeId peer, int retentionDays);

  /// Erase every message of the conversation with [peer] (incl. file blobs) but
  /// KEEP the contact + chat-list entry — the chat stays, emptied. Tombstones +
  /// scrubs exactly like [removeConversation], so cleared messages are
  /// forensically gone and cannot resurrect if the peer re-delivers them.
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
  Future<void> applyRemoteClear(
      NodeId peer, String author, int seq, Map<String, int> watermark);

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
  /// the next store recreates it fresh. Stale `file:*` KV metadata may survive
  /// (KV keys are not enumerable) — readers treat the missing chunk runs as
  /// absent content. Returns the number of erased entries. NOT for product UI.
  Future<int> purgeFileStore();

  /// Bench/debug: entry counts per storage namespace, for diagnosing which
  /// namespace is approaching the log-index cap.
  Future<Map<String, int>> namespaceCounts();

  /// Bench/debug relief: erase the WHOLE message log (every conversation's
  /// rows) to free its log-index slots. Contacts and the per-author `conv_seq`
  /// cursors (settings KV) survive, so subsequent events keep gap-free,
  /// never-reused seqs and peers fold them normally. NOT for product UI.
  Future<int> purgeMessageLog();

  /// Persist a file deniably inside the container under [fileId].
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name});

  /// Load a previously stored file, or null if unknown / incomplete.
  Future<Uint8List?> loadFile(String fileId);

  /// True iff a blob is already stored under [fileId] — a cheap existence check
  /// (no chunk reads). Content dedup: a received file whose contentId we already
  /// hold is referenced (a fresh filePost event), not re-fetched over the network.
  Future<bool> hasFile(String fileId);

  /// Store ONE piece of a STREAMED file incrementally (its own record-run), so a
  /// large file is never held whole in RAM and its size is bounded by disk, not
  /// [kMaxStoredFileBytes]. [hasFile] becomes true once all [pieceCount] pieces
  /// are stored. Idempotent per (fileId, pieceIndex).
  Future<void> storeFilePiece(String fileId, int pieceIndex, int pieceCount,
      int pieceSize, int totalSize, Uint8List bytes,
      {String? name});

  /// Read [length] bytes at [offset] of a stored file WITHOUT loading it whole
  /// (reads only the covering records) — lets the sender serve a wire chunk
  /// straight from disk. Null if unknown / a needed record is missing.
  Future<Uint8List?> readFileRange(String fileId, int offset, int length);

  /// Lock the space and zeroize in-memory key material.
  Future<void> close();
}
