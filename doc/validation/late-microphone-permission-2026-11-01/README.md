# Late microphone permission and capture failure — 2026-11-01

## Confirmed defect

Android starts the receive path while its microphone prompt is pending. A late
denial previously did nothing to capture posture. A granted permission followed
by refused/throwing native capture only logged failure; an exceptional permission
future also only logged. The engine could remain receive-only while the FSM/UI
and peer still treated the microphone as enabled. The synchronous toggle fix
did not cover these callbacks.

Four tests on the real media controller reproduced this discrepancy before the
fix: denied permission, native false, native exception and permission exception.
Each expected unavailable input after completion but observed false. The tests
inject a deferred permission gate and fake native devices; no hardware or
elapsed-time thresholds are used. The platform gate factory defaults to the
existing Android-only policy in production.

## Change

`CallMicrophonePermission` now reports a current denial as well as a grant.
The controller closes capture intent on late failure, marks input unavailable,
and emits a local call-scoped notification. Its callback checks call, engine and
media generation before touching state or issuing a native command. Closing a
broken native device is best effort; this is not a hardware privacy guarantee.
Working receive audio is retained and a successful granted unmute clears the
unavailable flag.

The FSM accepts the notification only for its live current call while the
controller still reports input unavailable. It sets mic-off and announces that
posture to the peer. The operation counter invalidates older pending toggles,
including an optimistic mute whose late failure would otherwise restore mic-on.
Events queued before a successful retry and events for other calls are ignored;
the subscription is cancelled on dispose.

Only the existing opt-in `microphoneControl` outcome and permission category
enter diagnostics. The local event's call ID is not journalled or exported;
provider exceptions are not stringified by the failure callback.

## Verification

- **279 tests passed** with diagnostics enabled: actual media controller,
  microphone permission/state, FSM, peer mute, notification actions, call-log
  convergence, output diagnostics and journal. Additional final FSM checks pass
  after removal of an unnecessary null-aware operator.
- Coverage includes all four reproduced failures, successful late grant,
  keeping receive alive, stop/new-call/new-engine boundaries, stale notifications
  after retry, peer capture announcement, and invalidation of a pending toggle.
- Dart analysis of all six changed source/test files is clean. Normal/opt-in
  standalone AOT privacy verification passes.
- An updated separate Android QA APK is prepared with the accumulated Dart
  fixes. All three Veil/HV/media ARM64 libraries match the published input
  byte-for-byte; copied Dart source digests match the current worktree. The
  external-filesystem watchdog stayed valid and both owned build processes
  exited. This is build qualification, not a physical permission/call test.
  It is a private stand profile with authenticated hooks/developer logging,
  not a public diagnostic-distribution artifact. Only allowlisted reports are
  suitable for sharing; its private logs are not exported into those reports.

No desktop/phone stand app was launched in this round. Poco installation remains
blocked by the explicit installer refusal recorded in the preceding round; no
identical install retry, security bypass or network change is part of this one.
The main app/identity are not replaced. The original phone → Windows report and
NETCALL-01 remain active and unqualified on the candidate.

No push/release or native ABI/engine pin change. Existing delayed-complaint and
multi-device/performance work is not declared complete by these tests.
