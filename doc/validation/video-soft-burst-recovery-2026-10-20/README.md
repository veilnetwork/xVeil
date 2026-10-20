# Video recovery after brief duration-measured audio damage

## Scope

Follow-up to [the source hold report](../source-growth-hold-2026-10-20/README.md).
The strict 200 ms acoustic fixture target remains deferred. The measured audio
buffer ceiling remains 300 ms. This cycle changes two demonstrated causes of
video deterioration and recovery delay; it does not claim the full audio/video
or interaction-separation objective complete.

## Changes

| Evidence | Retained correction |
| --- | --- |
| Captured 28 ms then 114 ms damage in ~1 s produced a 142 ms window and cut two video rungs at a 138 ms buffer | Moderate 120 ms/six-second damage now needs fresh events spanning at least 3 s. A total of 240 ms in that window still qualifies immediately. |
| A new current peer report arrives during a 3 s growth hold; earned healthy observations survive, but recovery waits for another report | A distinct latest peer report during the earned recovery period can confirm the first healthy upshift after the hold. It is not required to arrive on that exact poll. |

Cached counters and elapsed time alone cannot make a burst sustained. Origin,
sequence, freshness, retirement, rollback, observation-gap and expiry guards
are retained. Counters remain separate per decoder/peer. The new thresholds
are local classification; authenticated RTCP framing and ciphertext are unchanged.
RTP loss, actual interruption, growing/capped buffers and large duration damage
retain their independent audio protections. The source-paid window and file
allowances still honor actual pressure.

Video still needs twelve healthy observations for ordinary recovery. The native
budget must acknowledge each applied rung; the existing bounded bitrate/FPS
ramp is retained. Old/unknown observations cannot create growth, one cached peer
report cannot authorize multiple promotions, and engine replacement resets the
recovery baseline. Existing tests for those cases pass. No new relay knowledge,
labels, scheduling preference or media priority was introduced.

## Verification

- A new regression test fails against the previous policy: expected level 1
  after a current distinct report and drained hold, but level stays 2. After the
  correction it passes with all prior related tests: **232 Flutter tests**.
- Real WebRTC packet-builder/parser smoke covers the captured 28+114 ms burst,
  cached/time-only non-qualification, fresh moderate damage spanning 3 s and
  the immediate 240 ms threshold. Gap/replay/retirement/expiry checks remain.
- The real production shim smoke verifies authenticated compound feedback:
  short combined damage remains below the cut trigger, a replay cannot make
  it sustained, and fresh continuing loss still protects audio.
- Real Opus direct/group call-planes smoke passes, including delivered audio
  while video worker/fanout queues are held, muted start/rebuild, native codec
  budgets, source cadence, restart and complete teardown.
- Production and frozen-baseline Dart analysis pass. New media hook/production
  libraries export 139/105 symbols. Both required-symbol gates and independent
  dynamic loads pass. SDK ABI is unchanged; the previously verified clean
  SDK binary from `ab6d6c14` is reused without a new Rust build or test claim.

## Controlled ordinary comparison

Same SDK, 1024 kbit/s neutral aggregate FIFO, actual Opus/VP8, anonymous
150 kbit/s/15 FPS source policy, synthetic 320x240 input, and two concurrent
512 KiB encrypted files. The old adapter runs from a frozen copy with its own
package configuration, old native library, and otherwise identical scripts.
No source changes/builds/tests run during captures. The old runtime lacks the
new recovery-confirmation diagnostic; the new runtime contains it.

| 180 s capture | Final-minute decoded FPS | Last dimensions | Missing markers | File hashes | Acoustic peak |
| --- | --- | --- | --- | --- | --- |
| Frozen baseline | 14.95 / 14.93 | 320x240 both | 0 / 348 | 2/2 correct | 180.28 ms |
| Candidate | 14.54 / 14.71 | 320x240 both | 0 / 348 | 2/2 correct | 170.38 ms |

After 60 s, both captures had zero additional audio recovery discards,
interruptions and fallback frames. Neither naturally triggered a video rung
cut. This establishes ordinary healthy-load behavior, not an end-to-end
reproduction of the short burst. The deterministic regression and real shim
checks establish the changed mechanisms. The earlier old-policy run near
3 FPS is retained in the linked report; comparing it alone with this candidate
would overstate an FPS improvement.

