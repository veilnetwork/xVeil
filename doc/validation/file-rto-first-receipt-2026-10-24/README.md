# First-receipt timing for selectively acknowledged file data — 24 October 2026

Follow-up: [saturated SACK correction and a completed reverse transfer](../file-sack-freshness-2026-10-24/README.md).
The results below retain this earlier cycle's measurements.

SDK `27757b35`, based on `cc52c17b`; unchanged Dart frontends from
xVeil `c9e2d58f`.

## Confirmed engine defect

When a missing head was repaired, a cumulative ACK retired the already SACKed
tail. The old retransmission estimator used the tail's entire age as a new RTT.
That age included waiting for the head repair, even when the repair spent the
wait in the sender's local queue. This could inflate the next repair deadline;
it is not evidence of a high network ping.

The deterministic regression hands the originals to transport, receives the
tail's SACK after 10 ms, and holds the head repair locally until 9 seconds.
The old code changes `(SRTT, variation, RTO)` from `(10, 5, 80)` to
`(1133, 2251, 1000)` ms. The corrected code preserves the valid timing tuple.
Its next lost segment becomes repairable at the retained 80-ms deadline.

## Correction and safety checks

The engine records an original segment's first SACK RTT. At cumulative retirement
it never times the already received tail again. A deferred first-receipt sample
can conservatively **grow** the timer, including a 3-times-observed-RTT bound;
it cannot shorten retained backoff using old receipt evidence. A genuinely new
original delivery still updates the estimator normally. An actually slow original
head remains a valid slow sample. The deferred bound is an implementation policy
verified against the existing two-path reordering simulation.

Removing the bogus sample initially exposed a client file/media regression:
an immediately ready local sender filled a bounded receiver queue in a burst.
The parent client test passed in 6.33 s; the intermediate correction exceeded its
unchanged 10-s gate. The default batch sender now yields between accepted cells
so its runnable local receiver can drain. FIFO and unaccepted-cell retention
remain unchanged. The real client feed test then passed in 0.49 s with byte-exact
file recovery and its original 300-ms media gate. The optimized carrier batch
override is unchanged; this is local scheduler cooperation, with no traffic-class
priority, relay media hint or mailbox fallback.

The 137 stream tests include local repair/original waits, a truly slow original,
deferred sample replay, sequence wrap, RACK on/off, two-path reordering and a
bounded local queue's ordered batch delivery. All pass. The 30 client anonymous
stream tests, formatting and all-target stream Clippy with warnings denied pass.
No ABI, wire format or crypto change is intended. The optional local numeric
stream summary gains a count of discarded repeated SACK-tail age samples.

## Physical qualification

A cellular Poco and Mac used owned QA profiles with both contact P2P overrides
denied. Frozen SDK source hashes, the installed QA APK and loaded Mac library
were checked; the 199 exported Veil functions match the baseline. There were no
media test hooks, PCM injection, calls or opened audio devices.

| Scenario | Result |
| --- | --- |
| 32 MiB, phone → Mac, source stopped for 10 seconds after 4 MiB | **Complete in 149.569 s**, SHA-256 matches; passes the original 180-second gate. |
| 32 MiB, Mac → phone, uninterrupted | **Failed 180-s gate** at **23.25 MiB**; no completed-file hash. |

The restarted phone preserved its identity and became ready after **15.051 s**.
The receiver resumed at **4.25 MiB** (some in-flight data arrived after the 4-MiB
fault trigger). Its one retained payload-idle failure coincided with the deliberate
source interruption. No matching access denial or EOF-before-manifest was retained,
and the receiver retained **one** offer row. The restarted source's numeric
counter reached 9,206, proving the new SACK-tail handling ran on the physical path.
That count alone does not quantify avoided delay or prove all of those samples
would previously have inflated the timer.

The preceding requester-proof-only run did **not** complete within 600 seconds;
its result remains [recorded as failed](../file-source-restart-2026-10-24/README.md).
The new completion is a measured success, while the route and observation time
vary between runs: it does not establish an isolated causal speedup ratio or
prove intermittent stalls eliminated.

The reverse receiver retained a payload-idle failure and later a stream reset.
Collection followed harness cancellation at the 180-s limit; the reset is not
attributed to a separate network failure here. Retained resume requests included
1.75 MiB and 23.25 MiB. Neither endpoint retained a matching access denial or
EOF-before-manifest. **Variable throughput and payload-idle recovery remain open.**
The new source-restart success does not qualify the reverse-direction timing gate.
Local source admission traces did show capacity waits, but their sampled queue
ages reached only 2 ms: those samples do not establish the cause of the much
longer pause. Further work must correlate actual stream gaps and handoffs rather
than infer packet loss or network latency from the retransmission timer.

## Scope and cleanup

Both stand cycles independently verified process absence, original APK hash
restoration, diagnostic property restoration, profile pointer preservation and
removal of owned captures/ADB forwarding. Contact P2P overrides were restored.
The installed Mac app was untouched. All builds used the monitored external
volume; Mac stands used `/private/tmp/`. No phone network setting was changed.

This cycle does not qualify Windows, live speech, audio/video, the full A/B/C
matrix, long offline periods or every crash stage. The overall defect work
remains active. [Evidence](summary.json) is a whitelist of test counts, timings,
byte counts, booleans and code references; identifiers, credentials, paths,
addresses, payloads, binaries and raw logs remain private.
