# Windows camera: terminal Source Reader flags

## Confirmed mechanism

The production MF camera loop checked the `ReadSample` HRESULT and end-of-stream
flag, but ignored `MF_SOURCE_READERF_ERROR`. A successful method return carrying
this flag could therefore trigger another read. With a simultaneous changed-type
flag and sample, the loop could also query the type and attempt conversion.

Microsoft specifies that after
[`MF_SOURCE_READERF_ERROR`](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/ne-mfreadwrite-mf_source_reader_flag)
the client must make no further Source Reader method calls. The HRESULT alone
is insufficient to implement that contract.

The loop now stops before type queries, conversion or another read. The existing
owning capture-thread teardown clears `running_` and releases the reader. This
does not add automatic restart, change negotiation, select another device or
alter the wire format.

This is a controlled native error-handling defect, not a physical reproduction
or attribution of the user's Windows 10 “waiting for camera” report.

## Red/green evidence

The existing native fixture includes the actual production capture loop and uses
a controlled `IMFSourceReader` with real MF type/sample/buffer objects. New cases
return `S_OK` with the terminal flag, both with a null sample and with a changed
type plus sample. Counters independently observe subsequent reader methods and
conversion attempts; the conversion stand-ins count and refuse attempts rather
than claiming to produce successful frames.

| Check | Previous source | Candidate |
| --- | --- | --- |
| Fatal flag, null sample | Two reads, one forbidden later method | One read, no later methods |
| Fatal flag, changed type/sample | Two reads, two later methods, one conversion attempt | One read, no later methods/conversion |
| Seven existing capture-loop controls | Pass | Pass |
| Five initial-format negotiation controls | Pass | Pass |

Both added cases fail assertions on the previous source; the capture-loop
runner exits 1 while the format control exits 0. The candidate passes all
**14 native checks**, both runners exit 0. MSVC builds with warnings as errors.
The ten transferred source inputs match their SHA-256 before and after both
credited runs. No skipped cases.

The supervisor's first observation retained assertion output but returned null
process exit codes. Its handle retention was corrected, and the unchanged
baseline was rerun before modifying production behavior. Only that rerun and
the final candidate are credited for exit status.

## Reproduction and limits

From an x64 Windows source checkout with MSVC/Windows SDK:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File third_party/veil/flutter/veil_media/test/run_mf_camera_change_smoke.ps1
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File third_party/veil/flutter/veil_media/test/run_mf_camera_format_smoke.ps1
```

These tests open no camera, app window or profile, and inject no mouse/keyboard
input. The real test host runs Windows 11; the source-reader behavior is injected.
No ordinary call, Windows 10 driver, visible preview or network is qualified by
this result. The existing application remains running and untouched.

The native runner and its supervisor bound child execution and remove their
owned compiler/source directories. No installed binaries, production relays or
user data change. The previously qualified private DLL predates this source fix;
a fresh full engine build, immutable pin and application package are still needed
before publication. No push or release occurs in this cycle.
