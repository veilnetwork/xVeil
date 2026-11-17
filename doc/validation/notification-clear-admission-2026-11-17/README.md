# Notification admission must follow pending global clears

Base: `7fa424fc`. This fixes a reproduced Dart scheduling defect in the shared
notification wrapper, including the desktop incoming-call path. It does not
attribute the reporting user's missing Windows 10 banner.

## Evidence

cancelAll serializes global clear intents through `_nativeClear`; guarded posts
serialize independently by OS ID. A post requested after two clears could enter
between them. It returned true, but the second clear then removed its alert.
No delayed backend effects or elapsed-time assumption are needed: two new cases
use a backend that applies both show and clear immediately and returns ordinary
async completions. The locked Windows notification package 3.1.1 also wraps its
synchronous clear FFI call in an async Dart method; native history/banner delivery
is not part of these recording-backend tests.

DesktopCallNotificationBridge already checks readiness, but then awaits a local
caller label. Two widget cases use the real bridge, CallService and
NotificationService, with Windows window queries mocked as background. While
label lookup is held, they enqueue two real wrapper clears. The first backend
clear applies immediately, but its acknowledgement is gated; the wrapper cannot
start the second until that reply arrives. The old bridge posts while waiting,
so the second clear erases the incoming-call alert without another alert attempt.
The second widget case ends the call during the held acknowledgement.

The final new-case baseline has **11 assertion failures and two passing
controls**: nine failures/two controls in the service suite and two failures in
the widget suite. No tests fail by timeout or fixture load. Ordinary posting and
an already retired ticket remain passing controls. Other cases cover different
OS IDs, retirement during the barrier, additional clear intents queued during
the wait, and a retained clear failure with successful/failed recovery.

## Change

Both readiness and post admission share the existing clear-draining behavior.
A guarded post joins startup and pending global clears inside its existing
per-ID queue, then rechecks its ticket and the retained clear intent. If a clear
still failed, the post returns false without acquiring notification/reply
ownership. A later admission can retry that retained intent once, as readiness
already did; the backend is not reinitialized.

Existing per-ID ordering, different-ID concurrency after the barrier, retirement
cleanup, privacy modes and call retry limits remain unchanged. Global clears
requested after a post has entered the backend still retain their normal clear
semantics. There is no new timeout, permission prompt, native plugin change,
window activation or notification content.

Two deliberate mutants test the new guards: removing the post-wait ticket check
causes two assertion failures; ignoring the failed-clear intent causes one.
Candidate source is restored byte-for-byte after both runs.

## Verification and limits

**222 tests passed, zero skipped**, across eighteen notification, incoming-call,
window/tray, policy/payload/reply, caller-label and diagnostic suites. With
XVEIL_DIAGNOSTICS=true, **128 tests passed, zero skipped**, in seven overlapping
suites; these counts are not added as unique cases. The analyzer is clean after
three test-style findings were corrected; whitespace checks pass.

Host core/storage libraries match their producer hashes and 1,144 Rust/Cargo
inputs; all 50 storage ABI checks pass. No native build, dependency/pin change or
release artifact is made. Effects are recorded by the injected plugin behind
the real wrapper. All checks run with TMPDIR=/private/tmp/; no desktop app,
physical toast, camera, microphone, phone installation, user container, seed,
window activation or OS input is used. Test processes exit and the existing
user's macOS app remains running. No push or release.

The actual Windows 10 notification, camera and one-way-contact complaints
remain separate. These tests prove the wrapper/bridge ordering, not the cause
of an absent signal or a missing native banner on that machine.
