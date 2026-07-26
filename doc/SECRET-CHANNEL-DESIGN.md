# Secret channels

Status: **specified, not implemented.** `access: secret` is rejected today —
`_prepareProtectedChannel` accepts only `restricted`, so `createChannel`
returns null for it, the API does not advertise the value, and the channel list
says in words that the channel is not hidden. Nothing in the product promises
what this document describes.

This exists because the feature was blocked on one thing only: nobody had said
whom the channel is hidden *from*. That is now decided.

## The threat model, as decided by the owner

A secret channel must hide its own existence from **both**:

* **(a) an outside network observer** — someone watching the traffic of a
  participant or of the network, who is not a member of the Space;
* **(b) other members of the same Space** — people who legitimately read the
  Space's control chain and its open channels, but are not in this channel.

(b) is the harder-sounding one and the cheaper one to build. (a) is the one
that decides whether the feature is honest, because a channel that is invisible
in the control chain but visible as a distinct traffic pattern is not hidden —
it is merely renamed.

## What is true today

A restricted channel writes one `SpaceChannelControlEnvelope` per epoch into
the Space's shared control chain
([space_channel.dart:306](../lib/domain/space_channel.dart#L306)). Its
cleartext carries:

| field | what a non-recipient member learns |
|---|---|
| `cid` | this channel exists, and which entries belong to it |
| `epoch` | how many times its key has been replaced, and when |
| `key.count` ([group_epoch.dart:83](../lib/domain/group_epoch.dart#L83)) | how many people can read it |
| `enc` length | roughly how much control data it carries |
| entry author + `createdAtMs` | who administers it and when they act |

So `secret` implemented as a flag over this envelope would be
**byte-identical to `restricted`** and would hide nothing. That is exactly why
it is refused rather than shipped.

## What each adversary must not learn

**(b) another member.** From the control chain alone they must not be able to
say: that a channel exists at all, how many such channels there are, how many
people read one, who administers it, or when its membership changed. They will
still see *that the Space has control traffic* — that is unavoidable and is not
a leak, provided one channel's traffic is not separable from another's.

**(a) a network observer.** They must not be able to say that a participant is
in a hidden channel, distinguish its traffic from the Space's ordinary traffic,
or infer membership size or activity from volume and timing.

## Design

### Layer 1 — entries a non-recipient cannot attribute (vs. b)

Replace the addressed envelope with an **unaddressed slot**:

* `cid` and `epoch` leave the cleartext. In their place goes a per-entry
  **recognition tag** `tag = HMAC(channelKeyEpoch, entrySalt)`, with a random
  `entrySalt` in the clear. A recipient trial-computes the tag for the keys it
  holds; a non-recipient sees random bytes and cannot link two entries of the
  same channel, cannot count channels, and cannot follow one across rotations.
* the recipient set is padded to a **fixed bucket** (e.g. 8/32/128) so
  `key.count` stops being a headcount, and the descriptor's per-recipient
  wrapped keys are padded to the same bucket.
* the ciphertext is padded to a **fixed size class**, so control operations
  (create / rename / membership change / rotate) are not told apart by length.
* the author is not the account: entries are signed by a **per-channel signing
  key** shared with the recipients, so the chain does not name who administers
  the channel. This costs non-repudiation *inside* the channel — a member could
  forge another member's control op — so the signing key must be per-epoch and
  the op must additionally carry the author encrypted *inside* the payload for
  the recipients to check.

Cost, stated plainly: every member downloads and trial-decrypts every hidden
entry. That is the price of unlinkability and it scales with the number of
hidden channels, not with membership.

### Layer 2 — traffic that does not stand out (vs. a)

Layer 1 is worthless to (a) if a hidden channel produces a distinct pattern.
What is needed:

* control entries are emitted on a **fixed cadence**, not when the user acts.
  The codebase already does this once: protected-channel key rotation runs in
  the hourly maintenance pass specifically so the timing of a rotation does not
  reveal who opened which screen. Secret channels generalise that rule —
  *every* control write is deferred to the next tick, and a tick with nothing
  to say emits an indistinguishable **cover entry**.
* message traffic is padded to the same size classes and cadence as the
  Space's open traffic, so a member of a hidden channel is not visible as a
  participant with "extra" traffic.
* the **anonymity set is the Space**, and it must be stated in the UI: a
  two-person Space with one hidden channel hides nothing, because the cover
  traffic and the hidden traffic have the same author.

### What this does not hide

* That the *Space* exists and that a participant belongs to it.
* Total volume over long windows, against an observer who can watch for weeks.
* Anything at all, if the endpoint is compromised — this is a metadata
  property, not a device-security one.

## Open questions that must be answered before code

1. **Cover-traffic budget.** A fixed cadence with cover entries costs bandwidth
   and store growth for every member, forever. What is the acceptable steady
   cost per Space per day? Without a number this cannot be designed, only
   hand-waved.
2. **Trial decryption bound.** How many hidden channels may one Space carry
   before the per-member cost is unacceptable? That number becomes a hard cap,
   enforced at creation.
3. **Loss of chain-level attribution.** Inside a hidden channel, control ops
   are signed by a shared key. Is that acceptable, or must a member be able to
   prove who removed them? These are mutually exclusive at the chain level.
4. **Migration.** Existing `restricted` channels cannot become secret without
   rewriting history that other members already hold. Secret is therefore a
   property fixed at creation, and that must be said in the UI.

## Verification this must pass before being called done

* An adversarial member with the full control chain cannot count hidden
  channels, link two entries of one channel, or detect a membership change —
  asserted as a test over a real chain, not by inspection.
* A recorded transcript of a Space with and without a hidden channel is
  indistinguishable by size and timing over a stated window.
* The break-check discipline used elsewhere in this repo: remove the padding,
  remove the tag blinding, remove the cadence — each removal must make a test
  fail. A green suite with the property removed means the property is not
  tested.
