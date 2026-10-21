# Video delivery driven startup (2026-10-21)

## Scope

BBR-inspired **source** probing above the existing transport/WebRTC controllers.
This does not enable BBR on QUIC, classify media at relays, prioritize relay
traffic, change route privacy budgets, or send call traffic through mailboxes.

- Start at the existing one-fps floor. Double the acknowledged source budget
  only after fresh remote decoder progress passes the previous probe's RTP
  timestamp watermark. Stop at the negotiated bitrate and cadence ceiling.
- Encoder setters must acknowledge a change before it consumes probe credit.
  A busy worker cannot earn another increase or restore an unapplied budget.
- Existing audio loss, buffer trend, source admission and pause gates remain
  authoritative. A cut halves the **applied** video budget. Drain for at least
  three seconds; retry with 25% probes after six seconds, then every three
  seconds while healthy decoder acknowledgements continue. Further video-only
  loss during the acknowledged three-second drain holds growth without another
  cut. Fresh audio failures and measured audio buffer pressure remain independent
  protection signals; a busy/unacknowledged setter earns no drain interval.
- Additional backlog evidence compares elapsed receiver sample time with the
  decoded 90-kHz RTP timeline. Lag of at least 80 ms plus one frame, sustained
  for three seconds, drains video; a short spike holds growth. The baseline
  uses a ten-second window to limit clock-rate drift. WebRTC's adaptive playout
  target alone cannot establish a growing queue. Its 500-ms hard ceiling remains
  independent. None of these measurements treats propagation RTT as a queue.
- Delivery-rate observations use receiver sampling intervals and are bounded
  by source production. A ten-second maximum retains application-limited low
  samples. This estimate is diagnostic; probing and queue/loss evidence govern
  the source budget, rather than treating static scenes as path capacity.
- All group receivers must acknowledge a probe, even if their reports arrive
  on different polls. Mixed older/newer engines retain the legacy ladder until
  all receivers supply the optional feedback. Once established, missing/stale
  feedback holds growth.
- Route, source, receiver generation and group membership changes start fresh
  measurements. Padding, retransmissions of older frames, replayed reports,
  and historical frames cannot fund the next probe.

## Native feedback

Optional RTCP APP `VVD1`, 64 bytes, carried inside the existing authenticated,
end-to-end encrypted channel. Unrecognized APP names are ignored by old peers.
No new relay header, traffic priority, or network-visible media role is added.
The receiver publishes at most one supplemental receiver report per 950 ms;
regular RTCP can also carry the latest fresh sample. A stale native worker does
not create a fresh measurement. The parser validates an entire compound before
publishing any observation, rejects duplicate known APP blocks, malformed
fields/reserved bytes, wrong target SSRC, regressions and replay.

| Wire offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | RTCP header, subtype 0, APP 204, length 15 |
| 4 | 4 | Sender SSRC |
| 8 | 4 | ASCII `VVD1` |
| 12 | 4 | Target video SSRC |
| 16 | 8 | Receiver generation, monotonic sample origin |
| 24 | 8 | Receiver monotonic sampling time, microseconds |
| 32 | 8 | Received RTP payload bytes |
| 40 | 8 | Decoded frames |
| 48 | 4 | Last decoded RTP timestamp |
| 52 | 4 | WebRTC current video playout delay, milliseconds |
| 56 | 8 | Reserved, zero |

The sender's local JSON adds the current source watermark/production and route
and encoder epochs. `sent_timestamp_valid` distinguishes a real zero RTP
clock from a source which has not emitted payload in this epoch. An empty
clock never creates a serial-number barrier against a random first timestamp
above 2^31. None of these local diagnostic fields is a relay hint.

## Endpoint flight admission

Physical captures exposed a prerequisite below the source controller. The
node-wide flight ledger contained 30–55 KB of background control traffic on
other paths while the short direct media path had a 12-KB QUIC window, zero
flight and no reported loss. The effective video window was one byte; queued
video expired after 200 ms without leaving the endpoint. Growing the encoder
cannot fix this condition.

