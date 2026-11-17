# Group audio stop does not wait for a pending peer open

Base: `e8a9fa92`. This extends the
[camera-retirement correction](../group-camera-stop-slot-2026-11-17/README.md):
that change stopped audio before capture cleanup once teardown entered the
lifecycle lane. It did not address waiting to enter that lane.

## Evidence and change

A roster update can own the serialized lifecycle lane while awaiting
`transport.open`. Public `stop()` invalidated the session immediately, but its
audio-stop command remained queued behind that open. The real group controller
therefore kept the command pending even after the service marked the call ended.

Seven new tests fail by assertion on the unchanged base, without timing
thresholds. Five exercise successful, refused, throwing and reentrant stop
replies, plus a queued replacement start. Two use the actual GroupCallService
and CallSlot for leave/dispose. Each first starts audio, then holds the peer-open
reply. Before releasing it, the tests check the stop command and retained engine
ownership. The service cases also attempt a competing direct-call lease. After
release, the late channel is closed without adding its peer, the engine is
disposed, and the slot becomes available. Gates and commands are joined in
cleanup even when an assertion fails.

Public stop now requests audio stop before waiting for the lifecycle lane. The
engine identity is recorded before entering the synchronous port, so reentrant
stop cannot issue a duplicate command. Only a successful reply suppresses the
cleanup attempt: refusal or exception permits a retry. Teardown still requests
stop for implicit replacement, and clears the identity after retiring its engine.
Engine disposal, channel reclamation and slot release remain serialized.

Source inspection also rejects an upstream suspicion: GroupCallService.leave
already sends its leave signal without awaiting delivery. No signaling change is
needed here. This patch does not alter native code, media pins, codecs,
permissions, membership checks, storage or own-device mailbox policy.

## Qualification and limits

**896 tests pass with zero skipped** across nineteen related call, group,
camera/source, slot, audio-policy and diagnostic suites. A diagnostics-enabled
run passes **459 tests with zero skipped** in five overlapping suites; these
counts are not additive. The analyzer and whitespace checks pass. All **1,956
tracked Dart/package-manifest inputs** retain their final-run hashes.

Two deliberate mutants confirm the guards: recording the stop identity after
the port causes one assertion failure; suppressing retries after a refused or
throwing stop causes two. The original implementation produces seven assertion
failures. All mutations are restored before the final runs.

These are real controller/service executions with controlled transport and
engine ports. They establish command ordering and ownership, not physical
microphone shutdown, audible silence, hardware-driver behavior, or the cause of
the original Windows 10 reports. Returned stop failure remains best-effort;
the patch does not claim successful physical shutdown after that failure.

Tests use TMPDIR=/private/tmp/. No app windows, OS input, microphone/camera,
phone installation, user container or seed change is involved. Test processes
exit and the existing user app remains running. No push or release.
