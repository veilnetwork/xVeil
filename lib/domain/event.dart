/// Event-log model (doc/EVENT-LOG-SYNC-DESIGN.md §15, doc/EVENT-LOG-IMPL-PLAN.md).
///
/// Chat history is an append-only, compacting LOG of events keyed by
/// (author, per-conversation per-author seq). The fold derives current state
/// AND edit-history; the mailbox carries log ENTRIES; gap-fill on reconnect
/// makes the transport best-effort. This file is the wire/storage value model;
/// the durable (author,seq) storage + fold live in the storage layer.
library;

/// Kind of a log event. Append-only — never reorder/remove a variant (the index
/// is the on-wire/on-disk `k`). `react`/`pin` are deferred (§16).
enum EventKind {
  /// A new text (or file, via [filePost]) message. Carries `body`.
  post,

  /// Replace the body of [LogEvent.target] with [LogEvent.body]. Applied only to
  /// a post by the SAME authenticated author, gated by R5 (seq strictly greater
  /// than the stored winning-edit seq) so it is last-writer-wins with no old
  /// body retained.
  edit,

  /// Tombstone [LogEvent.target] (unsend). Body-less (scrubbed). Same-author
  /// gate. A delete consumes a seq so the per-author stream stays gap-free.
  delete,

  /// Inert placeholder occupying a consumed-but-superseded seq (a delete, a
  /// collapsed edit chain, or a compacted entry). NO id/body/semantics on the
  /// recovery wire — makes {deleted, edited-away, compacted} indistinguishable
  /// (R-VOID / §12.1): no activity oracle, no deleted id ever travels.
  void_,

  /// A post whose body is a file descriptor (name/size/blob ref). The blob
  /// itself travels on the existing file-chunk plane; this is the log entry.
  filePost,

  /// Clear the whole conversation up to a per-author seq WATERMARK (carried as a
  /// JSON map `{authorHex: hw}` in [LogEvent.body]). Folded on every device it
  /// suppresses + scrubs every event with `(author, seq) <= watermark[author]`,
  /// so a clear is a first-class, replayable event that brings ANY device (the
  /// peer, or another of the author's OWN devices) to the same emptied state.
  /// ONLY the watermark travels — never a cleared message id or text (no oracle).
  /// The author's own clear is authoritative on their devices; a peer's clear is
  /// advisory (the receiver may apply or decline). A clear consumes a seq so the
  /// per-author stream stays gap-free (R4).
  clear,
}

/// One forward log event. [author] is the node-id hex of the originator and is
/// bound at the storage/dispatch boundary from the CRYPTO-AUTHENTICATED sender
/// (m.src) — NEVER trusted from an in-band wire field (R1). [seq] is the
/// per-(conversation, author) gap-free Lamport counter (R4/R5/R10). [ts] is
/// display-only (the fold itself is timestamp-free).
typedef LogEvent = ({
  EventKind kind,
  String author,
  int seq,
  String id,
  String? target,
  String? body,
  int ts,
});

/// Encode a [LogEvent] to the wire/JSON body. A [EventKind.void_] event drops
/// its `id`/`body` ON THE WIRE (the caller strips them) — here we still emit
/// whatever the record holds; the wire layer is responsible for the void
/// stripping per R-VOID.
Map<String, dynamic> encodeEventBody(LogEvent e) => {
      'k': e.kind.index,
      'a': e.author,
      'q': e.seq,
      'id': e.id,
      if (e.target != null) 'tg': e.target,
      if (e.body != null) 'b': e.body,
      'ts': e.ts,
    };

/// Local sync state for ONE conversation (event-log §15, RULE HW / RULE NH) —
/// the basis for gap-fill. For each author seen in the local log:
///
/// * [highWater] — the CONTIGUOUS high-water: the largest N such that every seq
///   in `1..N` is present locally (0 when even seq 1 is missing). This is the
///   ack ("I hold every event up to N from this author") AND the gap query ("ship
///   me everything newer than N").
/// * [holes] — the named missing seq ranges `[lo, hi]` strictly BELOW the highest
///   seq observed for that author (an interior gap that high-water alone can't
///   express). These are the targeted re-request ranges (RULE NH).
///
/// Posts, edits, voids, AND delete tombstones each consume a seq from their
/// author's per-(conversation, author) counter, so all four count toward the
/// stream — a gap-free prefix requires every one of them present, which is why a
/// deletion must keep its seq slot (R4) rather than vanish. An author with a
/// gap-free prefix and no interior gap has no entry in [holes]. Authors are
/// omitted from both maps when they have contributed no seq-bearing event
/// (e.g. a legacy pre-event-log conversation), which the sync layer treats as
/// "unknown / fall back to the legacy path" (R17).
typedef ConversationSync = ({
  Map<String, int> highWater,
  Map<String, List<(int lo, int hi)>> holes,
});

/// Decode a wire/JSON body to a [LogEvent], or null if malformed (a hostile or
/// corrupt frame must never throw out of the dispatch path — the caller drops a
/// null). Validates the kind index range and the required scalar types.
LogEvent? decodeEventBody(Map<String, dynamic> j) {
  final k = j['k'];
  final a = j['a'];
  final q = j['q'];
  final id = j['id'];
  final ts = j['ts'];
  if (k is! int || k < 0 || k >= EventKind.values.length) return null;
  if (a is! String || id is! String || q is! int || ts is! int) return null;
  final tg = j['tg'];
  final b = j['b'];
  return (
    kind: EventKind.values[k],
    author: a,
    seq: q,
    id: id,
    target: tg is String ? tg : null,
    body: b is String ? b : null,
    ts: ts,
  );
}
