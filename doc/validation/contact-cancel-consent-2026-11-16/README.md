# Late request cancellation preserves completed consent decisions

Base: `b2c6a1cc`. Local source fix; no push or release.

## Confirmed mechanism

A request-cancellation dialog can remain open while the peer's actual accept
arrives or the owner blocks the contact elsewhere. Its delayed confirmation
previously called unconditional conversation removal. The result erased the
accepted contact/history or the block and its durable decision records.

Four assertion-red controls reproduce this on the base: accepted and blocked,
each with ordinary and actual worker/native storage. The accepted case sends
and accepts conventional captured request/accept frames through two real
MessagingService instances, then delivers a peer message before cancellation.
No network delay threshold or inserted accepted row establishes that case.
The block case uses the ordinary user-facing service operation.

This proves a separate destructive stale-action defect. It does not attribute
the original Windows user's one-way messaging report to cancellation.

## Change

Storage now exposes guarded cancellation distinct from explicit conversation
deletion. It checks retained local outgoing intent under the contact writer
lane and holds that lane through destructive discovery, commit and scrubbing.
An accepted, blocked, missing or incoming-only contact is refused. Crossed
requests still retain local outgoing intent and remain retractable; the prior
forgetting/no-reused-consent control continues to pass.

The service uses an early read only to avoid touching an already stale action's
queue. Request retirement remains before destructive erasure, so failure during
scrubbing cannot leave the old request retrying after contact removal. The
storage check after that asynchronous work remains authoritative. Refusal does
not forget ratchet state. The result reaches the chat dialog: it navigates back
only after an actual retraction.

Unconditional explicit conversation deletion remains available through its
existing API. No wire, signature, ratchet, mailbox or native storage ABI change
is involved.

## Verification and limits

Final qualification: **243 passed, no skips**, across nine suites. Full
`dart analyze lib test` is clean. The ordinary/native controls cover:

- Acceptance before cancellation: contact, message IDs/bodies and durable
  decision token survive; normal peer messaging continues; cold reopen retains
  acceptance.
- Block before cancellation: block, pending decision and queue survive;
  ordinary sending remains refused, including after cold reopen.
- Accept/block writers ahead of cancellation keep their committed decisions.
  A remote accept queued behind actual cancellation cannot recreate consent.
  These are gates in the real storage serialization, not timing assertions.
- Incoming-only requests remain intact. Ordinary empty/nonempty cancellation,
  retransmission, crossed-request forgetting, atomic acceptance, consent races,
  mailbox retirement and forensic conversation erasure retain controls.

Two isolated widget cases verify actual dialog navigation for the service's
true/false results. Their service result is controlled; durable behavior is
qualified separately by the real service/storage cases above. An initial
combined widget/storage fixture stalled during teardown and was explicitly
stopped; it is not counted as either a product reproduction or a passing test.
The isolated navigation cases avoid that fixture's storage lifecycle coupling.

The selected native storage library matches its previously qualified bundled
hash and passes all 50 generated method checksums; it is unchanged by testing.
No Rust build is performed. The native cases are local worker/storage tests
with a captured synthetic transport, not a physical Windows/Android session.

All Flutter tests run with the required temporary-directory override. No user
app is opened or activated, no keyboard/mouse input is injected, and no user
container, phone, production relay or Windows installation is modified.

## Replacement request during a cancellation

A cancellation already running can pause on the contact read or on the
durable queue listing. A second cancellation can finish and a fresh request
to the same contact can be submitted in that interval. The earlier action
previously retired the fresh request and erased its greeting when it resumed.

The action now carries the consent revision across the read, the queue scan
and the guarded storage write. The contact writer checks it again after
reading the contact. An obsolete cancellation leaves the replacement and its
queued frame intact. A refusal also preserves the newer revision so it cannot
invalidate a replacement still being prepared.

Both delays reproduced destructive cancellation with ordinary storage before
the fix. The final tests use the same service API with ordinary and native
worker storage. They compare the new greeting and its durable frame, then
reopen the container and check that the same frame is still pending. The
transport is controlled by the tests. All 771 related tests passed without
skips and the targeted analyzer reported no issues. The cause of the original
one-way delivery report remains open.

## Acceptance cleanup after replacing the contact

Local acceptance, acceptance mirrored from a sibling, and a peer's acceptance
all retire pending request frames. If this queue scan paused while the owner
deleted and re-added the contact, the old acceptance could remove the new
request from the outbox. The peer path could also mark the new greeting as
delivered before the peer had received it.

Acceptance cleanup now checks the durable accepted state and keeps its consent
revision through the queue scan. Explicit deletion retires the old request
and invalidates the old consent. The peer path checks the relationship again
before reading and updating the greeting. The accepted contact's ordinary
receipt path remains available while its decision is current.

All three entry points reproduced the defect on both ordinary and native
worker storage. The tests use the real delete and re-add commands. The new
greeting keeps its pending status, and its exact request frame survives a
cold reopen. The peer test delivers a captured answer through the regular
inbound service. The related suite passed 793 tests without skips, and the
targeted analyzer reported no issues. The original Windows user's connection
remains unverified.

## Retrying a stored acceptance after reopening

An acceptance from the previous relationship can still be present in the
durable queue. After reopening storage, the generic retry pass used to send
it even when the current relationship was pending. The retry pass now
requires an accepted contact before either offering that frame to a mailbox
or scheduling its live transmission.

Incoming and outgoing pending contacts reproduced the extra acceptance before
the fix on both ordinary and native worker storage. The current outgoing
request still retries after reopening. Controls confirmed that an accepted
contact's queued answer also retries. The tests close and reopen storage and
exercise the usual outbox entry point with a controlled transport. The
related suite passed 799 tests without skips. The analyzer reported no issues.
