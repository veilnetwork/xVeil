# Delayed acceptance sends must retain consent and row admission

Base: `4b3bea18`. This fixes confirmed response-queue races. It does not
attribute the original Windows 10 one-way conversation complaint.

## Reproduction

The acceptance response worker checked durable membership, awaited a contact
read and sent when that snapshot said accepted. If block committed during the
read, the returned accepted snapshot still admitted transmission. An ACK during
the same wait could also remove the row without preventing that extra send.

Twenty controlled cases use real MessagingService acceptance, block and
authenticated ACK handling with ordinary asynchronous storage and the actual
hidden-volume worker. The local acceptance publication arms a gate on the
response worker's next contact or membership read, after the decision commit.
The case commits block/ACK (or an unrelated-peer control) before releasing the
read. It joins the real response future with the live-leg deadline kept out of
the oracle. No guessed delay establishes the result.

The unchanged base has **six assertion-red cases and fourteen passing
controls**. The failed cases send an accept after a concurrent block or after
its row was retired by its peer's ACK. Foreign-peer ACKs and ordinary sends
remain controls. The tests inspect actual emitted wire kinds, current contact
state and row membership, including cold reopen. They start at the existing
authenticated-message boundary; there is no network or cryptographic proof.

## Change

The worker reads current consent, then checks durable membership and the
still-current consent revision before admitting mailbox/live work. Active jobs
also hold a local admission token. Retirement invalidates that token and
cancels a matching waiting job, including when a delayed membership reply still
says true. Cancellation is scoped to the exact recipient's acceptance ID.

Only active response jobs allocate tokens: at most the queue's four concurrent
jobs. Finally removes the owned token on success, refusal and exception. There
are no growing ACK tombstones. Coalescing, queue bounds, per-recipient ordering
and durable retry remain intact. A failed persistence removal still leaves its
row for a subsequent retry. No worker re-enqueues a retired acceptance.

Already admitted transport futures keep their lane until they settle; this
does not promise cancellation of bytes already submitted to transport or revoke
an acceptance the peer previously received. The general Outbox retry path is
unchanged. This qualification concerns the initial bounded response queue.

An intermediate candidate only reordered the reads. The expanded fixture caught
two additional ACK failures while the membership reply was held; admission
invalidation closes that gap. A fixture import error is not counted as defect
evidence. Two deliberate mutants each produce two assertion failures: removing
the final consent-revision check and removing ACK-to-admission invalidation.
Both files are restored byte-for-byte before final qualification.

## Qualification and operational limits

**570 related tests passed, zero skipped**, across twenty-five queue, contact,
consent, handshake, decision/preference, mailbox, expiry/provenance and UI suites.
With XVEIL_DIAGNOSTICS=true, **108 tests passed, zero skipped**, across four
overlapping suites; counts are not added as unique cases. The analyzer reports
no issues, whitespace checks pass and all 50 storage ABI checks pass.

Selected native libraries match producer hashes and 1,144 Rust/Cargo inputs;
no native build, ABI or wire format change is made. Checks run headlessly with
TMPDIR=/private/tmp/ and synthetic containers. No GUI app is opened/activated,
no focus or OS input is changed, and no installed app, user container, phone or
seed is modified. The original Windows 10 case remains unattributed.
No push or release.
