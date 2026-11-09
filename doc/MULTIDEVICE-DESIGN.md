# Multi-device (design)

Status: v1 sync, guided production-safe sovereign link/re-adopt and
node-preserving all-devices-lost recovery are shipped. Padding/registry
privacy remains a separate follow-up.
Agreed decisions (2026-07-09, ROADMAP «Эпик: мультиустройства») are
restated here and mapped onto the shipped groups foundation.

## Shape: my devices are a private group

One master identity on several devices. The device set is a PRIVATE
GROUP over the Ф0 groups foundation this repo already ships end to end:

* control-log  = the device registry: addMember = link a device,
  removeMember + rotateEpoch = revoke it (a stolen device loses the
  future; already-downloaded history honestly cannot be revoked);
* message-log  = the SYNC-EVENT log (typed events, below);
* content path = lazy attachment fetch between my devices (the
  membership-authorized stream pull shipped in content-path bricks 2-3);
* scale-free log sync (brick 5) already lets devices exchange deltas
  without pairwise contact records.

What the groups substrate gives us for free: signed append-only logs,
deterministic folds, snapshot/delta wire with chunking, byte-exact
content transfer, non-contact admission. What multi-device ADDS: a
special-purpose group with its own membership rules, event vocabulary,
and apply-loop into the local store.

## Identity vs device keys

* Each device runs its own per-device instance identity (veil-core:
  InstanceRegistry, identity_document.bin + instance.toml — already in
  the FFI). It signs sync events but NEVER device-registry mutations.
* The device group's OWNER is the sovereign. Its signed v2 manifest and
  every addMember/removeMember entry carry an explicit signature algorithm;
  keys/signatures are variable-length so Falcon/hybrid bundles fit without a
  new wire version. Linked device identities are plain members, not admins.
* DECIDED (user, 2026-07-11), SHIPPED CORE (2026-07-12): encrypted sovereign
  material lives on EVERY device; the seed phrase decrypts it in RAM for one
  signing burst. The normal path is an Ed25519+Falcon512 `XVSB` bundle; the
  earlier opaque Ed25519 phrase-derived signer remains recovery bootstrap.

## Sovereign-signed linking

Confirmed flow and implemented invariants:

1. The user starts "Link device" on an EXISTING device and unlocks one
   short-lived sovereign signing burst. Mutable FFI phrase copies and native
   seeds are wiped; private material never crosses into Dart. The production
   normal path decrypts the local sovereign bundle rather than derive-only.
2. First link mints the device group with OWNER = the SOVEREIGN node id
   (manifest signed by the sovereign key). Every membership ControlOp of
   a device group (addMember AND removeMember) must be signed by the
   OWNER — instance admins may post sync events but cannot change
   membership. This is the point of "strict": a stolen device cannot
   link an attacker's device or revoke the victim's, because it never
   holds the phrase; the victim always can, because the phrase IS
   ownership.
3. The guided QR handshake is two-phase. The new device first shows its
   bootstrap invite. The existing device sovereign-signs that exact device
   into the registry without broadcasting, then shows a 30-minute public
   adoption token bound to source device, fresh/current gid and the exact
   signed-manifest hash. The new device scans it and stores one explicit
   pending admission; only then does the existing device send the durable
   encrypted snapshot. Contact and stranger ingress use the same gate.
4. The fold has a device-group-only validation rule: membership ops
   not signed by the owner are rejected (regular groups keep the
   existing role rules). Manifest signature, gid, owner key, algorithm,
   operation shape and member admission are checked BEFORE persistence.
5. Migration: an existing v1 group (instance-owned) is grandfathered
   read-only for sync but cannot admit NEW devices. The first sovereign action
   re-mints a fresh gid, carries all known devices as members, and re-signs the
   compact current sync state (including attachment refs) into the new group;
   old devices explicitly re-adopt it once (a planted snapshot never auto-adopts).