Fresh healthy primary feedback now permits a **shared two-MTU trial** for
secondary work, even when live or recently closed control connections occupy
the ordinary ledger. Actual coupled secondary flight, including abandoned
secondary debt, debits the trial. Primary flight remains in the ordinary ledger; a healthy audio
bandwidth-delay product cannot consume or enlarge the fixed additional trial.
Unselected prewarmed secondary channels retain a bounded control-handshake
allowance. They cannot spend the source trial or
earn growth; selecting one for actual local source traffic immediately charges
its existing flight to the trial. Actual pressure or expired health removes
it. A validated growth hold freezes an already-permitted trial through the
original deadline; it cannot create/enlarge one, earn ACK credit, inherit one
across a route change, or erase secondary debt. The allowance is not banked as
a paid window or multiplied
by the number of video/screen connections. Background control flight remains
charged to the ordinary pool; every connection retains its transport
congestion controller. This changes endpoint admission only.

## Source resolution

The low-rate startup sizing cap also follows a genuinely larger encoder
allocation. With fresh healthy audio and no growth hold, one fresh audio
observation permits at most a fourfold pixel-area probe, bounded by the
original source size and actual rate growth. Raising only the requested
profile earns nothing. Unknown/stale audio, paused video and holds do not
bank allocation credit. Actual audio pixel cuts retain the existing gradual
recovery; this faster path only releases a startup rate-derived sizing bound.

## Verification

- 182 Dart tests: existing adapter/growth checks plus thirteen delivery-model
  scenarios. The model reaches the 900-kbit/s, 60-fps source ceiling in eight
  simulated one-second observations at both 10-ms and 120-ms RTT.
- Production native shim compound send/parse test: video ACK, freshness,
  replay, wrong target, truncation, duplicates and reserved fields; existing
  audio feedback compatibility retained.
- Native startup sizing checks: funded allocation versus requested profile;
  one area probe per fresh observation; unknown/pressured/stale audio, pauses
  and growth holds; existing audio-cut recovery retained.
- Native RTP accounting test: payload/padding isolation, retransmitted frame
  watermark, RTP clock wrap and source restart.
- macOS arm64 and Android arm64 native libraries compiled against pinned WebRTC.
- 54 Rust local-source checks, including shared trial, primary/secondary debt,
  pressure/hold and feedback-expiry cases. A subsequent 124-test local Rust
  selection passed (one existing characterization test ignored), including
  stable propagation RTT above 150 ms without loss/expiry/congestion. Absolute
  RTT alone no longer renews source congestion indefinitely; actual loss,
  expiry and blocked ACKs remain protected. The relative reliable-path delay
  warning continues restraining ordered DATA; it no longer also contracts
  healthy lossy flight. A production coupling regression checks that the
  healthy two-MTU source trial survives that DATA warning, while actual
  primary pressure stops it and cannot be erased by a healthy report.
- Quinn initialization test: installing the budget before the handshake retires
  Initial/Handshake flight to zero after acknowledgement. No transport
  production change was needed for that accounting case.

Physical results and cleanup evidence are recorded after the stand run below.
The simulated timing is not a promise for an arbitrary real network.

### Physical qualification status

The current Mac/Blackview Wi-Fi P2P run passed with real cameras and real
codec/network traffic. The audio source was the isolated synthetic ADM driver.
Both RTP clocks in this run started above 2^31; an earlier run exposed the
empty-clock barrier defect fixed by the explicit local validity flag.

| Direction | First decoded frame | Full source budget acknowledged | First 5-s window at >=25 decoded FPS | First >=360p decoded frame | Final 15-s decoded FPS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mac -> Blackview | 4.01 s | 13.29 s | 15.65 s | 25.65 s | 30.0 |
| Blackview -> Mac | 4.91 s | 12.20 s | 14.42 s | 25.94 s | 29.5 |

Times are after the camera-enable request, not just the encoder setter. The
source ceiling is the existing 900-kbit/s, 60-fps budget; physical cameras
produced about 30 fps. Final decoded sizes were 640x360 on Blackview and
540x960 on Mac. No route switch occurred in 92 sampled call states. After a
five-second camera stop, both directions qualified their first full five-second
window at >=25 fps; that window length is not a five-second resume delay.

