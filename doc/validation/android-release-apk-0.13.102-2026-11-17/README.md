# Android release APK 0.13.102+121: package and installation qualification

## Actual inputs

The normal APKs come from tagged release run `44151584778`, Actions artifact
`14367820307`, source `7a322d5c315835cac77a6065bc9c027a6de25318`.
The downloaded archive matches its GitHub size and SHA-256. All three APKs
retain the approved Android signer and package `network.veil.xveil`.

| ABI | versionCode | APK SHA-256 |
|---|---:|---|
| arm64-v8a | 2121 | `c12c4f1c78597ada7a7d9d62be0473353a60f9c951f61eb5aeba8cd7e4c7e8e5` |
| armeabi-v7a | 1121 | `038dbaaf82e75f417da95c97def29714bcc4ef0a8b6988238fdd4ee932c74bb3` |
| x86_64 | 4121 | `523b63dbcef01eba8d5e8ef2ea746f308b7b12570b01e06f8dc1f81b59acecb6` |

VersionName is 0.13.102. Embedded media matches the current source-verified
engine pin exactly; speech-library architectures and required exports pass.
Normal AOT snapshots omit the detailed-diagnostics enabled marker. APK payloads
and ZIP metadata pass the private literal/regex and source-home URI checks,
subject only to the exact public-resource classification below. No signing
keystore or producer provenance record is embedded.

## Public MIME resource, not a private key

The first local regex scan rejects a key-header string in
`org/apache/tika/mime/tika-mimetypes.xml`. This is Apache Tika's MIME recognizer,
not key material. The complete 327696-byte resource is identical in the previous
official APK, the Maven `tika-core:3.2.3` JAR and the
[upstream 3.2.3 source](https://github.com/apache/tika/blob/3.2.3/tika-core/src/main/resources/org/apache/tika/mime/tika-mimetypes.xml).
Its SHA-256 is `e3f15ef4358674f773bfdbde2468684bccab76975479d6be7870a1702c0f99a4`.
The Maven JAR is also checked against its published SHA-1 sidecar; no PGP or
SHA-512 verification is claimed. The resource's independent exact SHA-256
comparison is the basis for this classification.

The operator checker exempts that one regex only for this complete resource
name and SHA. It still applies literal checks and every other rule, rejects
changed bytes or metadata, and treats scanner errors as failures. The private
policy file and APK bytes are unchanged. A failed attempt to fetch an absent
Maven SHA-512 sidecar and checks started before the resource proof existed
are not qualification passes or product failures. Repeated full normal-APK
verification passes after the exact public-resource proof is available.

## Installation and actual installed libraries

An owned ARM64 Android 14/API 34 emulator uses a separate loopback-only ADB
server restricted against physical USB devices, with no host window, camera
or microphone. Three sequential cases pass:

1. Official **0.13.101** installs. Its installed APK digest matches the verified
   download. The storage ABI negative control loads contract 30 but correctly
   reports one missing method out of the current 50.
2. In-place update to the exact verified **0.13.102** ARM64 APK succeeds. All
   **13** installed native libraries match their APK entries by SHA. The storage
   contract and all 50 method checksums match; the actual SDK contract hash
   matches. The cold process maps Flutter and the AOT snapshot, then stops.
3. Uninstall followed by a clean installation of the same verified APK passes
   the same native byte/ABI and cold-start checks.

The install runner compares actual library maps rather than hard-coding their
count. A later auxiliary audit initially assumes the old count of 12; correcting
that expectation and rereading both original installed-hash logs confirms all
13 current libraries. No installer or product guard is weakened.

The emulator and owned ADB process exit; all three reserved ports are independently
confirmed closed. The owned temporary image and AVD are removed. The existing
global SDK is retained and physical-device command count is zero. The separate
[actual storage-version transition](../android-storage-version-transition-2026-11-17/README.md)
also preserves two hidden spaces and their old/new payloads.

## Limits and publication

This is actual tagged normal-APK packaging and ARM64 installation qualification,
including an AOT process smoke check, not full onboarding, calls, every historical
migration, the affected HyperOS phone or the complete multi-device matrix.
The other two ABIs receive package checks rather than emulator execution.
The three diagnostic APKs subsequently pass signer/version/native/privacy
checks, enabled-report markers and absence of a raw log filename. All six
published APKs match the independently qualified Actions files, including
the exact installed ARM64 bytes. All ten release jobs pass.
[Final publication qualification](../release-0.13.102-2026-11-17/README.md).
No Windows 10 camera or ongoing-call network-handover complaint is declared
fixed by these results.
