# Android selected a thumbnail as the call capture — 2026-10-20

## Reproduced cause

The Blackview front camera does not expose the requested 640×360 preview/YUV
mode. `chooseCommonSize` ranked the common hardware modes with:

`8 × aspect-ratio error + abs(area - requested_area) / requested_area`

Every undersized mode has an area penalty below 1, while larger modes can cost
arbitrarily more. For this hardware list, exact-aspect 192×108 costs 0.91 and
960×540 costs 1.25. The policy therefore selected a thumbnail despite the
larger usable mode. The application log only printed requested 640×360 and
concealed the actual selection. The last baseline decoder trace independently
confirms **all 2471 phone frames arrived at Mac as 108×192** after rotation.
There was no explicit video pixel cap at the end of that run.

## Change

A pure Kotlin selection policy now uses `abs(ln(area / requested_area))` for
symmetric scale distance. Aspect preference and the preview/YUV intersection
remain; an exact available mode wins, and equal distances prefer fewer pixels.
The Blackview choices become 960×540 for the direct profile; the 352×198
low-bandwidth profile still selects 192×108 on the same list. Capture dimensions
are now exposed in local diagnostics, with the chosen metadata protected by
the same lock as the capture stats.

The normal codec/source adaptation still decides what to encode. No audio
thresholds, pacing, relay priorities, network privacy policy or native SDK/media
libraries changed. No larger codec resolution is forced by the capture fix.

## Verification

- The extracted production policy with the old formula fails the device-list
  regression: expected 960×540, selected 192×108. The new policy passes.
- **8 Kotlin/JVM checks** cover the recorded 31-mode intersection, an exact
  available mode, the low-bandwidth profile, 4:3-only hardware, a tiny-only
  fallback, deterministic cheaper ties, an empty list and invalid modes.
  Run `python3 scripts/test_call_camera_size.py`; it uses pinned artifacts from
  the existing Gradle cache and a JDK, without downloading dependencies.
- **156 Flutter tests** passed (camera capture lifecycle and bitrate adapter).
  Android profile build and diff whitespace checks passed.

## Physical Mac ↔ Blackview run

Android QA 12629 was built from the changed Kotlin sources; source hashes match
the disposable export. Mac remains on the exact 12628 stand. All non-AOT native
inputs and the Android signer are pinned as before; SDK is `70a99c1f`.

The same 150 s real P2P call used synthetic ADM: camera enable at 30 s, two
32 MiB file requests at 45 s, cancellation at 90 s. It did not record or play
physical microphones/speakers. All sampled routes stayed P2P.

The actual Camera2 selection is **960×540 at 29.6 capture FPS**. Mac decoder
metadata is complete (1868 recorded/seen frames, successful flush):

| Received phone size | All frames | Frames in source seconds 90–150 |
|---|---:|---:|
| 180×320 | 68 | 0 |
| 270×480 | 108 | 0 |
| 360×640 | 151 | 46 |
| 540×960 | 1541 | 1423 |

The final-minute decoded median area rose from 20736 to 518400 pixels, **25×**,
and the final frame was 540×960. This is decoded resolution evidence, not a
subjective sharpness score or proof of 25× perceptual quality. Native orientation
accounts for capture 960×540 becoming received 540×960.

Actual outgoing FPS, calculated from interval counters:

| Approximate interval (s) | Mac | Phone |
|---|---:|---:|
| 31–45 | 0.70 | 0.70 |
| 45–75 | 2.87 | 5.20 |
| 75–91 | 6.03 | 7.40 |
| 91–120 | 7.98 | 19.71 |
| 120–150 | 17.27 | 29.28 |

**Reverse video recovery was slower than in the preceding run.** No nominal
rung cuts were recorded, but Mac startup acceleration retired at observation 8:
RTT 200 ms against a 16 ms baseline, with receiver/peer buffers 56/65 ms and no
recorded loss or interruption. This crosses the existing RTT degradation rail;
it is outside the marginal-RTT hold fixed in the preceding cycle. The trace
establishes the policy decision, not that the larger capture caused the RTT
excursion. The source-size fix does not qualify the entire video recovery path.

All **290** expected tone transitions in source seconds 5–150 matched, with
complete observation rows and no driver errors. With video/files, point p95/max
were **110/130 ms** Mac → phone and **111/131 ms** phone → Mac. The largest reverse
phase delay's observed clock envelope is **124–142 ms**. PCM blocks are 10 ms;
unsampled clock drift is not proven bounded. These synthetic decoded timings
do not qualify hardware loudness or live speech intelligibility.

Native traces contain zero session violations/peer bans and two expected closed
stream messages on Android. Both file requests were canceled before completion;
HTTP waiters still end with RemoteDisconnected on app shutdown. This run proves
coexistence/cancellation, not completed file throughput.

## Cleanup and scope

Apps/helper PIDs and the owned ADB forward were independently checked absent.
Ordinary phone APK 12622 was restored and its installed SHA-256 matches. Mac
needed SIGKILL after its grace period (exit -9), with call activity already
released. Foreign root/SDK edits remain untouched. No push, release or relay
update. The full audio/video/screen/data priority/isolation goal remains active.
