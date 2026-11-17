# Detached native stops still belong to their engine

Base: `7c28376d`. This closes a further local engine-lifetime gap left by
capturing the current session fields. It does not attribute the original
Windows 10 camera report or prove a physical native use-after-free occurred.

## Evidence

Camera selection and OFF remove the native camera from the controller before
awaiting stop. A later session teardown saw no source there and could dispose
its engine while that earlier native stop was still pending. The Camera2/JNI
fence was known to the command, but lost to engine teardown.

The controlled fixture holds the stop reply, ends the session and observes both
engine disposal and teardown completion. Native/plugin successor engines are
started and stopped while that first reply remains held: they must complete
independently. Two reentrant cases call teardown synchronously from inside stop,
matching the possibility of a preview-notifier listener running during a native
bridge's stop. A synchronous throwing-port control checks error propagation and
retirement cleanup.

The final base run has **ten assertion failures and one passing error control**:
eight new lifetime cases plus two strengthened rebuild cases. The first candidate
run exposed two older tests waiting for a rebuild before releasing its camera
fence. That order depended on the unsafe early disposal. The run was stopped;
the tester exited. Those two tests now assert that the old engine is retained
and the new video source has not started while its own fence is held, then
release it and require a successful native/plugin rebuild. They are included in
the final base failures, not treated as a passing timeout workaround.

## Change

Every native camera/video-source stop initiated by the controller records a
future under its engine identity, including selection, OFF, screen transition,
restart cleanup and full session teardown. Registration precedes invocation of
the stop method, so a reentrant teardown sees the fence immediately.

Engine disposal joins the recorded replies for that engine, including sources
already detached from shared fields. Another engine's pending source does not
block it. Completed records are removed on success and error. The original
command still receives its error; teardown retains its existing best-effort
handling. This tracks known stop completion, not proof that a failed platform
port actually detached its resource.

Two deliberate mutants check the important boundaries. Registering after the
stop invocation yields two reentrant assertion failures. Joining all engines'
records yields four unrelated-engine blocking failures, with two no-successor
controls passing. Both mutants are restored byte-for-byte before final tests.

## Qualification and limits

**809 related tests passed, zero skipped**, across twenty-four media/call,
camera/video lifecycle, rendering, network/grant, audio-route and route-operation
suites. With XVEIL_DIAGNOSTICS=true, **215 tests passed, zero skipped** across
six overlapping suites. These counts are not added as unique cases. The final
analyzer reports no issues.

Selected core/storage libraries match their producer hashes and 1,144 recorded
Rust/Cargo inputs. All fifty hidden-volume binding checksums match; binaries
remain unchanged after testing. No native build is performed.

These are headless real-controller/call-FSM tests with controlled source ports,
not physical Camera2/JNI, Windows 10 capture or a complete screen/video-renderer
integration matrix. No native ABI, protocol, codec or permission policy changes.
The independent renderer-start continuation and global audio-router lifetime
candidates still need separate qualification.

All Flutter runs use TMPDIR=/private/tmp/. No app window, focus change, OS input,
phone/installed-app change or seed operation is performed. No push or release.
