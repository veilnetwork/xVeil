# Event-log conversation sync — design

> ⚠️ **READING ORDER / NORMATIVITY.** This doc grew through three adversarial
> review passes. **§13 is the current authoritative status; §12 supersedes §11;
> §11 supersedes the §1–§10 narrative.** §1–§10 are the first-draft model and
> contain claims later proven WRONG (e.g. "the substrate already does this" §3 —
> false; "(ts,author,seq) is a sound total order" §4.1 — false; the §5/§6
> deposit/sync sketch — superseded by §12.2/§12.4). **Do not implement from
> §1–§11 directly.** **§14 is the FINAL authoritative status** — a verification
> audit found §13.2's "substrate-blocked" verdict **OVERSTATED**: B1 (veil) is not
> a blocker, B2/B3 are far smaller than §13 claimed, and the scoped option-2 needs
> **zero** substrate work. Read §14 first.

Status: **DESIGN — BUILDABLE (see §14 substrate + §15 protocol spec).** Decision
(user, 2026-06-26): **Option 1 — full event-log.** Per §14 there is **no veil
work** and the substrate change is a *bounded* hidden-volume effort (deferrable
to scale); per §15 the protocol resolutions are settled and the v1 builds on the
**existing substrate**. Would supersede the imperative
edit/delete/ack/reconnect mechanism. Implement in a dedicated session per §15.6.
(The earlier "blocked on substrate" framing of §13 was corrected by §14.)

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

---

## 13. Third pass + external audit — STATUS: blocked on substrate (authoritative)

A third adversarial pass (against the real hidden-volume + veil-mailbox internals)
plus an independent external audit converged on the same conclusion: **§12 is more
coherent than §11 but is NOT a buildable spec.** The remaining blockers are no
longer protocol logic — they are **substrate primitives that do not exist**, so a
fourth protocol-resolution pass cannot fix them. This is the design's key finding:
**the event log is a substrate-first, multi-repo (hidden-volume + veil + xVeil)
effort, larger than a Dart-layer feature.**

### 13.1 What is clean and survives

`§12.1` (one inert void placeholder — modulo the void-vs-hole disambiguation in
§13.3), `§12.4` (recovery = rate-limit + epoch + authenticated wipe-signal +
R2 re-consent — modulo two edge cases), `§12.8` (capability pin per
acceptance-epoch), `§12.9` (build order), and `R1` (author bound to `m.src`),
`R2` (consent gating), `R5` (seq-gated LWW value-fold). These are sound.

### 13.2 SUBSTRATE PREREQUISITES (the real blockers — must be built first)

