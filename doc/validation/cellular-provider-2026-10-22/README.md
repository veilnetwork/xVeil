# Cellular call and file validation — 2026-10-22

**Status: failures reproduced; production fixes pending.**

Two physical endpoints: a Mac laptop and an Android phone on cellular data,
with Wi-Fi disabled on the phone. The phone was awake and unlocked. Test profiles
were isolated from existing conversations. The stand frontend used xVeil
`a6b7524b`, Veil `0.11.44` / `c67cfe30` and hidden-volume `2.6.3`. It used ordinary
production media engines and real microphones/cameras, with synthetic media and
PCM injection disabled. Builds finished before network measurements began.

Only aggregate observations are retained here: no peer/device identifiers,
addresses, paths, keys, message contents, camera images or audio recordings.
[summary.json](summary.json) contains the numeric measurements. Private working
captures are excluded from the repository.

## Results

| Case | Observed result |
|---|---|
| Contact request, laptop → phone | Received in 4.15 s; accepted at both endpoints by 5.29 s. |
| Text, each direction | Observed within 0.57 s, one copy each. After the failed large upload both directions still delivered within 0.57 s. |
| 32 MiB, laptop → phone, no call | Completed in 104.50 s; SHA-256 matched. |
| 32 MiB, phone → laptop, no call | Timed out at 180 s. Observed partial file reached 3,932,160 bytes (3.75 MiB); repeated stream reopening did not complete it. The source file was not moved or modified. |
| Audio call, laptop → phone, then enable cameras | Ring in 1.10 s, active 1.02 s after answering. Remained connected for 149 s. Automatically moved P2P → relay at about 35.4 s; the harness requested no route change. Sustained video failed: 2 decoded phone → laptop frames, none in the other direction across sampled media epochs. |
| Initial video call, phone → laptop, after phone restart | Ring in 1.71 s, active 4.72 s after answering. Remained connected for 179 s. Brief relay/P2P transitions settled on relay. The phone decoded 11 early laptop frames, then stopped progressing after about 14.3 s. No phone frames reached the laptop. |
| Audio-only call with two simultaneous 1 MiB files | Call remained P2P for 90 s, without ending unexpectedly. Both files eventually passed SHA-256, taking about 106 s from transfer start; completion was after hangup. |

The first 4 MiB simultaneous-transfer attempt was canceled by the harness before
completion. It is unscored as a product failure. The smaller-file recheck waited
for completion and for its request threads to exit.

## Evidence and remaining questions

### File upload

The receive side logged resume offsets, EOF mid-piece and subsequent attempts
that failed to obtain a manifest. The sending phone reported the fixed SDK
failure `veil IPC writer task closed`, a payload-write idle timeout and later an
onion-stream driver closure. These establish failure in the stream path; they
do not establish which network or application condition caused its first stall.

The ongoing ability to send short messages and establish calls after the failed
upload separates this observation from a complete node/process outage. The
32 MiB reverse transfer remains a failing case.

### Call media

The first automatic relay recovery followed a native audio-receive age above
3 seconds after cameras were enabled. Media counters were grouped by media epoch
so handover resets are not mistaken for an entire call's totals. Reported FPS
was not used as proof of moving video: frame counters stopped advancing while a
stale nonzero FPS value remained visible in one run.

Cameras continued capturing on Android while video transmission was held. Native
`audio_packetization_video_hold` / `video_send_paused` stayed set for most video
samples, with 60-ms audio packetization. This identifies a local admission gate
that requires investigation, including whether audio adaptation can release it
under these conditions. It does not prove that the gate caused the original
network/audio interruption.

Measured jitter-buffer-plus-device audio delay:

| Call | Laptop median / maximum | Phone median / maximum |
|---|---|---|
| First call with camera enable and handover | 10 / 198 ms | 151 / 1657 ms |
| Reverse video call | 32 / 242 ms | 151 / 303 ms |
| Audio-only recheck | 10 / 140 ms | 142 / 201 ms |

These are local buffer measurements, not end-to-end acoustic delay. Live speech,
headphone loudness and intelligibility were not assessed. The observed network
and one endpoint pair do not isolate the carrier as the cause of either defect.

## Cleanup

- All calls ended and owned log-capture processes exited.
- Owned Mac stand process exited; the installed Mac app was not replaced.
- Phone test caches were removed.
- The original phone APK was restored in place, with an exact SHA-256 match,
  preserving existing application data. Restored version: `0.13.88`, code `2107`.
- The phone app process was absent after restoration; the owned ADB forward was
  removed.