UX ANSWERS (user, 2026-07-11) — the flow above amended accordingly:
* KEY STORAGE (user's design, replaces derive-at-link): the sovereign
  key material is stored ON EVERY DEVICE as a blob ENCRYPTED with the
  seed phrase as its password. The phrase never persists; entering it
  decrypts the bundle strictly in RAM for one signing burst. Because
  the material is stored (not re-derived from entropy), the bundle can
  carry MORE than an ed25519 seed — notably a falcon512 (post-quantum)
  key — without bloating the phrase. Linking rules:
  - an EXISTING device is available → linking goes ONLY through it
    (phrase entered there to unlock the local sovereign bundle);
  - NO device available (all lost) → preserving the SAME sovereign requires
    a pre-issued `XVRC` certificate plus its separately stored recovery code.
    XVRC is an encrypted portable backup of the complete Ed25519+Falcon512
    keypair, not a bearer delegate; opening it recomputes the node id from the
    full public key and must match the AEAD-bound public header. The seed phrase
    alone cannot reconstruct the random Falcon half: without XVRC it can only
    bootstrap a NEW sovereign bundle with a different full public key/node id.
* Sovereign gate covers BOTH addMember and removeMember (a stolen
  device can neither admit an attacker nor revoke the victim's
  devices; revoking the stolen one requires the phrase — which is
  ownership).
* Migration: re-mint. A v1 instance-owned group is grandfathered for
  sync only; the first sovereign-signed link re-mints the group under
  the sovereign owner and existing devices re-adopt (guided, once).

## Sync-event vocabulary (v1 — "sync everything")

Events ride the device group's message-log as attachments-free bodies
(JSON, signed per author-device like any group message):

| kind        | payload                                             |
|-------------|------------------------------------------------------|
| msgMirror   | a 1:1 message I sent/received on that device (peer,  |
|             | direction, body/fileRef, ts, msgId)                  |
| readMark    | peer + watermark ts (read-status convergence)        |
| contactUp   | contact upsert: nodeId, alias, per-contact settings  |
| settingSet  | app-level setting key/value (platform-local keys —   |
|             | tray etc. — excluded by an allowlist)                |
| callLog     | call-journal entry                                   |
| historyAsk  | one device asking ANOTHER for the history it was     |
|             | linked too late to see (target device + scope)       |

Apply is idempotent and last-write-wins per (kind, key, ts) — the same
deterministic-fold discipline as group state.

`historyAsk` is the one COMMAND in this vocabulary; everything else is
state. Linking starts forward sync and nothing else, so a device linked
today holds none of yesterday — an answer for a second phone and the
wrong one for a replacement. The person chooses the scope, up to a full
copy, and the device that is asked answers with ordinary events of the
kinds above: the receiving side needed no new applier, because a
replayed mirror is the same mirror an online sibling would have sent.

Two rules keep a backfill from being a rollback:

* a message mirror keeps its REAL timestamp. Its key is the message id,
  so it conflicts with nothing, and the timestamp is where the message
  sits in the conversation.
* a contact row carries a COUNTER, which loses to any real event. The
  container records what a contact's status IS and never when it was
  decided, so there is no honest "when" to carry; stamped with the wall
  clock, every stale value would become the newest thing the fold had
  ever seen. Fill a gap, never overwrite — the same rule the archive
  walk already follows.

Being a command, it carries its own idempotence: the folded state is
replayed into the appliers on every bridge build, so the answering
device keeps a DURABLE watermark per asking device, written before the
walk rather than after — a replay that dies in the middle must not
restart from the top on the next launch. Attachments are NOT
inlined: msgMirror carries the contentId ref; the receiving device
fetches lazily over the membership-authorized pull when the user opens
the message.

## Availability boundary confirmed by the owner (2026-11-03)

Own-device synchronization does **not** use relay mailboxes. The owner explicitly
kept this v1 policy after reviewing the scenario where both A and C are offline
when B returns. Do not enable mailbox fallback for a linked device as a delivery
fix, or reinterpret a contact mailbox as an own-device replica.

A returning device needs an available holder of the missing state. If every
holder is offline, it waits; tests must distinguish that availability limit from
permanent data loss after a holder returns. Previously received local data must
remain available without any other device online. This decision does not waive
reconnect, interrupted synchronization, revoke or eventual-convergence checks
when the required holder becomes available again.

## Live history records larger than one page (2026-11-03)

The live-only own-history exchange keeps its 128-KiB/64-slice page bound.
Message pages carry at most 64 events (raised from 32 on 2026-11-08); inventory
remains at eight conversations. Durable publication still uses at most 16 rows
per cohort. Older application decoders capped at 32 events may reject larger
pages; old-version compatibility was explicitly waived by the owner.
The byte ceiling may end a message page earlier. A receiver rejects an over-cap
page before applying any event. Current sibling authorization is rechecked at
row admission and before subsequent state writes/publication/checkpoint; the
durable cursor advances only after the
whole accepted page completes. Interrupted pages replay idempotently, and a
revocation/binding change prevents the unfinished page from being checkpointed.

An event which cannot fit by itself is returned as a `record` descriptor in
the page response: position, encoded length and SHA-256. The requester fetches
64-KiB byte ranges with `op: record`, tied to its current conversation/cursor,
digest and offset. Every response still fits the ordinary page bound.

A logical record is capped at the existing 1-MiB application-frame bound;
stored message events are already capped at 512 KiB. Partial records reserve
their entire declared size against a shared 4-MiB budget. This is a separate
budget from existing frame admission and reply caches, not a bound on all
messaging memory. There is one active record per sibling pull.

The cursor stays before the record until all bytes match its digest and the
ordinary mirror/status applier completes. Partial bytes are RAM-only: restart
re-fetches that record from its beginning without replaying the committed
history prefix. A source change abandons the partial record and re-reads the
same cursor. Current device authorization, binding and expiry checks still
apply; the digest checks coherence and grants no authority. Mailboxes are
not involved.

This adds an app-level wire operation. Both devices need support for oversized
records; interoperability with older versions is outside the active release
requirements by the owner's decision. Ordinary short pages retain their
existing representation.

## Confirming an already held history prefix (2026-11-03)

An inventory can be a strict subset of the receiving device's history. If its
count and content digest exactly match the receiver's chronological prefix of
that length, all advertised rows are already held: no pages are requested just
to mirror the same rows back to their source.

For a receiver which needs to check the source, an ordinary `page` request can
carry an optional `prefix`: chronological endpoint, count and SHA-256. This
non-durable hint covers the already held rows' IDs, canonical order author/sequence, text,
inline emoji, edit frontier, delivered/reflected state, timestamps and direction.
The source compares it against its own complete prefix through that endpoint.
Only an exact match allows the page to start after it; the response echoes the
confirmed hint. A mismatch returns an ordinary page from the original cursor.
This adds no authority: ordinary current-device provenance, roster and host
binding gates still apply on both ends.

Before advancing its durable cursor, the receiver requires the echoed hint to
match its outstanding request and rechecks its own current prefix. A local change
discards the response and requests a normal page, without checkpointing the hint.
Only already stored, matching rows can be skipped. The verified checkpoint must
complete before applying a following page or fetching an oversized record.
Hints are not persisted; failed writes, cancellation and restarts cannot restore
an unconfirmed skip. Existing request/reassembly/reply bounds remain unchanged;
an oversized hint is omitted. There are no mailbox copies or new storage queues.

The request may also offer up to seven `prefixFallbacks`, ordered by strictly
decreasing count and endpoint. They cover shorter local prefixes: a device can
already hold a late echo tail beyond a gap, so its entire held set is not
necessarily a prefix. The source selects the longest candidate which actually
matches its complete prefix; the receiver accepts only an offered candidate
and rechecks that specific subset. Candidates share the existing 1500-character
query bound and are removed if necessary to fit. There are at most eight candidates per request,
not an unbounded prefix search. Gaps and provisional positions are still repaired.

A page reply may include `prefixPending`, an optional integer bit mask over the
actual ordered proposal list (primary bit 0, then fallbacks). A set bit reports
that the source currently has fewer rows through that endpoint than the
proposal requires. A fully checkable mismatch has no bit. The client may retain
only those already-offered proposals for later pages of the same pull, always
filtering endpoints behind its current cursor. Invalid, out-of-range or absent
masks discard the proposals and keep the original plain-page behavior. Hints
are cleared at the end of the conversation and are never persisted.

This report only schedules another comparison; it cannot authorize a skip,
application, ACK or checkpoint. Every accepted prefix still requires a fresh
comparison on both ends and the ordinary current-device/binding/durability
gates. A candidate larger than the entire fresh snapshot needs no digest or
row walk; other candidates are hashed only at an exact prefix count. A source
which could already reject a candidate does not ask the client to keep
resending it. Older peers may ignore this optional metadata.

A restored page cursor gets one current inventory check before replaying pages:
other synchronization paths may already have filled the missing rows. If pages
are still needed for that conversation, the previously durable cursor is kept.
An independently verified prefix may advance it further, but must end strictly
after it. Neither a local row count nor a remembered hint can make that jump.

## Tech-notes resolved (engineering stance, flagged in ROADMAP)

1. xVeil v1 devices are separate node ids in the private app-level device
   group, not native `InstanceRegistry` entries under one recipient node id.
   The contacted device receives the mailbox copy and mirrors it through the
   device-sync log; relay-side per-device lifecycle is therefore not part of
   the shipped v1 path.
2. AUDIT (2026-07-12): native `fanout_encrypt` supports many instance certs,
   but the production mailbox resolver deliberately selects only the freshest
   registry instance and seals one envelope. The earlier statement that the
   mailbox already fanned out to all devices was false. Fixed-count envelope
   padding alone would not hide xVeil's app-level device count because that
   count never enters this native blob. A future native `InstanceTag::All`
   path must first define how app-level members map to a same-node registry,
   then hide both registry membership and envelope count; do not mark brick 5
   complete from the currently dormant fanout primitive.
3. Anonymous identities: NO public instance registry for them — v1
   scopes multi-device to the sovereign identity only; anonymous spaces
   stay single-device (seed-only recovery), revisit after Ф0.

## Bricks

1. (this) design + pure core: DeviceSyncEvent codec + apply-order fold,
   device-group conventions (marker in the manifest name-space, local
   registry of "my device group id"), unit tests. No wire, no UI.
2. Device-group lifecycle: create-on-first-link, addMember signing, revoke =
   remove + rotateEpoch; hooks + 2-device verify. The original debug lifecycle
   shipped first; the production QR ceremony and sovereign re-adopt are in
   brick 6.
3. Mirror loop: messaging taps (send/receive/read) → emit sync events;
   apply loop folds inbound events into the local store (dedup against
   native delivery); verify: message sent on desktop appears in the
   phone's 1:1 chat with the SAME peer conversation.
4. Contacts/settings/call-log sync + lazy attachment fetch. ✅ plus
   history backfill on request (`historyAsk`): Settings → Devices → a
   device → "Get data from this device", scope chosen by the person.
5. Padding/registry-privacy follow-ups + audit pass (the churn-outlier
   saga's stub-identity/EK-epoch grabli get re-checked here).
6. Sovereign hardening: ✅ opaque one-burst signer; ✅ signed algorithm-aware
   v2 manifest + owner-only add/revoke + legacy remint; ✅ encrypted sovereign
   blob replicated to every adopted device, Falcon/hybrid signer/verifier and
   blob-hash binding in the manifest; ✅ two-phase QR/UI guided link/re-adopt
   with an exact-manifest pending-admission gate; ✅ pre-issued `XVRC v1`
   recovery credential preserving the exact full sovereign public key/node id,
   with bounded Argon2id+ChaCha20-Poly1305, independent recovery code,
   fresh-registry-only adoption and rollback on partial failure.
