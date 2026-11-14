# Android secret-store persistence across process death

## Result

The corrected native persistence helper passed 40 fresh-process checks on an
isolated AOSP Android 15 ARM64 emulator (API 35). Both modes used the same APK:

| Native secret-store mode | Cycles | Fresh-process checks | Result |
| --- | ---: | ---: | --- |
| Ordinary quick-unlock namespace | 5 | 20 | Passed |
| Strong-biometric quick-unlock namespace | 5 | 20 | Passed |

Each cycle writes a synthetic encrypted value, kills the foreground process,
reads the exact value from a new process, kills that process, deletes the value,
kills again, and verifies absence in another new process. Every acknowledged
phase is followed by SIGKILL, including the verification phases. No Activity
stop/finish request is used before those kills. The driver checks the resumed
Activity, exact process identity, a new PID for every phase and process absence
after each kill.

The implementation is [QuickUnlockPersistenceAndroidProbe.kt](../../../test/native/QuickUnlockPersistenceAndroidProbe.kt),
with [the emulator driver](../../../scripts/test_quick_unlock_android_persistence.py).
The native helper, plugin encryption, preference files and Android Keystore are
real; no secure-store, cipher or commit adapter is replaced by a fixture in
this qualification. Values and keys are synthetic, and the QA package is separate
from xVeil. The application guard refuses to run outside that debuggable package.

## Protected mode

A virtual fingerprint was enrolled on this disposable emulator. The protected
mode uses the same strong-biometric/AES-GCM options as the application's secret
store. Every process checks the actual AndroidKeyStore key metadata: user
authentication required, no positive authentication-validity window, biometric
enrollment invalidation enabled and strong-biometric authentication type.
The driver supplies virtual fingerprint events to the system prompt; it does
not replace authentication with an application boolean or plaintext backend.

This qualifies emulated Android authentication and storage, not a person's
physical fingerprint, hardware-backed security or an OEM implementation.

## Provenance and scope

The isolated Debug APK compiled the actual 20 app Kotlin sources, seven SDK
Kotlin sources and 24 selected flutter_secure_storage 10.3.4 Java sources, plus
the QA Activity. The probe is only in a test source directory and its temporary
manifest; it is not a production launcher or exported production component.
The manifest harness initially needed its Android XML namespace preserved;
that harness-only packaging failure was corrected before any counted run.

Source inventories matched around compilation and both final runtime series.
Both installed APKs matched the selected local APK's SHA-256, recorded privately.
The runtime does not start Flutter, a node, media capture or any user container.
The existing Dart/native composition and refusal tests remain the separate
[persistence boundary qualification](../android-quick-unlock-persistence-2026-11-15/README.md).
The earlier ordinary-namespace-only exploratory series is not added to the
40-check final result.

The probe APK can be driven with:

```sh
python3 scripts/test_quick_unlock_android_persistence.py \
  --serial emulator-5580 --apk /path/to/qa.apk \
  --output /path/to/new/private-results \
  --aapt2 /path/to/android-sdk/build-tools/36.0.0/aapt2 --cycles 5
```

Use `--biometric` for the protected series after enrolling virtual fingerprint 1.
The driver requires an emulator named `xveil_persistence_qa`, verifies the fixed
debuggable QA package, and refuses an existing installation. It verifies the
installed APK, records only bounded per-phase public results, keeps raw command
output private, and stops/uninstalls only its own QA application on completion
or failure. Building the isolated probe APK and provisioning the emulator are
separate setup steps; this driver does not modify the production project or
silently create/download an Android image.

## Cleanup and limits

Both series verified process exit and uninstallation. The owned emulator exited;
ADB's transient offline entry was allowed to disappear without restarting the
shared ADB server. Its temporary AVD, downloaded image and private SDK copy were
removed, reclaiming approximately 2.4 GiB. No host SDK packages or user AVDs were
added or removed; physical devices and installed xVeil were untouched.

These are positive runs of the fixed implementation, not an unpatched A/B test.
Disk-write refusal remains covered by fault-controlled tests from the preceding
round; real device disk failure and power loss were not injected here. This does
not qualify the full Flutter biometric UI, physical devices, native media
shutdown, terminal-only erasure recovery or managed-storage migration/defaults.
Managed storage remains disabled. No installation on a user's device, push or
release occurred.
