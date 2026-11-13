# Windows camera: bounded anonymous source probe

The reported Windows 10 camera failure remains open. Enumeration succeeds but
the application preview waits for camera/video. The available machine runs
Windows 11; a successful capture there does not qualify the original device.

## Tool

`scripts/probe-windows-camera.ps1` compiles and runs a separate Media Foundation
probe. It never opens an xVeil profile, changes camera permissions or ACLs,
records media, connects to peers or uploads a report. Close xVeil and other
camera applications first: exclusive ownership by another app is a separate
cause of activation failure. The camera indicator may light during this test.

Run from a source checkout with MSVC x64 build tools and Windows SDK installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/probe-windows-camera.ps1
```

The execution-policy option applies to this process only. The script does not
change the system policy. The source tool is not an installer or an embedded
diagnostic export; it requires build tools and is not a prebuilt end-user asset.
`-CameraIndex 0` is the default ordinal, with a maximum of 15. Names and device
IDs are neither requested nor reported. Enumeration order is not guaranteed to
match xVeil's saved camera choice; selecting the same ordinal is not proof of
the same physical source across separate enumerations.

The probe uses the exact production `veil_mf_camera_format.h` negotiation helper
from the pinned SDK. It counts at most eight nonempty OS samples. It does not
convert them to I420, encode video, or prove app capture, transmission, rendering
or visible image quality. Format-request refusal is reported directly; the
application's subsequent native-default inspection is not reproduced here.

The anonymous output allows only schema, numeric stage/HRESULT, camera count
capped at 16, sample count capped at 8, and the cap flag. Unknown fields are
discarded; malformed values are rejected without driver text. Compiler output
is separate operator-only verbose information and is not part of this report.
No device names, paths, network addresses, profile identifiers or pixel data
are present in the report.

| Stage | Meaning |
|---|---|
| 0 | At least one nonempty OS sample received |
| 1–2 | COM / Media Foundation startup failed |
| 3–5 | Capture attributes / enumeration / selected ordinal unavailable |
| 6 | Source activation failed |
| 7–8 | Source-reader attributes / reader creation failed |
| 9 | Requested uncompressed format refused |
| 10 | Sample read or sample-length query failed |
| 11 | No nonempty samples before completion |
| 12 | Process watchdog expired; a timeout report replaces native output |

Stage 5 or 11 may carry HRESULT zero: that means no failed HRESULT was
returned, not that capture succeeded. A process-wide 10-second watchdog covers
activation, synchronous read and teardown. The PowerShell parent also bounds
the child wait and cleans its generated executable/object/log directory.

## Evidence

On the available Windows 11 machine (build 26300):

- 15 report checks passed: numeric HRESULT retained, extra private fields
  omitted, malformed types/ranges and false success rejected.
- The real native watchdog terminated a stalled fixture with exit code 124.
- Index 0 returned stage 0, HRESULT 0, one enumerated camera and eight nonempty
  samples. No video was recorded or sent.
- Index 15 returned stage 5 and zero samples, rather than silently choosing a
  different device or treating enumeration as successful capture.
- MSVC compiled with warnings as errors. Source-file hashes, including the
  production format helper, were checked after transfer before execution.
- The temporary checkout and generated files were removed. No camera-probe
  process remained. No xVeil stand/application instance was launched.

Earlier attempts did not qualify capture: execution policy initially refused
the source script; subsequent builds exposed missing deterministic-pathmap and
WinRT include setup, then a signed-enum conversion rejected by `/WX`. These
were corrected before the credited native runs. The report-only tests had
already passed, but were not counted as physical capture qualification.

The tool is a local committed diagnostic addition, not a release or camera
fix. Existing media binaries, source pins, application storage and production
seeds remain unchanged. The original Windows 10 needs its own capture result
and xVeil diagnostic export before attributing the failure to OS capture,
conversion/encoding or transmission.
