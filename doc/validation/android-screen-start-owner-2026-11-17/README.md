# Android pending screen start belongs to its media session

Base: `632136ad`. This addresses a locally reproduced Android controller defect,
not the cause of the Windows 10 camera complaint.

## Reproduction

An Android screen-enable first detaches/stops the camera, then requests screen
capture. Its `_screenStarting` future survived `_stopSession`. During a delayed
camera-plugin stop, normal hangup could therefore finish and release the actual
`CallSlot`, while that future remained pending. The next call became active,
but `_startAndroidCam` saw the old screen-start gate and silently declined to
start. Completing the old operation did not retry the new camera.

An Activity-free Flutter instrumentation probe ran on a physical Android 11
arm64 phone. It uses real `Platform.isAndroid`, controller, and (in two cases)
`CallService`/`CallSlot`. Engine/camera/transport and all platform device ports
are controlled. No private controller fields, platform overrides or new
production test seams are used; no physical media is captured.

The unchanged base produced **six assertion failures and three passing controls**
in the final nine-case probe. The two real-FSM cases use native-camera refusal,
plugin fallback, pending plugin-stop during screen enable, hangup and a new
connected call. The slot genuinely releases and the successor becomes active, but neither
native nor plugin successor capture starts. Additional controller cases exercise
native stop fences, same-call replacement and a replacement screen request.
Ordinary capture/hangup, hangup with no successor and retention of an already
running projection across a same-call route rebuild remain passing controls.

Early harness runs with missing embedding runtime dependencies, an incomplete
transport fake, and an APK kernel still selected instead of a staged kernel
are **not** red product tests. Qualified runs verified the SHA-256 of the actual
extracted kernel selected by this debug FlutterLoader before and after execution.
The real assertion-red run followed those corrections.

## Change

Teardown detaches the pending start synchronously after deciding whether an
already-running consented screen source may survive a same-call rebuild. Old
futures still finish and clear only their own request; they cannot suppress
successor capture or answer its screen-enable request. The detached plugin camera
also registers its stop in the existing per-engine retirement set. Hangup retains
the old engine and real call slot until that source answers; a new real call is
not admitted over its physical camera teardown. After release, a retry starts
capture normally. The controller-only independent-engine cases separately check
that old continuations cannot touch resources already owned by a successor.

The screen request also snapshots both camera owners before any stop await.
Otherwise allowing the successor to run would let an older native-stop
continuation read and stop the new plugin camera. Screen startup retains its
own source across its await and retires only that source on lost ownership;
old cleanup no longer clears/stops the successor through shared fields.

Native stop fences still hold their original engine until completion. No
MediaProjection grant is reused across calls; the existing same-call retained
source/rebind behavior remains supported. No timeout, codec, routing, wire,
permission or native dependency policy is changed.

## Verification

The checked-in [headless probe](../../../test/native/android_media_lifetime_headless/README.md)
passes **9/9** cases on Android after the change. The final nine-case source
also ran against the unchanged base: six assertion-red outcomes and three
controls, with no watchdog/timeout failures. The initial eight-case probe had
six reds/two controls and passed after the initial owner fix; the added retained
projection control passes on both sides. The real-FSM oracle was then extended
to require old camera/engine/slot retirement rather than permit early admission.

Two deliberate owner mutants of the earlier eight-case candidate each produced
one assertion failure: reading the replacement plugin after the old native
stop, and restoring shared-field cleanup after a retired screen-start reply.
The latter first exhausted an incomplete fixture's recovery-camera queue; that
run is not counted as assertion evidence. The corrected fixture permits normal
camera restoration and fails specifically on the new projection outcome.
A separate final-candidate mutant removes only the plugin retirement registration;
its two real-FSM cases fail while the other seven controls pass. Candidate bytes
are restored after each mutation.

**895 host tests passed, zero skipped**, across thirty call/media, camera,
projection, permission, resource lifetime, routing and widget suites.
**293 tests passed, zero skipped**, with diagnostics enabled in nine overlapping
suites; these counts are not added as unique cases. The first broad run exposed
an obsolete exact-call spelling in the host structural guard after the helper
acquired an epoch argument. Its lookup was updated without relaxing its ordering
assertion. Analyzer and whitespace checks pass.

The separate APK builder was exercised with actual SDK/D8/signing/installation
and its packaged probe passed all eight then-present cases. Later source/oracle
qualification, including the final nine-case runs, uses that same isolated
embedding with a verified app-private debug kernel. Its selected kernel SHA-256
is checked before and after execution; changing DartEntrypoint's bundle path
alone was not sufficient in this FlutterLoader. Only the dedicated QA package's
extracted debug kernel was replaced, never a user application. This is test
execution provenance, not a published application artifact or a release pin.

Host core/storage libraries match producer hashes and 1,144 Rust/Cargo inputs;
all 50 storage ABI checks pass. No Veil/storage/media native library is rebuilt.
Android's probe does not include these libraries: media/device ports are fake.
The default debug VM service cannot open a listener without INTERNET permission;
that expected harness log is not a media/network failure.

The source path being tested is Android control flow over synthetic adapters,
not actual Camera2/MediaProjection hardware behavior. Windows 10 capture,
notification delivery and the original contact-handshake complaint remain
separate. No desktop window is opened/activated and no OS input is injected.
Both owned QA packages are stopped/uninstalled with PID checks; user app install
metadata is unchanged and the existing macOS app remains running. Private debug
build intermediates are removed after qualification. No push or release.
