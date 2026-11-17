# Pending Android group screen starts belong to their session and source

Base: `b36e35dd`. This addresses independently reproduced group-controller
ordering failures, not the original Windows 10 camera complaint.

## Evidence

The group handoff checked only media epoch after awaiting camera stop. Public
leave/replacement invalidated the session request immediately, but media epoch
changed only after teardown entered the lifecycle lane. A pending peer open
could hold that lane: the obsolete handoff then started screen capture and its
frame callback still admitted frames after leave. Separately, a late platform
start reply reclaimed the shared screen field, potentially stopping the next
call's projection. The pending-start future could also answer a successor's
screen-enable request.

Eleven tests on the unchanged base give **six assertion failures and five
passing controls**. They use actual GroupCallService, controller and CallSlot,
with controlled transport, camera, screen and engine ports:

- leave and same-call engine replacement while peer-open holds the lane and
  camera stop holds the screen handoff;
- source frames before/after leave while cleanup is still blocked;
- a pending platform start followed by leave, a new camera call, or a new screen
  call, including success/refusal/exception replies from the old start;
- current-session successful/refused/throwing starts, preserving the original
  exception contract and camera recovery after a normal refusal.

Source commands, frame admission, engine retirement, actual slot ownership and
service state are the oracle. No elapsed-time thresholds are used. Every held
reply is released and commands are joined in cleanup, including failing runs.

The initial suspicion that an old pending screen start prevented the next
camera from starting is **not confirmed for this controller**: that case passes
on the unchanged base. The confirmed gate failure concerns the next screen
enable, not the camera. An initial nine-case probe had four assertion failures
and five controls; the final probe adds the distinct gate and frame failures.

## Change

Handoff captures session request, engine and media epoch before its first wait.
It checks that owner before source admission and after the platform reply.
Initial screen startup passes its own owner to the same source helper. Commands,
source-stop callbacks and frames no longer gain authority from a still-attached
but retiring engine.

The helper retains its exact source across startup. A retired successful or
refused reply stops that source, never the shared field of a successor; it does
not clear the successor's sharing state. An attached old reference is retained
until that cleanup reply returns. Teardown detaches its pending-start future;
old finally blocks still clear only their own future. Thus a new enable starts
its own source rather than waiting for an earlier call's reply.

The existing exception contract remains unchanged. This is not a complete audit
of source-start exceptions or detached screen-stop lifetime. No permission,
native ABI, media pin, codec, signaling, membership or storage policy changes.

## Qualification and limits

**937 tests pass, zero skipped**, in twenty related call, group, source/capture,
slot, audio-policy, diagnostics and profile-lifetime suites. **487 pass, zero
skipped**, with diagnostics enabled in five overlapping suites; these counts
are not additive. Analyzer and whitespace checks pass. All **1,956 tracked
Dart/package-manifest inputs** retain their final-run hashes.

Three deliberate mutants fail as intended: retaining the old gate **1**,
restoring shared-source cleanup **2**, and admitting frames under the old
engine-only guard **1**. Mutants are restored before final testing. The final
baseline has six assertion-red cases and five controls, without load failures
or watchdog timeouts.

This is host execution of Android control flow against synthetic source ports,
not physical Camera2/MediaProjection or a real network call. It proves command
and frame admission, not the hardware stopping at a particular instant. The
original Windows 10 reports remain separate.

Tests use TMPDIR=/private/tmp/. No app windows, OS input, physical media, phone
installation, user container or seeds are changed. Test processes exit and the
existing user app remains running. No push or release.
