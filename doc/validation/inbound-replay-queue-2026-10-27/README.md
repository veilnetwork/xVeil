# Incoming replay queue and journal reads — 2026-10-27

The unlocked incoming video call passed. Burst delivery and delivery during
history catch-up remain **open**. These changes reduce demonstrated redundant
work; they do not qualify Windows 10 one-way delivery or the full multi-device
matrix. Nothing was pushed, released or deployed.

Sources: xVeil base `67ab98e1` plus the changes in this commit, Veil `1d36980d`.
Existing production-seed native artifacts were reused; no Rust build was run.
The isolated Android QA receiver used the candidate Dart code. The macOS QA
devices retained base `67ab98e1`, so this was a receiver-side investigation,
not a comparison of three identical application builds. Native test hooks and
low identity difficulty were disabled.

| Role | Device | Identity |
| --- | --- | --- |
| A | Android, Wi-Fi | X |
| B | macOS | X |
| C | macOS | Y |

## Confirmed redundant work and corrections

1. **Exact authenticated retries occupied independent queue slots.** In the
   behavioral regression, 100 pending identical frames occupied 100 slots on
   the old caller and one slot on the candidate. Coalescing is limited to
   authenticated live group frames and messages carrying an ID. Source,
   device, provenance, reply route, admission class and payload must match.
   Callback-bearing mailbox deliveries and legacy messages without IDs are
   not coalesced. A retry after completion enters again, preserving ACK and
   chunk-reassembly behavior. Byte and frame limits are unchanged. Native
   ratchet progress still requests a checkpoint through one owned drainer,
   which shutdown joins.
2. **Whole-file loads requested every small log record separately.** The
   worker now accepts at most 64 exact record IDs per request. Ordering,
   first-missing-record refusal, the size guard and non-batch fallback are
   tested. No neighboring records or ranges substitute for missing data.
   The old whole-file loader failed the new batching regression; streamed
   file and range reads are unchanged.
3. **Concurrent journal readers repeated the same segment read.** Twenty
   concurrent readers previously issued 20 reads of the first segment; they
   now share one unfinished read. Completed results are not cached. Tests
   verify separate decoded bundles, visibility of deletion and repair, and
   retry after an injected read failure. Existing save-overtakes-load and
   missing-segment regressions also pass. Signature and membership checks
   still run for every caller.

## Physical observations and limits

The first cold text reached B while A still lacked it at 126,394 ms. A later
received it. The durable queue peaked at 477 frames. Captured handled group
frames included 177 repeated frame IDs among 388 chunk frames and 84 among
163 whole-group frames. No raw IDs are published.

Worker-side timing separated native work from request scheduling. Baseline
native commits had a median of 21.4 ms; the surrounding RPC wait could exceed
two seconds. Later incoming ratchet checkpoints usually took about 2 ms,
while dispatch took seconds. Summed waits overlap across concurrent readers
and must not be interpreted as elapsed wall time.

With B offline, C sent 100 texts to X. With coalescing and record batching,
A had 13 at the 124,706 ms observation limit, with 1,159 duplicate frames
coalesced and a peak queue depth of 106. After B returned, the subsequent
121,508 ms observer ended at A=27, B=25, C=100. No duplicates were observed;
history had not converged. The earlier coalescing-only run also failed its
delivery limit. The five-minute C-offline transition was not executed.

Before sharing pending segment reads, a separate 90,797 ms catch-up sample
completed 251 journal loads, whose median duration was 4,903 ms. After that
change, an 81,136 ms sample completed 158 loads, with a median of 2,529 ms and
519 segment-read requests instead of 2,051. These runs retained advancing
profiles and different in-flight backlogs: **they are not a controlled speed
comparison**. Metrics were reset with existing reads in flight, so completion
and start counts can differ.

The newly sent text was absent at both catch-up observation limits. In the
last sample no plain-message frame reached the instrumented receiver, while
group chunks and control frames continued arriving. Local read amplification
is demonstrated, but it does not by itself explain every delivery delay.
Sender dispatch, routing and catch-up traffic still require investigation;
neither permanent loss nor complete recovery is established by this sample.

After the user unlocked Android, C's incoming video call rang A and B within
1,266 ms. A answered, B stopped ringing, and the call remained active for
30 seconds through relays. Audio receive counters advanced by 647 packets on
A and 274 on C; video receive counters advanced by 337 and 286 frames. This
checks bidirectional media flow, not speech intelligibility, loudness or
visual smoothness. It used the preceding audio-startup guard build, before
the queue/read optimizations in this commit.

## Verification and evidence

The storage, backpressure, provenance, ratchet and snapshot suite passed 204
tests. The full group-service and device-sync bridge suite passed another
330, with three existing skips. Static analysis of nine changed files passed.
The standalone admission result and final cleanup audit are recorded in
[summary.json](summary.json).

Timing instrumentation existed only in a private QA source copy and was
removed after the stand run. Public evidence uses role/count/timing
allowlists; raw device logs, identities, content, keys and native identifiers
remain private. Current encrypted QA profiles were retained. Main application
installations and data, system power policy, relay configuration, mailbox
policy and relay scheduling were unchanged. Final process/permission/forward
cleanup results are in the aggregate summary.
