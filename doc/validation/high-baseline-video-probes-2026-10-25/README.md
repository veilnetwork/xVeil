# Physical phone validation and high-baseline video probes

## Fix

A route whose measured RTT stays above 400 ms could not spend causal decoder
ACKs on a video probe even with fresh, healthy playout in both audio directions.
The baseline phone run captured this condition: at 15 s after camera enable,
both senders had healthy buffers, zero loss, no source pressure and confirmed
decoder progress, yet RTT of 406/441 ms held their source budgets at 1 FPS.

The adapter now permits its existing cautious probes on such a measured route
when RTT is within 120 ms of its own windowed floor and below 2 s. A probe still
requires fresh decoded media sent after the preceding native budget ACK, a
maximum 25% step, and the 950-ms pacing floor. Higher bitrate/FPS remains
bounded by the negotiated route profile. Ordinary recovery and legacy engines
retain their existing RTT rules. Missing/stale audio, loss, buffer growth or
pressure, source pressure, decoder queueing and missing receiver ACKs retain
their vetoes. A rise from a short RTT floor to 400–700 ms does not qualify.

No relay protocol, scheduling class or media label changes. Native libraries
are byte-identical across the baseline and candidate Mac apps; Android native
libraries retain the qualified production inputs. The source change is in the
Dart adapter. A boolean decision-history field is available under the existing
stand diagnostic gate, which excludes product builds.

## Verification

Seven new cases ran against the preceding adapter: the healthy 420-ms route
failed to increase above 1 FPS, as expected; six safety cases passed. With the
fix, 339 adapter/model/audio/group tests passed. These include rejection of a
new queue above the RTT floor, a two-second RTT, missing audio, loss, growing
buffers and cached decoder frames. Focused static analysis found no issues.

Rebuilt and signed separate QA frontends using the production SDK/media/HV
libraries. The installed APK hash was checked on the phone. All production
Dart source hashes still match the built checkout. The SDK artifact is
`325e36e0`; checkout `54dff306` adds optional DHT tracing, without a functional
routing change. Native features are
`node-embedded,production-seeds,packet-tunnel`, with normal PoW and no native
fault injection. External-target mount monitoring passed during frontend
builds, which read the previously qualified packet-tunnel archive.

## Physical calls

A physical Android phone on Wi-Fi and a Mac used separate QA identities, linked
through a real contact request and acceptance. The request took 24.0 s and both
sides were accepted after 26.6 s. Subsequent text messages arrived in 0.72/0.77 s,
one copy each. The first identity's normal production-difficulty provisioning
completed after the initial 150-s helper wait expired; a separate readiness
wait then confirmed a real stack. That helper timeout is not a boot failure.

| Run | First five decoded frames on both | Final five-second decoded FPS, Mac / phone | Gate result |
|---|---:|---:|---|
| Baseline, relay | 9.50 s | 29.55 / 29.55 | Existing final-window gate passed; earlier phone stall recorded |
| Candidate, relay | 27.60 s | 29.46 / 11.71 | Failed startup and final FPS gates |
| Candidate, anonymous | 23.24 s | Subsequent windows stopped progressing | Failed video continuity gate |
| Candidate, P2P | 8.60 s | 29.53 / 30.48 | Passed; stayed P2P throughout observation |

The receiver labels above identify where frames were decoded. The first
five-second window at or above 20 FPS appeared after 69.4/85.2 s in the
baseline, 49.9 s/never in the candidate relay run, and 17.4/13.9 s in P2P.
Observed decoded-stall lower bounds include 21.0 s on the baseline phone and
19.4 s on the candidate relay Mac. These early stalls remain findings even
when an existing final-window gate passes.

The candidate relay's RTT floor started near 96/99 ms and later rose as high as
729/486 ms. There were **zero** qualified observations of the new high-baseline
branch. This run therefore does not physically qualify that branch or establish
a video startup speedup from this fix. Its local audio-buffer peaks were
134/269 ms. The relay-video problem remains open.

Both endpoints used `onion` in the anonymous run. Audio RTP counters continued
advancing in every observation window, but the local Mac buffer reached 290 ms,
policy observations reported audio interruptions, and both sources eventually
paused video. RTT reached 1.75/1.78 s. Thus anonymous signalling and duplex audio
packet flow were exercised; usable uninterrupted anonymous audiovisual quality
was not established.

P2P reached approximately 30 decoded FPS in both directions and had no policy
interruption observations. Audio-buffer peaks were 110/82 ms. Sampled RTT
settled near 9–11 ms. This confirms the phone/codec path can sustain that cadence.
Live speech, acoustic loudness, cellular connectivity and the full multi-device
matrix were not tested in this cycle. RTP counts on silent microphones do not
establish intelligible or uninterrupted speech.

## RTCP attribution

Matched SR send/receive and the exact RR feedback blocks using private native
traces. The exported data contains aggregate relative measurements only.

| Run / source | Matched audio observations | Callback transit RTT median / max | Unsubtracted receiver residence max |
|---|---:|---:|---:|
| Baseline Mac | 24 | 370.3 / 419.6 ms | 0.780 ms |
| Baseline phone | 22 | 376.5 / 486.1 ms | 0.038 ms |
| Candidate Mac | 26 | 390.1 / 727.9 ms | 1.264 ms |
| Candidate phone | 23 | 379.5 / 485.5 ms | 0.045 ms |

Every available RR block with LSR matched uniquely in these captures. Relative
source SR scheduling excess stayed below 0.1 ms. The large delays are in the
callback-to-callback transit component, which includes SDK queues, connections,
relay processing, network and dispatch. The individual contributions remain
unattributed. These results do not identify a particular relay or provider.

## Preparation failures and cleanup

Three Mac preparation attempts used an overlong QA profile name. The existing
32-character validator rejected it and selected the default profile, where the
QA password was refused. The helper now validates the name before launch and
checks the selected-profile log before attempting unlock. Direct native opens
on separate copies verified both the original and post-call QA containers.
Default store/preferences modification times predate the first failed launch;
no default-profile modification was observed. Each failed attempt was closed
and its clone archived before the next attempt. An early P2P runner invocation
preceded its readiness manifest, failed before entering setup and placed no
call; the completed readiness check preceded the actual P2P run.

The final audit checked seven owned Mac process groups and the phone QA
process: zero remaining. Removed the owned ADB forward, restored and verified
the initial User-0 microphone/camera grants, restored QA anonymity/P2P settings,
and archived owned runtime directories and test-profile clones. Main app
binaries were not replaced.

[summary.json](summary.json) and the four CSV files use fixed role labels,
software hashes, relative durations and allowlisted numeric/boolean metrics.
Identities, addresses, keys, absolute native timestamps, capture labels, raw
logs, screenshots and media remain in private local evidence.
