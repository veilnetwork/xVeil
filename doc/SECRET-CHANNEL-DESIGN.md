# Secret channels

Status: **will not be built. `restricted` already does the job.**

## The decision that closed this

The owner settled the threat model, and settling it removed the feature:

> If something truly secret needs writing, private groups exist. Channels are
> more for teams inside other teams. The fact that people are talking is not
> much of a problem, as long as the substance is not revealed.

That is the whole answer. It drops the network observer entirely, and it
reduces "hide from other members of the Space" to **hide the substance**, not
the existence. Both of the expensive layers this document used to specify —
unlinkable entries and cover traffic on a fixed cadence — existed only to hide
the *fact* of a channel. Nobody needs that here.

## Why nothing is left to build

A restricted channel already hides the substance from a non-recipient member.
A control entry carries EITHER a cleartext channel descriptor OR the sealed
envelope, never both, so the channel's name, its membership list and every
message stay inside the ciphertext. Asserted, not assumed:
`test/group_service_test.dart`, *"NOT leaked: the name and the substance stay
inside the ciphertext"*.

What a non-recipient member CAN still work out is listed below and is now
accepted rather than fixed: that some hidden channel exists, how many there
are, how many people read each, when a key was replaced, and who signed the
control entry.

`access: secret` therefore stays **rejected at creation**. Shipping it as a
flag over the same envelope would be byte-identical to `restricted` — a
promise of secrecy that changes nothing, which is worse than not offering it.

## What is true today

A restricted channel writes one `SpaceChannelControlEnvelope` per epoch into
the Space's shared control chain
([space_channel.dart:306](../lib/domain/space_channel.dart#L306)). Its
cleartext carries:

| field | what a non-recipient member learns |
|---|---|
| `cid` | this channel exists, and which entries belong to it |
| `epoch` | how many times its key has been replaced, and when |
| `key.count` ([group_epoch.dart:83](../lib/domain/group_epoch.dart#L83)) | how many people can read it — the members PLUS the administrator, who is a recipient of their own channel |
| `enc` length | roughly how much control data it carries |
| entry author + `createdAtMs` | who administers it and when they act |

Under the decided threat model every row above is ACCEPTABLE: it reveals that
a team is talking, never what about. That is the line the owner drew.

## What each adversary must not learn

**(b) another member.** From the control chain alone they must not be able to
say: that a channel exists at all, how many such channels there are, how many
people read one, who administers it, or when its membership changed. They will
still see *that the Space has control traffic* — that is unavoidable and is not
a leak, provided one channel's traffic is not separable from another's.

**(a) a network observer.** They must not be able to say that a participant is
in a hidden channel, distinguish its traffic from the Space's ordinary traffic,
or infer membership size or activity from volume and timing.

## The design that is NOT being built

Kept for the record, so that reviving the feature starts from the reasoning
rather than from scratch. Everything in this section addresses a threat the
owner has explicitly set aside.


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

## The questions this used to be blocked on — all moot

They were: the cover-traffic budget, the cap on trial decryption, and whether
chain-level attribution could be given up. Each of them only exists to pay for
hiding the *fact* of a channel. With that requirement gone, none needs an
answer.

## The former open questions, for the record

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

## The leak table is now executable

`test/group_service_test.dart`, group *"secret-channel groundwork: what the
control chain gives away"*, asserts the table above against a real Space with
two restricted channels: a non-recipient can count the channels, read each
one's headcount, link two entries of one channel, watch a rotation as an epoch
bump, and name the administrator. A sixth test asserts that `secret` is still
refused, so none of this is promised away.

They are written as the CURRENT truth on purpose. An implementation of secret
channels must make each of them fail; a green suite with those tests unchanged
would mean nothing was hidden. If one starts failing without such an
implementation, this document is wrong and must be corrected first.

Writing them already corrected one thing here: the headcount is members plus
the administrator, not members alone.

## What is still true and worth keeping

The leak table above is executable (see below). If someone later decides the
existence of a channel must be hidden after all, those tests are the starting
point: each is written as the current truth and an implementation would have
to make it fail.

## Verification a revival would have to pass

* An adversarial member with the full control chain cannot count hidden
  channels, link two entries of one channel, or detect a membership change —
  asserted as a test over a real chain, not by inspection.
* A recorded transcript of a Space with and without a hidden channel is
  indistinguishable by size and timing over a stated window.
* The break-check discipline used elsewhere in this repo: remove the padding,
  remove the tag blinding, remove the cadence — each removal must make a test
  fail. A green suite with the property removed means the property is not
  tested.