- **B1 — relay overwrite / sealed content-id (veil).** §12.2's "one in-flight
  blob per author, overwritten each round" is **unimplementable**: `veil-mailbox
  put_classified` is **first-write-wins** (same `(receiver, content_id)` →
  `Duplicate` no-op) — there is **no overwrite/replace**. And `content_id` is
  **cleartext to the relay** (`receiver_id|content_id|sender_id|blob`), so a
  stable per-`(recipient,author)` key (needed for overwrite) is a linkable
  per-correspondent handle today's random-uuid content-id denies, and a
  `covered_high_water`-derived key leaks sync progress (low-entropy → brute-force).
  **Need:** a relay replace/supersede primitive AND/OR an opaque, unlinkable,
  per-deposit content-id — a veil change, before §12.2/§12.4 deposit semantics
  can exist.
- **B2 — per-conversation log partition WITHOUT the namespace byte (hidden-volume).**
  §12.7 ("one Log-namespace per conversation") is **infeasible**: `Namespace` is a
  **`u8`** (≤256 ids ever, ~250 after the system namespaces), with **no recycling**
  (Inv-W1 forbids in-place reuse; `compact_known` is barred multi-identity), so it
  caps a user at **~250 conversations *ever* per identity**; and the full active
  root set must fit one Commit chunk → **`MAX_NAMESPACES_PER_TX ≈ 95`** live
  namespaces → sends fail globally past ~95 chats — a **smaller** cap than the
  ~15K-log_id one §12.7 set out to fix. Also `eraseSpace` forensically erases a
  **hard-coded 5-namespace list**, so dynamic namespaces 6..N **survive a wipe**
  (deniability break). **Need:** partition the **`u64` log-id space** per
  conversation inside the *existing* `MESSAGE_LOG` namespace (e.g. a
  conversation-id prefix in the log-id), not the namespace byte — and a
  per-conversation IndexFull/roll-over story — OR widen `Namespace` + make
  `eraseSpace` enumerate dynamically. A hidden-volume change either way.
- **B3 — decoy-preserving per-space batch repack (hidden-volume).** §12.3's
  `append_log_isolated` and `per-space repack-in-place` **do not exist**, and
  in-place rewrite is **forbidden by Inv-W1**; the only real mechanisms are
  `vacuum` (scrubs only *unreferenced* chunks — can't re-split a still-live dense
  batch) and `compact_known` (container-wide, exclusive-lock, **DROPS every
  decoy/duress space** — a duress break, correctly barred on the live path per
  `app_controller.canCompactStorage`). So the forward-secrecy scrub guarantee is
  **relocated onto unbuilt code, not closed**. **Need:** either commit every
  editable post one-record-per-`DataBatch` (accept the commit/padding cost +
  reconcile with the storage-bloat work) OR a new format-gated, decoy-preserving,
  per-space batch-repack primitive in hidden-volume. + R6's prescribed regression
  test (edit one record in a multi-record batch → orphan chunk gone) as a gate.

### 13.3 Remaining protocol contradictions (need a 4th pass AFTER B1–B3 are decided)

- **§12.2 vs §12.5** — overwrite-per-author blob vs named-hole **subset** repair (a
  subset clobbers the tail); resolution direction: named-hole/recovery deposits get
  **distinct content-ids** (additional blobs, never an overwrite of the tail) —
  but this depends on B1's chosen relay semantics.
- **§12.3 internal** — "one editable record per batch" vs "bulk recovery as one
  dense commit": dense recovery puts editable posts in shared batches → the FS hole
  reopens in the recovered-history window. Resolution depends on B3.
- **§12.6 vs §12.5/§12.1** — author-monotone `ts` is a function of the **locally-held
  subset**, not the event set, so honest devices diverge on display order *during a
  gap window* (converges once the gap repairs). Acceptable IF documented as
  "order converges on convergence"; the §4.1 fold must be **purely seq/causal**,
  `ts` **display-only** (the external audit's fold-vs-display point).
- **§12.1 void-vs-hole** — the recovering peer must treat a replayed void at seq N as
  **satisfied**, never a hole to re-request (else permanent re-request). One line.
- **§12.4 edges** — forged drop-to-zero re-consent annoyance (R1-bound, backoff-
  throttled; low); **both-sides-wiped** deadlock (after re-consent neither holds the
  other accepted — needs a defined mutual-reconnect path).

### 13.4 Gaps the passes + external audit surfaced (in-scope for the redesign)

- **Files/attachments are entirely absent from the model** — the event model is
  `post/edit/delete` with a `body`, but the wire has `fileMeta`/`fileChunk` and
  `Message` has `fileId`/`fileName`. How a file message is an event, how chunks
  sync, and what `scrub`/`void` mean for an attachment are **unspecified**.
- **`high-water`-as-delivery-ack ambiguity** — §5/§6 use `sync` as both ack and gap
  query; after §12 it is unclear whether R7's clamp to `my_highest_emitted_seq`
  is still normative. A peer can falsely "ack" a high-water → eternal hole or
  wrong delivered-state. Pin the rule.
- **Named-hole rate-limit (external High)** — §12.5's "exempt from the rate-limiter"
  is itself a replay/seal amplifier; needs per-hole dedup + cooldown +
  "already-answered-in-epoch-N".
- **Doc hygiene** — strike/annotate the superseded §1–§10 claims inline (banner
  added at the top); the code comments already mis-state "per-conversation
  MESSAGE_LOG" (`storage.dart`, `chat.dart`) though the adapter uses a single
  `Ns.messageLog` — fix the comments so nobody assumes B2 is done.
- **WireKind compat test** — the old decoder falls back to plain `message` on an
  unknown `t`; add a test that an un-upgraded peer never renders a JSON event/sync
  frame as a normal message under any capability-negotiation failure.

### 13.5 Meta-verdict and the decision this forces

Three internal passes + one external audit have **converged**: the protocol logic
is now well-understood, but it sits on substrate that **cannot host it as-is**
(B1–B3). Further protocol-only passes have hit diminishing returns — they keep
discovering that the next resolution needs a store/relay primitive that doesn't
exist. The honest options:

1. **Substrate-first full build.** Land B1 (veil relay), B2+B3 (hidden-volume)
   as their own reviewed efforts, THEN a 4th protocol pass on §13.3, THEN the
   xVeil Dart implementation. Largest; truest to the full event-log + recovery.
2. **Scope down to "reliable edit/delete + offline reconcile" on the EXISTING
   substrate.** Keep today's per-message model; add a durable edit/delete outbox
   (retry like text), idempotent receiver apply, and a bounded reconcile — **no
   per-conversation namespaces, no CRDT recovery, no relay overwrite**. Delivers
   the user's actual pain (the edit/delete-offline bug, already tactically fixed)
   + divergence repair, for a fraction of B1–B3. Recovery (#9) stays the simpler
   bounded `reconnect` from the recovery-handshake note.
3. **Park it.** Ship the feature-list items (pagination, metadata, chat-mgmt) on
   the current model; revisit the event log when the substrate work is justified.

Recommendation: **option 2** unless full multi-device CRDT recovery is a hard
requirement — it captures most of the value without the two-repo substrate
rewrites, and B1–B3 can be added later if/when option 1 is justified.

---

## 14. Verification audit — §13.2 blockers were OVERSTATED (FINAL authoritative)

After §13, a **verification pass audited the §13 auditors** against the real
veil-mailbox + hidden-volume code (plus an independent external audit). It
**confirmed the raw facts** (mailbox `put_classified` is first-write-wins on
`(receiver, content_id)` — veil-mailbox `lib.rs:731`; `Namespace` is a `u8` —
`index.rs:58`; `compact_known` is unsafe in multi-identity — `app_controller.dart`
`canCompactStorage`) but found §13.2's **conclusions overstated**. Corrected,
code-grounded reality:

### 14.1 B1 (veil relay) — NOT a blocker; no veil change needed

- The relay does **not** need an overwrite/replace primitive. §12.2's "one blob
  per author, overwritten each round" is **one** way to bound relay state, not a
  requirement. The needed semantics — a later round supersedes the prior in-flight
  blob — is **already achievable on the existing API**: deposit each round under a
  **fresh opaque content-id** and ack / let-TTL-drop the superseded one (TTL =
  `DEFAULT_TTL_SECS` 7d, `prune_expired`; ack at `lib.rs:989`). This is **exactly
  the put-new/ack-old pattern `edit:`/`del:` already use** (`messaging.dart:900`).
- `content_id` is **not** a random uuid (the §13.2 premise) — it is a
  deterministic domain-separated `blake3DeriveKey('veil.mailbox.content_id.v1', id)`
  (`messaging.dart:863`); distinct `edit:`/`del:` prefixes already give per-event
  ids. So **R12 (per-event content-id) is already shipped** for the imperative
  path — zero substrate work. A keyed-BLAKE3 per-deposit id stays unlinkable (no
  cleartext correspondent handle, no high-water leak).
- **Action:** drop B1 from the plan. §12.2 should be re-specced as
  "fresh-content-id-per-round + ack/TTL", not "overwrite". The single-blob-per-
  author CRDT optimization is a *defer-able nicety*, not a prerequisite.

### 14.2 B2 (hidden-volume namespace + log-id) — reframed, much smaller

- **"~250 conversations EVER / no recycling" is FALSE.** A namespace byte is
  **recyclable**: an emptied namespace is omitted from the next Commit's roots
  (`space/commit.rs:243`) and the byte is free to reuse (proven by
  `tests/erase_namespace.rs` `write_after_erase_recreates_namespace`). Inv-W1
  forbids reusing a physical **slot index**, not a namespace byte. Real cap =
  **~95 LIVE namespaces at once** (the active root set must fit one Commit chunk,
  `MAX_NAMESPACES_PER_TX`), which recycles — not a lifetime ceiling.
- **Per-conversation seq (R10) is FREE:** keep the single `MESSAGE_LOG` namespace
  and put a **conversation-id prefix in the u64 log-id** — existing-API usage rule,
  zero substrate change. (But this does **not** raise the IndexFull ceiling.)
- **The ~15K-log-id IndexFull cap is real and is per-namespace-TOTAL** (one log-id
  per message in one flat B+ tree; `space/commit.rs:208`, `index.rs:404`). The
  prefix does **not** relieve it. Cheapest relief, in order: (1) **per-conversation
  namespace** (≤~95 live, recyclable — fine for the vast majority of users); (2)
  the already-noted **3-level index** (`R-LOG-INDEX-3L`, `index.rs:23-26`) to raise
  the per-namespace cap if truly unlimited chats are needed. Either is a *bounded*
  hidden-volume change, not a wall.
- **eraseSpace deniability fix** (dynamic namespaces 6..N must be erased on wipe):
  enumerate via the **existing `list_namespaces()` FFI** instead of the hard-coded
  5-namespace list — a small FFI/Dart plumb, **no format change**.

### 14.3 B3 (scrub-vs-batch) — a USAGE RULE, not a missing primitive

- "One editable record per `DataBatch`" is the **default of today's per-op model**:
  every `appendMessage`/`editMessage`/`deleteMessage` is its own commit → its own
  singleton batch (`hidden_volume_storage.dart:357,416,448`; FFI one-`begin_tx`-
  per-commit). `append_log_isolated` is **unnecessary** — append+commit already
  give it.
- Inv-W1 "in-place rewrite forbidden" is **overstated**: vacuum's scrub-to-random
  **is** an in-place byte overwrite of an orphan slot (an explicit FS carve-out,
  `vacuum.rs:87`). A format-gated per-space scrub+repack is **permitted** by Inv-W1
  (the narrow ban is a *second* overwrite with new live data).
- The FS hole exists **only** in the event-log's BATCHED paths (R13 N-events/round,
  bulk recovery, the existing coalesced `removeConversation`), **not** in today's
  per-op model. **Rule:** keep editable events one-record-per-commit; apply bulk
  recovery one-per-commit too (accept the per-commit padding — already cut 4× to
  256 KiB buckets). + R6's regression test.

### 14.4 Corrected decision (records the user's choice)

- **Option 2 (reliable edit/delete + offline reconcile on the existing substrate)
  needs ZERO substrate work** — today's per-op model is already FS-safe, the relay
  already does distinct-content-id offline deposits (shipped: the `edit:`/`del:`
  mailbox fix), and per-conversation seq is a free log-id prefix. Pure xVeil Dart.
- **Option 1 (full event-log) — the user's choice — is MUCH smaller than §13
  implied:** **no veil work** (B1 dropped); hidden-volume reduces to (a) the small
  `eraseSpace`/`list_namespaces` fix, (b) **one bounded choice for IndexFull**
  (per-conversation namespaces, ≤~95 live, OR the `R-LOG-INDEX-3L` index change),
  (c) a usage rule (one-record-per-commit for editable events) + R6's test; then
  the 4th protocol pass (§13.3) + the §13.4 gaps (files, high-water-as-ack,
  named-hole cooldown, WireKind normative decode rule) + the Dart build.
- **Sequencing (option 1, corrected):** start in **hidden-volume** — (1)
  `eraseSpace`→`list_namespaces` deniability fix (smallest, independently
  shippable), (2) decide IndexFull relief (per-conversation namespace vs 3-level
  index) and build it, both with the established HV pre-tag gate; **no veil
  session needed**; then the 4th protocol pass; then the xVeil Dart event-log.

**Net:** the substrate is a *bounded* hidden-volume effort plus protocol work —
not the two-repo wall §13 described. The verification pass paid for itself by
stopping a needless veil project and a wrong "permanent ~250-chat cap" panic.

---

## 15. Buildable protocol spec — pass-4 resolutions (FINAL, with §14)

A fourth pass RESOLVED the §13.3 contradictions in light of §14, designed the
missing files model, and closed the §13.4 gaps; an external audit confirmed the
remaining doc-consistency items. §15 is the implementation contract: §14
(substrate) + §15 (protocol) supersede §1–§13. **It builds on the EXISTING
substrate;** the only deferred substrate item is IndexFull relief (§15.5).

### 15.0 Decision record (single, authoritative)

**Option 1 (full event-log) is chosen.** No veil work. Hidden-volume change is a
bounded, deferrable IndexFull relief. The v1 below is **pure xVeil-Dart on the
existing substrate** (+ one hidden-volume scrub regression test). This record
supersedes §13.5's "recommend option 2" and §11/§12's "must-have" framings.
**"Zero substrate" ≠ "zero work":** the Dart event-log (durable per-record
`(author,seq)`, the fold, sync/gap-fill, the recovery handshake, files) is real
implementation — today's `edit`/`del` are still fire-and-forget and not in the
`flushOutbox` retry loop (`messaging.dart:887,908,745`); the event-log replaces
that with the unified §15.3 loop.

### 15.1 Protocol resolutions (the §13.3 items, now decided)

- **R-DEP (no-overwrite deposit — DISSOLVES §12.2 vs §12.5).** Every deposit — a
  contiguous round OR a named-hole repair — is its own opaque blob under its own
  fresh content-id (`_contentIdFor(tag)`, `messaging.dart:863`; tag = a round
  nonce, or `hole:<author>:<lo>-<hi>:<epoch>`). Nothing is overwritten, so a
  subset hole-blob never clobbers a tail-blob. Receiver dedups/applies the INNER
  `(author,seq)` key on drain; a blob is acked or TTL-dropped once its seq range
  is covered. Relay-state is bounded by a *deposit-cadence* policy (cap distinct
  in-flight ids per `(recipient,author,epoch)` + jitter — reuse `_stashed` /
  `_stashRetryBackoff` / `_peerUnresolvedBackoff`), NOT by overwrite. **Already
  the shipped pattern for `edit:`/`del:`** → zero veil change.
- **R-ORDER (§12.6 — two layers).** (1) FOLD/APPLY is purely seq/causal and
  **ts-free** (R5 value-fold; an edit/delete applies iff the target exists and
  `target.author == event.author`, R16). (2) DISPLAY sorts by `(effective_ts,
  author, seq)` with a **stable** sort, where `effective_ts(e) =
  max(future_clamp(e.ts_raw), running_max_ts_of_e.author_over_APPLIED_events_with_seq<e.seq)`
  — an author-monotone floor that is a function of the **applied event subset**,
  identical on two devices holding the same subset. Reject R9's receive-time
  floor. **Documented invariant:** *display order converges on event-set
  convergence; transient divergence is bounded to the gap window and self-heals.*
  Fix `loadMessages`'s non-stable `List.sort` (`hidden_volume_storage.dart:344`)
  to the `(author,seq)`-tiebroken stable sort (needs the durable `(author,seq)`).
- **R-VOID (§12.1 void-vs-hole — one line).** An inert void `(author,seq,kind=void)`
  on the wire **advances the contiguous high-water like any applied event** = it
  is SATISFIED, never recorded as a missing seq, never a named hole. A named hole
  is only an ABSENT seq below the high-water. (An out-of-order void buffers in the
  bounded R7 gap buffer and applies when contiguous.)
- **R-RECOVER2 (§12.4 both-sides-wiped).** Route through the **explicit
  authenticated recovery trigger** (the absorbed recovery-handshake — §15-inlined
  below; do NOT collapse it into a bare sync): either side, on un-acked-past-
  threshold or wanting to reach a non-accepted peer, sends an authenticated
  `reconnect`; the receiver disambiguates by its own state; both-wiped → both
  re-introduce as `pendingIncoming`, both re-accept, then both replay from zero.
  Forged-drop-to-zero is bounded by R1 (authenticated `m.src`) + backoff +
  `kMaxPreConsentIntros`.
- **R-SCRUB2 (§12.3 — restated).** Scrub-safety is governed by *whether a record
  is ever editable/deletable*, not by the write path: **any ever-editable event is
  committed one-record-per-`DataBatch` (one per-op commit) on EVERY path — live,
  edit, delete, AND recovery replay.** That is the existing per-op default
  (`hidden_volume_storage.dart:357,416,448`); accept the per-commit padding (cut
  4× to 256 KiB). Historical, no-longer-editable posts (outside an "editable
  window" — define as last-N or last-T) may be dense. + the R6 regression test.

### 15.2 Files / attachments model (the gap every prior pass missed)

- **A file message is ONE `filePost` event** (a new appended `WireKind`) whose
  body is the descriptor `{name,size,count,blobKind}` (the shape
  `fileMetaEnvelope` already serialises, `wire_envelope.dart:90`); its id is the
  existing file-message id. **Chunks are NEVER events.**
- **Two planes.** PLANE 1 (seq): only the `filePost` participates in
  seq/gap-fill/high-water (idempotent on `(author,seq)`), exactly like a text
  post. PLANE 2 (bytes): chunks stay out-of-band over the existing
  `fileMeta`/`fileChunk` + `FileReassembler` (`messaging.dart:524`,
  `file_transfer.dart:92`), dedup by `transferId`+index. v1 blob gap-fill =
  sender re-streams an un-acked file on reconnect (covers the real pain;
  wiped-peer-wants-old-file is a documented deferral).
- **Edit / delete / void of a file.** Edit = caption/text-body only (bytes are
  immutable). Delete/void MUST atomically tombstone the `MESSAGE_LOG` row AND
  **purge the blob + every `Ns.fileChunks` record** (scrub). FS holds on the
  existing substrate because **each file's chunks are committed in a single
  commit → its own isolated `DataBatch` set** (`file_store.dart:34`), so a delete
  cleanly orphans+scrubs them. A re-delivered/re-streamed transfer of a DELETED
  file must hit the `isMessageDeleted` guard (no resurrection).

### 15.3 §13.4 gaps — normative rules

- **RULE HW (high-water = ack + gap cursor).** A `sync` carries per-author
  contiguous-applied high-waters. **Anti-forgery:** clamp a peer's claimed
  high-water *about my author-stream* to `my_highest_emitted_seq` (a peer can't
  ack a seq it was never owed). Delivery/read state (`MessageStatus`) is derived
  **only** from a contiguous, monotone, clamped high-water — never from a raw
  claimed value. R8's value-clamp is NOT the knob (it kills Case-A recovery, §12.4);
  HW is an anti-forgery clamp, not a recovery suppressor. Legacy per-id `ack`
  keeps working in a mixed-pair window.
- **RULE NH (named-hole governor — supersedes §12.5's bare exemption).** A
  named-hole repair is exempt from the *coarse* per-peer reconcile rate-limiter
  (so a legit gap repairs promptly) but governed by a **per-hole** governor: a
  monotonic sync-epoch/nonce per round + an `answeredHole[(peer,author,range)]`
  ledger → the responder answers a given hole **once per epoch** (dedup +
  cooldown), so a broken/hostile accepted peer can't storm. A replayed void is
  SATISFIED (R-VOID), never re-requested as a hole.
- **RULE WC (WireKind compat — defense-in-depth, BOTH required).** (1) CAPABILITY
  GATE: an `event`/`sync` frame is emitted **only** to a peer pinned event-capable
  per the §12.8 per-`(contact,acceptance-epoch)` pin (set only via an authenticated
  re-accept advert). (2) STRUCTURAL MARKER: event/sync frames carry a marker (a
  reserved `v:2` key on the `{t,b}` envelope) so the legacy decoder — which today
  falls back to plain `message` on an unknown `t` (`wire_envelope.dart:55`) — can
  **detect-and-drop** rather than mis-render them as a chat message. **Regression
  test:** an un-upgraded decoder fed an event/sync frame yields *no rendered
  message* (drop), never a JSON blob shown as text.

### 15.4 Per-conversation seq layout (the external audit's underspec)

Per-conversation seq (R10) on the single `MESSAGE_LOG` namespace via a **u64
log-id prefix**: `log_id = (conv_slot << S) | conv_seq`, where `conv_slot` is a
per-conversation index assigned on first message (a small KV `conv_slot` map in
SETTINGS) and `conv_seq` is the per-conversation monotonic counter. This gives
(a) per-conversation seq for the protocol, and (b) a contiguous **prefix range
scan** per conversation (`[conv_slot<<S, (conv_slot+1)<<S)`) — which **also
serves message pagination** (load latest N of one chat without a full log scan).
It does **NOT** relieve IndexFull (still per-namespace-total — §14.2). Pin: the
bit split `S` (e.g. 40 low bits = 1T msgs/conv, 24 high = 16M convs), the
migration from today's global `msg_next_id` (`hidden_volume_storage.dart:357`)
(re-key new messages; legacy messages keep a reserved `conv_slot=0` legacy range),
and that `loadMessages` becomes a prefix range scan.

### 15.5 v1 must-have (existing substrate) vs deferred

**v1 (pure Dart + 1 HV test, existing substrate):** R1 (author=m.src), R2
(consent), R5 + R-ORDER fold, durable `(author,seq)` via §15.4 prefix, R-DEP
deposit, RULE HW, R-VOID, R-SCRUB2 (per-op commit) + R6 test, RULE NH, RULE WC,
§15.2 files, R-RECOVER2 + the inlined recovery handshake, §12.8 epoch pin.
**Deferred (bounded HV, at scale):** IndexFull relief (per-conversation namespace
≤~95 live, OR R-LOG-INDEX-3L) + the `eraseSpace`→`list_namespaces` fix (only once
dynamic namespaces exist).

### 15.6 Build order

1. **Storage foundation:** durable per-record `(author,seq)` + §15.4 prefix layout
   + the stable `(author,seq)` sort + the R6 one-record-per-batch scrub test.
   (This also unlocks message **pagination** as a side effect — do it first.)
2. **Fold + apply** (R5/R-ORDER/R-VOID/R16) over the durable records.
3. **Sync/gap-fill loop** (R-DEP/RULE HW/RULE NH) replacing `flushOutbox`+`ack`+
   per-op stash; **RULE WC** capability gate + structural marker first so no frame
   ever reaches an un-upgraded peer.
4. **Files** (§15.2) and **recovery** (R-RECOVER2 + inlined handshake + §12.8 pin).
5. **Deferred:** IndexFull relief when a real user nears the cap.

### 15.7 Recovery handshake (inlined — was an external memory ref)

The absorbed recovery-handshake (previously only in an agent memory note, not the
repo — external audit #5): Case-A = chat data lost but identity (node keypair)
survives → `node_id` stable → peer can still reach you. New authenticated
`reconnect` (greeting-like, "we were connected"), sent when a message stays
un-acked past ~2 min, **bounded** (~5–6 tries over ~1–2 h, then "not delivered" +
manual retry — not forever). Receiver disambiguates by its own state: blocked →
silent drop (no oracle); unknown/pending → surface as `pendingIncoming` "wants to
reconnect" under `kMaxPreConsentIntros`; already-accepted → re-ack. Offline-vs-
wiped is indistinguishable from outside (good — no presence oracle). Case-B =
identity also lost → new `node_id` → unrecoverable by protocol → manual re-invite,
shown honestly. The mailbox is the durable carrier (deposits wait for retention).
Optional `chatClosed` (intentional delete → "peer can re-invite") is opt-in,
default-OFF (deniable).

---

## 16. Media + storage tiering (DESIGN — extends §15.2; on-disk tiers need a deniability review before code)

Planned: files / images / video / stickers / emoji, plus a user setting to keep
**heavy** blobs **outside** the encrypted volume (optionally encrypted on disk).
The on-disk option is a **deniability trade-off** and must be designed, not just
flagged — §16.3 is load-bearing.

### 16.1 Media kinds (unify under the §15.2 `filePost`)

One `filePost` event with a `mediaKind` and a descriptor body; bytes stay
out-of-band (§15.2 plane 2):

- **emoji** — Unicode text; renders inline in a normal text `post`. No storage
  change. (Emoji *reactions* to a message are a future event kind, post-v1.)
- **sticker** — a reference to a **reusable asset** `sticker:<pack>:<id>`, NOT a
  per-message blob. The asset is cached once locally (small, in-volume) and
  dedup'd across all uses; a sticker message is tiny on the wire. Packs are
  bundled or fetched-and-cached.
- **image** — full blob + an always-**in-volume thumbnail** (small, e.g. ≤64 KB,
  for instant deniable preview); descriptor carries `{w,h,mime,thumbRef,blobRef}`.
- **video** — like image (poster-frame thumbnail in-volume) + `durationMs`.
- **file** — generic blob, no thumbnail (mime-type icon).

Descriptor: `{name, size, mime, mediaKind, w?, h?, durationMs?, thumbRef?,
blobRef, blobTier}`. The **thumbnail is always in-volume** (deniable preview,
scrubbable); only the **full blob** is tiered (§16.2).

### 16.2 Storage tiers for the full blob

Per file, the full blob lands in one of three tiers, chosen by the LOCAL policy
(sender's tier ≠ receiver's tier — each device stores per its own setting; the
wire carries only the descriptor + bytes):

1. **In-volume (DEFAULT — fully deniable).** Blob in the hidden-volume container
   (`Ns.fileChunks`), scrubbable on delete, hidden by lock + decoy/duress. Cost:
   container bloat + ~15K-log-id pressure (§14.2) + large-blob perf in the
   log-structured store.
2. **On-disk, ENCRYPTED (opt-in).** Blob AEAD-encrypted under a **per-file key**
   and written to the plain app-data filesystem, NOT the container. The container
   holds only the descriptor + the per-file key (tiny → no volume bloat, no
   IndexFull pressure). Confidentiality preserved; **deniability degraded** (§16.3).
3. **On-disk, PLAINTEXT (separate opt-in — most compatible, least private).** Blob
   written unencrypted (max perf, OS "open in app" integration). NO
   confidentiality, NO deniability. Explicit opt-in + warning; for genuinely
   innocuous media only.

**Routing setting:** a size threshold (e.g. "blobs > N MB go to disk") + the two
tier toggles (on-disk-encrypted, on-disk-plaintext). **Default = everything
in-volume.** The user opts into on-disk for heavy media to avoid bloat/perf/cap.

### 16.3 Deniability analysis (load-bearing — the on-disk tiers trade deniability)

- **Default stays fully deniable.** No behavior change unless the user opts in.
- **On-disk ENCRYPTED — confidential but existence-revealing.** A forensic
  adversary on a seized device sees the **existence, size, and count** of
  encrypted blobs on plain disk → "this device holds hidden encrypted data" — a
  signal you **cannot deny**, and one a **decoy/duress unlock does not hide**
  (on-disk files live outside any space, so a duress unlock of a decoy reveals
  them). The *content* is safe (AEAD under a per-file key derived from the real
  space key, so a decoy/duress space cannot decrypt it), but the *fact* leaks.
  **⇒ explicit opt-in + a blunt warning** ("files kept outside the encrypted
  container are visible on this device even when locked or under duress").
- **Forward-secrecy on delete WITHOUT reliable disk erase (elegant).** Keep the
  per-file key **in-volume**; on delete, **scrub the key** (the existing
  forensic-erase). The on-disk ciphertext then becomes cryptographically inert —
  **unrecoverable even if the raw disk bytes survive** (SSD wear-levelling /
  journaling FS make secure-erase unreliable, so we do not depend on it). Disk
  file unlink is best-effort hygiene on top.
- **On-disk PLAINTEXT** has no protection — recoverable by disk forensics even
  after delete; for innocuous media the user explicitly accepts that.
- **Capacity bonus:** moving heavy blobs out of the volume **relieves the ~15K
  IndexFull pressure** (§14.2) — an on-disk blob costs one in-volume metadata
  entry, not a chunk run. So the on-disk tier is also a lever for the deferred
  capacity story.

### 16.4 Delete / scrub per tier

- **In-volume:** existing scrub (forensic erase of the blob's `DataBatch` set; §15.2).
- **On-disk encrypted:** scrub the in-volume **key** (makes the ciphertext inert)
  + best-effort `File.delete`. A re-streamed/re-delivered copy hits the
  `isMessageDeleted` guard (no resurrection), and the key is gone, so it cannot be
  decrypted even if re-written.
- **On-disk plaintext:** best-effort `File.delete` + overwrite; warn it is
  forensically recoverable.

### 16.5 v1 vs deferred + the gate

- **v1 (existing substrate, default deniable):** the §15.2 `filePost` model +
  in-volume blobs (+ in-volume thumbnails for image/video). Stickers as cached
  asset refs. Emoji free. This needs **no** tiering.
- **Deferred (opt-in, AFTER a focused deniability review):** the on-disk
  encrypted + plaintext tiers + the routing setting + the per-file-key scrub.
  **Gate:** the on-disk tiers must pass a deniability review (the existence/size
  leak, the decoy/duress interaction, the key-scrub forward-secrecy claim, the
  cross-space key isolation) before implementation — same discipline as the
  event-log itself. The threat-model boundary (T2' multi-snapshot, T3 coercion)
  changes the moment a blob leaves the container.
