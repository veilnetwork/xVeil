# Device journal visibility and message storage waits — 2026-10-28

Concurrent public reads could export a signed device-journal row that had never
been saved. Device-post batching held a working bundle in `_batchBundles`, and
public `load()` returned that draft to every reader. The second row of a batch
could therefore be included in an archive or used by sync readers while the
final batch write was still pending. A later storage failure did not undo the
already returned snapshot.

## Correction

The working bundle now belongs to an explicit private object passed only to the
row builders of that serialized batch. Public `load()` reads storage; `_save()`
always follows its normal durable-write path. Row builders still share the
same draft and the batch still saves once. Successful completion and broadcast
continue to follow that save. Ordinary reads can see the preceding committed
state while rows are being built, or wait for a pending store write. They cannot
read the row builder's unsaved bundle.

Call-publication deduplication still joins the mutation gate. Reading only the
preceding committed call log would otherwise allow duplicate publication while
an earlier call post was pending. The separate synchronous outgoing-event stream
retains its local-intent semantics; this change addresses storage-backed bundle
reads, not a redesign of that stream.

Two regressions start an archive export while the second batch has built one
row and is signing another. The batch write is held, then either committed or
rejected before writing. Before release, the export must either be pending or
contain only committed rows. On rejection it must not contain either rejected
row; the committed fold must agree. The failure variant then retries a row
and requires a correct fold with unique sequence numbers. Both variants exported the unsaved row
against the preceding implementation and pass after the correction.

The 18-file suite passed 604 tests with three existing skips. Static analysis
found no issues. After adding the failed-write retry assertions, the affected
five-test selection also passed; these counts overlap. Existing batching (30 events in fewer than ten header saves),
call-publication success/failure, storage-read failures, admission/revoke races,
source attribution, durable ACK and history tests remain green. Fake signatures
and injected failures establish application behavior, not native cryptographic
or power-loss qualification.

## Measurements

A is Android/profile-AOT on Wi-Fi; B is its Mac sibling; C is another identity
on Mac. Mac Dart builds are debug. Two timed phases used retained profiles and
sent 12 A-to-C and six C-to-X messages with six submitters after a fixed
30-second warm-up. Production native and HV binaries were reused; no Rust,
relay or main-app changes were made.

The preliminary phase measured the bridge, batches and ACK status work. It did
not yet have the chat-append/outbound-ACK sub-stage timers. The corrected phase
added those timers and linked all six new C logical message IDs to their store
and bridge timings on A. Raw IDs remain private.

| Corrected phase: six new C messages stored on A | Mean ms | Peak ms |
| --- | ---: | ---: |
| Append chat row | 32.8 | 60.7 |
| Publish own-device copy, including the bridge | 3,227.3 | 4,785.4 |
| Bridge: check peer membership | 0.0 | 0.1 |
| Bridge: prepare mirror | 0.0 | 0.0 |
| Bridge: wait for journal publication | 3,227.1 | 4,785.2 |
| Their batches' run time | 3,180.7 | 4,783.8 |

These are nested measurements, not additive costs. A batch duration is repeated
for each message it contains and must not be summed as independent work.
Across all ten completed A batches in that window, load averaged 1,090.6 ms and
save 1,381.9 ms. Across all nine outbound ACK calls on A, transport send averaged
70.1 ms; the identity callback averaged 0.8 ms. No own-device target-fanout read
was observed in those outbound ACK calls. Across 25 inbound ACK membership checks,
the mean rounded to 0.0 ms; 17 status updates averaged 137.8 ms. These are different
sample sets and cannot be subtracted from one message's latency.

The main wait in this workload is local own-device journal publication. A single
chat append or cached membership check does not explain the seconds spent in
`_store`. Removing the durable mirror join would hide the wait while weakening
recovery; it is retained.

| Whole workload observation | Preliminary | Corrected |
| --- | ---: | ---: |
| Submit all 18 messages, seconds | 17.3 | 19.0 |
| Observe all three projections, seconds | 58.5 | 39.8 |
| Complete visible rows on every role | 838 | 856 |

All 18 logical IDs converged without duplicates, and complete visible IDs/order
matched in both phases. Histories advanced, timers changed, and background frame
mixes differed, so the last table is not a controlled latency improvement claim.

## Ordinary build and next work

Both QA source copies were restored to repository `lib` and rebuilt. The final
ordinary Android build was profile/AOT with no private timer strings, and the
private timing endpoint returned 404 on all three roles. Its 18-message burst
submitted in 17.3 seconds. All 18 messages and delivery marks converged by the
48.0-second observation; all 874 visible IDs and their order matched without
duplicates. There are no per-frame stage timings in this ordinary phase.

All owned apps were closed after every phase. The independent final audit
checked 41 recorded process groups and both owned Mac executable paths, found
none remaining, and confirmed that Android QA was stopped and its owned ADB
forward removed. Main app data and system power settings were unchanged.
Evidence is recorded in [summary.json](summary.json).

The next concrete candidate is the file-store commit sequence used for small
journal headers/segments: it writes a chunk batch and then publishes metadata
in another commit. A bounded atomic publication for small replacements may
remove a commit without relaxing durability. It still needs sync/async parity,
GC accounting, failure/retry, streamed replacement, size-boundary and native
verification. No such file-store optimization is included here.

Long delivery latency, Windows reports, partial chunk-ACK receiver-crash
recovery, live speech/headphone volume, long offline, revoke/split-brain and the
full multi-device matrix remain unqualified. Nothing was pushed, released or
deployed. Public evidence contains allowlisted roles, counters and timings;
raw logs, addresses, identities, device/message IDs and credentials remain
in private files.
