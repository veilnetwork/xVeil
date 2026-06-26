# Event-log conversation sync — design

Status: **DESIGN (pre-implementation).** Supersedes the imperative
edit/delete/ack/reconnect mechanism once implemented. Implement in a
dedicated session after this design passes adversarial review.

Related: `MESSAGE-EDIT-DELETE-DESIGN.md`, `OFFLINE-DELIVERY-DESIGN.md`,
and the agreed recovery-handshake note (memory `recovery-handshake-design`),
which this design **absorbs**.

---

## 1. Problem

Today a conversation is **mutable state** mutated by **imperative,
fire-and-forget operations**:

- a message is a stored row; `edit` rewrites it in place; `del` removes it;
- each op is a one-shot `WireKind` frame (`message` / `edit` / `del` / `ack`)
  sent best-effort over the live transport, with a *separate* mailbox deposit
  bolted on per op (and `flushOutbox` re-trying only `message`s).

This is fragile to exactly the failures a P2P/offline messenger lives in:

- **Lost ops.** An `edit`/`del` made while the peer is offline was dropped
  entirely until the 2026-06-26 patch added a mailbox deposit — and even now
  there is no retry if that first deposit fails, and no `flushOutbox` for ops.
- **Ordering.** An `edit` that reaches the peer before the original `message`
  targets a non-existent id and is lost.
- **No reconciliation.** If two sides diverge (one missed an op), nothing
  detects or repairs it. There is no "what have you not seen?" question.
- **Recovery is a special case.** "One side wiped its chat data" needs its own
  bespoke `reconnect` handshake (the recovery-handshake note) bolted on the side.

Each of these is a separate patch today. They are all the **same** problem: we
ship *mutations* and hope they all arrive, in order, exactly once.

## 2. Core idea

Model a conversation as a **per-conversation append-only log of immutable
events**, each stamped with a **per-author logical clock**. Local state is a
deterministic **fold** over the events. Sync is **"send me the events I am
missing"** (gap-fill by high-water mark), not "replay my mutations at you".

This single mechanism subsumes: message send, edit, delete-for-everyone,
delivery ack, offline delivery, retry, divergence reconciliation, **and**
data-loss recovery (the `reconnect` handshake).

```
author A: e1(post)  e2(post)  e3(edit e1)  e4(post)
author B:                      e1(post)            e2(delete A:e4)
state  = fold(merge(A.events, B.events))   (deterministic, idempotent)
sync   = "I have A≤2, B≤0; send me the rest"  →  peer ships A:e3,e4 / B:e1,e2
```

## 3. The deniability tension — and its resolution

Event-sourcing's defining strength is that it **keeps all history**. Our
edit/delete deliberately **destroys** history: `scrubDeleted()` makes the prior
plaintext unrecoverable, because forward-secrecy / deniability requires that a
**seized, coerced device cannot reveal what was edited away or deleted**. A
naïve event log storing `edited from "X" to "Y"` or `deleted: "<old text>"`
**re-introduces exactly the recoverable history we destroy on purpose.** This
is the load-bearing constraint; the design is wrong if it weakens it.

**Resolution — a *compacting* event log:**

1. **Events carry only what reaches the *current* state, plus sync metadata.**
   `post` carries its body. `edit` carries `(target, NEW body)` — never the
   old. `delete` carries `(target)` — a tombstone, never the old body.
2. **Applying an edit/delete scrubs the superseded plaintext immediately**, as
   today. The log retains the event's **identity + clock** (for gap-fill) and
   the **current** content, not the destroyed content.
3. **The substrate already does this.** hidden-volume's `MESSAGE_LOG` namespace
   is an append-log of `DataBatch` chunks with monotonic log-ids and
   `scrubDeleted`; an edit/delete rewrites + scrubs. So "a compacting append log
   whose superseded content is forensically erased" is **already** how storage
   behaves. The change is in the **domain/wire layer**, not the store.

**Consequence (a deliberate, correct limitation):** scrubbed/compacted events
can no longer be replayed. A peer that lost its data recovers only the
**non-compacted (current) state**, never content the other side already
destroyed. You cannot recover what was deliberately erased — and you should not
be able to. Documented, not a bug.

## 4. Event model

