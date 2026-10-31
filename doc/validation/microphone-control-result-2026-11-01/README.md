# Refused microphone controls — 2026-11-01

## Confirmed defect

After successful audio startup, `VeilCallMediaController.setMicMuted` discarded
native `trySetMicMuted` failure and exceptions. `CallService.setMicEnabled`
optimistically changed `micOn` and announced that posture regardless. Only an
earlier receive-only startup flag could remute a failed unmute. A microphone
which became unavailable later therefore left the UI/peer claiming capture was
on. A refused mute could similarly be announced as successful.

The native implementation can change its microphone intent before reporting a
capture/worker error, so a failed operation is not proof that the entire native
state remained unchanged. The fix does not claim transactional hardware state.

## Change

- The media control returns acceptance/failure instead of `void`. Remembering
  intent before a session exists remains accepted; this is not proof of capture.
- Refused unmute explicitly closes capture intent again, marks input unavailable,
  and leaves the working receive path open. A later successful unmute clears
  that state and remains available without restarting the call.
- Refused mute retains the user's mute intent for route rebuilding. The error
  path never deliberately reopens capture to roll back a failed mute.
- The FSM restores its previous displayed/announced posture on refusal or
  exception. This conservative posture is not a hardware-state measurement.
  Call/operation guards prevent an older result overwriting a newer mic action,
  changing a subsequent call, or announcing capture after hangup/dispose.
- Opt-in anonymous reports retain `microphoneControl`: requested `enabled` and
  `success` only. No call/device identifiers, exception strings or paths.

## Evidence

- Four tests through the real controller fail on the old implementation:
  mute/unmute, each with native false or exception (expected false, received
  null). Existing four startup tests still pass as baseline controls.
- Restoring only the old FSM method while keeping the typed media contract
  makes all five targeted tests fail: four posture cases and an older operation
  overwriting a newer failed unmute. No timing thresholds are involved.
- Final opt-in suite: **244 passed**, covering controller startup/control,
  real-controller same-call route rebuilding, FSM/peer capture, deferred
  permission state and anonymous diagnostics. Two rebuild tests verify capture
  stays muted after refused mute/unmute despite a stale initial call snapshot.
- Three additional dependent suites: **21 passed** (peer mute, notification
  action, call-log convergence). Dart analysis of five changed files is clean.
- Normal/opt-in standalone AOT privacy verification passes with the new retained
  event. An initial suite invocation named a nonexistent overlay test; it is not
  counted. The final invocation lists only actual test files and passes.

This fixes proven result propagation and stale-result behavior, not the proven
cause of the owner's Poco → Windows no-audio report. Late permission callbacks
are a separate path; this change does not assert that every asynchronous input
failure is already reflected by the UI. No native SDK/engine change or new pin.

Follow-up: [late permission/capture callbacks](../late-microphone-permission-2026-11-01/README.md)
are now connected to call-scoped mic-off notification with stale-generation
guards and peer announcement. This extends the earlier synchronous fix.

## Phone check

Poco is present and authorized in ADB. The system policy initially inspected
belongs to another Android user/profile and is not evidence about user 0.
A direct install of the existing separate QA package for user 0 was then
rechecked and again ended with `INSTALL_FAILED_USER_RESTRICTED: Install canceled
by user`. Its package ID differs from the main application; the main app/data
were not replaced, security restrictions were not bypassed, and network settings
were not changed. No phone QA process or desktop stand was launched in this
round. NETCALL-01 and the actual phone-to-Windows call remain unqualified.

Project changes are local only, without push/release. Private test/ADB logs are
not copied into this document.
