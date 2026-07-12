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

Apply is idempotent and last-write-wins per (kind, key, ts) — the same
deterministic-fold discipline as group state. Attachments are NOT
inlined: msgMirror carries the contentId ref; the receiving device
fetches lazily over the membership-authorized pull when the user opens
the message.

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
4. Contacts/settings/call-log sync + lazy attachment fetch.
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
