# Windows camera: validate layout before frame conversion

Veil base: `86a73c43`; fix: `33314eac`. The original Windows 10 camera complaint
remains unattributed. This is a native source/buffer-admission fix, with no GUI
launch, physical capture, installed-app replacement or release.

## Confirmed mechanism

The MF reader accepted an advertised stride shorter than a complete pixel row.
Deliver then checked buffer size using that stride and passed a wider image to
libyuv. A buffer could pass the length check while still lacking bytes that
conversion would read. NV12 additionally needs a full UV pair at the end of an
odd-width row. The type observer also narrowed unsigned dimensions to signed
integers without checking range and accepted INT32_MIN RGB stride, whose
negation is not representable in the previous signed arithmetic.

The source is a local driver/media buffer, not a remote message. The fixture
proves admission of invalid layouts to the conversion boundary; it does not
demonstrate a network exploit or execute an out-of-bounds pixel read.

The implementation uses the contiguous representation provided by
[IMFMediaBuffer::Lock / IMF2DBuffer](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/nn-mfobjects-imf2dbuffer).
Its signed default stride is described by
[MF_MT_DEFAULT_STRIDE](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-mt-default-stride-attribute).
Successful enumeration or sufficient total length alone does not validate a
particular row layout.

## Change

ReadCurrentFormat validates signed dimension/stride representability and the
minimum complete row for NV12, YUY2 and RGB32 before publishing any new fields.
Failed observation leaves the previous geometry available for bounded format
recovery. No arbitrary camera-resolution ceiling or different-device fallback
is introduced.

Deliver validates the complete source extent in wide arithmetic before resizing
I420 planes. This also avoids the previous DWORD multiplication for YUY2 size
checks. Chroma rounding, negative RGB offsets and aspect-ratio multiplication
use arithmetic that does not overflow the former signed intermediates. Packed,
padded and supported bottom-up RGB layouts retain their conversion paths.

## Native evidence

The Windows 11 console fixture compiles the actual production capture source
with MSVC /W4 /WX, real MF media types/samples/buffers, and the existing bounded
reader/conversion fixture. libyuv stand-ins count and refuse conversion; they
never access pixels, create an image or manufacture a successful video frame.

| Case | Base | Candidate |
| --- | --- | --- |
| Short NV12, YUY2 and RGB32 row | 3 failures: conversion attempted | Rejected before conversion |
| Odd-width NV12 with incomplete UV row | Failure: conversion attempted | Rejected before conversion |
| Width/height outside signed conversion range | 2 failures: type accepted | Type rejected |
| INT32_MIN RGB stride | Failure: type accepted | Type rejected |
| Packed/padded layouts, bottom-up RGB, complete odd-width UV row | Pass | Pass |
| Truncated source planes/rows | Pass | Pass |
| Existing dynamic-format, fatal-reader, diagnostics and initial-negotiation controls | Pass | Pass |

The credited base run has **seven assertion failures and 26 passing controls**;
the candidate has **33 passing checks**. Sixteen new cases extend the existing
capture fixture; the other seventeen checks retain prior loop/negotiation
coverage. Deliberately oversized metadata cases do not call Deliver on the old
implementation, avoiding unsafe allocations. Large-buffer allocation pressure
and pixel/color quality are not qualified by this fixture.

All ten transferred inputs match their hashes before/after both credited runs
and again before cleanup. Two earlier harness observations are excluded: native
nonzero stderr first escaped PowerShell's capture, and a subsequent observation
timed out. Owned process absence was checked before another run; the credited
runner uses explicit console processes, redirected output and watchdogs.
The transferred source directory was removed after owner/hash checks; no owned
process remained. No microphone, camera, preview window or input control was used.

The previous full private DLL was built from `86a73c43` and does **not** contain
this fix. A new verified full engine build, immutable pins and final packaging
are still required; source-digest checks must not be bypassed. Physical Windows
10 capture, the reporting user's driver and a network video call remain open.
Nothing was pushed, published or deployed to seeds.
