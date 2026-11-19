# Initial request admission after a relationship decision

Base: `1f5c6c26`. This extends the
[manual retry qualification](../contact-request-retry-2026-11-17/README.md)
to the first request. It does not attribute the original Windows 10 report.

## Reproduction

The first submission prepared pending contact intent, saved the greeting, then
unconditionally enqueued its request. A completed accept, block or cancellation
between those steps could retire the relationship's request obligations before
the initial submission created another one. A cancellation followed by a fresh
request also failed to distinguish the old operation from the new relationship.

The fixture holds completion of a real committed greeting append, completes the
decision through MessagingService, then resumes submission. On the base source,
all eight cases fail on the obsolete request reappearing in durable Outbox:
four decisions on an ordinary KV store and the real native worker/container.
These are assertion failures, not startup failures. Captured wire envelopes also
allow checking that the resumed operation makes no request send after the fix.

## Change

Initial submission captures the originating contact revision. Final admission
checks that revision and the current durable outgoing request intent under the
same Outbox/contact lanes used by retry admission. It cannot borrow the pending
status of a fresh request after cancellation. A completed durable block is also
refused even without a service-side revision notification. Wire IDs, sender
sequence, timestamps, durable age and storage-error propagation are preserved.

Pending preparation itself cannot change an accepted/blocked decision or grant
normal messaging access. It therefore no longer invalidates accepted-access
revisions: a concurrent incoming intro or another legitimate new greeting must
not cancel the original outgoing operation. Actual decisions, cancellation and
service disposal still invalidate it. Crossed incoming status must retain the
existing outgoing intent; incoming-only intent cannot authorize a first send.

A submission queued behind a completed acceptance still follows the ordinary
message path and its consent checks. An intermediate candidate accidentally
refused this valid case. Existing ordinary/native controls caught both failures;
the final implementation preserves that behavior. A local greeting rejected by
the existing erasure/expiry gate no longer becomes an empty replacement request.

The new initial admission method shares the existing guarded persistence core
with manual retry; the retry's exact-row check and stricter pendingOutgoing
requirement remain intact. The API fault fixture now targets the new admission
boundary. This is a Dart storage interface change, with no native ABI change.

## Verification

The focused suite has **36 passing cases**, covering empty/nonempty requests,
accept/block/cancel/cancel-and-replace, crossed requests, concurrent valid
greetings, unrelated decisions, service disposal, durable block without a
revision notice, erased greetings and two storage commit faults. Before-commit
refusal and lost-reply-after-commit both remain errors, send no initial network
copy, and recover through the existing manual retry with the same greeting ID.

**348 related tests pass, zero skips**, across 14 suites: initial/retry/incoming
request races, greeting order, consent, atomic acceptance, device decisions,
request lifecycle, mailbox, UI feedback/consent, HTTP admission and managed
encrypted/plaintext storage. `dart analyze lib test` reports no issues. The
retained native library matches its preceding provenance hash; current exports,
contract and all 50 binding checksums pass. Rust was not rebuilt.

The first related invocation included a nonexistent test filename; that load
failure is not counted as a product failure or successful check. The credited
final invocation uses existing files and the corrected acceptance behavior.

## Limits

This verifies local admission and controlled transport invocation, not the
remote Windows peer's screen or network. Greeting persistence and request
admission are still separate operations; this does not make the whole composer
transaction atomic or change draft recovery on an exception. Work already
admitted before a later decision cannot be recalled from the network. A result
that was admitted before a subsequent decision continues to describe that local
admission; obsolete continuation cannot initiate another network attempt.

No GUI applications were launched or activated, no OS input was injected, and
the existing user application was left running. Only synthetic test stores were
opened. No phone, relay, installed package, native binary, push or release changes.

## Verifying a lost commit reply

The original qualification above preserved both write errors. The later
reproduction distinguished pre-commit failure from a lost reply after the
full commit. In the latter case the old code reported an error even though
the request was already durable and could be sent by a later retry.

Initial admission and manual retry now share a read-only check of the exact
indexed payload in the same open store. The stored frame must match byte for
byte before admission is reported. If the record is absent or the check
fails, the original write error propagates. Readback leaves the index and
payload untouched. The normal contact revision still gates the live leg.

Two tests first reproduced the lost-reply error on the original code. The
final fixture checks initial admission, manual retry, pre-commit failure,
and temporarily unreadable readback after a commit. The valid record
survives reopening with the same greeting ID, body and sequence. The fault
is injected in the ordinary store. The same focused suite also exercises
the ordinary success and consent controls with the native storage worker.
The related suite passed 800 tests without skips. The analyzer reported no
issues in the changed files.