All 95 measured audio tone transitions in each direction matched during the
scored phases. Point estimates for maximum decoded PCM transition delay were
81.2 ms Mac -> Blackview and 151.0 ms Blackview -> Mac over those phases;
steady video maxima were 70.7 and 89.9 ms. These include codec/network/playout,
not microphone/speaker acoustics or subjective speech intelligibility. Raw
clock uncertainty envelopes and complete sample counts remain with the capture.

Relay qualification remains open. With corrected source clocks and the
absolute-RTT admission fix, a continuous forced-relay run reached its first
complete >=25-FPS window 19.0 s after camera enable in both directions. By the
last 15 s, decoded cadence had fallen to 0.67 FPS on Mac and 0.33 FPS on
Blackview, with maximum decode gaps of 8.82 and 5.36 s. This run never stopped
the cameras, ruling out camera restart as the sole cause. No route switch
occurred in 90 sampled states. All accepted audio RTP packets in scored
5-98-s intervals reached native ingress; isolated delivery peaks were 263/285 ms
with medians near 50/57 ms. These are packet delivery times, not playout delay.

Endpoint diagnostics recorded video admission blocked by a one-byte local
flight window while the actual QUIC path had zero flight/loss and substantial
congestion headroom. The run also exposed repeated video-only cuts within the
intended drain period (900 -> 450 -> 225 kbit/s in consecutive polls). The
three-second drain now governs repeated video cuts as well as growth. Its
regression test also verifies immediate audio protection during that interval;
183 adapter/growth/model tests passed.

A further relay run with the drain fix retained moving frames in both
directions but ended at 2.4/2.73 decoded FPS. Native images remained 540x960
on Mac and 640x360 on Blackview. All accepted audio RTP in 5-98-s scored
intervals arrived, with packet delivery peaks 187.5/192.8 ms. This is still
not a passing video qualification. At 96.4-98.4 s, the ordered-DATA delay
warning on one primary path also fed the lossy flight pool, canceling video
admission despite healthy application audio measurements. Its implementation
contradicted the separate DATA-only policy. The fixed handler preserves the
DATA throttle and leaves lossy flight to actual pressure/loss and application
health. This addresses one observed cause, without attributing every earlier
video cut to that warning. No relay priority or media hint was introduced.

Requalification after the DATA-only fix was **not a pass**. At about 53 s,
Mac stopped receiving native audio RTP while the phone continued receiving
Mac audio and exchanging call-health signaling. After about 12 s of silence,
the existing relay repair recreated the media engine. The strict PCM runner
detected the changed generation and ended the measurement. Both directions
had delivered essentially no video in that attempt. This cannot qualify
startup or sustained relay video, and does not establish that the DATA-only
fix caused the receive failure. The missing relay ingress and the resulting
repair remain a separate unresolved transport investigation.

### Follow-up on 2026-10-22

The interrupted receive was localized before the network: sampled sealed
phone cells 2450-2650 were accepted into two first-hop queues, then discarded
by both runners as `child_unavailable`. A previously working first hop was
not selected. Negotiated datagram support had been treated as sufficient,
although the specific local source child was still warming.

Origin selection now takes a read-only, lane-specific readiness snapshot.
Ready children precede warming candidates; old unsupported transports retain
their compatibility fallback. The snapshot cannot open a connection and is
bound to the current live runner generation. In addition, actual sending and
explicit preparation keep warming only the existing preferred pair without
clearing a ready child. Once they authenticate, preferred cached routes can
replace the fallback. Cost snapshots stay read-only. This avoids both a gap
while switching and an indefinite preference for a ready but worse old route.
Fanout limits, ciphertext, replay identity and neutral relay headers remain
unchanged. Relays were not modified.

The actual IPC handler regression failed before selection was fixed (both
copies used warming hops), then passed for primary, video and legacy source
lane mapping. It also checks promotion after the preferred pair becomes ready.
176 IPC tests passed (five existing ignored); 125 local session checks passed
(one existing ignored), including owner/generation and closed-session bounds.

