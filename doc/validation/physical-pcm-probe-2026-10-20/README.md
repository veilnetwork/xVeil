# Physical decoded-PCM probe and an audio-only startup failure

## Scope

The goal remains audio priority and independent interactions under simultaneous
video, screen and data load. This cycle adds an observable synthetic audio input
to the real Mac/Android application path. It does **not** claim that goal complete
or change the deferred strict 200 ms acoustic target. Production call policies,
SDK network code, relay behavior and wire metadata are unchanged.

The native fixture replaces only the capture/playout device. The normal Opus,
NetEq, encryption, actual SDK channels, call negotiation, source feedback and
video adaptation remain. Cameras are real. No physical microphone or speaker is
opened by the synthetic ADM. This is decoded-pipeline timing, not a microphone-
to-speaker acoustic measurement or a headphone loudness qualification.

## Reviewable fixture

- `scripts/prepare_physical_pcm_probe.py` overlays disposable app/SDK exports
  outside the repository. It refuses repository roots and edits no production
  plugin source. Native media must explicitly contain stand-only test hooks.
- `scripts/physical_pcm_probe.dart` wraps the existing `native_pcm_driver.cc`.
  Actual capture times and decoded tone metadata are recorded; no voice waveform
  is retained. Both C struct sizes are checked before passing writable buffers.
  The native thread is stopped and joined before engine destruction. A failed
  stop retains the engine rather than freeing a callback's target.
- The private authenticated `/qa_pcm` endpoint reports the monotonic clock and
  starts the prepared source at a calibrated future epoch. A separate
  `XVEIL_PCM_PROBE=true` build define and source index are required.
- `scripts/analyze_physical_pcm.py` uses actual source capture rows and decoded
  transitions. Ordinals are never re-anchored to a later repeated tone. It
  reports observed clock-bracket uncertainty and leaves the overall quality
  verdict unset. Missing recordings, incomplete intervals and engine replacement
  reject full qualification.
- Two analyzer tests pass: capture-based delay with clock intervals, and a lost
  period that must not become an apparently fast later cycle. Dart analysis of
  the probe passes. QA export analysis has no errors and retains two existing
  SDK lint infos; those were not silently removed to obtain a green result.

The driver/native source is the previously checked SDK `19004dc5`. Android media
was built in the existing isolated Linux builder with `VEIL_MEDIA_TEST_HOOKS=1`;
Mac reuses the corresponding verified hook dylib. Native clocks and struct ABI
were exercised on both actual devices. All app launches/builds use
`TMPDIR=/private/tmp/` on Mac.

## First attempt: incomplete recording

Private AOT builds 12623 ran the call for 300 seconds with continuously generated
audio, cameras from 30 seconds, an explicit P2P-to-relay request at 150 seconds,
and concurrent 4 MiB files in each direction in both phases. During observation,
both decoded streams contained the expected remote tone and their RMS was about
8400. Neither driver reported dropped observation rows or capture/playout errors.

This is **not** a complete delay qualification. Flutter's Android system temp
was `code_cache`; the collector accepted only `cache`, failed to copy that file,
and APK restoration cleared it. Mac's full recording and the original results
remain; the missing phone recording is not reconstructed from the intended
schedule or a maximum timing counter.

The probe now uses the app's ordinary cache on Android. The collector accepts
only owned PCM subdirectories, copies the data before APK restoration, and keeps
the first attempt's collection failure visible.

The four 4 MiB downloads did not finish in that attempt. Initial download waits
expired after about 120 seconds, leaving background retries against an already
closed fixture sink. Logs include resume offsets of 1 MiB and repeated manifest
waits, but no complete file hash was verified. This is not called a successful
file-load qualification. The repeat uses a longer HTTP wait and explicit bounded
cancellation after measurement; its later file phase was never reached.

## Second attempt: audio-only one-way failure

Builds 12624 fix recording preservation. Both source recordings were collected
and remained readable after restoring the ordinary app. The call failed the
fixture's engine-generation guard at about 14 seconds, before camera or file
activation. The original error and complete short recordings are retained.

| Early observation | Mac | Android |
| --- | ---: | ---: |
| Maximum sampled queued outbound audio RTP | 268 | 343 |
| Maximum sampled accepted inbound audio RTP | 273 | **0** |
| Sampled local audio RTP send drops | 0 | 0 |

The phone requested recovery after receiving no audio. Mac rebuilt its local P2P
media engine in response. The new generation had not been given a measurement
source, so the fixture stopped instead of quietly restarting/re-aligning it and
turning the outage into a passing result. This leaves a concrete startup delivery
failure to investigate; its production cause is not established here.

For the first generation only, the actual source and decoded observations on
the audio-only interval **5–9 s** show:

| Direction | Matched transitions | Unmatched transitions |
| --- | ---: | ---: |
| Android → Mac | 4 | 0 |
| Mac → Android | 0 | 4 |

Android → Mac's maximum point estimate is 162.8 ms, with a measured clock-bracket
interval of 156.1–169.5 ms. The PCM blocks are 10 ms and unsampled clock drift is
not proven bounded; these figures are not hardware acoustic latency. There is
no delay estimate for the undelivered reverse direction.

`early-one-way-pcm.json` retains that explicitly partial result. The full analyzer
correctly rejects this capture because Mac has two engine generations. No camera
quality or file-interference conclusion is drawn from this short attempt.

## Remaining work

The next action is to trace the queued Mac audio through the direct SDK transport
and the phone's ingress/demultiplexing/decryption path. The startup failure occurs
before video, so this capture does not justify another video-threshold change.
Then repeat complete decoded-PCM measurement under real video/file load and
qualify screen traffic. Live speech, physical device audio and headphone loudness
remain separate unverified requirements.

## Provenance, restoration and cleanup

`proof.json` maps exact sources, packages, build/analysis logs and private raw
recording hashes. The incomplete first attempt and aborted repeat both remain.
Credentials and hook keys are excluded. Normal phone QA build **12622** was
restored after each attempt without uninstalling or deleting profiles; the
ordinary Mac stand app was restored as well. At cycle end neither app uses the
synthetic-microphone build.

All owned Mac apps/helpers, Android app processes and ADB forwards were checked
absent. All recorded probe instances report stopped; Mac processes required the
bounded fixture's SIGKILL cleanup, which remains exit -9 in the results. Foreign
root/SDK work fingerprints are unchanged. No push, release or relay mutation.
