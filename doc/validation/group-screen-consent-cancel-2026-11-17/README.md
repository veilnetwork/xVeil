# Initial group screen consent is cancelled before waiting for teardown

Base: `cb406542`. This fixes an independently reproduced group startup barrier,
not the original Windows 10 camera complaint.

## Evidence

When a group call started with screen sharing enabled, its serialized media
start awaited Android's screen-consent reply. Public stop invalidated the call
but queued screen cleanup behind that same start. The native stop needed to
cancel consent therefore did not reach Android until consent answered itself.

The existing Android handler already supports cancellation:
MainActivity.stopScreenCapture validates the session, retires its bridge,
cancels ScreenCapturePermissionActivity, answers pending start with false, then
waits for service stop before answering stop. No Kotlin change is needed.

Six tests run the actual GroupCallService, controller, CallSlot and
AndroidScreenCapture/MethodChannel adapter against controlled native replies.
The unchanged base produces **five assertion failures and one passing control**:
leave, dispose, reentrant dispose, late grant and stop error all observe zero
native stop requests before the start reply. Already-accepted consent passes.
There are no timing thresholds or watchdog failures. On assertion failure,
cleanup independently resolves both gates so the baseline is not left hung.

The native boundary validates the actual session argument. In ordinary cancel,
stop answers the pending start with false but retains a separate stop-reply
gate. Tests verify that the engine and competing lease remain unavailable until
that gate answers. A late true reply cannot restore an active call. An actual
bridge stop error preserves the existing best-effort teardown policy. Every
case observes exactly one native stop before final fixture cleanup.

## Change

Public stop captures and detaches its current Android screen source after
invalidating the session, then requests retirement without waiting for the
lifecycle lane. The existing retirement registry records the reply before
entering the source port. Android can therefore resolve consent while the old
start owns the lane, and serialized teardown can proceed after the reply.

Reentrant stop sees no shared source to stop again. The actual Android source's
in-flight stop is joined by late-start cleanup. Engine/slot release still waits
for its known reply, including already-running capture. Returned stop failure
remains best-effort and is not proof of physical shutdown.

No native code, ABI, media pin, permission policy, codec, signaling, membership,
storage layout or own-device mailbox policy changes.

## Qualification and limits

**954 tests pass, zero skipped**, across twenty related call, group, capture,
slot, audio-policy, diagnostics and profile-lifetime suites. **504 pass, zero
skipped**, with diagnostics enabled in five overlapping suites; these counts
are not additive. Analyzer and whitespace checks pass. All **1,956 tracked
Dart/package-manifest inputs** retain their final-run hashes.

A deliberate mutant calls source stop without retirement registration. The
accepted-consent control then fails because the engine retires before native
stop answers. The original implementation gives five assertion-red cases and
one passing control. All mutations are restored before final testing.

These are host executions of the real Dart Android bridge against controlled
platform replies. The Kotlin cancellation sequence is checked by source, not by
opening a physical consent Activity. No real MediaProjection, camera, microphone
or Windows 10 hardware is exercised; the original reports remain separate.

Tests use TMPDIR=/private/tmp/. No app windows, OS input, phone installation,
user container or seed is changed. Test processes exit and the existing user
app remains running. No push or release.
