# Phone–Mac Wi-Fi reference call

## Result

A real Blackview BV6600Pro and this Mac completed a four-minute call over the
local Wi-Fi network on 2026-10-21. All 115 state observations on each endpoint
reported P2P; both route-handover counters remained zero. Incoming ringing
appeared after **175 ms**. No relay recovery, rate limiter or traffic shaper
was requested. The phone used 5-GHz Wi-Fi; its initial RSSI was −63 dBm and
reported link rate was 390 Mbit/s. The link rate is a radio estimate, not an
application-throughput measurement.

This is a LAN/P2P reference. The previous shared-1024-kbit/s, three-participant,
relay experiment exercised a different topology and bottleneck. This capture
does not measure an Internet relay route or establish the condition of the ISP.

## Audio

The private QA build submitted a generated PCM signal to the actual Opus
encoder and observed decoded PCM on the opposite device. Physical microphones
and speakers were bypassed. Consequently this measures capture submission to
decoded PCM, with the real codecs and network; microphone gain, acoustic echo,
speaker latency, headphone loudness and speech intelligibility remain untested.

| Window | Mac → phone median / maximum | Phone → Mac median / maximum |
| --- | ---: | ---: |
| Audio, 5–60 s | 51.1 / 90.7 ms | 71.0 / 111.0 ms |
| Audio + video, 60–120 s | 50.1 / 51.3 ms | 60.9 / 71.0 ms |
| Audio + video + file attempts, 120–180 s | 58.6 / 91.2 ms | 70.9 / 72.0 ms |
| After cancellation requests, 180–240 s | 60.8 / 91.0 ms | 71.9 / 91.9 ms |

These are midpoint estimates. There were nine eight-request clock calibrations
per device, including the beginning and end. The observed offset envelopes
produce corrections of **−9.96 to +11.06 ms** for Mac → phone and **−11.06 to
+9.96 ms** for phone → Mac. The largest decoded-delay estimate therefore has an
interval of **99.9–120.9 ms**. This envelope bounds the sampled calibrations;
unobserved clock drift is not proven bounded. PCM observation resolution is
10 ms. The first five seconds are excluded from the phase statistics.

All **470 tone transitions** in the analyzed windows matched in ordinal order,
with no missing transitions. The drivers reported zero failed callbacks and
zero dropped observation rows. Both native audio-interruption counters and
durations remained zero. Short concealment did occur: six events at the Mac
and eight at the phone. Zero counted interruptions does not mean every audio
sample was original or prove subjective listening quality.

### Delivery and endpoint queues

All **22,752 encoded speech packets** with source inputs between 5 and 240 s
had matching send and recipient-ingress witnesses, with zero missing payload
packets in either direction. Matching uses the sender RTP origin, sequence,
timestamp and payload length; padding is excluded.

The largest encoded-packet-to-recipient-ingress midpoint estimates were 53.3 ms
Mac → phone and 62.2 ms phone → Mac, with clock intervals **43.4–64.4 ms** and
**51.1–72.1 ms**, respectively. The former 133-ms delivery tail did not recur.
This span includes endpoint SDK/transport work and transit; it is not solely
radio propagation and has not been split into QUIC acceptance and link transit.

One-way packet medians have midpoint estimates near or below zero in one
direction because USB clock calibration is asymmetric. They must not be used
as precise physical network delays. RTT is measured within an endpoint clock:
during audio and unloaded video its median was **8–11 ms**, with sampled maxima
of 10–26 ms depending on the endpoint/window. Under file attempts an isolated
sample reached 154 ms. Reported media loss stayed at 0% in every state sample.

Measured local spans across the capture:

- Native send admission: at most **0.067 ms on Mac / 2.549 ms on phone**.
  This is media-to-SDK admission, not a QUIC wire acknowledgement.
- Recipient ingress to native drain: at most **0.180 ms on Mac / 5.171 ms on
  phone**.
- Encoded packet to native send attempt: at most **14.248 ms on Mac / 22.246 ms
  on phone**. This includes the local pacing/scheduling span before admission.

