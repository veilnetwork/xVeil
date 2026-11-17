# Refused Android camera choices must not replace a working preference

Base: `562d5296`. This is a separately reproduced Android selection defect,
not attribution of the original Windows 10 camera report or the earlier mirror
complaint.

## Evidence

Live Android selection saved the requested camera ID before stopping the old
source or opening the new one. If both Camera2 and the plugin refused that
choice, the preference remained the failed ID and the working old source was
not restored. The desktop selection path already preserved the previous choice
and attempted recovery.

Six exact-base controls produce **three assertion failures and three passes**.
The failures are the saved preference after refusal, for native recovery,
plugin recovery and unavailable recovery. Successful native/plugin selections
and selecting while the camera is OFF pass. These are assertions, not timeouts
or load failures. The fixture runs the real call service and media controller
with controlled engine, native-camera, plugin and transport boundaries.

## Change

A live Android choice now probes the requested device before persistence. If it
is refused, the controller attempts the previous choice once through the usual
Camera2/plugin chain. Temporary probe feedback does not disable the user's ON
intent before recovery can run. A recovered camera retains its posture; if
recovery also fails, the existing camera-unavailable event turns capture OFF
while keeping the call and receive pipeline alive. The rejected choice returns
false and never becomes the saved preference.

Both attempts retain the originating call, engine, media epoch, operation and
preference owner. Each attempt snapshots its requested ID for native and plugin
startup. A superseded answer retires its own source and cannot start fallback
or overwrite the newer selection. The preference owner/operation is checked
again after awaiting preference access. OFF and screen-owned choices retain
their existing deferred-intent behavior, without eagerly opening hardware.

No wire format, permissions, camera format, mirroring, native media binary,
automatic lens substitution or own-device mailbox policy changes.

## Qualification

- **732 tests pass, zero skipped**, across nine direct/group media, call FSM,
  camera-intent, teardown, overlay and diagnostic suites.
- With diagnostics enabled, **230 pass, zero skipped**, in three overlapping
  suites. Exported cameraStart evidence identifies selection/recovery and the
  final success category, excluding device IDs and the call ID. Counts from the
  two runs are not added as unique cases. Analyzer and whitespace checks pass.
- Ten added cases cover successful native/plugin selection, both recovery paths,
  unavailable recovery, OFF selection, and an outstanding recovery superseded
  by OFF, hangup, another selection or a profile-backend handoff. Controlled
  source gates establish the order without elapsed-time thresholds.
- Removing the attempt-owner predicate gives **one assertion failure and three
  controls**; permitting intermediate failure feedback gives **three assertion
  failures and two controls**. Both mutants are restored byte-for-byte before
  final ordinary/diagnostic testing, with unchanged source hashes.

An initial plugin-recovery fixture exhausted its camera factory when the list
API legitimately constructed an enumeration-only bridge. The fixture now keeps
enumeration separate from capture attempts. That error is excluded from the
baseline assertion evidence. One analyzer style finding was also corrected.

These are headless application control-flow tests, not physical Android capture,
an OEM permission check, a network video call or Windows 10 qualification. No
GUI windows, focus changes, OS input, camera/microphone startup, phone installs,
user containers or seeds are involved. All test processes exit; the existing
user app remains running. No push or release.
