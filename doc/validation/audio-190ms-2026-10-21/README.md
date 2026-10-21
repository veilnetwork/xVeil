# Checking whether the qualified audio peak can fall below 190 ms

The request is interpreted as **190 milliseconds**, rather than seconds. The
previously qualified implementation remains unchanged: Veil `50eb39cb`, pinned
by xVeil `188d445c`, with the repeated qualification recorded in `5e285426`.
Its two complete workload peaks were 190.256 and 190.304 ms. Neither satisfies
a strict `<190 ms` requirement.

## Receiver experiments

Private media copies were compared using the same recorded packet arrivals
from the accepted `cadence-repeat-360` capture. The replay uses real Opus and
NetEq but regenerated tones and quantized virtual render callbacks. It cannot
replace a new full workload test.

| Private change | Replay maximum, source 2 to receiver 0 | Decision |
| --- | ---: | --- |
| Unchanged receiver | 190 ms | Reference |
| 40-ms packet target ceiling 120 → 110 ms | 190 ms | No peak improvement |
| 40-ms packet target ceiling 120 → 100 ms | 190 ms | No peak improvement |
| Validated decoded-age threshold 140 → 130 ms for 40-ms packets | 190 ms | More catch-up without eliminating the peak |
| 40-ms packet recovery budget 160 → 150 ms | 190 ms | No peak improvement |
| Speech acceleration threshold reduced by 10 ms | 190 ms | More concealment; no peak improvement |
| Short-packet recovery slack reduced by 20 ms | 180 ms | Tested in the full workload; rejected |

The last candidate changes the recovery budget for 40-ms packets from 160 to
140 ms, its validated-age threshold from 140 to 120 ms, and its maximum NetEq
target from 120 to 100 ms. The 20-ms and 60-ms packet budgets remain unchanged.
It retains packet-clock validation, available-speech guards, FEC/PLC behavior,
bounded callback work, and stricter caller limits.

Its six replay maxima were 170–180 ms, with all 357 expected transitions in
each direction and no interruptions. However, catch-up discards increased to
510–1780 ms per direction over 360 seconds. These model results were therefore
only a reason to run a real workload, not evidence of qualification.

`replay-prototypes.json`, `six-path-comparison.json`, and
`budget140-six-replays.json` retain the diagnostic results. Private changes are
preserved in `prototype-patches.json`; none was applied to production sources.

## Full workload result: rejected

The candidate ran for the same 360 seconds, using the same staged Rust SDK,
three separate SDK/codec processes, six audio/video directions, three encrypted
512-KiB files, and one neutral 1024-kbit/s FIFO per direction. Packetization
was not overridden. All media source files match production except the single
receiver header. The fixture, relay behavior, gates and rate were unchanged.

| Check | Previously accepted repeat | Candidate |
| --- | ---: | ---: |
| Maximum capture-to-decoded audio delay | 190.304 ms | **200.187 ms** |
| Matched / missing measured transitions | 2112 / 0 | 2112 / 0 |
| Video paths meeting the final content-change gate | 6 / 6 | **4 / 6** |
| Completed authenticated files | 3 / 3 | 3 / 3 |
| Final native audio interruptions | 0 | **1, lasting 150 ms** |
| Catch-up discards, summed across six receivers | 4000 ms | **8990 ms** |
| Concealed samples, summed across six receivers | 69878 | 91950 |

Four audio paths peaked at 170–180 ms; the two paths into receiver 2 reached
200.153 and 200.187 ms. Video from source 2 changed only nine times in each
receiver's final 15-second observation, against the unchanged requirement of
14. The complete capture verdict and the independent audit both fail.

The worst decoded marker is independently joined to its actual packet in
`budget140-native-peak.json`:

| Stage | Time |
| --- | ---: |
| Capture marker to encoded packet | 20.416 ms |
| Encoded packet to receiver ingress | **133.192 ms** |
| Ingress to WebRTC | 0.026 ms |
| WebRTC insertion to decoded PCM marker | 46.554 ms |
| Total | **200.187 ms** |

Its receiver storage brackets are 32 → 22 ms and 62 → 52 ms. The required
complete-packet reserve correctly prevents another catch-up pull. This peak
cannot safely be removed by discarding a large local backlog: that backlog is
absent. The experiment changes the feedback loop and packet-arrival schedule,
so its stage differences are not a controlled attribution of every regression
to one receiver constant. There is no evidence here identifying the individual
transport hop responsible for the 133-ms span.

There were no PCM clock failures, lost rows, late intervals or deadline misses.
The independent audit also verifies the original neutral FIFO schedule and
complete, untruncated wire trace. These checks do not excuse the failed audio,
video or interruption gates.

`fixture-timing.json` records no garbage collections during capture. Maximum
FIFO release lateness was 16.059 ms globally and 1.837 ms in the peak's
271.6–272.0-second window. This window check is not an identification of the
peak's encrypted packets; no fixture time is subtracted from the result.

## Outcome

**No safe, reproducible improvement below 190 ms was established in this
cycle.** The working receiver and the existing qualified implementation are
preserved. Further optimization should investigate the delivery tail and
receiver/transport feedback together, rather than assuming a lower buffer cap
will reduce the complete-call maximum.

Both local receiver/controller regressions and the real three-party Opus/mixing
recovery test passed before the candidate capture. Passing those isolated tests
did not predict its full workload behavior. `cleanup-verification.json`
independently confirms that all 11 observed owned processes have exited.

The raw stand capture is retained locally at
`~/.cache/codex/xveil-audio-190-20261021/budget140-360`. Archived summaries,
source patches, hashes and audit outputs support this conclusion; they contain
generated-tone metadata rather than recordings of human speech. All latency
numbers concern the owned same-host decoded-PCM stand, not acoustic delay on
physical devices.
