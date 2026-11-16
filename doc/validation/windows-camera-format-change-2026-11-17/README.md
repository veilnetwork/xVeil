# Windows camera: observe dynamic output without renegotiating it

Veil base: `5d9884a6`; fix: `8a44d344`. Confirmed source defect; no push, release or installed
application replacement. The original Windows 10 camera complaint remains
unattributed.

## Mechanism and fix

The actual Media Foundation capture loop handled
`MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED` by calling initial format negotiation
again with its previous dimensions. That operation can change the reader's
output for future samples. Reading back those newly requested parameters does
not describe the already observed format-change event or its current sample.
It also needlessly changes a readable new output back to the old profile.

Initial negotiation now retains its existing bounded NV12/YUY2/RGB32 fallbacks.
The change-event path only reads the current output subtype, geometry and signed
stride. If the changed output is unreadable, the existing bounded converter
recovery is retained, but the old sample is discarded. Only a later sample may
use the newly negotiated parameters. Failed recovery stops capture; compressed
bytes are not passed to an uncompressed converter.
No device fallback, permission change or camera selection policy is added.

This follows the separation between requesting output and observing its
[current media type](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-imfsourcereader-getcurrentmediatype)
in the [Source Reader API](https://learn.microsoft.com/en-us/windows/win32/medfound/processing-media-data-with-the-source-reader).
It does not assert why the reporter's preview remained empty.

## Controlled native evidence

The new Windows-only fixture compiles the actual production capture source,
including its real `CaptureLoop`, on the available Windows 11 host. A test-only
friend injects a controlled `IMFSourceReader`; Media Foundation media-type
objects are real. The reader emits a format-change event followed by EOF.
Metadata cases return null samples. The recovery case additionally supplies a
real MF sample/buffer containing synthetic opaque bytes, deliberately not an
image, to detect conversion of a stale sample. This tests metadata transitions
and sample admission, not pixel quality, a physical driver or network video.

The compile-only libyuv stand-ins count and refuse conversion attempts; they
never manufacture a successful frame. Header guards restrict them to this explicit test macro.
The normal production build does not use that include directory or friend.
No physical camera, microphone, preview window, profile or contact is opened.

| Case | Baseline | Candidate |
| --- | --- | --- |
| Unchanged stream/gap control | Pass | Pass |
| NV12 geometry change | Fail | Pass |
| YUY2 subtype/geometry/stride | Fail | Pass |
| RGB32 negative stride | Fail | Pass |
| Recovery skips the old-format sample | Fail | Pass |
| Unsupported output with refused recovery | Pass | Pass |
| Current-type read failure | Pass | Pass |

All four baseline failures are assertion failures after successful compilation.
Readable changes require zero new format requests and the exact observed
geometry/stride/subtype. Recovery keeps the original future-format negotiation
but must skip conversion of the old sample. The baseline attempts that stale
conversion once; the final candidate attempts it zero times. Recovery refusal
and query failure retain explicit stop/read-count controls. The final baseline
and candidate use the same seven cases.

An initial candidate passed the smaller metadata-only fixture but stopped on
unsupported output instead of retaining recovery. The added recovery control
rejects that intermediate source; this regression is separate from the original
baseline. The final implementation preserves the supported recovery path.

Final qualification: **12 native checks passed** (seven capture-loop cases and
five unchanged initial-negotiation cases). The latter cover:
exact NV12, unsized NV12, YUY2, RGB32 and bounded refusal. MSVC builds the
fixtures with warnings as errors. Ten transferred input hashes match before
and after each credited run.

Preparation failures are excluded: process policy first refused script
execution; stricter compilation then exposed two signed stream-enum conversions.
Explicit DWORD casts preserve those values. The credited baseline differs from
the base only by those casts and the inert test friend, before the behavior fix.
The script's execution-policy override applies only to its child process.

## Reproduction and limits

From an x64 Windows source checkout with MSVC/Windows SDK installed:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File third_party/veil/flutter/veil_media/test/run_mf_camera_change_smoke.ps1
```

The fixture runner creates an owned temporary directory, bounds its executable
with a process watchdog and removes compiler outputs after exit. The external
stand's transferred source copy is also removed after verifying its owner and
absence of live children. No app is launched or focused; no mouse/keyboard,
phone, installed package or production relay is touched.

This is a source fix. Existing media-engine pins and installed binaries do not
contain it. A new verified engine build/pin is required before publication;
source-digest checks must remain enabled. Physical Windows 10 capture, ordinary
call negotiation, rendering and the user's original failure remain open.
