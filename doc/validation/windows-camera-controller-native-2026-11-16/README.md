# Windows camera through the application controller

The available Windows 11 computer passes the actual `VeilCallMediaController`
startup path with a physical camera and the pinned native engine. This extends
the earlier [C ABI control](../windows-headless-camera-2026-11-16/README.md), which
bypassed the application's preferences, audio startup, video admission and Dart
preview timer. It does not reproduce or close the reported Windows 10 failure.

## Method

An opt-in Flutter test instantiates the production controller and real
`VeilMediaEngine` objects. Its factory only retains the real sender for stats
assertions. SharedPreferences is replaced with an in-memory store before use;
no installed profile or saved device choice is opened.

The transport is explicitly synthetic: only channels 42/43 are available. Its
separate DLL delivers native datagrams to the peer callback in the same process;
no real node, relay, authenticated session or network call is created. Direct
route-probe admission is simulated to select the direct controller profile.
The receiver starts the real native decoder. Local evidence comes from the
application's `localVideoFrame` notifier, not a direct native preview read.

For each profile the test requires at least ten local preview updates and ten
fresh decoded frames, switches the camera off/on through the controller, then
requires ten additional updates/frames on both sides. The Dart SDK getters
filter unchanged native frame sequences. Camera start and restart must succeed;
final native stats require a running camera and a muted microphone. Teardown
must close the owned channel and clear the application's preview notifier.

The synthetic peer explicitly advertises that it captures neither audio nor
video. The sender's microphone stays muted. No images, camera frames, video or
audio are saved. Only frame/packet counts, dimensions and categorical results
are exported. This is not a test of human audibility or screen painting.

## Final results

| Controller profile | Local preview updates | Receiver decoded frames | Native datagram attempts | Preview size |
| --- | ---: | ---: | ---: | --- |
| Anonymous | 155 | 20 | 85 | 352×198 |
| Direct | 310 | 20 | 82 | 640×360 |

Both restart checks and both mute/capture assertions pass. Counts cover the
whole case, not FPS, loss or latency; the packet counter includes native control
traffic and attempts rejected when the peer callback is absent. The observer
polls decoded frames, so its count is not the decoder's total frame count.
There is no A/B performance claim.

The final run verifies **706** staged application/test/resource input hashes
before and after execution. The transport shim has a separate source hash and
is compiled with MSVC. The actual media DLL matches the retained, independently
qualified Release archive before and after use; that archive's media comes from
`engine-2026.11.12.2`. No installed package DLL is replaced. The test uses a
frozen SDK/dependency configuration from that qualified Windows workspace.

Preparation history is kept separate:

- An initial asset-bundle refusal omitted required application resources; no
  camera test ran and it is not a product failure.
- An earlier anonymous-profile control and an earlier two-profile control pass.
  They did not explicitly advertise the synthetic receiver's mute state and are
  not used as the final table or as performance baselines.
- A fresh final workspace stalled in SQLite hook preparation. Its outer
  watchdog stopped that owned process tree before the camera test ran.
- The credited final run reuses the already prepared two-profile workspace,
  verifies all original inputs, updates only the test's receiver-capture field,
  records the new input manifest, and verifies those inputs after the run.
  Production code, dependency hooks and their configuration are not weakened
  or bypassed to obtain the pass.
- Analyzer: no issues in the committed Dart test. At the ordinary opt-in-off
  default, both physical cases are **skipped**, not counted as passed.

No application window, tray action, focus operation, mouse/keyboard automation,
phone operation or system camera setting is used. All owned test processes exit;
transient Windows workspaces are removed after collecting private evidence.
The user's existing application and retained qualified package stay unchanged.

## Reproduce

Use an x64 MSVC developer shell, an owned temporary directory and the verified
media DLL from a matching Windows build. Compile the callback shim there as
`veilclient_ffi.dll`; never copy it into an installed application:

```powershell
cl /nologo /std:c++17 /EHsc /O1 /MD /LD <repository>/test/native/windows_camera_loopback_transport.cpp /Fe:veilclient_ffi.dll
```

Point `VEIL_MEDIA_DYLIB` at the verified media DLL, and both `VEIL_FFI_DYLIB` and
`XVEIL_CAMERA_STUB_DLL` at the synthetic DLL's absolute path. Put its directory
first in the child process's PATH, with the matching Visual C++ runtime files.
Then, from the disposable Flutter workspace:

```powershell
flutter test --no-pub --concurrency=1 --dart-define=XVEIL_NATIVE_WINDOWS_CAMERA_TEST=true test/native/windows_call_camera_native_test.dart
```

The test refuses a core DLL without the explicit shim counter export. Use an
external process-tree watchdog in addition to the Dart timeout: synchronous FFI
can prevent Dart timers from firing. Remove only owned files after every child
has exited. Normal CI must leave this physical-camera opt-in disabled.

## Remaining scope

This covers current application controller code, the two camera profiles,
physical capture, native encoding/decoding and camera off/on on this host.
It does not cover the reporter's Windows 10 camera/driver, ordinary CallService
negotiation, the preview widget, desktop notification visibility, real relay/P2P
transport, or an installed AOT call. Existing categorical camera-start,
capturing and preview diagnostics remain the mechanism for a new report from
that computer. The Windows 10 complaint remains open. No release or push occurs.
