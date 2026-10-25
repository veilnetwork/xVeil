# Video continuity across Opus packet-duration changes

Follow-up to [camera/audio route continuity](../call-camera-audio-route-2026-10-25/README.md).

## Confirmed cause

After the camera-route fix, the phone still stopped video for **32023 ms**.
Camera capture kept advancing, but transmitted video stayed at three frames.
The native `audio_packetization_video_hold` and `video_send_paused` indicators
were set. Current audio pressure estimates were small; the native gate was
waiting for Opus to replace its 60-ms packets with packets of at most 40 ms.
Promoting the one-FPS video trial to two FPS withdrew the sparse exception and
closed video admission until that audio-only allocation finally changed.

This is a local source gate, independently observable before network delivery.
It is not a diagnosis of packet loss or a relay failure.

## Change

SDK commit `20a09084` removes packet duration and the codec's pending long-mode
grant from the video-blocking condition. After an actual audio packet has been
emitted, video can continue while ANA changes packet duration. The initial or
resumed capture witness is still required. Explicit pause, stopped-source
admission, mute handling, measured audio-pressure adaptation and native budget
acknowledgements retain their existing paths.

Audio retains its real ANA duration selection, payload bounds and source-quiet
rules. No codec, wire protocol, relay service class, network priority, mailbox
policy, adaptive threshold or application bitrate ladder was changed.

## Physical qualification

Mac and Android QA profiles used the same identities and Dart frontends as the
preceding baseline. Only the production media libraries were replaced; the Rust
SDK and all other Android native libraries match the baseline. Both endpoints
denied P2P and reported relay transport. Network conditions were not forced
identical between runs.

Two complete audio-to-video calls were run, with applications restarted between
them. Each had ten seconds of audio before requesting both cameras, followed by
18 five-poll video windows, hangup and verified application cleanup. Before the
candidate calls, the fixture required five decoded frames on both devices
within 15 seconds and at least 20 decoded FPS on each device in the final window.
Both candidates passed those gates; actual audio RTP and decoded frames advanced
on both endpoints in every video window.

| Metric | Baseline | Candidate 1 | Candidate 2 |
|---|---:|---:|---:|
| Camera request to five decoded frames on both devices | 38.914 s | 8.076 s | 6.526 s |
| Maximum phone video transmit gap | 32.023 s | 1.842 s | 1.002 s |
| Final measured decoded FPS, Mac / phone | 29.94 / 30.33 | 30.06 / 29.67 | 30.07 / 29.29 |
| Largest sampled audio pressure estimate, Mac / phone | 147 / 166 ms | 121 / 156 ms | 122 / 154 ms |
| First five-second decoded window with >=20 FPS on both devices, after camera request | 48.113 s | 30.738 s | 19.863 s |

The audio pressure estimate includes receiver buffering and relative RTP age;
it is not acoustic latency. Candidate 1 recorded one 150-ms audio interruption
during its initial audio-only phase, before camera activation. Neither candidate
recorded additional audio interruptions during video. The room was mostly quiet;
speech intelligibility, loudness and subjective image quality were not assessed.

**Remaining work:** the full-quality ramp still takes about 20–31 seconds by the
five-second-window measure above. Removing the 32-second packetization stall
does not establish that video reaches its final quality immediately. Native
encoder allocation, decoder-feedback qualification and the application's probe
ramp remain relevant measurements for the next investigation. Manual audio
device restarts and capture-clock continuity also remain unqualified.

## Regression and build evidence

- The revised policy regression fails against the previous production header.
- Policy and real-Opus checks pass: **1017 packets decoded**, continuous RTP
  timestamps, existing payload bounds, explicit pause, quiescence and resume.
- The native Opus/VP8 pipeline passes with a real 60-ms audio warm-up and fixed
  48-kbit allocation. Promoting video from one to three FPS keeps video and audio
  moving; explicit pause and mute/unmute are exercised. This fixture uses local
  transport callbacks, not public relays.
- **200** focused Dart adapter/source-pressure/camera checks pass.
- Production Android and macOS media builds pass. Test exports are absent from
  the physical-call libraries; the separate native fixture uses an explicit test
  build. External storage remained mounted throughout the builds.
- The installed QA APK digest matches its artifact. The main app was untouched.

Both Mac process groups and QA phone processes were verified absent after their
calls. Original QA camera/microphone grant states were restored and checked,
owned ADB forwards removed, and the test profile archived. System power and
volume settings were not changed.

[summary.json](summary.json) records aggregates, software hashes and cleanup
proofs. [timeline.csv](timeline.csv) is a fixed whitelist of numeric counters
against relative elapsed time. Raw RTP identifiers/timestamps, device IDs,
addresses, credentials, capture labels, images and audio remain excluded.

This is not a Windows, live-speech, background or complete multi-device-matrix
qualification. The remaining production fault-injection audit is also separate.
