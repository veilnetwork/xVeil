# Bounded message records and recoverable bulk scrubbing — 2026-10-28

Two storage defects were confirmed against application `0dd2a74f`:

| Finding | Evidence | Change |
| --- | --- | --- |
| Large post/edit JSON exceeds the encrypted record capacity | The real native file rejected a 16-KiB random fixture encoded as text with `HvException.PayloadTooLarge`; the preceding physical campaign also rejected a roughly 12-KB text fixture | Split the stored event into bounded records within one transaction |
| Interrupted bulk clear/prune can skip required vacuum on reopen | A small-record regression against the exact old storage source observed one scrub call instead of two after an injected interruption | Persist the scrub obligation in every successful message-deletion batch |

## Persistence

Events up to 1,800 encoded bytes retain the existing single-record format.
Larger events, bounded at 512 KiB, use a descriptor and 1,200-byte pieces encoded
as small JSON records in the existing deterministic message-log shards. The
descriptor, pieces, author-sequence update and first-use shard markers share
one commit. Reserving global log IDs may leave unused physical IDs after a
failed write; it does not consume the conversation's author sequence.

Reads reconstruct one logical event, checking the bounded descriptor, every
piece's owner/index/length, and SHA-256 before exposing its original JSON.
History, edit history, gap-fill and conversation high-water therefore see the
original event count and sequence. Pieces can cross shard boundaries. Warm
folds still rebuild when an earlier allocated writer commits after a later one.
A lost worker reply after commit leaves the potentially durable rows eligible
for reads on the existing handle, without reporting success to its caller.

Wrappers are body-less void records to older readers. Surrounding ordinary
history remains readable on downgrade, but displaying newly split events
requires the current reader. Already valid split records stay readable when
the inline write threshold changes. No eager conversion, new namespace, native
library change or plaintext spill file was introduced.

## Deletion and recovery

A rewrite of a split event verifies ownership and replaces all its pieces with
body-less records in the same commit unit as its head. Point deletion includes
the post and retained edit rows. Bulk fallback never splits a head from its own
pieces. Normal deletion scrubbing reclaims the superseded encrypted batches.

Bulk clear, removal and retention pruning now also commit the existing pending
scrub marker with each successful message batch, under the deletion/scrub gate.
On reopen the existing recovery path completes vacuum before exposing history.
The obligation also covers ordinary small records; it is not specific to the
new format. An uncertain failed mutation invalidates the cached obligation so
the next recovery reads its durable state.

Bulk mutation can still finish only a subset of its logical events if a later
batch fails. This change does not add a durable transaction spanning an entire
multi-batch conversation clear. Failure injection is not a physical power-cut
qualification.

## Verification

The final 17-file compatibility run passed 284 tests without skips. Static
analysis found no issues in the three changed Dart files. Allowlisted results
are recorded in `summary.json`. Tests include a real encrypted file across reopen, post/edit
history and metadata, deletion and scrub, missing/misbound/corrupt pieces,
oversize descriptors and input, UTF-8 boundaries, refused and uncertain commits,
cross-shard publication with a delayed independent writer, bounded bulk
fallback, and scrub recovery after interrupted clear/prune. The small-record
scrub regression failed against the exact previous storage source for the
expected reason; an initial private test-runner metadata failure was repaired
before that red result was obtained.

## Physical qualification

The final source used retained encrypted profiles: A is Android on Wi-Fi and
B its Mac sibling; C is a different identity on Mac. Android uses profile/AOT
and Mac debug Dart, with frozen production native SDK/media/hidden-volume
artifacts. Both private `lib` copies were byte-for-byte equal to the root source;
the APK proof also binds its exact Dart diff. No private timing overlay or
native test hook was used.

A sent twelve messages and C sent six, using six concurrent submitters. One
message carried 2,000 generated ASCII characters plus its fixture prefix,
necessarily exceeding the 1,800-byte inline storage boundary while remaining
within the live wire bound.

| Final-source observation | Result |
| --- | ---: |
| New messages per role | 18 |
| First all-role observation after submission began | 29.5 s |
| Equal full histories before deletion | 1,406 rows each |
| Group chunk queues empty before mutation | 88.8 s |
| Edited text observed on all roles after edit request began | 10.2 s |
| Deleted target absent on all roles after delete request began | 12.6 s |
| Equal full histories after deletion | 1,405 rows each |
| Duplicate logical IDs | 0 |
| Unrelated logical IDs preserved after deletion | All |

Full logical ID order agreed before and after the edit and after deletion.
Final group chunk queues were empty. B retained one unrelated P2P endpoint
announcement; complete outbox drainage is not claimed. These observations do
not constitute a controlled latency comparison. An earlier candidate run also
converged with a smaller fixture; only the final-source numbers are used above.

After both runs the apps were closed. The independent final audit found zero
processes in 91 recorded owned process groups, zero matching Mac QA executables,
zero Android QA package/named-subprocess instances and no owned ADB forward.
QA permissions were restored; the main app/data and system power settings were
unchanged.

This is a storage correction. The live authenticated-message path still has a
6,144-byte encoded-delivery limit, including protocol overhead. End-to-end
delivery of text spanning tens of kilobytes over relay is not established by
the large native-storage fixture and remains follow-up work. No claim of
improved delivery latency, call quality, Windows qualification or completion of
the entire multi-device matrix is made.

Only QA profiles/apps were used. Raw logs, addresses, credentials, message IDs
and fixture bodies remain private. Public evidence contains fixed roles,
counts, timings and source-owned labels. No push, release or server update was
performed.