The next 180-second ready-route run kept both engines and delivered every
accepted audio RTP packet in the scored phases. First complete >=25-FPS
windows were 19.19 s Mac -> phone and 22.78 s phone -> Mac after camera enable;
>=360p appeared after 39.74/45.15 s. Final 15-s cadence was 7.27/27.27 FPS.
That asymmetry remained a failure to qualify sustained video. All 104 Mac
and four phone rejected video attempts were exact repeats of previously
admitted RTP identities, rather than new original packets. Some repairs were
more than two seconds old. Counting them as fresh admission loss caused
additional source cuts for the same history.

The native transport now retains total failures and additionally reports
`video_tx_source_rtp_drops`, using WebRTC's local `PacketOptions::is_media`
classification (original media, excluding retransmission/padding). One-to-one
and group transports supply this field. Adaptation consumes original-source
failures, with legacy counter fallback; raw receiver loss and all audio
protection remain independent. The production shim test exercises real
`SendRtp` with accepted originals, rejected repairs and rejected originals.
185 Dart adapter/growth/model checks passed, including video-only/muted audio.
Both native arm64 libraries compiled; focused native counter/shim checks pass.

A subsequent physical run with the new counter had poor audio delivery
(about 191-ms median Mac -> phone packet delivery during an early phase),
spent much of startup protecting audio, and did not qualify video. This
cannot be presented as a passing controller measurement. Preferred-path
preparation/promotion was added after that run. Its next 180-second run kept
both engines and delivered all scored audio RTP, with approximately 48-55-ms
median packet delivery and peaks below 185 ms. Sustained video still failed:
final decoded cadence was 7.93 FPS Mac -> phone and 1.93 FPS phone -> Mac.
Neither original video admission counter increased; rejected retries no longer
appeared as original source loss.

The next endpoint-budget regression exposed another inconsistency: a healthy
growth hold removed the pre-existing two-MTU trial, reducing available video
admission from 2400 bytes to a one-byte window behind unrelated control debt.
The paid window was preserved, but the usable temporary allowance vanished.
A validated hold now retains only that already-permitted shared byte limit
through its original deadline. It cannot inflate it with a new MTU or replay,
bank ACK growth, start from unknown health, survive a route change, or override
actual pressure. These bounds pass 127 local session checks (one existing
characterization ignored).

The 180-second held-trial run kept both engines and delivered all scored
accepted audio RTP packets (approximately 47/55-ms medians, packet peaks below
176 ms). Both directions reached a complete >=25-FPS window about 30 seconds
after camera enable. The final cadence was 29.93 FPS Mac -> phone but only
5.33 FPS phone -> Mac, so sustained relay video still did not qualify.

In that run the new decoder-delay check repeatedly cut phone video despite
zero original video admission failures. WebRTC `current_delay_ms` includes
its adaptive jitter/playout target: it rose from 60 to about 250 ms even while
decoded RTP advanced at the expected cadence. Comparing this value with the
lifetime minimum mistook estimator adjustment for a growing queue. The source
model now compares elapsed receiver sample time with decoded RTP media time,
with one-frame quantization allowance, a bounded ten-second baseline and the
existing three-second persistence. Clock offsets cancel; slow clock-rate drift
cannot accumulate over the lifetime of a call. The independent 500-ms ceiling,
receiver loss and audio protection are retained. A regression fails on the old
model; 188 focused Dart checks pass, including actual sustained media lag,
spike recovery, sparse frames, RTP wrap and 20-minute clock-rate drift.
The decoder-clock candidate was then exercised on the same physical endpoints:

| Measurement | Forced relay, 180 s | P2P, 100 s with camera restart |
| --- | --- | --- |
| First complete five-second >=25-FPS window after camera enable | 27.42 s Mac -> phone; 27.01 s phone -> Mac | 23.73 s Mac -> phone; 20.14 s phone -> Mac |
| Final 15-second decoded cadence | 22.20 / 20.87 FPS | 30.00 / 29.47 FPS |
| Final dimensions | Mac -> phone: 480x270 / 640x360; phone -> Mac: 134x240 / 180x320 | Mac -> phone: 640x360; phone -> Mac: 540x960 |
| Engine restarts / route changes | None; relay throughout | None; P2P throughout |
| Missing accepted audio RTP in scored intervals | Zero in each direction | Zero in each direction |