Both ordinary raw fixture results remain **false**: the baseline recorded
5/0 and candidate 2/2 skipped feedback reports. Original hold expiry is
explicitly rejected. The existing no-skips gate is retained; the measured
quality results above are not substituted for a raw passing verdict.

## Saturated group capture

The candidate retains the saturated 360 s, three-process group scenario with
six video directions and three 512 KiB encrypted files. All 2112 markers arrived,
all three file hashes matched, and all directions retained 320x240. Final-minute
FPS were 1.02–2.25. Peak acoustic delay was 220.17 ms; summed additional native
recovery discards after 60 s were 70 ms across three receivers, with no reported
interruptions/fallback frames. The final-minute neutral FIFO admitted 91–92% of
1024 kbit/s capacity. The original raw fixture result remains **false**, including
the deferred strict 200 ms requirement. No gate was relaxed.

The prior candidate recorded in the source-hold report had 1.32–2.02 FPS,
270.18 ms acoustic peak and 1090 ms summed discards. This is an explicitly
historical comparison, not a newly paired baseline or a causal performance
claim. Low group FPS under a nearly full aggregate link is not fixed by simply
increasing an audio threshold.

## Same-call capacity recovery

A neutral link capacity increase was added to the fixture, not production
routing: 1024 to 8192 kbit/s at measurement second 120, without restarting
workers, peers, calls or routes. The applied event is timestamped in the result
and the timer is joined before teardown. Files and video are frozen at their
original measurement deadlines.

| 300 s call | Before step, six paths (60–120 s) | Final minute, six paths (240–300 s) | Audio markers | Files |
| --- | --- | --- | --- | --- |
| Initial observation | 1.24–3.22 FPS | 14.42–14.47 FPS | 1752 matched / 6 unobserved | 3/3 hashes correct |
| With PCM observation tail | 1.09–4.05 FPS | 14.39–14.44 FPS | **1758 matched / 0 missing** | 3/3 hashes correct |

Both runs kept all six directions at 320x240 and restored the nominal 150
kbit/s, 15 FPS profile on all three controllers. In the second capture the rate
change was applied at 120.005 s. Native recovery discards, interruptions and
fallback-frame counters had **zero additional increments** after step+5 s for
all receivers. This verifies recovery in an already running, previously
capacity-limited call, in addition to the permanently saturated 360 s case.

The six initially unobserved markers were all the last source transition at
299.970 s. The PCM observer stopped at 300.000 s, leaving only 30 ms for real
codec/network/playout delay. Raw data and the unchanged false verdict are
retained in `capacity-relief-missing-markers.json`. The fixture now records an
extra second of real PCM after freezing file/video metrics. The checked source
interval is still [5, 300); no source edge was removed or discounted. The repeat
observed all six final markers and all earlier checked transitions.

The repeat's original raw verdict is still **false**, including the deferred
strict acoustic gate: peak 210.10 ms. All three worker quality/clock verdicts,
route/topology checks, file hashes, process exits and socket cleanup passed.
At 300 s it is not labeled a completed 360 s contention qualification.
This is evidence of video recovery, not completion of every audio criterion.

## Broader objective and limits

Production wiring already binds separate local clients/senders for audio,
video, screen, feedback and call control in `veil_flutter_transport.dart` and
SDK `media_ffi`. This cycle retains that wiring; the native blocked-video tests
provide dynamic evidence for local audio independence. These captures are not
proof of every physical/network combination or full end-to-end isolation.

The capacity step now verifies same-call recovery and headroom across six
video directions. Remaining verification includes real screen capture,
physical P2P/relay/obfs paths, live speech and headphone loudness.
Synthetic marker integrity does not establish speech intelligibility. The
200 ms acoustic target is deferred, not silently relaxed into a pass.

## Provenance and cleanup

`build-proof.json` maps exact current source digests and native binaries.
`policy-baseline-proof.json` describes the frozen old adapter/package root.
`test-proof.json` records regression/verification logs and hashes. Comparisons
retain original raw verdicts, dimensions, frame counters, file hashes, audio
recoveries and scope. Raw traces remain at their recorded cache locations.

All owned fixture/helper/worker/policy PIDs were checked absent after captures;
all embedded node stops returned zero, threads/timers exited and sockets closed.
The initial no-tail capture is retained with its own independent cleanup proof.
Foreign root/SDK WIP diff hashes remained unchanged. No physical UI apps were
opened, and no phone installation, push, release or relay mutation occurred.
