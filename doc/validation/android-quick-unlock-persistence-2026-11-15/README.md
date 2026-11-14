# Android quick-unlock persistence

## Confirmed boundary

The selected flutter_secure_storage 10.3.4 Android sources implement ordinary
write/delete with `SharedPreferences.Editor.apply()`. Its callback and the
plugin's subsequent read observe RAM; neither reports whether the asynchronous
disk write succeeded. The local Android SDK contract distinguishes this from
`commit()`, which returns the persistence result and waits for earlier `apply()`
work on that same preference store.

The application previously used plugin completion plus readback as permission
to advance quick-unlock enrollment/removal and managed-profile erasure. A native
payload test reproduces that boundary: with unconfirmed protected-record
deletion, the old application continues to delete the real managed identity.
This establishes a missing durability prerequisite, not a reproduced Android
crash or attribution of a historical user report.

The existing deletion order was already correct: preserve a public cleanup
intent while deleting/verifying its protected slot, then remove the public
record. No new disk roster or terminal scope list is needed for this correction.
The missing step was persistence confirmation beneath that protocol.

## Correction

`QuickUnlockSecretStore` now awaits an Android-native persistence barrier after
each successful plugin write/delete. The native bridge commits the selected
namespace's wrapped-key store, algorithm/configuration store and encrypted-data
store, using their pinned plugin naming rules. Namespace selection is shared
with the existing authenticated read bridge. Caller-provided paths, preference
filenames and credential values are not accepted by this new port.

Commits execute on the existing background executor, away from the UI thread.
An accepted task survives executor shutdown and settles its own reply. Every
selected store is attempted; a false result or exception refuses success.
False/null replies and a missing bridge also refuse success on the Dart side.
No RAM-readback fallback is used. Existing plugin failures propagate before a
barrier can report success.

The plugin still owns encryption, authentication and record mutation. Cipher
policy, storage format and the single authenticated-read prompt are unchanged.
Non-Android adapters do not use this new bridge. Ordinary quick-unlock setup and
forget operations benefit as well as the still-disabled managed-storage path.

## Evidence

- Before the fix, seven of eight new checks failed behaviorally, including the
  actual native-payload preservation assertion. The plugin-refusal control
  already passed. Compilation errors and timeouts are not counted as red tests.
  Persisted enrollment is established explicitly before the deletion controls;
  an earlier fixture that assumed new plugin writes had already persisted was
  corrected before counting those negative results.
- After the fix, all eight passed: accepted write/delete settlement waits on a
  gate, false/null/missing confirmation refuses success, plugin refusal stays a
  failure, and protected-delete refusal retains a cleanup intent that a fresh
  adapter can recover from the modeled persisted state. The timing oracle is
  operation settlement versus barrier admission, not elapsed milliseconds.
- The payload case snapshots actual managed identity files, confirms their bytes
  remain unchanged on unconfirmed credential removal, then retries and completes
  native erasure and external absence verification.
- 166 checks passed across 13 serial Flutter suites, including quick-unlock
  configuration/queues, late authenticated reads, scope retirement, native vault
  handoff, live managed-profile erasure and pending-erasure startup exclusion.
- Kotlin/JVM checks cover namespace isolation and validation, all three commit
  failures/exceptions, dependency ordering and accepted work during executor
  shutdown. Three private-copy mutants compiled and exited with failure: ignore
  commit refusal, omit the data-store commit and select the wrong wrapped-key
  namespace. The original passed. Watchdog expiration is not a passing oracle.
- An isolated Android APK compiled all 20 actual app Kotlin files, seven SDK
  Kotlin files and 24 selected plugin Java files. Source inventories matched
  before/after the build and the app Kotlin task executed rather than reporting
  a cached success. No developer app or credential store was installed/opened.
- Dart analysis passed. Flutter qualification froze sources and checked the four
  existing pinned native-library hashes before/after the runs. No Rust or media
  engine was rebuilt for this change.

## Remaining scope

Android plugin persistence and restart are modeled at the channel boundary;
the native helper runs on the host JVM and compiles against the Android sources,
but real-device process-kill/disk-failure qualification remains open. ADB had no
connected device in this round. No actual Keychain/Keystore secrets were used.
The later [Android restart qualification](../android-quick-unlock-restart-2026-11-15/README.md)
ran the real plugin/helper in a disposable Android 15 emulator, including a
strong-biometric key and 40 fresh-process checks. It does not replace physical
device or complete application qualification.

This does not solve terminal-only application recovery, reconstruct a missing
scope roster, independently observe native media shutdown or activate managed
storage. The cold-start refusal shell and the existing activation gates remain.
There is no push, installation or release in this cycle.
