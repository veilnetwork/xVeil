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
`rejected-history30.patch` preserves the exact evaluated change. The next
investigation keeps the original jitter estimator and tests a separate arrival
floor for continuous-speech timing, without feeding it to `DelayManager`.
