# Android direct-call camera refusal must reach the call state

Base: `f36c97c6`. This qualifies direct camera-control paths, not physical camera
capture or the original Windows 10 waiting-preview complaint.

## Confirmed mechanisms

The Android controller tried Camera2 and then its plugin fallback. If both
refused startup, the source disappeared without reporting failed camera posture.
The live call retained camera ON even though neither source was running. A
rejected initial camera permission also skipped capture without clearing ON.

The baseline uses the committed base plus an isolated camera-source/platform
adapter. Defaults still select Platform.isAndroid, AndroidNativeCallCamera and
AndroidCameraCapture with the original quality/selection/lifetime arguments.
This adapter enables the actual Android camera control branch on the host;
it does not model CallService, the media controller or their state propagation.
It is not an Android runtime or a real JNI/native capture test.

| Controlled base case | Result |
| --- | --- |
| Initial camera permission denied | Assertion failure: camera remains ON; no source opened |
| Initial Camera2 and fallback refuse | Assertion failure: camera remains ON |
| Toggle Camera2 and fallback refuse | Assertion failure: camera remains ON |
| Initial/toggle successful Camera2 or fallback | Four passing controls |

The combined baseline has **three assertion failures and four controls**. Native
sources and permission outcomes are explicit; asynchronous gates establish the
ordering, without a performance threshold. The candidate files were restored
byte-for-byte after the baseline overlay. An earlier run separately exposed the
two source-refusal cases, and an intermediate candidate exposed the still-
unhandled permission denial; these are not additional independent samples.

## Change

Owned Camera2/fallback outcomes now report success or refusal to the existing
scoped camera-feedback path. Failed fallback startup, including its exception
path, retires the source and records a categorical failure. Cleanup exceptions
retain the source's existing capture-lifetime retirement obligation.

Permission denial reports only while the same call/engine still owns camera ON.
It cannot reject an already installed newer camera source. CallCameraState's
optional denial callback obeys the same call, engine and current-intent guards
as permission-granted capture.

The service keeps the live call and video receive, switches the local camera OFF
and announces actual capture posture. ON can retry without replacing the engine.
Initial, toggle, selected-device and failed-share recovery use their corresponding
existing diagnostic origin. Private IDs, source exception text and camera pixels
are not copied into the anonymous journal.

## Qualification and limits

The direct-controller fixture has **24 cases**: permission denial/retry; successful
native/fallback and refused/throwing fallback at initial start and toggle; late
native/fallback answers after OFF, replacement capture or hangup. These use real
CallService and VeilCallMediaController with controlled source/transport engines.
They verify live/receive posture, actual camera flags and peer announcements,
refusal cleanup, retry on the same engine, and protection of a newer source.

Five additional CallCameraState cases verify that denial feedback is suppressed
after OFF, call end, engine replacement or another call. Existing permission and
camera-intent tests are retained.

**655 tests passed, zero skipped**, across fifteen related suites covering direct
media/FSM, media routes, camera intent, group media/FSM/teardown, both native
Camera2 bridge lifecycle suites, plugin capture/selection/retirement and the
diagnostic journal. All **24 direct cases also pass with diagnostics enabled**:
the actual JSON retains categorical outcomes, excludes private fixture text and
IDs, and late obsolete answers do not replace the current camera evidence.
`dart analyze lib test` reports no issues after a private factory-field rename,
an unused import removal and bracing a test assertion.

All tests are headless on macOS with TMPDIR=/private/tmp/. The injectable camera
choice is test-only; other Android platform services are not emulated by it.
No app window is opened/activated, no input is sent, and the existing user's Mac
app remains running. Native libraries, installed apps, pins and seeds are not
changed. Physical Android capture and the reporting user's Windows camera remain
separate checks. Nothing is pushed or released.