These measurements do not expose a persistent 133-ms endpoint queue on the
Wi-Fi/P2P path. See `packet-summary.json` for the exact peak witnesses and all
phase distributions, and `sample-summary.json` for sampled RTT and buffers.

## Video: healthy steady state, slow startup

Real cameras were enabled at approximately 60 s. Actual decoded-frame traces
showed the following, independent of the cumulative UI FPS averages:

| Receiver | First video minute | File-attempt minute | Final minute |
| --- | ---: | ---: | ---: |
| Mac, receiving phone | 6.65 FPS | 27.68 FPS | **29.57 FPS** |
| Phone, receiving Mac | 6.87 FPS | 28.83 FPS | **30.00 FPS** |

In the final minute the Mac decoded 540×960 video from the phone and the phone
decoded 640×360 video from the Mac. Largest frame gaps in that minute were
78 and 91 ms, respectively. The 1.1–1.2-second cumulative maximum gaps originated
in the first video minute, rather than recurring throughout the call.

The initial adaptation level was 4 on both devices; the level reached 0 at
call times 138.7 s on Mac and 149.3 s on phone, approximately **79–89 s after
camera enable**. The adaptation trace identifies this as startup recovery.
The policy starts a new video sender at the lowest rung and gradually earns
recovery using video progress and fresh audio/peer feedback. There were no
native audio-pressure pixel cuts and neither sender was paused for audio in
the sampled states. This capture demonstrates a slow application-controlled
startup on a low-RTT link; it does not by itself isolate which recovery gate
accounts for each wait. Startup tuning is an outstanding issue, not a fix
implemented in this measurement cycle.

## File-load limitation

Two 32-MiB random-file transfers were started at approximately 120 s. Neither
completed with a verified SHA-256 by 180 s, when both cancellation requests
were acknowledged. The outstanding HTTP waiters ended with `RemoteDisconnected`
when the owned test apps were stopped. Thus **file completion is not qualified**.
The final minute means after the cancellation requests; the capture does not
prove all transport queues were immediately empty. The audio measurements
remain usable; this is not a passed combined audio/video/file-transfer gate.

## Build provenance and cleanup

The root source was `5fb806a6`, with SDK pin `50eb39cb`. Disposable copies reused
the existing QA AOT/Flutter engine and PCM driver. The two Dart call-policy
files were byte-identical to current source. Native media source files were
checked against the SDK pin; Android media was rebuilt, and Mac media reused
the already verified latest library. Android Rust was rebuilt from the clean
private export containing `9eef87b9` and QA helpers; subsequent SDK commits to
`50eb39cb` changed C++ media. Concurrent worktree changes were excluded.
`build-proof.json` records signed library/APK hashes and ABI parity. No
production behavior or relay configuration was changed in this cycle.

The exact installed phone APK was saved before testing. After the test it was
restored, and its version code **12622** and SHA-256 were independently verified.
The private runner's restore step initially failed because a local variable
shadowed its directory path; restoration was completed manually and that runner
bug was corrected. The Mac required an owned SIGKILL after its eight-second
SIGTERM timeout. Independent checks confirmed absence of the Mac app, phone
app, capture launcher and owned logcat process; the owned ADB forward was
removed. See `cleanup-proof.json`.

Owner-only raw observations, clock-calibration inputs and APK backups are under
`~/.cache/codex/xveil-wifi-reference-20261021/`. Published evidence here excludes
API keys, identities, contact data and raw device logs. Raw input hashes are
recorded in `private-input-sha256.json`.

Reproduce PCM analysis using the raw capture:

```sh
python3 scripts/analyze_physical_pcm.py RAW_CAPTURE_DIR --duration 240 \
  --phases doc/validation/wifi-reference-2026-10-21/phases.json \
  --output pcm-summary.json
python3 -m unittest discover -s scripts -p test_analyze_physical_pcm.py
```

The analyzer now accepts explicit phase intervals so a natural-route capture
does not inherit labels for a forced relay handover from earlier experiments.
All three analyzer regressions passed, including ordinal loss matching and
custom-phase labeling.
