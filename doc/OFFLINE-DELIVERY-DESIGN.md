# Offline delivery (mailbox / rendezvous) — design

Status: **draft for review** (no code yet). Closes the "messages are lost when a
peer is offline" gap flagged in live testing.

## 1. Problem

xVeil sends chat over a live veil **session** (`app.send`). If the recipient is
offline there is no session, so the message is dropped — never re-delivered when
they return. We need store-and-forward.

## 2. What veil already provides (build on this — do NOT reinvent)

veil ships a complete, metadata-private store-and-forward stack. The pieces
(FFI in `veilclient-ffi`, Dart in the `veil_flutter` plugin):

- **Mailbox** (`VeilClient.mailbox` → `VeilMailbox`):
  - `put({receiverId, contentId, senderId, blob, pushEnvelope?, capabilityToken?,
    wakeHmacEnvelope?})` — deposit a blob for an offline receiver at a relay.
    Dedup by `contentId`; quotas + rate limits; returns `MailboxPutStatus`.
    **The caller MUST end-to-end encrypt `blob`; relays cannot decrypt.**
  - `fetch({receiverId, authCookie})` → `List<MailboxBlob{senderId, contentId,
    depositedAt, data}>` — the receiver pulls pending blobs.
  - `ack(...)` — remove fetched blobs.
  - `VeilPush.drainMailbox(...)` — a fetch-loop helper for background drains.
- **Rendezvous / onion anonymity** (`VeilClient`):
  - `registerOnionService({hopCount})` — publish this node's **unlinkable**
    rendezvous ad over an onion circuit, so peers reach it *by identity* without
    learning its location. This is how a receiver becomes findable + how its
    mailbox replicas are located.
  - resolve-by-identity (blinded per-period descriptor) → reach a peer / locate
    its rendezvous relays (`veil_lookup_rendezvous_replicas`).
  - `register_rendezvous_publisher_with_push` + push/wake-HMAC envelopes — let a
    relay fire an authenticated wake-push (FCM/APNs) so a sleeping device knows
    to drain its mailbox (defeats presence-oracle / battery-DoS).
- **Relays**: any node opts in with `mailbox.enabled = true` (`MailboxConfig`);
  capability tokens gate PUTs when a relay sets `require_capability_token`.
- **Peer-sync outbox** (separate, complementary): `handle_outbox_put` /
  `handle_outbox_find_missing` — when two peers reconnect they exchange a Bloom
  filter of what each holds and backfill the gaps. Good for the
  "both were online but a message slipped" case; NOT for "recipient was fully
  offline" (that needs the mailbox). No FFI exposed yet.

**Metadata posture is strong and fits the threat model:** onion circuits hide
the sender's location from the relay; unlinkable blinded descriptors hide *which
identity* a mailbox belongs to. Use these paths — not raw `node_id` addressing.

## 3. Architecture (xVeil integration)

```
Receiver (once, at unlock):  registerOnionService()  + register rendezvous
                             publisher (persist authCookie in the SPACE)
Sender (peer offline):       resolve receiver by identity → relay + cap token
                             → SEAL message for receiver → mailbox.put(...)
Receiver (on connect/wake):  mailbox.fetch(receiverId, authCookie) → unseal
                             → deliver into the chat (dedup by contentId) → ack
```

`contentId` = the message id (already a uuid) → relay-side dedup + receiver-side
idempotency, so a message that was *both* mailboxed and later direct-synced is
not shown twice. The mailbox blob carries the same `WireEnvelope` we already
send live, just sealed.

## 3b. Sender offline — local outbox (complements the mailbox)

The mailbox covers a **recipient** being offline. A **sender** being offline
("wrote a message in the woods, it should go out when I reconnect") is covered by
a **local outbox** — app-layer, no relay, no crypto:

