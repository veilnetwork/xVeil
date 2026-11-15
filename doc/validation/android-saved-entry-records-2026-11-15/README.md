# Android saved-entry presence and removal

## Confirmed failure mechanism

The selected flutter_secure_storage 10.3.4 plugin initializes its cipher before
dispatching read, containsKey and delete. The protected initializer can request
biometric authentication or fail on unavailable/invalid key material even when
the requested record is already absent. The application's absence check used
readback, so a cleanup verification could reach that initializer too.

This is a confirmed integration mechanism from the selected plugin and red
channel tests. It is not attribution of a reported user incident or a reproduced
physical-device key-invalidation case.

## Change

Android presence checks and explicit known-record removal now use the existing
private native channel. Requests supply only the fixed quick-unlock key and
biometric mode. The strict namespace mapping and selected plugin's key prefix
choose the same raw data record used by the write path.

The native presence port returns whether that raw key exists. It requests no
cipher initialization, credential values, migration/reset, key generation,
edits or commits. A corrupt encrypted value still counts as present.
An unavailable bridge, null result or native error refuses verification.

Explicit removal deletes exactly that prefixed key with a synchronous commit
off the main thread, then checks absence. False commit results, readback failure
or a remaining entry refuse success. A false commit may already have changed
RAM; that observation cannot stand in for persisted deletion. Retry performs
another owned commit. Other scopes and wrapped-key/configuration stores are not
cleared by this port. Authentication requirements for reading passwords and the
existing bound-erasure authority checks remain unchanged.

The Dart mutation stays pending until the native reply. Already accepted native
work follows the existing executor-drain policy on disposal. Missing/unknown
replies have no decrypting or empty fallback. Darwin retains its existing
matching local-only read policy. Plugin writes continue to use the native
persistence barrier from the preceding round.

## Evidence

- Eight new Android checks failed behaviorally on the preceding implementation;
  the Darwin policy control already passed. All nine pass with this change.
  They cover present/absent records with cipher initialization unavailable,
  unknown/missing replies and removal settlement behind a gate. Correctness
  does not depend on an elapsed-time threshold.
- 175 checks passed in 14 serial Flutter suites. These include saved-entry
  configuration, queues, late reads, retirement and native profile erasure.
  The actual-payload test now uses the native removal/presence channel model:
  unconfirmed removal preserves real managed identity bytes and cleanup intent;
  a confirmed retry completes erasure.
- The actual native record owner passed Kotlin/JVM checks for exact key and
  namespace selection, read-only presence, sibling preservation, a failed
  commit with changed RAM/unchanged disk, lost removal, inspection refusal and
  invalid requests before opening a store.
- Three private-copy mutants compiled and exited normally with failure:
  ignoring commit refusal, omitting the post-removal check and selecting the
  wrong record prefix. The original passed. Compiler errors, crashes and
  watchdog expiration are not counted as behavioral rejection.
- An isolated APK compiled 21 actual app Kotlin files, seven SDK Kotlin files
  and 24 selected plugin Java files. Source inventories and APK digest were
  retained privately. No user application or OS credential store was opened.
- Dart analysis passed. Flutter qualification froze sources and verified the
  four existing native-library hashes. No Rust/media engine was rebuilt.

## Limits

The subsequent [Android file-integrity qualification](../android-saved-entry-file-integrity-2026-11-15/README.md)
runs these channel methods on Android, including removed keys and damaged files,
and adds backing-file/cache validation. The limits below describe this earlier
round rather than the follow-up's result.

The new raw-record owner ran on the host JVM and compiled for Android; its new
channel methods have not yet run on an Android device/emulator. The prior
[40 Android process-death checks](../android-quick-unlock-restart-2026-11-15/README.md)
qualified the earlier persistence path and do not retroactively qualify this
new removal/inspection port. ADB had no attached devices in this round.
Presence remains a platform preference-store observation; independent integrity
validation or repair of a damaged backing preference file is outside this port.

Scope discovery after a cold terminal-only restart remains unfinished. This
change supplies a read-only absence primitive, not a reconstructed roster,
cleanup grant or complete startup recovery. Managed storage remains disabled;
native media observation and packaged migration/maintenance gates remain open.
There is no push, installation or release in this cycle.
