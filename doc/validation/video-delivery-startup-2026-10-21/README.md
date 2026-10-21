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
  seconds while healthy decoder acknowledgements continue.
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
and encoder epochs. None of those local diagnostic fields is a relay hint.

## Verification

- 181 Dart tests: existing adapter/growth checks plus twelve delivery-model
  scenarios. The model reaches the 900-kbit/s, 60-fps source ceiling in eight
  simulated one-second observations at both 10-ms and 120-ms RTT.
- Production native shim compound send/parse test: video ACK, freshness,
  replay, wrong target, truncation, duplicates and reserved fields; existing
  audio feedback compatibility retained.
- Native RTP accounting test: payload/padding isolation, retransmitted frame
  watermark, RTP clock wrap and source restart.
- macOS arm64 and Android arm64 native libraries compiled against pinned WebRTC.

Physical results and cleanup evidence are recorded after the stand run below.
The simulated timing is not a promise for an arbitrary real network.

### Physical qualification status

Not yet qualified for the requested startup time. Two Mac/Blackview Wi-Fi
runs preserved live P2P audio, but an independent outgoing source did not carry
video in both directions. The second run, with bidirectional text delivery
before the call and a 60-second route warmup, decoded Mac video on Android;
Android's video source had no ready framing snapshot and repeatedly attempted
channel setup. Decoder feedback was observed on the working direction, but
zero decoded frames cannot earn a probe. Native target increases on the legacy
fallback are **not** counted as successful video startup.

These observations identify a prerequisite below the source controller; they
do not establish its cause or prove a release regression. Source-channel
qualification is being investigated. Private raw captures remain outside the
repository at `~/.cache/codex/xveil-video-bbr-20261021/`. Setup-failure, no-video
and one-direction captures are kept separately. Each completed run closed the
owned Mac/phone instances and restored the exact published Android APK.