- Every outgoing op (message / edit / delete / file chunk) is persisted with a
  delivery state: `queued → sent → delivered` (or `queued` while the node is
  offline). It already lives in the deniable container (it's just a Message row).
- A flush runs whenever the node reaches `connected` (watch `nodeStatusProvider`)
  and on app start: re-attempt every still-`queued`/unconfirmed op in order.
- Per op, the flush decides the channel: a live session to the peer → direct
  send; peer offline → mailbox.put (Phase B). The receiver dedups by message id,
  so re-sending a queued op that secretly already arrived is harmless.

Together the local outbox + mailbox cover all four online/offline combinations.
This piece is safe + locally testable and ships first (no relay, no sealing).

## 3c. Message edit + delete

Edits and deletes are **operations referencing an existing message id**, carried
over the exact same delivery channels (live / outbox / mailbox), so they reach an
offline peer too:

- Wire: extend `WireEnvelope` with `edit` (`{id, body}`) and `delete` (`{id}`)
  kinds (appended — existing indices unchanged). Consent-gated like messages.
- Storage: `Message` gains `editedAt` + an `isDeleted` tombstone. Edit rewrites
  `body` (keep `editedAt` for an "edited" marker); delete replaces the row with a
  tombstone ("message deleted") — the bytes are scrubbed from the container.
- Semantics: **delete for me** (local only — never leaves the device) vs **delete
  for everyone** (emit a `delete` op to the peer). Edit is always "for everyone"
  (emit an `edit`). Editing/deleting a *received* message is delete-for-me only
  (you can't rewrite someone else's outgoing copy).
- Offline: an edit/delete to an offline peer is queued in the local outbox /
  mailboxed like any op; the peer applies it by id on fetch.

**Deniability requirement — delete/edit MUST scrub, not just hide.** In this
threat model a "deleted" (or pre-edit) message must not be recoverable from the
container after a coerced unlock. A view-only tombstone is NOT enough: messages
currently live in the **append-only MESSAGE_LOG**, which has no per-entry delete,
so the original plaintext would persist (encrypted, but recoverable once the
space is open). Real scrubbing needs the message store to be **deletable +
compactable**:
- Move messages from the append-log to **KV keyed by message id + a maintained
  id-index** (KV supports `DeleteOp`, and hidden-volume's open-time auto-vacuum +
  `compact_known` scrub orphaned/ deleted entries so forensics can't recover
  them). Trade-off: KV has no key enumeration, hence the explicit id-index (same
  pattern already used for `contacts:index`).
- Edit = overwrite the message's KV value (then compact to scrub the old bytes);
  delete = `DeleteOp` the id + drop it from the index (+ compact).

This is a **storage refactor of the verified message path** — a real decision
(enumerability via index vs the current scannable log) and security-relevant, so
it does NOT ship as a naive tombstone. The **local outbox** (3b) has no such
caveat and ships first.

The local outbox is safe + locally testable (fake transport, like the consent/
file tests). Edit/delete ship after the message-store-deletability rework.

## 3d. Sealing — RESOLVED: use veil's high-level onion send (option C)

Investigation conclusion: **xVeil should NOT hand-seal blobs.** veil already does
it on the routed path:

- **Send:** `sendToOnionService` / `sendAnonymousAuthenticated` address the peer by
  its Ed25519 IDENTITY (a `.onion`-like handle), seal the payload E2E under the
  peer's published ML-KEM key (post-quantum, the *right* key), and onion-route it
  — neither relays nor the rendezvous relay learn our location.
- **Offline recipient:** `veil-dispatcher/src/delivery.rs` has a built-in
  **mailbox fallback** — when a routed frame can't reach the (offline) recipient
  it is deposited (already sealed) at a mailbox relay. So offline delivery is
  automatic on this path; xVeil does no manual `mailbox.put`.
- **Anonymous vs normal (your requirement):** the onion path IS the anonymous
  path; the existing direct `app.send` is the fast non-anonymous path. Keep both
  behind a per-conversation (or global) mode switch; the offline-capable path is
  the onion one.

**Remaining concrete gap — RECEIVER side.** `drainMailbox` returns the **raw
sealed blob** (`MailboxBlobOut.blob`; the daemon does NOT unseal on fetch). So a
fetched mailbox blob still needs the onion-unseal + delivery into the normal
inbound app stream. Either (a) confirm/expose a veil daemon path that, on drain,
onion-unseals fetched blobs and delivers them as the usual `AuthAppDeliver`
inbound events (preferred — keeps crypto in veil), or (b) a veil "ingest fetched
blob" helper. This is the one veil-side piece to settle before the receive flow
works end-to-end; it is NOT app-level crypto.

## 3e. Deniability of rendezvous publish — analysis

Concern: does publishing a rendezvous ad (so an offline peer can reach you) leak
the hidden-identity model? Analysis:

- `registerOnionService` publishes an **unlinkable, per-period blinded
  descriptor**. The network / relays / rendezvous relay learn *that some onion
  service exists* but NOT which identity — only a holder of your invite (who
  knows your identity key) can resolve it. So a published rendezvous does not
  reveal *which* identity it belongs to.
- **Multi-identity:** only the **active** identity publishes (xVeil runs one
  active identity at a time — see MULTI-IDENTITY-DESIGN.md). So a device with N
  hidden identities never advertises N descriptors at once; the network can't
  infer the count or that they share a device.
- **Coercion:** the rendezvous auth-cookie + publisher state live INSIDE each
  identity's space, so a coerced unlock of one identity reveals only its
  rendezvous — consistent with the deniable model.
- **Residual (only if Phase-3 simultaneous identities lands):** N identities
  refreshing descriptors in lockstep (same device clock) is a correlation signal.
  Mitigation then: stagger/jitter per-identity refresh. Not an issue while one
  active identity publishes.

**Verdict: safe to publish the active identity's rendezvous.** Avoid lockstep
multi-identity publishing if/when simultaneous identities are added.

## 4. Open decisions (need the user / careful review)

1. **E2E sealing of the blob — THE crypto question.** Relays can't decrypt, so
   xVeil must seal the message for the receiver. Options:
   - (a) A veil-provided seal-to-identity primitive if one exists (the
     sender-anonymous / sealed-reply onion methods may already cover this —
     needs confirming). PREFERRED — reuse audited crypto.
   - (b) xVeil seals with the recipient's public key from the invite (X25519
     sealed box + AEAD). Works, but is new crypto in a life-critical app →
     needs a security review before shipping. Do NOT hand-roll this blind.
