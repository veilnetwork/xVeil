# Investigating the 280-ms audio peak

The requested gate is decoded capture-to-output latency below 200 ms under the
existing full workload. The relay must remain neutral. Reducing latency by
losing tone transitions, stopping the workload early, or silently relaxing its
gates does not qualify.

## Recorded cause

`baseline-peak-pipeline.json` joins the original maximum to its actual encoded
packet, authenticated SDK cell, source transport, and receiver output clock.
The source and receiver clocks belong to the same owned host.

| Stage | Time |
| --- | ---: |
| Capture marker to encoded packet | 10.129 ms |
| Encoded packet to receiver ingress | 132.136 ms |
| Receiver ingress to WebRTC | 0.009 ms |
| WebRTC insertion to decoded PCM marker | 137.806 ms |
| Total | 280.080 ms |

Native send admission was 0.004 ms. SDK sealing, IPC and dispatch were also
sub-millisecond. At the output marker, the receiver target was 120 ms with a
40-ms packet, and its recorded local storage fell from 140 to 120 ms. The
relative RTP clock age was approximately 228 ms. The long span is therefore a
combination of delivery delay and receiver buffering; it is not a 280-ms local
send queue or a measurement of propagation alone.

The original source connection's recorded QUIC datagram queue maximum was
1.670 ms, without a congestion-window or pacing block in the surrounding
snapshots. This does not identify each downstream hop. No per-hop UDP/shaper
identity is inferred from adjacent packets or packet lengths.

## Rejected changes

* Lowering only the policy ceiling from 300 to 200 ms produced a 250.235-ms
  peak. All files arrived, but video remained slower and its tail gates failed.
  This was a private policy export; the production ceiling was not changed.
* Reducing the pressured source floor from two competing MTUs to one produced
  a 200.103-ms peak, with no missing voice transitions and all files delivered.
  Video tail changes fell to 9–13, below the required 14. This candidate also
  enabled opaque forwarding diagnostics, unlike the original capture, so its
  performance difference is not attributed exclusively to the floor parameter.
  Its source-cell diagnostics reached their cap; the full source-session
  analyzer correctly refused attribution. Native PCM/packet traces remained
  complete. Neither the latency nor video gate passed.
* Receiver-only prototypes were evaluated against the same recorded arrival
  schedule using regenerated Opus tones. Aggressive age trimming repeatedly
  fought NetEq's refilling, and lowering the target to offset standing delivery
  delay increased concealment. Their peaks remained above 200 ms. These
  prototypes were not applied to production sources.

Raw failed verdicts are retained in `rejected-ceiling-200.json` and
`rejected-one-packet-floor.json`. The original workload runs for 360 seconds
with three SDK/codec processes, six audio/video directions and three encrypted
512-KiB files. The blind FIFO allows 1024 kbit/s in each direction and knows
nothing about application traffic types.

## Source reservation defect

The source pool stored a total window containing temporary control headroom.
When a control connection became idle or closed, subtracting the smaller
current reserve from that stored total authorized an extra competing packet
without new delivery evidence. Closing a control connection also left its real
outstanding wire debt, so the freed reservation could not represent a refund.

Three regression cases fail on the original source:

| Case | Original allowance | Expected allowance |
| --- | ---: | ---: |
| Control lease expires under pressure | 3601 bytes | 2401 bytes |
| Paid growth retained after control expiry | 4801 bytes | 3601 bytes |
| Control closes with outstanding flight | 2401 bytes | 1201 bytes |

The fix records the reserve included in each stored window and removes retired
headroom before using or reducing that window. Increasing a reserve still
consumes existing competing capacity; it does not create extra capacity.
The two-MTU floor, actual flight debt, primary bypass, and control allowance
remain intact. Local diagnostics expose the stored and current reserves so
the exercised correction can be verified independently.

All 15 source-pool tests pass. The complete session suite passes 645 tests,
with eight existing manual characterization cases ignored. Bootstrap passes
141 tests with one ignored case. See the captured logs in this directory.

