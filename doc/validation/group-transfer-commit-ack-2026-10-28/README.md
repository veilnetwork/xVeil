# Atomic retirement of committed group transfers — 2026-10-28

The remaining post-commit limitation in the [joined-ingest check](../group-ingest-receipts-2026-10-27/README.md)
was reproduced against application `8d4c6a93`. The receiver's terminal handler
verified a seven-slice bundle, persisted a commit marker and returned success,
but delivery of just the first individual ACK left six sender outbox rows.
After receiver restart its RAM receipts were gone and that
tail could not reconstruct the complete bundle. This was a recovery-copy
retirement defect after successful persistence, distinct from acknowledging
before persistence.

New group chunk transfers opt into a transfer-level acknowledgement with the
additive `a:1` field. The receiver joins every slice, validates its content-bound
transfer ID, awaits successful group ingestion, then sends one `grpa:` ACK. Even
a committed retry with a RAM receipt must first assemble all slices again:
acknowledging its first slice could race the sender still enqueueing the rest.
Existing reassembly limits, handler epochs, admission and membership checks
continue to apply.

The sender binds the ACK to the complete canonical transfer ID and destination.
An own-identity alias additionally requires a verified sibling destination.
Only matching, opted-in group chunks are selected. Another accepted contact,
another transfer, document chunks and ordinary user-message delivery marks are
unaffected. Anonymous one-time reply delivery retains the existing ACK
authentication model.

All selected authoritative outbox index keys are retired in one encrypted-store
transaction. Small transfers reclaim payload logs in the same transaction;
large ones reclaim logs after index retirement in bounded batches, respecting
the native log-tombstone cap. An uncertain transaction invalidates the cache
before rethrowing, so later storage reads reload its all-or-none durable result.
No persistent receiver receipt journal or native schema change was added.

## Deterministic checks

Eleven relevant test files passed 504 tests with three existing skips. This
includes the real hidden-volume native test enabled with `XVEIL_HV_DYLIB`.
Static analysis found no issues in the ten changed Dart files.

The old-source regression failed with six residual sender rows after one ACK;
the corrected source retires the whole transfer with that single ACK. Coverage
also includes loss of all ACKs followed by receiver restart, replay after a RAM
receipt, another sender attempting retirement, verified own-device aliases,
individual legacy ACKs, and an already queued legacy transfer across upgrade.
Storage checks inject failure before and uncertainty after the atomic commit,
preserve an unrelated recipient, reload both the live and reopened storage,
and retire 1,100 rows without exceeding the log-deletion cap. A real encrypted
file verifies recipient-scoped batch retirement across reopen and a transaction
deleting 2,200 index keys. Failure injection does not claim a physical power-cut
test.

## Compatibility and limits

The new recovery guarantee requires an opted-in transfer and a receiver that
understands its transfer ACK. Old senders and receivers retain individual ACK
compatibility. A new sender preserves legacy mode for an identical transfer
already queued by an older client; this change does not reconstruct an old
orphaned tail. Mixed-version post-commit crashes retain the previous limitation.
The corresponding shared-document chunk protocol is unchanged.

The first physical attempt used an additional synthetic 12,300-character text
fixture. It failed at message storage with `HvException.PayloadTooLarge` before
qualification completed. That run is not counted as a passing delivery check;
the text-record size limit is a separate observed, unfixed issue. The follow-up
uses a 1,200-character fixture and retained profiles.

## Physical follow-up

A is Android on Wi-Fi; B is its Mac sibling and C is a different identity on
Mac. All three use retained encrypted QA profiles. Android uses profile/AOT,
both Mac bundles use debug Dart, and production native libraries are frozen.
Both source copies were byte-for-byte equal to the application's `lib` tree.
No timing overlay or native test hook was used.

A sends twelve messages to C and C sends six to identity A/B, with six concurrent
submitters. One A message includes the 1,200-character fixture. All eighteen
messages were visible on all roles by 59.4 seconds after submission began. Each
complete history contained 1,371 rows, with the same logical IDs in the same
order and no duplicates. The longer fixture was byte-for-byte identical on all
roles. This check establishes convergence, not a delivery-latency improvement.

The existing diagnostic log recorded six aggregate ACK sends on A (five unique
IDs) and twenty-five on B (twelve unique IDs), including repeats. Pending group
chunk queues reached zero on all roles at 109.2 seconds and stayed empty through
the final observation at 166.7 seconds. One separate P2P endpoint announcement
remained in B's outbox; complete outbox drainage is not claimed.

After cleanup, an independent audit found no process in 87 recorded owned Mac
process groups, no Mac QA executable, no Android QA package process or named
subprocess, and no owned ADB forward. QA permissions were restored.

Physical results and independent cleanup are recorded in `summary.json`.
Private logs retain credentials, addresses, message IDs and fixture bodies;
the public summary contains only fixed roles, counts, timings and labels.
The main app and its data were not modified. No Rust build, relay update,
push or release was performed in this cycle.
