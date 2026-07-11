# Multi-device (design)

Status: DRAFT v1 — brick 1 (this doc + the pure device-group core).
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

* The SOVEREIGN (master) key exists only via the seed phrase — ownership
  and recovery. Secondary devices never store it.
* Each device runs its own per-device instance identity (veil-core:
  InstanceRegistry, identity_document.bin + instance.toml — already in
  the FFI). Linking = the OLD device signs the NEW one into the device
  group (addMember) after a QR handshake carrying the new device's
  public identity + a short-auth code.
* The device group's OWNER is the sovereign; v1 practical stance: the
  first (linking) device acts for the sovereign the same way it already
  signs group ops today.
* DECIDED (user, 2026-07-11): the production stance is STRICT sovereign
  signing — linking a device requires the sovereign key (seed phrase
  entered at link time) to sign the device-group manifest/addMember op.
  The v1 instance-key path above stays only until that brick lands
  ("sovereign-подпись линковки", scheduled after brick 4/5); no new
  format work may assume the first-device-acts-for-sovereign shortcut.

## Sovereign-signed linking (design draft — pending UX answers)

Proposed flow (recommendation, not yet confirmed):

1. The user starts "Link device" on an EXISTING device and is prompted
   for the seed phrase. The sovereign identity TOML is derived from the
   phrase strictly IN RAM (the recovery-flow derivation, reused), used
   for the signatures below, then wiped. Nothing sovereign ever touches
   disk on any device (canon).
2. First link mints the device group with OWNER = the SOVEREIGN node id
   (manifest signed by the sovereign key). Every membership ControlOp of
   a device group (addMember AND removeMember) must be signed by the
   OWNER — instance admins may post sync events but cannot change
   membership. This is the point of "strict": a stolen device cannot
   link an attacker's device or revoke the victim's, because it never
   holds the phrase; the victim always can, because the phrase IS
   ownership.
3. The QR handshake stays as today (gid + new device's public identity +
   short-auth code); only the signer of the resulting addMember changes.
4. The fold gains a device-group-only validation rule: membership ops
   not signed by the owner are rejected (regular groups keep the
   existing role rules — this is scoped by the marker name).
5. Migration: an existing v1 group (instance-owned) is grandfathered
   read-only for sync but cannot admit NEW devices; the first
   sovereign-signed link re-mints the group under the sovereign owner
   and the old devices re-adopt (one-time, guided).

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
  - NO device available (all lost) → a new device can join via the
    seed phrase itself, or via a pre-issued CERTIFICATE (delegation
    artifact — format TBD in the implementation brick).
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

1. Mailbox multi-reader (an ACK by one device deletes the relay copy):
   v1 does NOT rely on per-instance relay copies — the device-sync log
   itself is the recovery path: whichever device drained the mailbox
   mirrors the message into the device group (msgMirror), and the other
   devices converge from there. Relay-side per-instance lifecycle can
   come later as an optimization.
2. Fanout-envelope count leaking the device count: unchanged in v1 (the
   mailbox already fans out per-instance envelopes); padding to a fixed
   envelope set is a follow-up crypto brick, noted not blocking.
3. Anonymous identities: NO public instance registry for them — v1
   scopes multi-device to the sovereign identity only; anonymous spaces
   stay single-device (seed-only recovery), revisit after Ф0.

## Bricks

1. (this) design + pure core: DeviceSyncEvent codec + apply-order fold,
   device-group conventions (marker in the manifest name-space, local
   registry of "my device group id"), unit tests. No wire, no UI.
2. Device-group lifecycle: create-on-first-link, QR link handshake
   (reuse invite QR machinery), addMember signing, revoke = remove +
   rotateEpoch; hooks + 2-device verify (desktop links phone-as-device
   fixture — the pair IS two devices).
3. Mirror loop: messaging taps (send/receive/read) → emit sync events;
   apply loop folds inbound events into the local store (dedup against
   native delivery); verify: message sent on desktop appears in the
   phone's 1:1 chat with the SAME peer conversation.
4. Contacts/settings/call-log sync + lazy attachment fetch.
5. Padding/registry-privacy follow-ups + audit pass (the churn-outlier
   saga's stub-identity/EK-epoch grabli get re-checked here).
