# Delivery-tail attribution under contention

The purpose of this cycle is to separate sender admission, transport/link
transit, relay forwarding and receiver delivery. Production buffers, traffic
policy and relays were not modified. Both captures use the previously qualified
Rust SDK and media binaries; opt-in opaque-ciphertext correlation is diagnostic
only and does not give the relay an audio classification or a priority hint.

## Original 133-ms event: what can be recovered

`original-133ms-sdk-peak.json` and `original-133ms-source-session.json` identify
the exact authenticated cell from the rejected receiver-budget experiment:
epoch `7c125db0358662cf`, sequence 6915, source 0 to receiver 2.

| Stage | Time |
| --- | ---: |
| Encoded packet to native submission | 0.034 ms |
| Native submission to local QUIC DATAGRAM acceptance | 0.186 ms |
| DATAGRAM acceptance to authenticated recipient SDK | **132.958 ms** |
| Authenticated SDK to native ingress | 0.014 ms |
| Encoded packet to native ingress | **133.192 ms** |

The source connection is exactly identified as local trace ID 26. Handler
entry to source-budget admission was 0.035 ms; budget admission to DATAGRAM
acceptance was 0.011 ms. The old capture did not enable opaque hop correlation,
so its remaining 132.958 ms cannot retrospectively be divided between hops.
The following measurements concern new packets, not a fabricated split of the
old event.

## New capture on the unchanged qualified implementation

`opaque-current-360` runs the same 360-second workload: three SDK/codec worker
processes, six audio/video directions and three encrypted 512-KiB files. Each
direction has one blind, shared 1024-kbit/s FIFO. The relay star is verified;
there is no participant-to-participant session. No packet-duration override
is applied.

All 53,250 encoded speech packets in the six measured paths from 5 to 360
seconds have exact native fanout and ingress witnesses, with zero missing
packets. The analysis matches the actual sender RTP origin, channel, sequence,
timestamp and payload length; padding is excluded. All relevant native traces
are complete. The maximum observed encoded-to-ingress delivery is **116.461
ms**, at source input 338.160 seconds, source 0 to receiver 1.

| Stage of that exact authenticated cell | Time |
| --- | ---: |
| Encoded packet to native submission | 0.045 ms |
| Sender submission to local DATAGRAM acceptance | 0.620 ms |
| Source transport acceptance to relay dispatch | **77.805 ms** |
| Relay dispatch to outbound transport selection | **0.051 ms** |
| Relay transport selection to recipient dispatch | **37.804 ms** |
| Recipient dispatch to authenticated SDK | 0.113 ms |
| SDK to native ingress | 0.023 ms |
| Total | **116.461 ms** |

The matching source QUIC connection is trace ID 19. Nearby snapshots, including
ones after delivery, report a lifetime maximum outgoing DATAGRAM queue age of
**0.749 ms**, no congestion-window or pacing-blocked age, a maximum event-queue
delay of 0.281 ms and maximum UDP send wait of 0.864 ms. These are cumulative
connection counters, not per-cell queue durations to subtract from a hop.

The complete blind FIFO trace contains 240,151 events and is independently
verified against the original byte deadlines. During the first hop's interval,
all direction-0 FIFO observations have 45.98–76.01 ms of scheduled queue time;
during the second hop's interval, direction-1 observations have 31.96–38.72 ms.
These are interval contexts, not an identification of the encrypted UDP
datagram carrying the cell. No adjacent packet is guessed from size or order.

The same capture's largest **decoded-audio** delay is a different event:
190.130 ms, of which delivery accounts for 31.833 ms. Optimizing the maximum
delivery packet and measuring the maximum decoded-signal delay are separate
analyses of the recorded data.

This diagnostic capture is **not a new qualification**: it retains all 2112
measured tone transitions, completes the three files and has zero final native
audio interruptions, but two video tails have 13 content changes instead of
the unchanged required 14. The raw verdict and independent audit remain false.

## Capacity-only control

A second 360-second capture uses the same binaries, fixture, topology,
diagnostics and workload. Only the FIFO capacity changes: **1024 → 8192
kbit/s at 120 seconds**. Before inspecting its result, the analysis windows
were recorded as 20–120, 120–125 and 125–360 seconds. All three windows remain
reported; they do not change the capture's full-run quality gates.

