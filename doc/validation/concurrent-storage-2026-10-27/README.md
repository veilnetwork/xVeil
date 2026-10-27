# Concurrent message storage — 2026-10-27

Two reproducible persistence defects were found while investigating phone send
latency. These changes address correctness, not the remaining delivery delay.

* Sixteen concurrent local appends could all read the same conversation/author
  sequence cursor before committing: all sixteen received sequence 1. Appends,
  edits and emitted clears now share a lane per conversation and author. Other
  conversations/authors can still complete while one data commit is stalled.
* With a deliberately delayed asynchronous commit, a newer record could finish
  first, then the older commit overwrote the durable global cursor with a lower
  value. A warm history scan also skipped that late record. This is demonstrated
  against the asynchronous storage contract; native commit reordering on a real
  device was not established by this test.

Global IDs now come from durably reserved windows, normally eight IDs. Message,
call-journal and multipart outbox data commits do not rewrite the shared cursor.
Multipart outbox records reserve a contiguous range. Failed writes or crashes
can leave unused internal IDs; these are separate from wire conversation
sequence numbers. No wire format or cryptographic policy changed. Existing
damage caused before this change is not repaired automatically.

History readers track the committed frontier rather than the unused reservation
tail. A commit behind an already folded frontier, or during its asynchronous
snapshot read, requests a clean replay. Incremental scans filter their boundary
overlap instead of replaying an old post over a warm edit winner. Accepted writes
drain before close/erase; new writes are refused during that maintenance.

The final serial test run passed **321 tests**, including real encrypted outbox
storage, storage recovery, worker death/close, device sync, call journals and
durable redelivery. Added cases exercise concurrent appends/edits/clear, failed
data and reservation commits, independent streams, lifecycle draining, late
commits before/during reads, reopen and disjoint multipart ranges. Static
analysis reported no issues. Production code contains no private stage timers.

## Physical stand

A is Android on Wi-Fi and B is macOS, both identity X; C is another macOS
instance, identity Y. Retained profiles started with 502 visible messages.
Android used profile/AOT with its existing authenticated debug API explicitly
enabled; both Mac instances used debug Dart. Frozen production Veil
`1d36980d`, media and hidden-volume artifacts were reused, without native test
hooks, reduced identity difficulty, forced routes or Rust builds.

Six concurrent API workers submitted 12 A-to-C and six C-to-X messages. All 18
eventually appeared exactly once on each device. The resulting **520 visible
IDs and their order matched**. New rows had unique raw sequence values per
origin on each device. Submission took 27.3 seconds; Android catch-up then took
tens of seconds. Full-history observations were spaced ten seconds apart rather
than polled every half second. This is not an isolated latency benchmark.

This does **not** establish full event-state convergence. At the data snapshot,
five new A/B rows differed in raw `seq` and five in delivery status, while their
bodies and timestamps matched. The API exports raw sequence numbers, not the
separate repaired ordering position used for provisional own echoes. Raw
sequence differences therefore do not alone establish an ordering defect.
Repaired positions and later status convergence need a separate comparison;
no new defect or complete-state pass is claimed from these fields.

C then placed an incoming video call to X with Android unlocked. A/B rang after
271/319 ms. Answering on A stopped B ringing; A/C became active after 5,189 ms.
Across 35 samples over 88.7 seconds, both endpoints stayed active on P2P, cameras
remained on and audio receive counters increased. Native audio-delay peaks were
101 ms on A and 83 ms on C; these are not end-to-end speech-delay measurements.
Neither endpoint reported a stalled worker.

Video quality is **not qualified**: after the first 30 sampling seconds, received
FPS was 3.7–21.5 on A (median 17.7), and 1.0–17.4 on C (median 11.3).
There was no zero-FPS sample in that interval, but the dips remain a concern.
No person assessed speech intelligibility or headphone volume in this run.

All started apps were closed. The final audit found no processes in five
recorded process groups, no owned Mac executable processes, no Android QA app
process and no owned ADB forward. Main app data and system power settings were
unchanged. Raw IDs, keys and logs remain in private local files; the committed
[summary](summary.json) contains allowlisted roles, counts and timings.

Nothing was pushed, released or deployed. Delivery latency, video dips, the
earlier partial chunk-ACK receiver-crash limit, Windows reports and the full
multi-device matrix remain open.


### FPS interpretation correction

The [follow-up](../canonical-history-work-2026-10-27/README.md) checked the
implementation: the exported FPS snapshots above are cumulative rates since
the first frame, including earlier startup/slow periods. They are not rolling
rates, even where a summary field was named `steady_rx_fps`. Filtering samples
to those after 30 seconds does not change that definition. Use counter deltas
over sampling intervals to investigate current cadence; these older snapshots
alone do not establish continuing video degradation or absence of freezes.