The full workload peaks at 200.179 ms, with all 2112 measured tone transitions
matched, all three files delivered, and five of six video tails passing. The
remaining video tail has 13 changes instead of 14. All observed clock failures,
late intervals and dropped PCM rows remain zero. The correction is exercised
in 93 source-window snapshots. Raw qualification is still false; neither this
result nor its rounded presentation proves the strict 200-ms gate.

The new worst packet spends 10.311 ms before encoding, 78.001 ms in delivery,
0.030 ms between ingress and WebRTC, and 111.837 ms before the PCM marker.
Its selected authenticated SDK/IPC join is complete. The global source-session
analyzer still refuses the run because its bounded source-cell diagnostics
reach their cap later; that failed diagnostic check is not suppressed.

## Arrival replay diagnostic

`scripts/replay_group_audio_arrivals.py` extracts validated nonempty RTP
arrivals, regenerates mono 24-kbit Opus tones, and runs real NetEq on virtual
10-ms render ticks. Padding can reuse an audio timestamp; it is excluded before
matching the encoded packet. The output records source/header hashes and
preserves tone ordinals from the beginning rather than rephasing each interval.

The six original directions retain all 357 generated transitions in this
diagnostic. Results are in `baseline-six-replays.json`. A negative control with
four seconds of arrivals removed yields 353 rather than 357 transitions and
fails sequence completeness, even though the alternating frequencies match
again after the gap.

This is a receiver comparison tool. Regenerated tones and quantized arrivals
do not reproduce the exact original PCM, the group mix, human speech, device
I/O latency, or acoustic latency. Its result cannot replace a full workload
qualification.

## Rejected longer estimator history

The pinned arrival history used a two-second RTP window, while the delay
manager's jitter histogram decays much more slowly (500-ms resampling,
0.983 forgetting factor). A sustained 80-ms delivery step therefore became
the new arrival zero after two seconds, while the target still remembered the
earlier variation. Normal speech could look underfilled and be expanded on
top of the upstream delay.

The candidate regression feeds actual `DecisionLogic::PacketArrived` calls
through the controller factory. At six seconds, the original factory reports
zero instead of the retained 80-ms delivery step. The negative run fails that
assertion. With a bounded 30-second history, the case passes at all four
supported sample rates, with ordinary and wrapping RTP timestamps. The test
also checks duplicates, non-speech notifications, eventual rebasing after a
sustained route change, and clearing the history on a stream/codec reset.
The existing missing-packet, DTX/CNG, DTMF, concealment and cooldown cases pass.

The candidate's 30-second observation horizon matches the endpoint RTP-age window. No
target ceiling, packet duration, bitrate, sender priority, relay behavior or
latency gate was changed. A persistent new path still establishes a new floor;
this is not a lifetime minimum or a claim of a universal network-delay bound.

`history30-paired-replays.json` compares the same six recorded schedules with
both receivers. Generator version 2 uses each participant's original tone
bands, rather than normalizing all directions to 600/900 Hz. All 357 markers
per direction remain present. Baseline maxima are 180–200 ms; the candidate
maxima are 170–180 ms. Concealed and preemptively inserted samples decrease in
every direction. These regenerated, virtual-clock results remain diagnostic;
the full workload must independently pass the original gates.

It did not: `history30-full-workload.json` records a 230.126-ms maximum, with
all measured voice transitions present and all three files hash-verified, but
all six video tails failing (7–12 changes rather than 14). There were no clock
failures, late intervals or dropped PCM rows, and the shaper trace is complete.
All owned processes were independently verified absent after teardown.

The worst packet spends 10.293 ms before encoding, 100.207 ms in delivery,
0.019 ms between ingress and WebRTC, and 119.607 ms before decoded PCM. Its
receiver holds 134–144 ms with a 120-ms target. The new recorded arrivals
also fail in a paired replay with the original receiver: merely extending
the jitter estimator's history does not resolve the latency gate. It changes
the target's input distribution as well as the speech timing decision.

