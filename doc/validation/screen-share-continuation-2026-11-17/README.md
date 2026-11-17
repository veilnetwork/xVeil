# One-to-one screen-share completion and camera hand-back

Base: `83579fe1`. This is a confirmed call-control defect found while reviewing
capture startup. It is **not attribution of the Windows 10 camera report**:
that device and its failing capture have not been reproduced here.

## Confirmed mechanism

`CallService.setScreenShareEnabled` retained a Call snapshot across asynchronous
source start/stop. On completion it published that old snapshot and, for a stop,
used the old camera flag to restore capture. In controlled service tests:

- A completed hangup's cleared slot became the old active call again.
- A replacement call was overwritten with the old call's state.
- Camera/microphone OFF chosen during the wait were overwritten in local state.
- An old stop completion invoked camera enable after service disposal; the
  existing `_set` teardown guard prevented publication but not that invocation.
- A refused stop was announced as stopped and invoked camera restoration.

These are application state and controller-invocation observations, not proof
of a physical camera opening, OS capture cancellation or media delivery.

## Change

Both start and stop must report success before the service claims a transition.
After waiting, the service checks disposal, the current live call and its ID,
then updates the current snapshot rather than replacing newer fields with the
captured snapshot. Hand-back uses the current camera intent. It goes through
the existing guarded camera-result path, so a refused/throwing camera start
updates unavailability instead of leaving the service claiming capture.

Another ownership check after camera restoration prevents a delayed completion
from announcing an unrelated replacement call's media set. Newer camera OFF
intent retains its existing operation-epoch protection. The source's actual
start/stop implementation and permission flow are unchanged by this FSM fix.

## Evidence

The corrected baseline subset has **eight assertion failures and 16 passing
controls**. Explicit completers hold media start/stop; fake time does not rely
on timing thresholds. Successful normal start/stop, failed start, OS-revoked
share, off intent, video upgrade and ordered renegotiation remain controls.

The first fixture had two invalid expectations: it expected an ended call to
remain in `current` (the service deliberately clears it), and expected capture
posture fields in a media-set renegotiation that does not carry those fields.
Those failures are not credited. Both expectations were corrected, the exact
base runtime restored, and only the repeated baseline is used above. The
candidate runtime was restored before its credited checks.

The expanded screen-share group has **30 passing cases**, including camera ON
chosen during a stop, camera restoration refusal/exception, and hangup,
replacement or newer camera OFF during the camera hand-back wait.

**394 related tests pass, zero skips**, across seven suites: CallService,
application media startup, camera intent state, route operation ordering,
desktop screen startup, call-screen permissions and structured diagnostics.
`dart analyze lib test` reports no issues. Unrelated formatter changes were
excluded from the diff.

## Scope and cleanup

This qualifies the one-to-one application FSM with controlled media outcomes.
It does not prove the underlying OS capturer has stopped, qualify concurrent
opposite source requests, or replace real camera/network testing. The current
Windows 10 "waiting for camera" complaint remains open; its prepared numeric
capture diagnostics and local native DLL qualification are described
[separately](../windows-camera-evidence-2026-11-17/README.md).

No GUI applications, focus changes, keyboard/mouse injection, native builds,
device capture, user profiles or remote machines were involved. Test processes
exit, the existing user application stays running, and no installed package,
phone, relay, push or release changes.
