# Android managed-storage bootstrap

Managed storage remains disabled in production defaults. These checks use an
isolated Android 15 arm64 AOSP emulator and a separate application ID, ordinary
`lib/main.dart`, testnet configuration and the managed-storage QA define. No
user container or production application was opened. This does not qualify
Poco/Blackview firmware, calls, camera, notifications or release artifacts.

## Confirmed filesystem rejection

The complete debug application stopped before `runApp`: opening the managed
profile-preferences worker returned `ManagedWorkerFailure(invalid)`. Independent
Android `stat` checks found `files` with mode 0771, owned by the current app UID
and its equal primary GID; the app-data parent was 0700. The original policy
refused the group-write bit even though this is the app's own Android group.

Android's [ContextImpl](https://android.googlesource.com/platform/frameworks/base/+/10ca6954bdbe7fceed1bf4e322f0a8761fa293bb/core/java/android/app/ContextImpl.java)
creates `getFilesDir()` with 0771. Its
[process launcher](https://android.googlesource.com/platform/frameworks/base/+/cdcc8526e194884ae506468a71021718ccd7c7a8/services/core/java/com/android/server/am/ProcessList.java)
passes the app UID as its primary GID. The correction permits this group-write
bit only on Android directory ancestors owned by the full current application
UID, with exactly that GID. The application-ID range is 10000–19999 modulo the
Android user offset. It grants no private-file status and does not admit shared,
media/cache, foreign-profile or arbitrary equal Unix UID/GID groups. Existing
0700/0600 requirements for privately created children remain intact; the app
does not chmod the OS directory.

The new positive case fails on the old policy. All 21 focused policy,
profile-lease and file-publication checks pass; analysis of the two changed Dart
files is clean. In the actual APK before/after comparison, all four native
libraries are byte-identical and the Dart policy is the only application-source
delta. The corrected application reaches normal onboarding instead of failing
at preferences bootstrap. Invalid existing metadata is not replaced by an
empty fallback.

## Mandatory Android media build admission

An earlier incomplete QA package installed successfully, then failed during
activity initialization because `libveil_media.so` was absent. Android camera
and renderer classes load it before Dart starts. This was a QA packaging error,
not evidence of a missing engine in the released application, but neither the
debug builder nor direct Flutter/Gradle invocation rejected it.

The builder now checks staged engines before native compilation in both modes.
Gradle checks the libraries for the selected target ABIs before packaging,
including direct Flutter builds. It captures serializable task inputs and
supports configuration-cache reuse. Presence admission supplements the existing
ABI/export/provenance checks; it does not replace them.

The old debug plan fails the new regression guard. The focused Python run has
10 passing tests and one separately counted host-platform skip. Real Gradle
checks cover present media, configuration-cache reuse, removal after cache
creation, and an absent engine for a different selected ABI. Only the two
presence controls succeed; both missing-library cases fail at the intended
task. A real Flutter APK build also refuses a missing arm64 engine.

For the final QA APK, Veil and hidden-volume were built from the selected source
revisions in a dedicated external Cargo target with a live mount guard. The
media engine was built from current source against the immutable WebRTC SDK;
its source digest and required exports were checked. The existing published
media pin did not match the current development source and was not silently
accepted or changed. This local QA build does not constitute a new engine pin.
SQLite matches its package-pinned Android asset. Each packaged library was
independently reproduced from its selected input using the actual NDK stripping
transformation and compared byte for byte; raw pre-strip SHA equality is not
claimed. The APK has only the requested ABI, separate package ID and intended
testnet assets. Call or audible-output qualification is not implied by including
the engine.

## Scope

Normal storage-mode onboarding/reopen results are recorded in the companion
Android mode qualification. Platform destructive/recovery operations,
biometrics for the new backends, release AOT and production activation remain
separate gates. Raw logs, credentials, recovery certificates and local evidence
stay outside the repository.