In the relay run, both sources retained their full budget through the previous
false-trigger interval and held roughly 28-30 decoded FPS beyond the first
minute even as WebRTC's playout estimate reached 225-250 ms. The old repeated
collapse to 1-5 FPS did not recur. There were still real decoder timeline stalls
(up to 2.03 s), bounded cuts to 450 kbit/s, and periods at 21-22 FPS; this is not
a claim of uninterrupted 30-FPS relay video. Audio packet delivery medians were
about 43-60 ms, with measured packet maxima below 144 ms. These are endpoint
packet-flight estimates, not acoustic mouth-to-ear latency.

For P2P, after camera off at 40 s and on at 45 s, both receivers qualified in
the first complete five-second window. That five seconds is the scoring window,
not a five-second restart outage. Final decoder gaps remained below 72 ms.
The 20-24-second initial windows in this run also show that fast probing does
not bypass initial audio-health qualification; the earlier 15-second P2P result
is not a deterministic startup guarantee. The initial phase did not yet reach
360p before the deliberately scheduled camera restart. Synthetic PCM was used;
no new live-speech/listening claim is made.

The source-model false-trigger correction is verified, but the complete relay
quality gate remains open: actual intermittent decoder stalls and the remaining
low phone -> Mac resolution must be explained before claiming sustained high
quality on relay routes. Zero original RTP admission failures at the native
API do not establish successful downstream delivery. No relay-side cause has
been established for these remaining stalls.

## Paid source flight follow-up (2026-10-22)

Late relay attribution in the earlier candidate was incomplete: the Android
logcat process exited with `Unexpected EOF` about 36 seconds into the call.
Native RTP/decoder files remained complete, but missing late transport logs
cannot establish a downstream cause. The private runner now temporarily raises
only Android's main log ring from its recorded size to 16 MiB, asserts logcat
remains alive during sampling, and restores the original size during cleanup.
The next 180-second capture retained 26.8 MB of continuous phone logs, with
no EOF and successful buffer/policy/process cleanup. It was a diagnostic run,
not a clean FPS comparison: a host SDK test build overlapped part of the call.
An audio interruption around 80 seconds activated genuine audio protection.

The complete log exposed source DATAGRAM expiry behind a one-byte effective
window despite a roughly 245-309-kB QUIC congestion window on that connection.
Source-pool records also showed healthy, unpressured video constrained to the
shared two-MTU exception while unrelated control flight exceeded the ordinary
node ledger. A deterministic regression then showed that an ACK-funded usable
window of 3600 bytes still exposed only 2400 bytes to the live source behind
100 kB of background control debt. This prevented earned growth from being
spent even when local demand and real delivery had qualified it.

SDK `a374b387` makes the healthy shared allowance use the already-funded usable
source window, with its original two-MTU minimum. It subtracts the ordinary
control reserve through the existing reserve-retirement calculation. This is
not a new large constant or an exemption from per-connection QUIC congestion
control. Actual coupled secondary flight, including closed-source debt, still
debits the shared allowance. Unknown health, real pressure and route changes
retain their gates; a growth hold freezes only its prior allowance and cannot
bank ACKs, reprice its MTU or enlarge through replay. No priority or media role
is exported to relays. The new regression fails before the fix (2401 versus
3601 including the sentinel byte), then passes. All 129 local session checks
pass, with one existing ignored characterization. Both endpoint FFI libraries
built successfully. The subsequent clean 180-second relay capture retained
29.67 FPS phone -> Mac and 30.07 FPS Mac -> phone at the tail, with 360x640 /
640x360 frames. Audio RTP joins had no missing accepted packets and packet
peaks below 150 ms. However, full traces still exposed isolated 1.2-1.6-second
decoder stalls despite the improved average cadence.

## Growth-hold boundary and measured source recovery

