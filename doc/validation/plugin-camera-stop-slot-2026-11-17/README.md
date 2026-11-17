# Pending camera stops must retain the direct-call lease

Base: `46cbbc51`. Two independently reproduced completion gaps affect the
direct-call slot. Neither attributes the original Windows 10 camera report.

## Evidence

OFF, device selection and startup cleanup detach the plugin camera before
awaiting its stop. Session teardown no longer saw that source and could finish
while its known stop future was pending. The real CallSlot then admitted a
competing group-call lease. The previously tracked Camera2 stops already had an
engine-associated barrier; these plugin paths bypassed it.

A second gap survives fixing those paths: hangup waits on the first media stop,
but concurrent dispose calls stop again. The direct controller has detached its
engine, so the second stop can return and release the same lease before the
first completes. A synchronous callback from inside the media stop also
reproduces this ordering.

The final unchanged-base run has **12 assertion failures and four controls**:

| Case | Base result |
| --- | --- |
| Plugin OFF/selection, ordinary/reentrant ending and concurrent dispose | Six slot-admission failures |
| Startup cleanup, ordinary/reentrant ending | Two slot-admission failures |
| Real AndroidCameraCapture / CameraController, held CameraPlatform.dispose | Two slot-admission failures |
| Media stop synchronously disposes its service, successful/failed reply | Two slot-admission failures |
| Plugin stop error handling | Two passing controls |
| Distinct calls in standalone wiring without a global slot | Two passing controls |

The real-adapter cases use the existing controlled camera platform, not a
physical camera. Initialized/image-streaming state is checked before OFF or
selection. The platform disposal gate remains held through hangup; only its
release permits cleanup. Other cases use controlled source ports. Assertions
use actual lease acquisition, with every accidentally acquired test lease
released before reporting failure. No elapsed-time threshold is the oracle.

## Change

All three detached plugin-stop paths now use the existing engine-associated
stop registry. Registration precedes invoking the source, including synchronous
callbacks. Teardown joins the known reply; successful and failed replies remove
their registry entry. Audio stop remains before this wait. Existing best-effort
error handling is retained: a failed port reply is not proof of physical release.

CallService publishes a shared completion before entering its media-stop port.
Repeated ending/disposal of that call joins the pending stop. Completion
releases only its captured lease and clears only its own pending record. The
call ID is captured before dispose clears current state, preserving distinct
teardown ownership in standalone wiring which omits the global slot.

An intermediate coalescer incorrectly joined a newer standalone call's dispose
to the old call. One assertion failure and one unchanged hangup control exposed
this; capturing the disposing call's ID fixes it. Early fixture error-handling
and declaration errors were corrected and excluded from baseline evidence.

Four deliberate mutants establish the guards: late source registration gives
three assertion failures, late service registration two, ignoring call scope
two, and omitting dispose's captured ID one. Every mutant is restored
byte-for-byte before final tests.

## Qualification and limits

**820 tests pass, zero skipped**, across seventeen direct/group call, slot,
camera/source lifecycle, capture-retirement and diagnostic suites. With
diagnostics enabled, **246 pass, zero skipped**, in three overlapping suites;
the counts are not added as unique cases. The analyzer is clean and all
**1,956 tracked Dart/package-manifest inputs** retain their final-run hashes.

The tests qualify control-flow and lease ownership. Physical Android driver
release, audible speech, native pointer safety and the original Windows 10
hardware are not qualified. No native ABI, media binary/pin, codec, permission,
wire format or own-device mailbox policy changes.

All tests use TMPDIR=/private/tmp/. Test processes exit; the existing user's
Mac app remains running. No GUI window, focus change, OS input, camera/microphone
startup, phone installation, user container or seed change occurs. No push or
release.

## Separate confirmed group case, still open

**Subsequent update:** this was the status at the end of the direct-call cycle.
The [separate group fix and qualification](../group-camera-stop-slot-2026-11-17/README.md)
now close this mechanism locally. The observations below retain its baseline.

An isolated probe using the current GroupCallService and
VeilGroupCallMediaController confirms the analogous detached Android-camera
stop gap in the group path. With OFF's source-stop gate held, leave completes
and the actual CallSlot admits a direct-call lease. The probe has one assertion
failure, releases its gate, joins the command and disposes its services. Its
source/result remain private; it is not included among the passing tests above.

Group media uses a serialized lifecycle lane, so its repair was left for separate
qualification. That later cycle retains known camera stops and issues audio
stop before capture waits. No physical group-camera failure is established by
either cycle.