The candidate header and its regression were removed from production sources.
`rejected-history30.patch` preserves the exact evaluated change. The subsequent
diagnostic kept the original jitter estimator and used a separate arrival floor
for continuous-speech timing, without feeding it to `DelayManager`. Its peak
remained 230 ms and concealed samples increased. Neither it nor the following
private prototypes was applied to production.

Lowering only the native target ceiling to 100 or 80 ms did not clear the new
arrival schedule's peak (220–230 ms). Avoiding a second maximum-jitter reserve
with the 80-ms ceiling reached 200 ms on the selected path, still failing the
strict gate. Adding the separate speech floor across all six directions still
reached 210 ms. All regenerated marker sequences remained complete, but these
candidates do not establish a latency/quality solution.

## Delivery gaps and fixture timing

`delivery-distributions.json` and `delivery-gap-witnesses.json` retain native
packet joins for both full runs. In the longer-history run, all six paths have
their largest ingress gap around 345.08 seconds. On source 2 to receiver 1,
successive packets are encoded 40.002 ms apart but arrive 157.424 ms apart.
The latter spends 174.754 ms in encoded-to-ingress delivery. This gap precedes
the decoder; lowering its target cannot remove the gap.

The blind FIFO's recorded release deadlines reveal an additional fixture
delay there: a packet ready at approximately 345.153 seconds is sent only at
345.238 seconds, 84.710 ms late. This is separate from the FIFO's intended byte
serialization delay. The original 280-ms peak's surrounding FIFO release
lateness is only 1.668 ms; the reservation-fixed 200.179-ms peak's is 1.188 ms.
The fixture stall therefore does not explain away either earlier result.

The old archive retains 250000 GC-tracked dictionaries on this Python 3.14
host. The updated archive packs completed scalar records into immutable bytes,
retaining mutable dictionaries only for pending packets. A comparison retains
the same 250000 records with two additional tracked objects instead of 250001.
One measured full collection takes 2.719 rather than 11.841 ms. This shows an
avoidable diagnostics cost, not proof that GC caused the entire 84.710-ms
stall in the earlier uninstrumented run.

Four tests verify metadata roundtrips, completion after ring wrap, bounded GC
object growth, unchanged FIFO admission across trace capacities, and capacity
validation. A new full capture uses the original media library and records GC
event times without changing thresholds or forcing collections. All raw audio,
video and file gates remain intact.

That full capture is retained in `packed-trace-full-workload.json`. No GC
collections occur during capture; FIFO release lateness peaks at 9.068 ms.
The unchanged media library still peaks at 200.254 ms, with no missing voice
markers and all files hash-verified. Video tails are 8–13, still failing. No
clock failures, late intervals or dropped PCM rows occur, and every owned
process is independently verified absent. The fixture improvement does not
turn the existing application into a qualifying result.

The new worst marker spends 10.487 ms before encoding, 70.905 ms in delivery,
0.031 ms between ingress and WebRTC, and 118.831 ms before decoded PCM. The
RTP clock age is approximately 150 ms, despite only 50–90 ms being stored at
the surrounding render callbacks. The existing hard catch-up checks storage
against 160 ms and therefore cannot respond to that upstream contribution.

The next candidate keeps the original target estimator and codec. It extends
bounded catch-up to a high, authenticated decoded RTP age, requiring at least
one complete packet plus 30 ms before an extra 10-ms pull. Unlike the earlier age prototype,
the alignment check carries the actual decoded-packet witness across its
subsequent 10-ms blocks. A standalone replay retains all markers and does not
increase concealed samples. Its full workload result follows below.

## Decoded-age catch-up: audio passes, overall qualification remains false

`age-valid-full-workload.json` records the new 360-second full capture with
the same source SDK, production policy, 1024-kbit/s blind FIFO, six audio/video
directions and three encrypted 512-KiB files. No bitrate, packet-duration or
jitter-estimator setting was changed. All streams remain at 40 ms / 24 kbit/s
after the ordinary startup retune.