The next stall was attributed to individual RTP/ciphertext work items. Phone
RTP 30792-30800 formed one 8654-byte original frame, mapped unambiguously by
packet count, byte size and time to sealed cells 8602-8610 in the private trace.
Only its first two cells reached the DATAGRAM handle; the remaining seven
expired in the local queue at 200 ms. No original native RTP admission failed.
The same RTP identities were retransmitted about 1.65 seconds later, ending
the decoder's wait. During the loss the source pool showed no measured
pressure, an expired growth hold, and no positive-health lease; its ordinary
paid window was still present. Current audio samples were healthy, but the
last known-health hold report had cleared the positive lease. The original
hold deadline expired between frontend polls, withdrawing all source allowance
behind control debt until the next positive report.

SDK `42abd620` retains the already-permitted allowance through the original
validated health sample's three-second TTL, independently of the event's growth
hold deadline. It never changes the original event deadline, grants fresh
capacity from an unknown state, banks delivery credit, or rebases freshness at
receipt. Real pressure, source inactivity and route changes still revoke it.
The regression fails before the fix (one-byte sentinel instead of 2401 bytes).
Delay, replay, future samples, sample expiry and lack of growth authorization
are covered; 131 local session checks pass, one existing characterization
ignored. Both endpoint FFI libraries compiled.

Its 180-second clean relay run kept both engines and all sampled relay routes.
After second 60, mean decoded cadence was 28.65 / 29.65 FPS (phone -> Mac /
Mac -> phone), with maximum gaps 125 / 301 ms and no multi-second steady-state
stall. Final cadence was 29.33 / 30.00 FPS at 360x640 / 640x360. All scored
accepted audio RTP arrived; packet peaks were below 176 ms. Initial video still
had a different problem: short duration-measured audio catch-up events latched
source pressure for twelve more healthy samples. The video source was locally
blocked for 15-18 seconds and subsequently recovered with bounded 25% probes;
first complete >=25-FPS windows were 56-60 seconds after camera enable.

The frontend source policy now permits its bounded initial/recovery trial after
three complete healthy observations when both active directions supply native
soft-loss duration evidence. Packet loss, native admission loss, interruption,
growing/capped buffers and excessive requested buffers retain twelve-sample
recovery; a later mild event cannot shorten pending hard-failure recovery.
Legacy, partial and stalled measurements cannot contribute to the fast path.
Known small events retain their existing growth hold and the node's gradual
DATA ramp / QUIC flight bounds remain authoritative. The startup regression
fails before this change; 222 source/adapter/delivery/growth tests pass and
focused Dart analysis is clean. In the next physical run, the source latch
cleared at 5.4 / 7.5 seconds (Mac / phone). That run did not qualify video:
the final 15 seconds fell to 0.33 / 1.93 FPS (phone -> Mac / Mac -> phone),
despite complete accepted-audio RTP delivery and packet peaks below 146 ms.
The node flight trace repeatedly showed transport pressure while frontend
consumer feedback was healthy. One primary first-hop connection accumulated
19 / 38 QUIC losses, while redundant paths delivered every scored audio packet.

## Transport warnings versus consumer health

SDK `40b3e920` distinguishes trusted first-hop transport warnings from measured
consumer failure. Fresh positive consumer health (including an already-held
allowance within its original sample TTL) prevents one path's loss, blocked
ACK or stalled writer from repeatedly halving the node-wide lossy source
window. Per-connection QUIC congestion control remains in force, and the same
warning still restrains ordered DATA. Warnings cannot grant flight, create or
refresh health, fund growth or erase a live pressure lease. Unknown/expired
health keeps the conservative fallback. Actual negative consumer feedback
clears the positive/held health immediately; source inactivity and route reset
also revoke it. Neither wire priority nor relay behavior changes.

The live-QUIC regression failed before the fix (one-byte sentinel instead of
the existing 2401-byte trial), then passed. Paid-window retention, expiry,
negative feedback, route reset, stalled writers and continued DATA restraint
are covered. All 134 local session checks pass, with one existing ignored
characterization. Both endpoint FFI libraries compiled and were installed in
the disposable stand with the faster measured-source frontend.

