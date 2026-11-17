# Group camera stops retain the lease while audio stops promptly

Base: `4a94518f`. This fixes the independently confirmed group case recorded in
the [direct-call cycle](../plugin-camera-stop-slot-2026-11-17/README.md#separate-confirmed-group-case-still-open).
It does not attribute the original Windows 10 camera complaint.

## Evidence

Group OFF and screen handoff detached the Android camera before awaiting stop.
The serialized session teardown then found no camera and could release the
actual CallSlot while that known reply remained pending. Startup-failure cleanup
had the same detachment gap. Separately, teardown of a still-attached camera
awaited its stop before issuing audio stop, delaying that command too.

Nineteen new cases on the unchanged base produce **15 assertion failures and
four passing controls**. They drive the real GroupCallService/media controller
and actual CallSlot with controlled group, engine and source boundaries:

- OFF, screen handoff and attached-camera teardown, with ordinary ending,
  reentrant disposal, concurrent disposal and close failures;
- failed-start cleanup after the room becomes active, including disposal from
  inside the source's stop callback;
- three real AndroidCameraCapture/CameraController cases against the existing
  controlled CameraPlatform, holding its dispose reply;
- old cleanup following a returned close error, while a distinct newer engine
  runs an audio-only room. Successful/failed late replies are controls.

Failures establish lease admission before the camera reply or a missing audio
stop command while close is held. Gates and actual competing lease acquisition
are the oracle, without elapsed-time thresholds. Accidentally acquired test
leases are released before assertions; every gate and pending command is joined
in cleanup. Late source frames cannot enter the ended room, and an old screen
handoff cannot create a screen source after leave.

## Change

Known Android-camera stop futures are registered under their engine before
invoking the source. This covers OFF, handoff, captured teardown and startup
cleanup. The lifecycle lane joins its engine's replies before disposal and lease
release, including sources no longer visible in the camera field. Completed
success/error records are removed; a late old-engine cleanup does not hold a
different engine. Group stop/start serialization remains in place.

Teardown binds the current engine and issues audio stop before camera or screen
waits. It retains the original best-effort policy after a returned failure;
a failed reply does not establish physical release. The existing screen-handoff
error contract is preserved. No permission, capture format, codec, native ABI,
media pin, signaling, membership policy or own-device mailbox behavior changes.

## Qualification

**889 tests pass, zero skipped**, across nineteen direct/group call, slot,
camera/source lifecycle, retirement, audio/source-policy and diagnostic suites.
With diagnostics enabled, **452 pass, zero skipped**, in five overlapping suites;
these counts are not added as unique cases. The analyzer and whitespace checks
pass. All **1,956 tracked Dart/package-manifest inputs** keep their final-run
hashes.

Three deliberate mutants give assertion failures: skipping the join **10**,
moving audio stop behind capture retirement **17**, and joining every engine's
camera records **2**. All are restored byte-for-byte before final testing.
The final group-only suite has **169 passing tests**.

The real-adapter cases execute the actual Dart I420 converter isolate. Each
verifies initialized/image-streaming controller state before the controlled
platform close, and the real isolate-exit notification before completed lease
release. The controlled platform emits no images; no physical camera is used.
The initial fixture omitted Flutter binding initialization and incorrectly
expected handoff errors to be swallowed. Both were corrected before the final
baseline. Eight test-style findings were also corrected.

All checks use TMPDIR=/private/tmp/. Test processes and converter isolates exit;
the existing user's Mac app remains running. No GUI window, focus change, OS
input, physical microphone/camera startup, phone installation, user container or seed
change is performed. Physical driver close, audible silence, real group network
calls and the original Windows 10 hardware are not qualified. No push or release.
