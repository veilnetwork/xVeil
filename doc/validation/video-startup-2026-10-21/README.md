# Faster measured video startup

## Cause and change

The Wi-Fi reference exposed two serial limits in `CallBitrateAdapter`:
each accepted increase added at most one FPS, and bitrate grew at most 10%
of its previously applied value. At the 900-kbit/s, 60-FPS profile the cold
floor is 15 kbit/s at one FPS. Even after granting six FPS, the old ramp took
about twenty observations to fund their 90-kbit/s target. Cadence could thus
run ahead of its byte allocation, producing very small images while the
pending bitrate prevented the next quality-rung promotion.

The accelerated ramp applies only during measured low-latency startup:

- Existing health gates still require actual video progress, audio telemetry
  in both directions, RTT at most 60 ms, measured/target playout below 100 ms,
  no reported loss, low jitter and an available endpoint source budget.
- Each quality rung still requires three healthy observations and a distinct
  peer report. Unapplied ramps cannot bank another promotion.
- The native target grows cadence and bitrate together. Cadence increases by
  50% of its applied value, at least one FPS and at most one tenth of the
  negotiated profile per step; bitrate funds that cadence, also capped at one
  tenth of the profile per step. Native acceptance, distinct observations and
  the existing approximately one-second interval remain mandatory.
- Startup remains active until the full target is acknowledged by native
  code, rather than ending when the nominal ladder first reaches level zero.
- Ordinary recovery and legacy engines retain their former step limits.
  Existing loss, buffer-pressure, pause and route-budget protections remain
  active. Relay forwarding and peer protocol fields were not changed.

The patch is confined to the Dart sender policy. No native library or relay
configuration was changed.

## Real phone–Mac comparison

A new 180-second call used the same Mac and Blackview as the
[Wi-Fi reference](../wifi-reference-2026-10-21/README.md), with exact matching
native library bytes. The temporary build generated audio PCM and observed
decoded PCM while using the real cameras, codecs and network. No physical
microphone, speaker or subjective speech-quality check was performed.

After a 60-second network warmup, the call rang on the phone in 175 ms. Cameras
were requested at call time 31.12 s; the camera APIs returned at 32.93 s. All
86 state observations on each endpoint reported P2P and both handover counters
remained zero. File transfers and forced relay recovery were not started.

Times below are relative to camera enable. The previous capture recorded camera
enable at approximately 60 s. State polling introduces approximately two seconds
of event-time granularity. A nominal top rung, an acknowledged native target,
and a decoded frame rate are different measurements:

| Sender metric | Before | After |
| --- | ---: | ---: |
| Mac: nominal top quality rung | 78.7 s | **43.7 s** |
| Phone: nominal top quality rung | 89.3 s | **28.8 s** |
| Mac: acknowledged 900-kbit/s, 60-FPS ceiling | 112.4 s | **47.9 s** |
| Phone: acknowledged 900-kbit/s, 60-FPS ceiling | 118.6 s | **30.9 s** |

The cameras physically supply about 30 FPS. The 60-FPS value above is the
negotiated sender ceiling, not a claim that either camera captured 60 FPS.

Actual decoded-frame traces show:

| Receiver | First video minute, before | First video minute, after | Final minute, after |
| --- | ---: | ---: | ---: |
| Mac, receiving phone | 6.65 FPS | **20.53 FPS** | **29.60 FPS** |
| Phone, receiving Mac | 6.87 FPS | **16.13 FPS** | **30.00 FPS** |

The final minute decoded 540×960 at the Mac and 640×360 at the phone.
Largest frame gaps during that minute were 95.7 and 50.0 ms respectively.
Initial sparse-trial frame gaps still reached 1.0–1.4 s; startup was accelerated,
not removed. The native audio-pressure pixel-cut counters remained zero.