The clean 180-second relay run kept one engine per endpoint and relay routes
throughout. The first complete five-second windows at >=25 decoded FPS ended
12.94 seconds after camera enable for Mac -> phone and 17.27 seconds for
phone -> Mac. First >=360p frames appeared at 23.87 / 35.12 seconds. Final
cadence was 30.00 FPS at 640x360 and 29.13 FPS at 540x960 respectively. After
second 60, mean decoded cadence was 29.99 / 29.26 FPS, maximum inter-frame gaps
89 / 94 ms, and there were no gaps over 250 ms. The phone recorded two deferred
first-hop warnings while its consumer was healthy; neither endpoint applied
unknown-health transport fallback during this run.

All scored accepted audio RTP packets arrived in both directions. Estimated
packet-flight medians were 43 / 54 ms and maxima 162 / 158 ms (Mac -> phone /
phone -> Mac). These are native packet joins with clock-calibration bounds,
not acoustic mouth-to-ear delay or a subjective live-speech assessment. The
stand used deterministic PCM and real cameras, with no source/bitrate pin.
The earlier failed run and this successful run used a real changing network;
the isolated before/after regression establishes the particular admission bug,
while the physical run establishes this candidate's observed performance.

The subsequent 100-second P2P regression kept direct routes throughout and
restarted both cameras at seconds 40/45. Initial complete >=25-FPS windows
ended 18.69 / 19.23 seconds after enable (phone -> Mac / Mac -> phone);
after restart they ended at 15.89 / 16.74 seconds. Final cadence was
29.27 / 30.00 FPS. Maximum post-restart inter-frame gaps were 105 / 104 ms;
all scored accepted audio RTP arrived. Its original audio buffers performed
duration-measured latency catch-up near second 38, and the source protection
temporarily cut pixel count. This run therefore does not establish rapid
high-resolution recovery during audio catch-up: Mac -> phone first reached
360p at 21.07 seconds after initial enable, phone -> Mac at 69.35 seconds
(including the deliberate five-second camera-off interval). The original
audio-protection policy remains active; the path-warning fix does not suppress
consumer failures or promise immediate resolution recovery under them.

## Production test-input boundary

SDK `ea3f857e` puts the legacy built-in synthetic video threads and the
`VEIL_MEDIA_VIDEO_KBPS` pin behind `VEIL_MEDIA_TEST_HOOKS`, for both individual
and group engines. Public API arguments and route ceilings remain available
in ordinary builds. Both macOS and Android production libraries compiled with
105 public exports and contain neither environment switch; both switches were
present in the previously published libraries. Explicit stand builds compiled
with their existing 139 / 138 exports, and the BWE route-handover smoke passed.
No synthetic-source or bitrate-test pin is needed by the physical camera test.

Private raw captures remain outside the repository at
`~/.cache/codex/xveil-video-bbr-20261021/`; the earlier qualified P2P capture is
`capture-clock-valid-p2p-qualified`. Earlier failed/setup runs are kept
separately. Follow-up captures include
`capture-relay-ready-before-source-filter` and
`capture-relay-source-filter-before-promotion`, followed by
`capture-relay-promotion-before-held-trial` and
`capture-relay-held-trial-before-decoder-clock`. The latest candidate captures
include `capture-relay-decoder-clock` and `capture-p2p-decoder-clock`.
The current SDK/frontend qualification captures are
`capture-relay-transport-health` and `capture-p2p-transport-health`;
the immediately preceding failure is preserved as
`capture-relay-measured-source-transport-pressure`.
Completed owned app/logcat processes were closed and verified absent.
Each completed relay run restored its temporary per-contact P2P override.
The published 0.13.88 phone APK (code 2107) was restored after these checks
without uninstalling data. Its installed APK hash matches the published file;
the original UID is unchanged and the restored package is not debuggable.
Both runs restored log-buffer sizing, and the relay run restored its temporary
per-contact policy. All owned apps were closed and verified absent. The
production Mac installation has not been replaced. Raw traces and restoration
proofs remain in the private cache; no endpoint secrets are committed here.
