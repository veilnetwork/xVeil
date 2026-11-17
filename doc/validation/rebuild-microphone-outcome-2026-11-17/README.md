# Receive-only reconstruction must update capture posture

Base: `c4c16725`. This fixes a confirmed local controller/FSM integration gap;
it does not establish the cause of the reported Windows 10 one-way audio.

## Reproduction and change

When native audio startup proves that playout works but capture failed, the
controller keeps receive-only audio, mutes its input and sets
startedWithoutMicrophone. Initial CallService startup reads that flag. An active
call undergoing a route rebuild does not repeat that initial-start transition,
so it could keep micOn=true and advertise capture despite the failed input.

The same receive-only branch now emits the existing microphoneUnavailable
feedback. CallService's existing current-call/current-failure checks apply it,
invalidate older toggles and announce the muted capture posture. No route,
permission, native audio recovery or consent policy changes. This reports a
failed input honestly; it does not make an unavailable microphone work.

Five new gate-independent tests use the real CallService, real media controller
and health-triggered relay rebuild with controlled native/transport ports. One
case fails by assertion on the unchanged base: a working input becomes
unavailable during reconstruction, yet the service retains micOn=true. Four
controls pass on that base: already-muted input, healthy input, failed output
and refusal to enforce receive-only mute.

The fixed case checks the active call/relay route, preserved camera, live
replacement engine, mute command and peer capture announcement (audio=false,
video=true). A later successful explicit microphone retry restores audio=true.
Both genuine unusable-audio cases still fail repair and end the call. The fake
wire begins at the authenticated signal boundary; no network or physical audio
delivery is claimed.

## Qualification

The focused two-suite run passes 180 tests. Final qualification passes **844
related tests with no skips** across twenty-four suites and **254 tests with
diagnostics enabled and no skips** across seven overlapping suites. Counts are
not added as unique tests. The analyzer reports no issues; whitespace checks
pass. Existing native libraries match producer hashes and 1,144 Rust/Cargo
inputs; no native build is made.

All checks are headless with TMPDIR=/private/tmp/. No app window, focus change,
OS input, device capture, phone/container/install or seed operation is used.
The original Windows 10 complaint remains open. No push or release.