The two senders did not recover at identical speeds. At approximately call
times 45–50 s, Mac retained a reported RTT of 176 ms while measured audio
buffers stayed near 44–57 ms. The existing relative-RTT guard held its pending
target; after RTT recovered it required the existing twelve healthy recovery
observations. This accounts for much of Mac's additional delay. This cycle
keeps that guard; it does not treat a good Wi-Fi connection as an unconditional
right to use the full route budget.

The baseline introduced file attempts in its second video minute. The new
capture has no file load. First-video-minute comparisons precede those baseline
file attempts; whole-call recovery timings are observational comparisons of
separate calls, not a controlled capacity experiment.

## Audio stayed bounded during faster video startup

| Window | Mac → phone median / maximum | Phone → Mac median / maximum |
| --- | ---: | ---: |
| Audio only, 5–30 s | 60.8 / 110.0 ms | 71.1 / 140.8 ms |
| Video-startup phase, 30–90 s | 60.1 / 62.0 ms | 70.7 / 71.0 ms |
| Video steady phase, 90–180 s | 59.3 / 91.3 ms | 71.8 / 72.0 ms |

These are synthetic capture-to-decoded-PCM midpoint estimates, sampled at 10 ms.
Seven eight-request clock calibrations per endpoint produced observed clock
corrections of −12.09 to +6.54 ms for Mac → phone and −6.54 to +12.09 ms in the
opposite direction. The maximum upper estimate with video was **97.84 ms**.
The largest whole-call upper estimate was **152.89 ms**, in the audio-only
phase before cameras were enabled. Unobserved drift between calibrations is
not proven bounded.

All **350 analyzed tone transitions** matched in ordinal order. PCM drivers
reported zero failed callbacks and zero dropped rows. All **16,850 encoded
speech packets** with source inputs between 5 and 180 s had matching native
send and recipient-ingress witnesses; padding was excluded and there were no
missing payload packets. Both native audio-interruption counts and durations
were zero. Short concealment still occurred: four events at Mac and six at
phone. No subjective loudness or intelligibility claim follows from this test.

## Verification and provenance

- The two new funding regressions failed on the old policy: additional FPS
  received only 33 instead of 60 kbit/s in the 30-FPS case, and 16 instead of
  30 kbit/s in the 60-FPS case.
- **198 tests passed:** 161 policy tests and 37 related group/route tests.
  Seven new policy regressions cover proportional funding and full-target
  convergence for 30/60-FPS profiles, higher RTT/local/peer playout gates,
  busy native acceptance/repeated application, and legacy integer cadence.
- `dart analyze` reported no issues for the edited source and test.
- Four signed Mac native libraries and all Android native libraries other
  than the newly compiled app AOT matched the Wi-Fi reference exactly.
  Concurrent multi-device worktree changes were excluded from private builds.
- After the physical capture, review added the explicit `supportsLowRateVideo`
  guard to preserve legacy integer-cadence behavior. The measured engines
  support that capability, so their branch behavior is unchanged. That is
  the only source difference from the measured policy; both source hashes
  and this distinction are recorded in `build-and-tests.json`. The final
  regression suite includes the legacy case.

Both owned apps, the measurement launcher and logcat process were independently
verified absent. The exact original phone APK, version code 12622, was restored
and its SHA-256 verified. The owned ADB forward was removed. Mac needed an owned
SIGKILL after its eight-second SIGTERM timeout. See `cleanup-proof.json`.

Owner-only raw evidence and APK backups remain under
`~/.cache/codex/xveil-video-startup-20261021/`. Public artifacts contain metrics,
calibration brackets, input hashes and build/cleanup proofs, without hook keys,
identities, contacts or raw logs.

```sh
TMPDIR=/private/tmp/ flutter test --no-pub \
  test/call_bitrate_adapter_test.dart \
  test/group_call_audio_adapter_test.dart \
  test/call_media_route_operations_test.dart
dart analyze lib/state/call_bitrate_adapter.dart test/call_bitrate_adapter_test.dart
python3 scripts/analyze_physical_pcm.py RAW_CAPTURE_DIR --duration 180 \
  --phases doc/validation/video-startup-2026-10-21/phases.json \
  --output pcm-summary.json
```
