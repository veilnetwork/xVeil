# Repeated canonical-history work — 2026-10-27

Phone profiling located a substantial wait before a chat send completed: in the
first window, the append stage took 36.7 ms (including author lookup), while
own-device journal publication took 3,612 ms out of a 3,783 ms `sendText` call.
Repeated journal views consumed substantial client time during the same window.

`_acceptedMessageRows` already canonicalized and verified all input rows. It
then called `_acceptedMessageChain` for every author/scope, which canonicalized
that same complete set again. A six-row fixture made 12 signature checks with
one author and 24 with three authors.

The chain fold now has a private entry point for an already-canonical set.
One synchronous view shares that set across its author/scope folds. Callers
starting from raw input still use the verifying entry point. New reads verify
again; no verification result is cached across views or awaits. Chain links,
fork quarantine, retention cuts and lifecycle filtering use the existing rules.

The regression compares one/three-author histories, repeats each read and sends
an invalid-signature row directly to ingest. It failed before the change and
passes afterward. The final related suite covers groups, crypto lookup,
retention, lifecycle and device sync; results are in [summary.json](summary.json).
Fixtures use fake signatures for application rules; native cryptographic
strength is not inferred from their checks. Static analysis reported no issues.

## Phone timing

A is Android on Wi-Fi and B is macOS, both identity X; C is another macOS
instance, identity Y. Android used profile/AOT; the Mac instances used debug
Dart. Retained profiles and the same frozen production native libraries were
used in both phases, with no forced route or native test hook. Private copies
added stage timers and memory-only commit probes; repository production code
received only the canonical-history change.

Three spaced sends each way completed in both phases:

| Observation | Before, ms | After, ms |
| --- | --- | --- |
| A submission, three rounds | 3,826 / 6,450 / 4,262 | 2,650 / 3,088 / 1,077 |
| A-to-C copy first observed on B | 10,092 / 10,669 / 9,126 | 6,925 / 6,096 / 4,631 |
| C-to-X first storage observation on A | 13,997 / 14,118 / 10,641 | 1,830 / 1,699 / 1,307 |

In the first phone window, mean group-view time was 857.9 ms over 13 calls
before, and 356.5 ms over 18 calls after. The append stage also varied with
background work: it was 342.4 ms in that candidate window. Stage totals overlap
and must not be added together. Profiles advanced between phases; polling and
event-loop stalls affect observation times. This supports removing duplicate
client work, not an isolated network-latency or universal speedup claim.

## Earlier projection differences

The earlier 18-message burst was rechecked with explicit ordering fields.
All 18 messages were present on A/B/C. A/B ordering authors and all ordering
sequences agreed; A/B delivery statuses agreed after settling/reconnect. Five
raw sequence differences on B corresponded to five explicit ordering repairs of
provisional own echoes. Raw `seq` alone had been an insufficient comparison.
Counterpart author aliases are a separate identity/device-address question;
three-way raw author equality is not asserted. Both new six-message phases also
converged in the fields checked. This does not qualify all historical state,
settings or the full multi-device matrix.

## Uninstrumented stand and FPS correction

Both private copies were restored to the repository sources and rebuilt. The
Android APK was AOT and lacked private timer strings; the endpoint returned 404
on all three running devices. An unpaced burst of 12 A-to-C plus six C-to-X
messages converged without duplicates. All **550 visible IDs and their order
matched**. Burst submission still took **27.0 seconds**; that bottleneck remains.

C then called X. A/B rang after 593/680 ms; answering on A stopped B ringing.
A/C became active after 3,813 ms. Across 41 samples over 89.8 seconds, both stayed
active on P2P with cameras on and increasing audio receive counters. Native
audio-delay peaks were 93/91 ms, not end-to-end speech-delay measurements.
Neither endpoint reported a stalled worker. No person assessed live speech or
headphone volume.

An interpretation error in earlier FPS reporting was found. Native cadence FPS
is `(frames - 1) / (last_frame_time - first_frame_time)`; the Dart fallback uses
the same lifetime-rate formula. A low snapshot after startup can coexist with a
current 30 FPS stream. Medians of snapshots after 30 seconds are still cumulative
rates and must not be presented as current FPS.

Using counter differences over host sampling intervals after 30 seconds,
received/rendered rates had medians of about **29.5 FPS on A** and **29.2 FPS on
C**. Sampling-time skew can produce interval estimates above capture FPS; these
are coarse interval estimates, not per-frame smoothness measurements. Android
transmission and Mac delivery were still only about 7–10 FPS in sampled seconds
30.5–37.3, so initial ramp-up remains open. No video improvement is attributed to
this change. The two preceding validation reports now explicitly label their
snapshot FPS observations as cumulative.

## Cleanup and remaining work

The last installed QA build contains the normal repository sources. Each phase
closed its apps. The final audit checked nine recorded process groups and both
owned Mac executable paths, found no app processes, and confirmed Android QA
termination and removal of the owned ADB forward. Main app data and system
power settings were unchanged. Raw logs, IDs and credentials remain private;
the public summary contains allowlisted roles, counters and timings.

Remaining work includes burst throughput, video ramp-up, frame-level quality,
live speech/headphone volume, Windows reports, partial chunk-ACK receiver-crash
recovery, long offline and the full multi-device matrix. Nothing was pushed,
released or deployed.
