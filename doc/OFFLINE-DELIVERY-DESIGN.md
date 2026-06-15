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
