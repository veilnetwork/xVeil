# A late manual contact retry cannot recreate an obsolete request

Base: `56d80211`. This is a separate confirmed race, not attribution of the
original Windows 10 one-way-conversation report.

## Reproduction

The manual “send request again” path checked `pendingOutgoing` once, then read
the Outbox and, for old requests, the greeting history. Those asynchronous reads
could outlive acceptance, blocking or cancellation. It subsequently enqueued
and sent its old request without consulting the newer decision.

Eight assertion-red cases reproduce this on the base: accepted, blocked,
cancelled and cancelled-then-new-request, each with ordinary and actual
worker/native storage. A gate holds the captured Outbox read; the real service
operation completes before releasing it. Acceptance uses two messaging services
and explicitly delivered conventional request/accept frames, not an injected
accepted contact row.

Each baseline emits one obsolete request. Acceptance/cancellation also leave a
recreated queue row. After cancellation followed by a fresh request, both request
IDs remain queued, even though the old greeting was erased locally. This is an
extra late send, not proof that previously handed-off network bytes can be
recalled by cancellation.

## Change

Manual retry captures a service/contact revision before reading state. Storage
admits it under the existing Outbox-then-contact write lanes, checking the latest
pending relationship, caller revision and exact previously selected frame.
A missing/replaced prior frame is refused rather than recreated. Callback checks
are synchronous and side-effect-free; they never enter the native worker.

Old requests without a durable control row retain their history fallback.
The first allowed retry persists a complete row before network work; subsequent
retries reuse its ID. Empty old requests without a surviving ID acquire one
durable ID on that first retry. Existing rows retain their original enqueue age;
legacy live metadata can be enriched without rewriting an already durable copy.

Cancellation invalidates the revision before retiring requests, while preserving
the required retirement-before-erasure order. Failed retirement cannot proceed
to forensic erasure. A changed revision also prevents stale RAM queue accounting,
status publication and signals. Already admitted network work is not recalled;
its actual deposit result keeps the existing boolean contract.

No contact decision, signature/ratchet rule, wire format, native storage ABI,
own-device mailbox policy or ordinary initial-request path changes.

## Verification

The final focused suite passes **24 cases**, including:

- All eight baseline races, with the new decision/contact and exact surviving
  queue preserved and no new obsolete request emitted.
- Unchanged empty/nonempty retries, with and without an older missing control
  row, through ordinary and native storage. Greeting ID/time/sequence and
  existing enqueue age are checked where available.
- A block begun inside the guarded storage read prevents a legacy enqueue.
  This is a critical-turn gate, not a timing threshold.
- An independently completed storage block is respected without a service
  cache notice, so the caller revision cannot replace the durable check.
- A selected row retired independently of contact state is not recreated.
  Deliberate local fixture retirement models this and legacy state; it is not
  claimed to be a valid remote ACK from an unaccepted peer.
- A refused publication and a lost reply after full publication both throw
  without a network send. The latter retains the committed row. A subsequent
  retry recovers one row and the same logical greeting ID. These two fault
  controls use an in-memory KV adapter; they do not simulate physical disk loss.

**369 related checks pass, zero skips**, across 15 suites covering consent,
crossed requests, cancellation, atomic acceptance, carrier ACK/ingress,
mailbox/direct retries, durable queues, API and chat consent widgets.
`dart analyze lib test` is clean. The real Flutter-free CLI builds as AOT and
exits successfully with `--help`; this is not a live headless network exchange.

The selected native storage library matches its previously qualified hash and
all 50 current binding checksums; its bytes remain unchanged. No Rust rebuild
is involved. The native cases qualify storage on the host with controlled
transports, not the user's Windows 10 hardware, UI or network.

Test owners and synthetic directories are closed/removed. No application is
launched or focused, no input is injected and the existing user application
stays running. No phone, installed package, real conversation or relay changes.
Edits remain local; no push or release occurs.
