# Video with muted local audio — 24 October 2026

Fix `1893a286`, regression completion `19171c10` in the SDK.

## Reproduced defect

The local audio/video admission policy waited for an actually encoded short
Opus packet before allowing non-sparse video. A deliberately muted microphone
stops recording, so that packet cannot arrive. A new adaptive-audio call started
muted produced **zero encoded/decoded video frames**, packet duration **0 ms**,
and `audio_packetization_video_hold=1`. This was reproduced against fresh
baseline SDK `fa7123f5` production sources in the existing test-only fake ADM
harness. The failing test uses the public start/mute/video APIs and real codecs.

The same missing state matters after a running encoder selected 60-ms Opus:
muting removes capture callbacks while the old packetization hold remains.
Stopped and receive-only audio likewise cannot provide fresh encoder output.

## Change

`AudioPacketPriority` now knows whether local audio is sending. The audio worker
sets that state on start, successful mute/unmute and stop. Intentional absence
of outgoing audio releases only its packetization-based video hold. Explicit
video pauses and all other source/budget controls still apply.

Before unmute can restart capture, the policy clears its old audio observation
and requires fresh actual output. Idempotent unmute does not keep resetting it.
No audio frame is synthesized to acknowledge recovery, and the receiver's audio
protection or relay scheduling is not changed.

## Verification

* Fresh baseline native test failed with **0 encoded / 0 decoded** frames.
* After correction the same initial-muted scenario produced **16 encoded and
  16 decoded VP8 frames**, still **0 ms** audio packet duration. No capture
  callback was supplied while muted.
* The real-codec test also verifies video after stop and receive-only restart.
* With real 60-ms Opus, the existing <=1-fps trial still runs and the larger
  unmuted source remains held. Muting allows **5 additional frames** during its
  measured window. Unmute reinstates the hold; after draining preexisting work
  the video frame counter stays fixed. The later sparse-resume assertion uses a
  fresh counter baseline, so the muted frames cannot make it pass falsely.
* The policy/real-Opus suite passed; **991 actual Opus packets decoded**. Existing
  quiet, in-flight video, repeated unmute, explicit pause and clock rules pass.
* Ordinary production libraries compile for macOS arm64 and Android arm64:
  **105 exported media functions**, exactly the previous production set, no
  test exports or synthetic-video marker. Test-only ADM/codec hooks were used
  solely by disposable native test libraries, not those production outputs.

No physical microphone/speaker, phone or user profile was used. This fixes one
confirmed local video freeze; it does not qualify all physical call failures,
Windows audio, headphone loudness or live speech. Software hashes and bounded
numeric/boolean results are in `summary.json`; raw logs/artifacts remain private.