| Source → receiver | Maximum decoded marker delay |
| --- | ---: |
| 1 → 0 | 190.222 ms |
| 2 → 0 | 190.348 ms |
| 0 → 1 | 190.203 ms |
| 2 → 1 | 190.174 ms |
| 0 → 2 | 190.270 ms |
| 1 → 2 | 190.228 ms |

All 2112 measured voice transitions match, with none missing. All three files
are authenticated and hash-verified, finishing in 351.897–352.256 seconds.
All receiver interruption counters and durations in the last regular
359-second snapshots are zero. These snapshots and concealment totals are
retained with the result; the protected codec profile was not weakened. No clock failures, late callback intervals or dropped PCM rows
occur. All eleven owned processes were independently verified absent.

The new worst packet spends 10.513 ms before encoding, 83.504 ms in delivery,
0.029 ms between ingress and WebRTC, and 96.301 ms before decoded PCM. The
FIFO still has a 77.040-ms late release at 311.911 seconds; the packing change
does not prove all scheduling stalls are eliminated. The audio result passes
despite that observed stall.

Four video tails pass with 14 changes. The two directions from source 2 have
12 and 13 changes; their last-minute decoded rates are 1.305 and 1.390 fps.
Raw `ok` and `contention_qualification` therefore remain false. This is a
passing strict audio result, not completion of the overall quality gate.
The remaining work is video continuity under the same load and an independent
repeat with the final committed media source.

The new decoder regression seeds accepted Opus RTP packets, obtains a genuine
decoded-packet witness, and tests the next block without packet metadata.
The original header fails: it does not shorten stale audio when the storage
is below its old queue-only ceiling. The new header drops one old 10-ms block.
It also verifies no age-based trim with an unknown/stale output origin,
insufficient queued audio, a caller-directed operation or a receive gap.
PLC, mute and decoder-error extra pulls preserve the last usable speech frame.
The complete existing recovery/controller tests and real three-party mixed
recovery test pass. The final source only relocates the private helper and
clarifies comments relative to the evaluated candidate; its decisions are
unchanged. No relay scheduling, application class or on-wire role was added.

## Remaining video gap starts at the encoder

`video-source-gap-witness.json` joins the existing image, RTP and decoder
metadata around the two failing tails. Source 2 emits a 1477-byte image at
346.097 s. Both RTP fragments arrive; the complete image is decoded at
346.271 s and 346.233 s on the two receivers. The sender does not produce its
next encoded image until 348.053 s. The corresponding decoded gaps are
1.935 s and 1.950 s. This particular pause is already present at the sender,
despite successful delivery of the preceding frame.

During that interval the camera is not paused, current audio pressure and
network-loss indications are false, and the video policy starts recovering
from 1 to 1.5 fps. The image-size recorder reports only 5833 payload bit/s at
the 1-fps setting: approximately 729 bytes of allocation per frame. The
1477-byte image spends more than two such allocations. The existing sizing
hint considers only a transport-sized frame (1376 bytes), and a fresh healthy
audio report exempts a moderate isolated overshoot. It has no frame-rate input.
The timing is consistent with codec frame debt; the recorded sender gap does
not establish a relay scheduling or receiver-buffering defect.

The candidate passes the real encoder rate-control FPS to the sizing policy.
At cadences of five fps or less, an image spending more than 1.5 allocations
requests fewer source pixels for future images. Every encoded reference and
callback remains forwarded unchanged. A separate funded pixel ceiling stops
healthy audio alone from undoing that sizing limit. Actual growth in bytes per
frame can relax it; temporary audio cuts can still recover toward that limit.
Unknown/invalid FPS and ordinary faster-camera cadence retain their existing
overshoot behavior. No bitrate, target FPS, audio profile or relay policy is
changed.

The sizing tests retain the existing cases and add the recorded 5833-bit/s
example, fractional FPS, funding-based recovery, suspension and rate jitter,
recovery after a separate audio cut, and invalid/unknown FPS. The new full
capture keeps every existing audio/video/file gate.

