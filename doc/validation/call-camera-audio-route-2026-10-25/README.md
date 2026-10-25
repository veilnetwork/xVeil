# Audio route continuity when enabling the camera

Continuation of [receiver fallback qualification](../call-receiver-fallback-2026-10-25/README.md).

## Finding and change

An audio-to-video upgrade reapplied `CallAudioRouter.useDefaultFor(video)`.
On Android this replaced the active earpiece with the loudspeaker, including
when the user had already selected a route. The default was being treated as
a command to switch an established call's devices.

On the physical Poco, that transition disconnected both AAudio streams with
`AAUDIO_ERROR_DISCONNECTED` (-899). Recovery reopened recording and playout.
At the Mac receiver, the corresponding RTP arrival gap was 3400 ms while RTP
media time advanced only 360 ms. The arrival/media intercept then remained
about 3 seconds above its previous baseline. This makes a capture discontinuity
look like persistent upstream delay to a relative RTP-age estimator. The
observed render buffer itself never exceeded 126 ms in the native trace.
These observations do not measure acoustic latency or prove a network queue.

The router now applies an automatic default only until a route is successfully
established. Camera upgrades keep that route. Explicit route selection and the
speaker toggle still apply immediately. Release clears the established state,
so a new video call still selects the loudspeaker and connected headphones
still take precedence during automatic initial selection. A failed native
selection remains retryable.

No video thresholds, encoder, native SDK, relay policy, transport priority,
mailbox policy or operating-system volume were changed in this cycle.

## Physical checks

Same QA identities on Mac and Poco, production SDK `a53142f5`, ordinary native
media without PCM test hooks, P2P denied on both endpoints, relay transport.
Radio/network conditions were not forced or held identical between runs.
The candidate frontends were rebuilt; all Android native library hashes match
the preceding QA APK. Only `lib/state/call_audio_route.dart` changed among the
548 production files under `lib/` in the build manifest (545 Dart, 3 ARB).

| Run | AAudio recording / playout recoveries | Peak audio pressure estimate, Mac / phone | Decoded FPS in final measured window, Mac / phone |
|---|---:|---:|---:|
| Prior code, video from call start | Not collected | See summary | 30.02 / 29.24 |
| Prior code, audio then both cameras | 1 / 1 | 3071 / 825 ms | 1.17 / 2.15 |
| Candidate, audio then both cameras | 0 / 0 | 147 / 166 ms | 29.94 / 30.33 |

The final candidate window lasted 5110 ms: actual audio RTP advanced by
29 / 128 packets and decoded video by 153 / 155 frames. Every one of the
18 video observation windows had positive audio RTP and decoded-frame progress
on both devices. This is a delivery check in a mostly quiet room, not a live
speech, loudness or visual image-quality qualification.

**Startup remains open.** The candidate took 38914 ms after requesting cameras
to collect five decoded frames on each device, versus 13558 ms in the prior
upgrade run. This is not first-frame latency: the test waits for five frames on
both endpoints and includes camera mounting and adaptive startup. The route
fix removes the measured device restart and eventual low-FPS stall; it does
not establish faster video startup. Manual device switching, headset removal
and RTP-clock continuity after an actual device restart require separate work.

## Regression and build checks

- 61 focused Flutter checks passed: route handling, camera state and group media.
- The revised route tests fail on the old router at the unintended native switch
  and repeated headphone-default calls; the candidate passes.
- Analyzer: no issues in the router, its tests and the calling media controller.
- Android APK and macOS QA builds passed. External build storage remained mounted.
- Incremental installation succeeded; the installed APK digest matches the built
  candidate. The main installed application was not changed.

Owned Mac process group and QA phone processes were verified absent after the
call. The owned ADB forward was removed, the test profile archived, and the
QA-only microphone/camera grants revoked and verified. No system power or
volume setting was changed.

## Evidence and scope

[summary.json](summary.json) contains aggregate results and software hashes.
[timeline.csv](timeline.csv) contains a fixed whitelist of numeric measurements
against relative elapsed time. Raw RTP timestamps, device/process identifiers,
addresses, API credentials, capture device labels, images and audio are excluded.
Detailed local traces stay in the private stand cache.

This cycle does not qualify Windows 10, live speech, background delivery, the
complete multi-device matrix or the remaining production fault-injection audit.

## Follow-up

The subsequent [packet-duration investigation](../video-packet-duration-2026-10-25/README.md)
identified a separate native gate behind the 32-second camera stall. Two calls
with that gate corrected reached five decoded frames on both devices in
6.526–8.076 seconds and finished around 30 FPS. The full-quality ramp still needs
20–31 seconds by the five-second-window measure; broader qualification remains
open.
