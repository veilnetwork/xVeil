# Joined group ingest and durable receipts — 2026-10-27

The group callbacks were declared `void`, although the provider started
asynchronous required work. Messaging returned from dispatch/reassembly and
acknowledged frames before the group write finished. Besides retiring the
sender's recovery copy prematurely, this let work accumulate behind the group
mutation gate outside transport admission.

Both UI and headless bindings now return a terminal result and join the group
operation. Whole snapshots and every slice of a chunked snapshot are ACKed only
after successful ingest. Missing handlers, rejected snapshots and write failures
leave frames retryable. Authorized sync/clear requests with nothing to change
are terminal too. The transport reservation covers the awaited operation.

Partial assemblies retain bounded, minimal ACK routes including physical-device
attribution. Separate bounded receipt caches bind source, frame ID and body;
completed chunk-transfer receipts require the existing content-bound SHA-256 ID.
Canonical IDs cannot be consumed through another wire kind, and reassembled
bytes must match their transfer digest. Handler replacement clears old receipts
and prevents an in-flight old handler from acknowledging for its replacement.
Own-device fallback ACK targets are resolved once per completed slice batch.
No relay scheduling, mailbox policy or media priority changed.

Legacy IDs without a content digest can still ingest through the existing group
validation, but only authenticated attribution permits their ACK. Anonymous
legacy senders therefore do not obtain terminal receipts from that path.

## Verification

An old-API-compatible test compiled against exact base `411c379a` and failed
because the ACK arrived while persistence was still held. With this change,
419 relevant tests passed, with three existing skips; analysis of all changed
Dart files passed without issues. Coverage includes whole-snapshot persistence,
storage failure and identical retry, actual sender-outbox survival through a
partial receiver restart, device ACK routing, malformed/corrupt chunks,
content-bound IDs, legacy attribution, handler replacement and shutdown joining.

The physical stand used retained encrypted profiles: A Android on Wi-Fi and B
macOS share identity X; C macOS is identity Y. All three used this candidate over
base `411c379a`, unchanged Veil `1d36980d` native artifacts, normal production
media libraries and normal identity difficulty. Both private source copies were
byte-for-byte equal to the application's `lib` tree. No timing overlay, native
test hook, Rust build or server change was involved.

Recovery of the previous 100-message fixture began at A=44, B=100, C=100. After
181,906 ms, A held 52 and B/C still held 100, without duplicate logical IDs.
The recovery gate deliberately stopped the later cold-message and new-burst
phases; no new messages were added. This does **not** qualify delivery latency
or complete convergence. Read-only diagnostic queries were made during recovery.

The captured phone log contains 41 slow save measurements, peaking at 1,829 ms,
and 98 slow flush-work measurements, peaking at 2,646 ms. These are selected slow
log samples, not a distribution of all writes or proof of the remaining root
cause. Individual deltas, larger catch-up batches, journal persistence and
device-event application still need separation in the next investigation.

## Remaining limits

Receipts are in RAM. A receiver crash **after** commit but during individual
slice ACKs can leave a sender with only a subset of a completed transfer. The
data is already durable, but retiring that residual outbox subset after restart
is not qualified here; fresh sync remains necessary. No persistent receipt or
atomic transfer-level retirement protocol was added.

This check does not verify Windows, long-offline/revocation scenarios, calls or
the complete multi-device matrix. The slow physical catch-up remains open.

All five recorded macOS process groups and the QA Android process were checked
absent after cleanup. QA permissions were restored and the owned ADB forward
removed. Main app data and system power settings were unchanged. No push,
release or deployment was performed. Public [evidence](summary.json) uses only
fixed labels and anonymous counts/timings.
