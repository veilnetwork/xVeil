# Android installation report: native extraction

Status: **complaint; project cause not established**. A user reports xVeil
0.13.100+119 failing installation on Android 14 / HyperOS 1. The screenshot
contains `INSTALL_FAILED_CONTAINER_ERROR` and
`Failed to extract native libraries, res=-18`. The UI labels this as insufficient
space; that label alone does not establish an out-of-space condition.
The same user subsequently confirmed that 0.13.99 installs on the affected
phone while 0.13.100 fails, including after removing the application. This
version-specific failure is historical; the controlled results below do not
qualify its original device state. In a later update the user reports that
after removing the app, rebooting and creating a new identity under 0.13.99,
the original 0.13.100 installed as an update. Both diagnostic controls also
installed, but were tried after that reset. These simultaneous changes do not
isolate container size, internal free space or installer state. The original
failing container and installation log are unavailable.

## Android meaning

[Android 14 NativeLibraryHelper](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-14.0.0_r1/core/jni/com_android_internal_content_NativeLibraryHelper.cpp)
uses this result for failure to create the extraction temporary file, inflate
an entry, change its timestamp/permissions or rename the extracted file. The
underlying installer log and errno are needed to distinguish these paths.
The application and its encrypted container do not perform this extraction.

## Checks completed

The retained official arm64 0.13.100 APK matches its previously verified public
SHA-256 and passes signature verification and CRC checks of every ZIP entry.
The two official arm64 packages contain the same 466 ZIP entries. 0.13.100
is only **1136 bytes larger**; every native library has the same extracted size
as 0.13.99. There is no observed native-size increase supporting a larger
extraction-buffer explanation. This does not rule out content-specific OEM
behavior or a problem with the unverified downloaded copy.

All 12 arm64 ELF libraries are present. Together they require **71,479,432 bytes**
when extracted; all LOAD alignments are at least 16 KiB. These observations do
not establish the free space or integrity of the user's downloaded copy.

| Control | Result | Scope |
|---|---|---|
| Android 14 / API 34 arm64 emulator: original signed 0.13.99 | Installed | Baseline, no user identities |
| Same emulator: original signed 0.13.100 over 0.13.99 | Installed; 12 extracted SHA match | Exact released APK, no activity launch requested |
| Same emulator: clean original signed 0.13.100 | Installed; 12 extracted SHA match | Exact released APK, no activity launch requested |
| Physical Android 11: separate no-code package with original libraries | Installed; 12 extracted SHA match | Payload-only extraction, not full xVeil or HyperOS |
| Same separate Android 11 package: replacement | Installed; 12 extracted SHA match | Payload-only extraction, not full xVeil or HyperOS |

The first emulator control used the signing-baseline archive, whose actual
version was 0.13.94. Its version oracle correctly rejected that run; no
0.13.100 result from it is credited. The final three cases above used the
public-digest-verified 0.13.99 baseline and exact 0.13.100 asset.

## Diagnostic packaging controls

Two operator-signed diagnostic APKs were prepared from the exact 0.13.100
release: a repacked DEFLATE control and a control storing the native libraries
without ZIP compression. Both retain the original manifest, version and every
non-signature payload byte. Their certificate matches the published release;
no application-data removal is required to update 0.13.99. They are not new
releases or a proven product fix. Production packaging remains unchanged.

On a separate Android 14 emulator, the 0.13.99 baseline, compressed-control
update, stored-library update and clean stored-library install all passed.
The three diagnostic launches mapped Flutter and AOT, and all 12 extracted
native SHA matched the original 0.13.100. This is installation/loading coverage,
not call, container or HyperOS qualification. The repeated 0.13.99 baseline is
not an additional distinct product scenario. The no-launch flag inherited by
the private template was corrected against its recorded three activity starts.
Both diagnostic APKs passed the developer-private-data scan. They remain
available to the operator. The user reports both install on the reset phone;
this does not compare compression in the original failing state. Its emulator,
owned process group, ports and temporary image
were cleaned after the check.

## Remaining evidence and cleanup

The affected HyperOS phone, its downloaded APK digest, installation origin,
internal-volume free space and the installer log at failure are not qualified.
The user cannot provide the downloaded APK digest or recovery-key format.
The reported error is no longer observed after the user's reset, but its
cause is unproven and it is not declared fixed by 0.13.101. Re-download
verification and the exact NativeLibraryHelper error/errno can narrow it;
blindly changing packaging or compacting identity storage is not a diagnosis.

No product source, packaging policy, native library or container was changed
for this investigation. The physical probe had a different package ID, no
application code and no user container; it was uninstalled and the real xVeil
package metadata remained unchanged. The emulator exited, its owned ports
closed, and its temporary image/data were removed. Private logs remain outside
the repository; this report contains no operator identifiers or local paths.
