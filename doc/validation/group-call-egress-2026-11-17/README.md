# Group-call transport waits must not hold group mutation admission

Base: `197924d8`. This closes the local mechanism recorded in the
[device-selection cycle](../media-device-selection-lifetime-2026-11-17/README.md#separate-group-call-finding-still-open).
It does not attribute a physical network failure or the original Windows 10
camera/notification/one-way-chat reports.

## Base evidence

GroupService.broadcastGroupCallSignal awaited every sender inside the group's
mutation lane. Incoming call-frame verification and local control mutations
need that same lane. Production GUI/headless callbacks use
MessagingService.sendGroupCallSignal: heartbeats await live sending, while the
other call controls retain their durable-admission path.

Two committed tests fail on the unchanged base by assertion, without waiting
for a timeout:

- A held sender prevents a valid incoming frame from completing. The exact same
  frame validates after releasing that sender.
- Two services whose sender callbacks await the opposite service's ingress
  cannot finish either receipt until the test's teardown escape is released.
  Both frames subsequently validate successfully. This reproduces a cycle under
  that callback contract, not a demonstrated production network deadlock.

Both tests release their gates and join pending work before closing synthetic
stores. The earlier intermittent audio-watchdog timeout remains unattributed;
it is not used as the causal oracle or erased by a passing repeat.

## Change

Outgoing call controls now have a separate FIFO lane per group. Only one fanout
for that group waits on transport at a time, as before. Another group can send
independently. The shared serialization helper retains the original ordering,
failure cleanup and tail-removal behavior for ordinary group mutations.

Preparation still runs inside the mutation lane: current membership, channel
kind/access/archive state, source permissions, encryption establishment and
local epoch-key commitment are validated before signing and encrypting. The
prepared send holds ciphertext, signal metadata, recipients and the commitment;
it does not retain the clear buffer or an epoch key. The temporary clear buffer
is wiped on every encryption exit.

Before each recipient admission, the mutation lane revalidates the source and
recipient scope, membership/channel epochs and key commitment. The sender is
invoked synchronously in that authorization turn, with its future immediately
observed for failure. Its asynchronous completion is awaited outside the lane.
This preserves an explicit admission boundary: a callback already admitted may
finish after a later revocation; an unadmitted recipient cannot use the stale
plan. No await gap is introduced between the final check and callback invocation.

Queued signals prepare only when their outgoing turn arrives, so they use the
current epoch rather than a precomputed stale plan. No wire version, own-device
mailbox, durable/ephemeral sender policy or parallel fanout policy is changed.

Shutdown refuses new call sends and joins the outgoing tails alongside existing
group work before closing event surfaces. Already active sender futures are
joined; queued or remaining unauthorized work is refused.

## Controls

The new cases cover incoming progress during a held send, opposite-ingress
callbacks, same-group FIFO and single active fanout, independent groups,
membership removal, protected-channel epoch rotation, archive, source revocation,
source/recipient voice restriction without an epoch change, synchronous/asynchronous
sender failure with a queued successor, and shutdown in ordinary/open/protected
rooms. Existing signed-signal, AEAD, replay, admission and group-call FSM tests
remain in place.

Three deliberate mutants verify that the guards are substantive:

| Removed guard | Failing assertions |
| --- | ---: |
| Per-recipient fresh authorization | 10, with three unchanged-state controls passing |
| Outgoing-tail disposal drain | 3 premature-completion failures |
| Source enterVoice permission | 1; membership/epoch/key remain valid while voice is forbidden |

Each mutant is restored byte-for-byte before final testing. An intermediate
formatting script failed to locate a wrapped test marker; it is excluded from
test evidence and the added regions were formatted with verified boundaries.

## Qualification and limits

The first broad invocation omitted explicit native library paths: it skipped
native crypto cases and failed four native container-open preconditions. Those
results are not final qualification. The corrected invocation selects the
previously qualified core/storage binaries, matches both producer input hashes
and 1,144 recorded Rust/Cargo inputs against current sources, and passes all 50
current hidden-volume binding checksums. No native build is performed.

**1,255 tests passed, zero skipped**, across sixteen suites: group calls/core/
epochs, Space access/lifecycle, group teardown/source priority/audio/overlays,
group media controller, direct call FSM/startup/camera state/outcomes and diagnostic
journal. The twenty new group-call cases pass alongside the existing watchdog
tests. `dart analyze lib test` reports no issues. Selected native binary hashes
remain unchanged after testing.

The source/callback fixtures use real group services and encryption with
controlled signer/transport boundaries; they do not prove physical relay/P2P
quality, audible speech, an AOT GUI call or a complete multi-device/revocation
matrix.

All checks are headless with TMPDIR=/private/tmp/. No app window, focus change,
OS keyboard/mouse input, installed-app change or seed operation is performed. The
existing user's Mac app remains running. No push or release is performed.
