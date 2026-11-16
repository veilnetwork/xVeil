# Windows camera fix: fresh native DLL and physical codec control

Veil `8a44d344` carries the [dynamic-format fix](../windows-camera-format-change-2026-11-17/README.md).
This follow-up builds and qualifies an isolated Windows x64 component containing
it. No installed application, published engine pin or production node is changed.
The original Windows 10 report remains unattributed.

## Producer and provenance

All ten native translation units are compiled and linked in a fresh output
directory using the repository's unchanged Windows wrapper builder. All 79
transferred producer inputs match their recorded hashes before/after building
and before teardown. The source digest matches the current checked-out native
tree. The selected WebRTC SDK matches the repository pin and its manifest's
libwebrtc SHA. Its pacing-header compatibility check remains enabled.

The first preparation attempt stops before compilation: the archived SDK setup
script nests its one-entry JSON command array under Windows PowerShell 5.1.
The private SDK copy removes only that outer array wrapper. Generated compiler
commands are then compared with the archived templates: extraction-path and
installed-header rebasing are allowed, every other compiler/ABI flag is
unchanged. Original/adapted setup hashes are retained privately. No global
PowerShell policy, installed SDK or product source is patched for preparation.

The resulting DLL is about 5.68 MiB, SHA-256:

```text
3bdf297ebdba389d9db29cf28fbe0be07f77918fa9d39f06826782fcb6647daf
```

Its recorded source/binary provenance verifies against the current native
source tree. The PE gate reports 107 exported names and 107 Dart lookup names;
all required media exports pass its existing sibling/optional rules. The
artifact private-pattern check passes. These checks are separate from
runtime capture and do not substitute for it.

## Physical control

The committed opt-in `windows_camera_dll_probe.py` loads the exact new DLL and
the explicitly synthetic transport shim from
`windows_camera_loopback_transport.cpp`. Two real native engines exchange
encoded/decoded video through callbacks in the same process. There is no real
Veil node, relay, authenticated peer, network call or application window.

For each profile the probe requires ten distinct local-preview updates and ten
decoded-frame updates before and after stopping/restarting the physical camera.
Both engines remain the same across that restart. Camera/video operations and
engine destruction must complete successfully. Native stats confirm an active
camera and muted microphone before final stop. Audio capture/playout is never
started; camera frames exist only in transient buffers and are not recorded.

| Requested profile | Local updates before/after restart | Decoded updates before/after restart | Datagram attempts |
| --- | --- | --- | ---: |
| 352×198, 15 fps, 150 kbit/s | 10 / 10 | 10 / 10 | 30 |
| 640×360, 60 fps, 900 kbit/s | 11 / 11 | 10 / 10 | 41 |

**Both physical cases pass, exit 0.** The requested FPS is not a measured capture
rate. Polling counts are not total encoded/decoded frame counts; datagrams also
include control traffic and attempts while a callback is absent. Progress after
restart does not attribute every decoded frame to a particular capture sample.
This is no speed/latency, packet-loss, image-quality or audibility comparison.

The DLL hash is unchanged after execution. The previously qualified runtime
files copied into the stand leave their source bundle unchanged. The probe has
its own process watchdog; the supervisor separately bounds synchronous FFI and
kills only its owned child tree if required. Loader-error dialogs are disabled
inside the probe process. No GUI is launched, focused or driven.

## Reproduction and teardown

From an x64 MSVC developer shell, compile the callback shim into an owned scratch
directory as `veilclient_ffi.dll`. Use a media DLL whose source/hash provenance
has already been verified and its matching runtime dependencies:

```powershell
python test/native/windows_camera_dll_probe.py --media-dll <candidate>/veil_media.dll --transport-shim <scratch>/veilclient_ffi.dll --use-physical-camera
```

The physical-camera flag is required; the camera indicator may light. CLI help
and refusal on a non-Windows host are separately checked before any native load.
Result JSON contains only categorical outcomes, configured profiles and numeric
progress counters; no device IDs, names, source paths or raw diagnostics.

Both Windows supervisors and all owned children exit. The temporary SDK,
producer source, compiler outputs and synthetic transport are removed after
source/native hash checks. A small verified DLL/provenance pair and private
qualification records remain locally for the next packaging step. The user's
existing macOS application stays running and untouched.

## Remaining scope

Normal physical capture, native conversion/encoding/decoding and camera restart
work with the newly built component on the available Windows 11 host. The
controlled native tests from the preceding report cover format-change events;
this physical camera run does not claim to provoke such an event.

The application controller, preference restoration, widgets, ordinary signaling,
real P2P/relay transport, an installed AOT package and the original Windows 10
camera/driver remain separate qualifications. The new DLL is private, not a new
published immutable engine asset. Engine repinning and final application
packaging remain required before release; source-digest guards stay enabled.