2. **Relay infrastructure (deniability-relevant).** Mailboxes need
   `mailbox.enabled` relay nodes that are *reachable and persistent*. Options:
   (a) every node opt-in (pure P2P, but availability is weak — your contact's
   relay may also be offline); (b) a set of community/operator-run relay nodes
   (more reliable, but who runs them, and the relay sees ciphertext + timing
   metadata — mitigated by onion + unlinkable descriptors). This is a network
   /governance decision, not just code.
3. **When to mailbox.** (a) Always also-mailbox every message (belt-and-
   suspenders, higher relay load) vs (b) only on delivery-failure / known-offline
   (needs a delivery signal we don't surface yet). Recommendation: start with
   "mailbox on send when no live session to the peer," add delivery-ack later.
4. **Persistence in the deniable container.** The receiver's rendezvous
   auth-cookie + publisher identity must live INSIDE the space (like the node
   identity) — never plaintext. Pending-outbound (un-acked sends) also persisted
   so they survive a restart.
5. **Fetch trigger.** Poll on connect + a timer for desktop; push-wake (FCM/APNs)
   for mobile (needs the push envelopes + a push project — a later, mobile phase).

## 5. Phasing

- **Phase A — foundation (mostly safe, additive):** bind `VeilMailbox` +
  `registerOnionService` + rendezvous-resolve into xVeil's transport; persist the
  auth-cookie/publisher in the space; receiver auto-publishes its rendezvous on
  unlock. No behaviour change to live chat yet.
- **Phase B — the sealed put/fetch flow (needs decision #1 + a relay):** seal +
  `put` on offline-send; `fetch` + unseal + deliver + `ack` on connect. Requires
  a reachable relay in the test network (`mailbox.enabled`) and the seal
  mechanism settled. **Live two-instance + offline test with the user.**
- **Phase C — robustness:** the peer-sync outbox (reconnect backfill) as a second
  channel; delivery acks; mailbox quotas/eviction handling in the UI.
- **Phase D — mobile wake:** push envelopes + FCM/APNs so a backgrounded phone
  drains its mailbox. Separate, mobile-infra phase.

## 6. What needs the user (do NOT ship blind)

- **The E2E seal mechanism** (decision #1) — confirm a veil primitive or get a
  crypto review of an xVeil seal. Getting this wrong leaks message contents.
- **Relay infrastructure** (decision #2) — a governance + availability call;
  also a test relay to verify anything end-to-end.
- **Deniability review** of the rendezvous-publisher lifecycle (a published
  rendezvous ad is, by design, discoverable-by-identity — confirm it does not
  weaken the hidden-identity model).
- **Live verification** — offline delivery cannot be tested without a relay + two
  instances + an offline window.

Recommended next step once you're back: settle decision #1 (seal) and stand up a
test relay; I implement Phase A immediately (it's safe/additive) and then B with
your live verification.
