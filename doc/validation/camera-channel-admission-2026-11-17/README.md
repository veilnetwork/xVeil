# Refused camera channel preparation must not leave camera ON

Base: `e1a16fa4`. This is a direct-call controller/FSM qualification, not an
attribution of the user's Windows 10 camera report.

## Confirmed mechanism

Turning the camera ON first clears the local screen-producer mode through
setMediaScreenSharing. Its native contract returns -1 for a closed/invalid
channel or one lacking screen ingress. The controller correctly refused capture
on a nonzero result, but returned without recording a failed camera outcome.
CallService therefore retained camera ON although capture had not started.

Two exact-base assertion failures reproduce this with real CallService and
VeilCallMediaController: enabling a previously disabled video camera and
upgrading an audio call to video. The channel failure and native camera engine
are controlled. Both failures assert cameraOn remained true. Two exception
controls already turned it OFF through the service's exception handler.

This proves handling of the channel's documented refusal, not that the reporter
hit that refusal or that a valid channel is ordinarily missing its ingress.
No timing threshold or absence of physical frames establishes the defect.

## Change

A missing channel, refusal or exception now reports failed camera posture to the
existing scoped camera-outcome path. The service keeps audio/video receive and
the active call, marks the local camera OFF and announces the actual capture
posture. A subsequent ON retries normal preparation/capture on the same engine.
The channel admission gate remains required; no fallback transport, camera
selection or privacy rule is changed.

The diagnostic cameraStart event distinguishes channelAdmission from callStart,
toggle, deviceSelection and recovery. The new enum value is appended so existing
codes retain their meaning. No camera driver failure is invented: this outcome
has no copied driver statistics, ID, label or error string.

## Qualification

- **580 tests passed, zero skipped**, across nine suites: direct media startup,
  direct-call FSM, media route operations/qualification, camera intent, group
  media/FSM/teardown and the diagnostic journal.
- All four new cases also pass with XVEIL_DIAGNOSTICS=true. They assert no camera
  start at refusal, active call/receive posture, camera OFF and its peer capture
  announcement, followed by a successful ON and exactly one new camera start.
  The real diagnostic JSON contains only the categorical admission failure;
  synthetic error text, camera ID, call ID and peer ID are absent.
- The existing actual AOT diagnostic artifact/flag/privacy control passes.
  `dart analyze lib test` reports no issues.

The initial fixture inspected the last signal even when an upgrade correctly
ended with a media-set signal rather than capture feedback. That null-capture
assertion was excluded; the corrected oracle selects capture announcements.
An initial related invocation named three nonexistent suites; those loader
failures were excluded and the final nine-suite run used verified file paths.

These are headless tests on macOS with TMPDIR=/private/tmp/. No app window is
opened/activated, no keyboard/mouse input is sent, and the existing user's Mac
app remains running. Native submodules, installed apps, engine pins and seeds
are unchanged; no native build, push or release is performed. Physical Windows
10 capture, the reporter's media channel and the original waiting-preview
complaint remain unqualified by this fixture.