| Recorded result | Before: 20–120 s | Transition: 120–125 s | After: 125–360 s |
| --- | ---: | ---: | ---: |
| Maximum encoded-to-ingress delivery | 127.713 ms | 6.732 ms | 37.610 ms |
| Per-path 99th-percentile delivery | 91.304–96.155 ms | 5.065–6.172 ms | 5.512–6.021 ms |
| Maximum capture-to-decoded audio delay | 190.203 ms | 130.202 ms | 130.105 ms |
| Matched / missing measured tone transitions | 594 / 0 | 30 / 0 | 1398 / 0 |

The control's low-rate peak has 74.074 ms before relay dispatch, 0.033 ms
inside the relay and 53.186 ms on the second transport/link span. The sender
submission span is 0.281 ms and recipient-to-SDK span is 0.100 ms.

The improvement already occurs while **all three files are still active**.
They complete at 184.239, 189.979 and 190.793 seconds. In a supplemental
125–184-second window, delivery's maximum is 37.610 ms and the largest per-path
99th percentile is 6.771 ms. This check addresses the possible confound that
delivery became fast only because the files had already finished.

The control's raw full-run verdict is true: all files pass authentication and
hash checks; all six video tails have 14 content changes; final audio
interruptions, PCM late intervals, lost rows and deadline misses are zero.
It is a capacity control, **not a fixed-1024-kbit/s qualification or a software
improvement**.

Its FIFO trace has 290,920 events but retains only the last 250,000. Source
diagnostic counters also reach their bounds later. The native audio traces
remain complete and the selected peak cells in every reported window have
complete authenticated endpoint, source and opaque-hop joins. No full-capture
FIFO deadline audit or full source-work coverage is claimed for this control.
See `trace-coverage.json`.

## Remaining local observation

The control's 37.610-ms maximum, at 165.880 seconds, includes 15.933 ms between
recipient dispatch entry and authenticated SDK receipt. Recipient synchronous
dispatch itself returns in 0.014 ms; the remaining 15.919 ms precedes the SDK
observation. Current markers do not distinguish recipient IPC delivery,
scheduling and SDK receive processing inside that interval. It is an unresolved
local tail, not an identified batching defect or the explanation of the old
133-ms event. It is retained explicitly in `control-receiver-tail.json`.

## Conclusion

On this owned stand, the dominant long delivery spans are associated with the
shared bandwidth bottleneck. The capacity-only intervention and the FIFO
context support that conclusion; the measured sender admission and relay
dispatch-to-selection spans are sub-millisecond in the investigated peaks.
No avoidable long sender-admission wait or relay forwarding queue was
established in those events. No production scheduling or receiver change is
justified by this cycle.

Further work at 1024 kbit/s would need to examine total offered wire load,
burst size and endpoint adaptation while preserving relay neutrality. The
small local receiver tail above remains separately unresolved. These software
stand captures do not measure phone power saving, physical network propagation
or acoustic latency.

## Reproduce and verification

```sh
python3 scripts/analyze_group_delivery_tail.py /path/to/opaque-current-360
python3 scripts/analyze_group_delivery_tail.py /path/to/capacity-step-360 \
  --from-seconds 20 --until-seconds 120
python3 scripts/analyze_group_delivery_tail.py /path/to/capacity-step-360 \
  --from-seconds 120 --until-seconds 125
python3 scripts/analyze_group_delivery_tail.py /path/to/capacity-step-360 \
  --from-seconds 125 --until-seconds 360
python3 scripts/analyze_group_delivery_tail.py /path/to/opaque-current-360 \
  --selection decoded
TMPDIR=/private/tmp/ PYTHONPATH=scripts python3 -m unittest \
  test_analyze_group_delivery_tail test_analyze_group_sdk_packet \
  test_analyze_group_source_session test_opaque_packet_route
```

All 32 focused tests pass. They cover exact cell and fanout binding, RTP wrap,
padding, original-clock phase windows, missing packets, disconnected routes,
contradictory clocks and post-completion observations that cannot be causal
starts. The existing SDK analyzer retains its default decoded-peak behavior.

All 22 observed stand/helper processes across the two captures are independently
verified absent. Raw captures remain locally beneath
`~/.cache/codex/xveil-delivery-tail-20261021/`. Archived stage results, build
proofs, capture summaries, coverage notes and source/input hashes support this
report; no plaintext audio, private identity configurations or human speech
recordings are archived.