A **conversation** is the (me, peer) pair, keyed by the peer node-id hex (as
today). Each conversation has a logical log; **both** participants author into
it. Only **shared, for-everyone** actions are events. Local-only actions
(delete-**for-me**, mark-read, mute, archive, folder) are **not** events and are
**never** shared — they stay device-local (and keep their deniability).

```
Event {
  author : NodeId          // who authored it (me or the peer)
  seq    : u64             // per-author monotonic counter (1,2,3,… per author)
  id     : String          // stable event id (the current message id for post)
  kind   : post | edit | delete   // extensible: react, pin, … later
  target : String?         // for edit/delete: the post's id
  body   : String?         // post: text; edit: NEW text; delete: none (scrubbed)
  ts     : u64             // author wall-clock ms (sentAtMs), for display order
}
```

- **`seq` is per-author and gap-free.** Author A's events are totally ordered by
  A's `seq`; this is what gap-fill keys on ("I have A up to 2"). It is a
  Lamport-style per-author sequence, **not** a shared global clock (a shared
  clock needs coordination two offline peers can't do).
- **`ts`** orders the *merged* timeline for display (existing `sentAtMs`), with
  `(ts, author, seq)` as the deterministic tiebreak. `ts` is **not** trusted for
  causality (a lying/clock-skewed peer only mis-sorts its **own** messages).
- **Causality across authors** is by `target`, not by clock: an `edit`/`delete`
  names the post id it acts on; the fold applies it when (and only when) the
  target exists.

### 4.1 The fold (deterministic state reconstruction)

Process each author's events in `seq` order; merge authors by `(ts, author,
seq)`. For each event:

- **post** → create/keep message `id` with `body`, `ts`, author→direction.
- **edit(target, newBody)** → iff `target` exists **and** was authored by the
  same author (you may only edit your own) → replace body, set `edited`, scrub
  old. If `target` not yet present → **hold** the event (pending) and apply it
  the moment the post arrives (fixes the edit-before-post race). Concurrent
  edits: highest `(ts, author, seq)` wins (last-writer-wins, deterministic).
- **delete(target)** → iff `target` exists and same author → tombstone + scrub.
  If absent → hold as a pending tombstone so a later-arriving post is born
  deleted (a delete can't be undone by a slower post).

The fold is **idempotent** (re-applying a seen `(author, seq)` is a no-op) and
**convergent** (same event set → same state on both ends).

## 5. Wire protocol

Reuse the existing compact-JSON `WireEnvelope` (`{t,b,i,s,…}`); **append** new
`WireKind`s so existing indices are untouched (the established compatibility
rule). Two new frames:

- **`event`** — carries one event: `{kind, author, seq, id, target?, body?, ts}`.
  Replaces `message` / `edit` / `del` on the new path (those stay decodable for
  un-upgraded peers — see §7).
- **`sync`** — a reconciliation request/offer: *"per author, the highest
  contiguous `seq` I have applied"* — e.g. `{me: 7, you: 4}`. It is both the
  **ack** ("I have your events ≤ 4") and the **gap query** ("send me > 4").

Delivery uses **both** legs already in place: live `_send` for low latency, and
a per-event mailbox deposit (`_maybeStash`, content-id = the event id) for
offline. Because every event is independently addressed and idempotent, the
mailbox naturally store-and-forwards the whole log.

## 6. Sync / reconcile protocol

On every (re)connect, on mailbox drain, and on a coarse timer:

1. Send a **`sync`** frame with my per-author high-water marks for this
   conversation.
2. On receiving a peer's `sync`: ship every local event with `seq` greater than
   the peer's stated high-water for that author, oldest-first, **bounded** per
   round (e.g. ≤ N events/round; continue next round) — both live and stashed.
3. On receiving an `event`: apply via the fold (idempotent); advance my
   high-water for that author when the sequence is contiguous; buffer a gap
   (event with `seq` > high-water+1) until the missing ones arrive.
4. **Retry** = "events past the peer's last-known high-water" — one uniform loop
   that replaces `flushOutbox` (messages), the per-op stash, and the bespoke
   ack. Bounded with the same escalating per-peer backoff already used for the
   mailbox (`_peerUnresolvedBackoff`).

**Delivery/read state** becomes a *projection of the peer's high-water*: their
`sync {you: K}` means "delivered up to my event K". (A future explicit
`read` event — opt-in, deniability-reviewed — could ride the same rail.)

## 7. Recovery (#9) and consent — for free

The recovery-handshake note's two cases fall out of sync:

- **Case A — chat data wiped, identity (node keypair) survives.** The wiped side
  comes back with high-water **0** for the peer. Its `sync {you: 0}` makes the
  peer replay the **entire (non-compacted) log** → the conversation
  reconstructs. No bespoke `reconnect` kind: a `sync` from a node we have no
  contact for **is** the reconnect signal.
- **Consent re-establishment.** A `sync`/`event` from an **unknown** node must
  re-enter the **consent gate** (never silently accept content from a stranger —
  the model is intact). The receiver disambiguates by **its own** state: have an
  accepted contact → reconcile; unknown/pending → surface as `pendingIncoming`
  "wants to reconnect" (under `kMaxPreConsentIntros`); blocked → **drop silently**
  (no oracle). This is exactly the recovery-handshake note's receiver logic,
  now keyed off `sync` instead of a separate `reconnect`.
- **Offline-vs-wiped stays indistinguishable** (good — no data-loss/presence
  oracle): `sync {you:0}` from someone could be a new contact or a wiped one;
  the sender learns the difference only from the response, and the UI stays
  neutral ("ожидает доставки") until then.
- **Case B — identity also lost** → new node-id → the peer's cached contact is
  dead → unrecoverable by protocol → out-of-band re-invite only. Shown honestly.
- **Intentional close** (`chatClosed`: "peer deleted the chat, can re-invite")
  stays an **opt-in, default-OFF** signal (deniable) — now just another event
  kind under the notify-peer flag.

## 8. Deniability analysis (to be hardened in review)

- **Content forward-secrecy preserved** (§3): superseded plaintext is scrubbed;
  events never carry destroyed content.
- **Sync metadata leak.** Per-author `seq` high-waters reveal *event counts* to
  the **peer** — who already sees all the content; not a new leak to an
  outsider. Sealed inside mailbox blobs (opaque to the relay, §
  OFFLINE-DELIVERY). **Per-space** (a decoy/duress identity's log and clocks are
  in its own space — no cross-identity leak), same isolation as everything else.
- **Activity-count vs a coercing adversary.** A seized device's *current* log
  exposes the current message set (as today) and a monotone `seq` ceiling, but
  **not** scrubbed history. The `seq` ceiling reveals "≥ this many events ever"
  — a mild metadata exposure to evaluate (mitigation option: per-conversation
  seq, not per-identity, so it bounds the leak to one chat).
- **No new presence oracle:** §7's offline-vs-wiped indistinguishability holds.
- **Compaction boundary:** what the log will replay for recovery == what has not
  been scrubbed. Define the compaction policy (how much recent history is kept
  replayable) as an explicit, deniability-reviewed parameter.

## 9. Migration

- **Storage:** add `(author, seq, kind, target)` to the `MESSAGE_LOG` event
  records; the existing `loadMessages` fold becomes the §4.1 fold. Existing rows
  migrate as `post` events with a back-filled per-author `seq` (deterministic
  from existing order) — one-time, in-place, scrubbing untouched.
- **Wire back-compat:** keep decoding `message`/`edit`/`del`/`ack` (un-upgraded
  peers). A conversation where **both** ends advertise the event protocol (a
  capability bit on `request`/`accept`/`sync`) uses event-log sync; a mixed pair
  degrades to today's best-effort path. No flag-day.
- **Subsumes + retires:** `flushOutbox` (message retry), the per-op
  `_maybeStash` for edit/del, the standalone `ack`, and the planned
  `WireKind.reconnect` all collapse into the §6 loop.

## 10. Open questions for adversarial review (before any code)

1. **Per-author seq forgery / gaps.** A malicious/buggy peer sends `seq` with
   holes, or rewinds it, or claims a huge high-water. Does the fold stay safe
   (bounded buffering, no infinite gap-wait, no resurrection of scrubbed ids)?
2. **Edit/delete of *another author's* post.** The fold restricts edit/delete to
   own posts — is that enforced on the **receiver** (a peer must not edit my
   messages on my device)?
3. **Pending-buffer DoS.** Holding edits/deletes whose target hasn't arrived:
   bound the buffer; what evicts a target that never comes?
4. **Compaction vs recovery race.** If A compacts event e5 while B (wiped) asks
   for "everything", B can't get e5. Is the resulting partial-history state
   coherent (no dangling edit/delete targets)?
5. **Seq metadata leak quantification** (§8) — per-conversation vs per-identity
   seq; what exactly a seized device reveals.
6. **Consent-gate bypass.** Can a `sync`/`event` from a stranger inject content
   without passing the request/accept gate? (Must not.)
7. **Idempotency under live+mailbox double-delivery** and re-edits racing on the
   relay content-id.
8. **Clock abuse** — a peer lying about `ts` only re-sorts its own messages;
   confirm it cannot reorder or supersede *my* events.

---

## 11. Adversarial review — resolved decisions (NORMATIVE)

A 4-lens design review (2026-06-26, before any code) found 20 findings
(11 blocker/high) and disproved several §1–§10 claims. The core model
survives; the rules below are the **binding refinements** — where they
contradict §1–§10, §11 wins. Each cites the finding it closes.

### 11.1 Authentication & consent (load-bearing)

- **R1 (BLOCKER — author binding).** `event.author` is **not** trusted from
  the wire. On receive, the event's author is **bound to the
  crypto-authenticated transport sender `m.src`** (reject if the in-band
  `author` ≠ `m.src`). The fold's "you may only edit/delete your own posts"
  check compares the **authenticated** author of the target post against the
  **authenticated** sender of the event — never two in-band fields. This is the
  event-log analog of today's `_isIncomingFrom(m.src, id)` gate. Without it an
  accepted peer can forge `author=ME` and edit/scrub my own messages.
- **R2 (consent gate per arm).** From a **non-accepted** node, an inbound
  event/sync materializes **at most one** pending intro (the single latest
  `post` body, counted under `kMaxPreConsentIntros`, surfaced as "wants to
  reconnect") and **never** applies edit/delete/status, **never** allocates a
  gap/pending buffer, and **never** drives a multi-event replay. The full
  reconcile (ship-my-log + apply-their-log, incl. Case-A recovery) fires **only
  after** `status == accepted`. A wiped peer re-enters as a fresh
  `pendingIncoming` and the user re-accepts — preserving the consent model.
  Route sync/event from non-accepted nodes through the **same**
  `kMaxPreConsentIntros` accounting and `_inboundChain` serialization. Blocked →
  **drop silently** (covers `sync`/`event` too — no presence oracle).
- **R3 (capability TOFU-pin).** Once a peer is observed to support the event
  protocol, **pin** that per-contact in the space; a later "no events" advert is
  anomalous → log/ignore, **do not** silently downgrade. Never mix legacy and
  event frames within one accepted, event-capable conversation (prevents a
  bit-flip downgrade that replays a legacy `edit` bypassing R1).

### 11.2 Durable sequence & the store (real changes, not "substrate already does")

- **R4 (BLOCKER — tombstone keeps the seq slot).** A delete/compaction must
  leave a **durable body-less skeleton** `(author, seq, id, kind=tombstone)`
  with the plaintext scrubbed. The fold treats a tombstone as a **valid,
  replayable seq slot**, so per-author seq stays gap-free for gap-fill. A delete
  must **not** drop the row (today it does → permanent seq hole → wiped peer
  buffers forever).
- **R5 (durable per-record author+seq + seq-gated edit).** Persist `(author,
  seq)` as **first-class, indexed** fields on the message record (not transient
  sync metadata). Apply an incoming edit **only if its `seq` is strictly greater
  than the stored winning-edit seq** (else drop + ack). This makes
  last-writer-wins deterministic across delivery order **without** retaining the
  old body (which is scrubbed). Today's destructive last-write-by-log_id +
  no-stored-seq diverges permanently on out-of-order edits.

### 11.3 Forward-secrecy scrub guarantee (the deniability load-bearer)

- **R6 (HIGH — scrub must actually erase).** `scrubDeleted → vacuum_data_batches`
  only erases a `DataBatch` chunk when **none** of the log-ids packed in it
  remain referenced. Today's safety is the *accidental* one-message-per-commit
  property. Event-log batching (§6 ≤N/round, §9 back-fill) would pack many
  records per batch → editing/deleting one leaves the **old plaintext
  AEAD-decryptable**. NORMATIVE: **any event whose target can later be
  edited/deleted is committed one-record-per-`DataBatch`** (documented as
  load-bearing, like `appendMessage` today); OR the event-path scrub calls
  `Container::compact_known` (full rewrite) when a shared batch is implicated.
  The §9 migration back-fill **must not** coalesce history into shared,
  never-scrubbable batches. Regression test required: edit one record in a known
  multi-record batch → assert the orphan chunk is gone.

### 11.4 Bounded buffers & anti-amplification (reuse the file-path discipline)

- **R7 (bound pending + gap buffers).** Hard cap per conversation
  (`kMaxPendingTargets`, `kMaxForwardGap`, byte cap); **reject** (don't buffer)
  an event whose `seq` exceeds high-water by more than a small `K`;
  **timeout-evict** never-resolving held edits/deletes and stale gaps
  (`kStalePendingTimeout`, **timeout-evict, not LRU**, so a hostile peer can't
  evict a victim's live entry). "Contiguous" is a **soft** requirement: after a
  bounded budget for a missing range, skip the gap and apply buffered
  higher-seq events. Clamp a peer's stated high-water to `my_highest_emitted_seq`.
- **R8 (sync is not an amplifier).** For an **accepted** contact a peer's
  per-author high-water is treated as **monotonic**: a regressed/zeroed
  high-water is "already satisfied", **not** a re-ship trigger (only a true
  no-prior-contact node gets a from-zero replay, itself accept-gated per R2).
  **Rate-limit** honoring sync per peer (coalesce; one replay pass per backoff
  window, reusing `_peerUnresolvedBackoff`-style escalation); cap events/round
  **and** rounds/window. Closes the self-inflicted ML-KEM-seal/onion storm.

### 11.5 Ordering (timeline integrity)

- **R9 (ts cannot reorder MY events).** Do **not** order the cross-author
  timeline ts-first from attacker input. Floor each peer's `ts` to a
  locally-observed receive window (`_wireSentAt` already clamps the *future*;
  also floor to `max(last-recv-ts-from-peer, recv_time − ε)`); assign **my own**
  events their true local insertion time. Final order = `(effective_ts, author,
  seq)` with a **stable** sort (today `loadMessages` uses a non-stable
  `List.sort` on bare timestamp → non-deterministic across devices). Closes the
  "stamp ts=0 to float above all my messages" reorder.

### 11.6 Per-conversation seq (MANDATED — convergence + metadata)

- **R10.** Seq is **per-conversation**, never per-identity. Per-identity seq
  makes gap-fill for chat C see holes that are events in *other* chats the peer
  can't fill → permanent stall **and** a leak ("A messaged someone at seq N").
  Per-conversation also bounds the seized-device event-count leak to one chat.
- **R11 (mutation-count leak — accept + bound, or hide).** A gap-free per-author
  seq leaks the **count of scrubbed/superseded mutations** to the peer and to a
  seized device (edit a post 30× → seq ceiling ~33 → "30 hidden revisions"),
  which today's model does not transmit. Decision: per-conversation seq (R10)
  bounds it to one chat; **document** that the seq ceiling reveals
  lifetime-mutation-count, not just current message count. Stretch option for a
  later pass: decouple the gap-fill cursor from a raw counter (per-target
  version vector / sparse live-id advertisement) so the high-water can't be read
  as "how many times I changed my mind".

### 11.7 Mailbox / relay exposure

- **R12 (content-id per event, not per target).** Mailbox content-id =
  `H(author ‖ seq)` (the event's own identity), **not** the target/message id —
  else a post and its edit/delete share an id and the relay dedups the second
  away (the exact bug the current code dodges with `edit:`/`del:` stash ids).
  Receiver-side application stays idempotent keyed on `(author, seq)`.
- **R13 (coalesce a round into one sealed blob).** Deposit a sync round's events
  as **one** sealed mailbox blob per recipient per round (the blob is already
  opaque to the relay; idempotency/dedup lives **inside** the sealed payload),
  **not** one deposit per event — restores "one deposit ≈ one delivery cycle"
  and hides per-event count/timing from the relay. Cap + jitter deposit cadence;
  reaffirm the multi-identity stagger/jitter as mandatory.

### 11.8 Compaction & recovery

- **R14 (compact a message and its terminal edit/delete as a UNIT).** A deleted
  message contributes **nothing** to recovery (no post, no tombstone replayed) —
  the wiped peer simply never learns it existed (the correct deniable outcome).
  An edited message replays only as **post-at-final-body**, never the
  intermediate edit events. This avoids dangling edit/delete targets a recovering
  peer would hold forever.
- **R15 (compaction preserves seq continuity for live history).** For events
  that DO replay, compaction must keep the seq sequence gap-free for the wiped
  peer — either a body-less placeholder at each consumed seq, or a signed set of
  intentionally-compacted seqs the responder tells the peer to treat as
  satisfied (not a content oracle). Without this, recovery stalls at the first
  compacted hole (contradicting §7's "replay the entire log").
- **R16 (held cross-author authorization).** Bind a held edit/delete to its
  authorizing author at **hold** time; on target arrival apply **only if**
  `target.author == event.author`. A B-authored tombstone may born-delete only a
  B-authored post — closes the "B sends delete(target=X) before MY post X
  arrives → suppresses my message" censorship primitive.

### 11.9 Migration & what must NOT be retired

- **R17 (don't trust cross-version high-waters).** A mixed pair (one side
  migrated) **degrades to today's best-effort path** until **both** ends run the
  event protocol (the R3-pinned capability). The first event-protocol sync after
  migration runs with the **`isMessageDeleted` guard active** so no tombstoned
  content re-materializes. The §4.1 fold honors `isMessageDeleted`
  (conversation-scoped) as a **hard precondition** for applying any post/edit
  (deleted id ⇒ drop + advance high-water, never store).
- **R18 (back-fill is not free).** Assign per-`(conversation, author)` seq by
  ascending `(timestamp, log_id)`; map legacy no-seq frames into a non-colliding
  synthesized seq space; perform the rewrite **without** coalescing history into
  shared batches (R6). Note arrival-order ≠ send-order — back-fill from stored
  send time, not receive order.
- **R19 (retire nothing load-bearing).** Folding `flushOutbox` / `ack` / per-op
  `_maybeStash` into the §6 loop must **preserve**: per-message **delivery
  status**, the **storm backoffs** (`_retryBackoff`, `_stashRetryBackoff`,
  `_peerUnresolvedBackoff` / ghost give-up), and the synchronous
  **early-cancel** of just-acked messages. These are not incidental — they tamed
  real onion/seal storms. The unified loop must re-express them, not drop them.
- **R20 (efficiency / pagination dependency).** The fold + gap-fill must not
  re-scan the whole `MESSAGE_LOG` per tick (today `loadMessages` is O(file) and
  there is no pagination). Event-log sync should land **after / together with**
  message pagination (feature #3) and benefit from the Stage-2 fast-open work —
  not on top of the current full-scan read path.

### 11.10 Net

The event-log direction holds, but it is a **real protocol + store change**,
not a wire-only refactor: durable per-record `(author, seq)` + tombstone
skeletons (R4/R5), an enforced scrub guarantee (R6), authenticated author
binding (R1), strict consent gating of replay (R2), bounded buffers (R7),
monotonic/rate-limited sync (R8), receive-window ts (R9), per-conversation seq
(R10), per-event content-ids + per-round sealed deposits (R12/R13), and
unit-compaction with seq continuity (R14–R16). Implement in a dedicated session
**after** message pagination. **See §12 — a second review pass found §11
internally contradictory; §12 supersedes the conflicting parts and is the
authoritative model.**

---

## 12. Second-pass review — coherent re-resolution (SUPERSEDES conflicting §11)

A second adversarial pass (2026-06-26) checked whether R1–R20 actually close the
findings **and are mutually consistent**. Verdict (4/4 lenses): **not
implementable as written** — the §11 hardening introduced ~5 real contradictions
between normative rules, all confirmed against the store/messaging code. The core
event-log direction stands; the rules below replace the conflicting ones. Where
§12 and §11 disagree, **§12 wins**. R1, R5 (value-fold), R16, R17, R19 stand.

### 12.1 Deleted/compacted seq slot — ONE inert placeholder (resolves R4 vs R14 vs R15)

R4 (durable id-bearing tombstone slot), R14 (deleted replays *nothing*), and R15
(seq must stay gap-free) were three mutually exclusive answers, and R15's
"signed compacted-seq set" option is itself an activity oracle. **Resolution —
one observable, one artifact:**

- A consumed-but-superseded seq (delete, collapsed edit chain, compaction)
  replays on the recovery wire as an **inert placeholder** `(author, seq,
  kind=void)` — **no id, no body, no action semantics**. Gap-free (gap-fill
  advances) **and** indistinguishable between {deleted, edited-away, compacted}
  → no oracle, no deleted id on the wire. This is the single primitive; **R15's
  signed-set option is dropped**.
- **R14 narrowed:** the body + intermediate-edit *semantics* never replay, but
  the seq slot does (as a void). Drop R14's "never learns it existed" (a
  consumed slot is observable — already implied by the R11 seq-ceiling leak).
- **R4 becomes a LOCAL-fold rule only:** id-bearing tombstones live in the local
  store for born-delete suppression (R16) and are **forbidden on the recovery
  wire** (closes the "recovery leaks deleted ids to the recovered device" hole).
- Invariant test: recover a peer whose counterpart deleted X → assert X's id
  **never** appears in the recovered peer's `MESSAGE_LOG`.

### 12.2 Relay deposit — outer round-object + inner per-event key (resolves R12 vs R13)

- **Outer (relay):** one sealed blob per `(sender, recipient, author)`, content-id
  `H(recipient ‖ author ‖ covered_high_water)`; each round **overwrites** the
  prior blob (a later round is a monotone-superset of the unacked tail) → the
  relay holds **one in-flight blob per author** = "one deposit ≈ one cycle" (R13)
  **and** dedupable/bounded (R12). No overlapping un-evictable blobs.
- **Inner (receiver):** per-event idempotency key `(author, seq)` applied
  **inside** the sealed payload on drain. R12 = inner key; R13 = outer keying.

### 12.3 Scrub vs batching — R6 wins store-side, no `compact_known` on the live path (resolves R6 vs R13 vs R18/R20)

`vacuum_data_batches` scrubs a `DataBatch` only when **none** of its packed
log-ids stay referenced; R13/R18 batching defeats it. R6's `compact_known`
fallback is **unusable live**: it is container-wide, exclusive-lock, **keeps only
the supplied-password space and DROPS every decoy/duress space** (a duress break)
and can't run with a handle open. **Resolution:**

- **Strike R6's `compact_known` fallback.** Sole live-path guarantee: **one
  editable record per `DataBatch`** (a `append_log_isolated` store primitive, or
  one commit per editable post). The R13 round is one sealed *relay* blob but is
  applied **store-side as N isolated commits**.
- **`compact_known`** is reserved for the single-identity, all-handles-closed
  Storage→Compact UI (its existing gate).
- **Extend R6 to the repack path:** Stage-3 `compact_known` re-coalesces pages
  into shared batches → reopens the hole *after* a user compacts. The messenger
  repack must keep editable records one-per-batch (or add a **per-space
  repack-in-place** primitive — `vacuum` can't, `compact_known` is too
  heavy/destructive mid-session).
- **Recovery replay** (bulk) is applied as **one dense multi-record commit** (no
  bloat); historical messages outside the editable window need not be
  one-per-batch; on the first edit/delete touching a dense historical batch,
  repack just that batch. Resolves the R6-vs-storage-bloat tension.
- R6's prescribed regression test (edit one record in a **multi-record** batch →
  orphan chunk gone) **does not exist and would fail today** → a **ship gate**.

### 12.4 Recovery vs anti-amplification — rate-limit + epoch, not value-clamp (resolves R8 vs R2/§7)

R8's "an accepted contact's zeroed high-water is already satisfied" **silently
kills Case-A recovery** (a wiped-but-identity-surviving peer is *still accepted*
on our side → ships nothing → deadlock). **Resolution:**

- Anti-amplification via **rate-limit** (one replay pass per per-peer backoff
  window; reuse `_peerUnresolvedBackoff`) + a monotonic **sync-epoch/nonce per
  round**, **not** a high-water value clamp.
- A high-water **dropping to zero / below a previously-acked floor** from an
  accepted contact is a **WIPE SIGNAL** → a distinguished **authenticated**
  recovery trigger (a recovery flag on `sync`, or a retained `WireKind.reconnect`
  — do **not** collapse reconnect into a bare sync). The one sanctioned
  exception to "already satisfied", gated by: (a) authenticated `m.src` == the
  accepted contact (R1); (b) **R2 re-consent** (wiped peer re-enters as
  `pendingIncoming`, user re-accepts, *then* replay); (c) one replay per backoff
  window; (d) capped to the non-compacted log.
- **§7 corrected:** a bare `sync{you:0}` from a contact we hold no longer
  "replays the entire log".

### 12.5 Gap repair — named holes exempt from the clamp (resolves R7 vs R8)

Advertise **two** numbers per author — the contiguous high-water **and** an
explicit set of known holes (`have 1–3 & 5–7, missing 4`). The peer ships
**named holes directly** (idempotent, bounded); a named-hole re-request is
**exempt** from the rate-limiter (targeted repair, not a flap). Without this,
R7's soft gap-skip + R8 = permanent silent divergence about a skipped seq.

### 12.6 Timeline order — author-monotone ts from the event set (resolves the R9 cross-device hole)

R9's flooring to **per-device receive-time** makes the same event get a different
`effective_ts` on each device → honest devices show different orders.
**Resolution:** `ts` = the author's clamped send time (identical on both
devices). Defend the `ts=0` attack **structurally**: floor a peer's `ts` to
**that peer's own previous max ts** (monotone-per-author, a function of the event
set alone → both devices compute it identically). Keep `_wireSentAt`'s
future-clamp. Order = `(effective_ts, author, seq)`, **stable** sort. An attacker
can then only mis-order **its own** events (the real §10.8 intent).

### 12.7 Log-id ceiling — per-conversation namespaces (resolves the new ~15K-cap hole)

A single shared `MESSAGE_LOG` namespace for **all** conversations + R4's
never-dropped tombstones hits hidden-volume's **~15K-log_id-per-namespace cap**
(`Error::IndexFull`) → **all** sends fail globally for a heavy user, and deleting
a chat *adds* tombstone slots. **Resolution (mandatory):** partition the event
log **one hidden-volume Log-namespace per conversation** (R10's per-conversation
seq is the natural partition; the store's own note recommends it). Seq, gap-fill,
placeholders, and the cap are all **per-conversation**; a per-conversation
repack/roll-over triggers off `SpaceStats.utilization_ratio`. Bounds R4
tombstones per chat and strengthens R10 isolation.

### 12.8 Capability pin — per acceptance-epoch (resolves the new R3 reinstall hole)

A permanent TOFU pin can't handle a Case-A wipe (the wiped peer's pin is gone) or
a reinstall. **Resolution:** the pin is per-**(contact, acceptance-epoch)**, reset
**only** on an **authenticated re-accept** that carries the capability advert
inside the authenticated accept (R1 + §9). A downgrade **not** accompanied by a
full re-accept stays "anomalous → ignore" (R3's attack resistance kept); a genuine
re-accept is the sanctioned reset.

### 12.9 Build order (corrects §11.10)

The fold/sync/compaction/recovery rules are **mutually dependent → ship as ONE
atomic unit** (they can't land incrementally on a record without durable
`(author, seq)`). Independently-shippable first: **R1 (author binding), R2
(consent gating), R3/§12.8 (capability pin), R6/§12.3 (scrub guarantee + its
regression test).** Then the atomic convergence+recovery feature: §12.1–12.2,
§12.4–12.7, R5/R10/R16/R17/R19.

### 12.10 Net (post-second-pass)

The store + protocol changes are **larger than first scoped**: per-conversation
Log-namespaces, durable per-record `(author, seq)`, inert void placeholders,
isolated-batch scrub (+ a per-space repack primitive), two-layer relay dedup, and
an authenticated recovery trigger. Two adversarial passes have replaced every
first-draft hand-wave with a concrete, mutually-consistent constraint — the point
of reviewing the design before the code. A short third pass to confirm §12's own
consistency is cheap insurance before implementation begins.
