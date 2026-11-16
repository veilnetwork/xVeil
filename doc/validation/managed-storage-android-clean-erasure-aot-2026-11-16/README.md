# Android release/AOT: ordinary profile erasure

Status: ordinary full-profile erasure, with a complete real saved entry and no
injected failure, passes on the fixed hook-free Android release. The preserved
profile subsequently cold-opens its original identity and note. Production
managed storage remains OFF; this adds a specific packaged scenario rather
than completing every platform/crash qualification.

## Existing artifact and fixtures

The exact fixed release/AOT APK from the
[interrupted-erasure qualification](../managed-storage-android-erasure-aot-2026-11-16/README.md)
is reused without rebuilding or reinstalling it. All 3,045 current product
inputs, the retained APK and its installed digest match the prior qualification.
The headless Android 15 AOSP ARM64 emulator retains the synthetic system PIN
and enrolled virtual fingerprint. No Mac window or physical phone is used.

The selected named profile has an encrypted identity, one note and a complete
biometric-only saved entry. The default profile contains the unencrypted
identity/note created after the previous erasure. Before deletion, normal cold
entry into the named profile uses exactly one CryptoObject-bound request; the
ordinary drawer and Saved Messages show its full original identity and exact
single note. Both public and protected saved-entry records must be present.
This prevents an empty or previously partially erased fixture from passing.

## Normal deletion and cold restart

After a verified process exit, the normal lock screen offers Clear all data.
The whole-profile explanation and exact typed confirmation are checked before
Delete forever. Directory permissions remain normal; no OS adapter, storage
result, application controller, timeout or fault boundary is substituted.

The ordinary action reaches positive fresh onboarding without a failure modal
or biometric request. Independent checks establish:

- all five encrypted identity payload/role paths are absent;
- the public entry and protected entry are both absent;
- the default profile's managed files and profile preferences remain byte
  identical before reopening;
- all eight protected-namespace files outside the removed protected data file
  remain byte identical, including its wrapping-key/configuration dependencies;
- the OS preference-file inventory is unchanged;
- the pending plan, native completion marker and application journal are absent.

The named profile is then force-stopped and cold-started again. Fresh onboarding
is still visible, no saved record is resurrected, no marker remains and the
default profile's files still match. This is a normal application restart after
a successful wipe, not a simulated device power loss.

## Usable preserved profile

Normal onboarding creates an explicitly unencrypted replacement identity in the
cleared named profile, with a fresh certificate and discovery declined. This
provides the ordinary Settings route back to the existing default profile;
no installation pointer or application state is edited externally.

A subsequent cold, no-password entry into the default profile shows its exact
pre-deletion full identity and single note. The erased named profile's old note
is absent. No OS saved record is recreated during either plaintext onboarding
or the preserved profile's reopening. UI XML is an identity/content oracle,
not proof of internal message-ID equality.

Together with the earlier opposite-direction scenario, the evidence now covers
both deleting default while preserving a named profile and deleting a named
profile while preserving default. The latter starts with both of its real
saved-entry records intact and uses the fixed release throughout.

## Audit, teardown and limits

The final audit re-reads actual biometric request traces, full identity/history
XML, raw record inventories, original payload-path absence and the installed
artifact/source manifests. It does not count these checks as a new test suite.
No runtime source changed, so the earlier 68 Flutter checks and two native
smoke executables are not reported as rerun.

The new synthetic certificate export and temporary UI dump are removed, no ADB
forward remains, and the owned application/emulator processes are verified
exited. The original Mac app remains untouched. No new build or duplicate APK
is created. The two fresh synthetic unencrypted identities remain in the stopped AVD;
the previous encrypted profile and its saved entry were deliberately erased.

This extends the Android packaged-erasure evidence. Other interruption points,
hardware/OEM behavior, OS wrapping-key lifecycle policy, macOS graphical AOT,
Windows native/package qualification and remaining activation requirements keep
their separate scope. No push, release or production-default change occurs.
