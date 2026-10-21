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
- A receiver's decoder delay rising 80 ms above its baseline for three seconds,
  or reaching 500 ms, is additional queue evidence. A short spike holds growth.
  This is decoder queue delay, not propagation RTT.
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
| 52 | 4 | Current decoder delay, milliseconds |
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
its existing flight to the trial. Pressure, a growth hold, or stale healthy
feedback removes it. The allowance is not banked as a paid window or multiplied
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

Private raw captures remain outside the repository at
`~/.cache/codex/xveil-video-bbr-20261021/`; the successful current P2P capture is
`capture-clock-valid-p2p-qualified`. Earlier failed/setup runs are kept
separately. Completed owned app/logcat processes were closed and verified absent.
The isolated QA APK is retained while relay verification is in progress; each
completed relay run restores its temporary per-contact P2P override.