`cadence-full-workload.json` records its passing result: raw `ok` and
`contention_qualification` are both true. The six audio maxima range from
180.262 to 190.256 ms. All 2112 measured voice transitions match, all three
files are hash-verified and finish in 351.945–352.015 seconds. Every video
direction has all 14 required tail image changes. Each receiver records 23
actual decoded frames in the final 15 seconds; the largest inter-frame gap
there is 730.774 ms, compared with the earlier 1.950-second source gap.
The observed final image dimensions are 160×120 at this constrained budget.
The sources' codec-rate/FPS records confirm that the new sizing rule is active.

All capture clocks pass, the route remains the neutral relay, and all eleven
owned processes are independently verified absent. The full QA source tree
matches the production media source tree byte-for-byte; only the build's test
hooks differ. The remaining gate is an independent run after committing these
sources. Its fixture additionally snapshots final native receiver counters
after all measured callbacks stop; the old periodic poll stops at 359 seconds
and cannot alone prove those counters through the end of the capture.

## Final repeat and completion audit

The independent committed-source run is in `cadence-repeat-full-workload.json`.
Raw `ok` and `contention_qualification` are true again. Both full captures use
the same media and SDK binaries, 360-second duration, three separate codec/SDK
workers, shared 1024-kbit/s FIFO in each direction, six media directions and
three encrypted 512-KiB files. `repeat-comparability.json` verifies that the
only fixture-source change is the additional statistics snapshot **after**
capture stops. The timed source code, profiles, clocks and gates are identical.

| Check | First passing capture | Independent repeat |
| --- | ---: | ---: |
| Maximum decoded audio delay | 190.256 ms | 190.304 ms |
| Matched measured voice transitions | 2112 / 2112 | 2112 / 2112 |
| Missing measured transitions | 0 | 0 |
| Video tails meeting the unchanged 14-change gate | 6 / 6 | 6 / 6 |
| Authenticated, hash-verified files | 3 / 3 | 3 / 3 |

The final native receiver snapshots occur at 361.021 seconds, after every
measured callback and its observation tail have stopped. All six receivers
report zero interruptions and zero interruption duration, with fresh native
receive ages of 3–60 ms and more than 360 seconds of emitted samples. The
codec payload floor remains 24 kbit/s; its bitrate/packet-duration settings,
ordinary FEC/PLC decisions and explicit caller-directed operations are intact.

The repeat's worst marker decomposes into 10.493 ms before encoding, 53.251 ms
in encoded-to-ingress delivery, 0.051 ms between ingress and WebRTC, and
126.510 ms before decoded PCM. These are packet-specific observations;
different stage maxima are not added together or described as physical
acoustic latency. The original observed total was 280.080 ms.

`final-qualification-audit.json` independently re-reads the source/decoded PCM
rows and full-image video witnesses, verifies the six voice paths by ordinal,
checks all files, final receiver counters, clocks and relay topology, and
recomputes every retained FIFO byte deadline at 1024000 bit/s. All eleven
checks pass. The source verifier is retained as `audit_capture.py`:

```sh
python3 doc/validation/audio-200ms-2026-10-20/audit_capture.py \
  /path/to/cadence-repeat-360 /private/tmp/group-qualification.json
```

SDK commit `50eb39cb` contains the committed media changes. Its Rust source is
unchanged from the reservation-fixed SDK binary at `9eef87b9`; the intervening
commits change only media C++ headers and their tests. The QA media source tree
matches production sources exactly, with test hooks enabled only by build flags.
No relay scheduler, wire role, priority hint, protocol format or quality gate
was changed. Pre-existing multi-device work remains untouched.

All 22 owned processes across the two passing captures were independently
verified absent. The requested software contention gate is achieved on this
reproducible stand. These captures do not claim human speech evaluation,
physical camera/display quality, acoustic delay or a universal bound on
arbitrary network propagation time.

## Follow-up: strict 190-ms request

The [2026-10-21 receiver investigation](../audio-190ms-2026-10-21/README.md)
does not establish a further qualified improvement. Its private lower-budget
candidate looked faster in arrival replay but failed the complete audio,
video and interruption gates. The qualified implementation above is preserved.
