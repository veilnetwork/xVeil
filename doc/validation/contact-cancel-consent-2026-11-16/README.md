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
