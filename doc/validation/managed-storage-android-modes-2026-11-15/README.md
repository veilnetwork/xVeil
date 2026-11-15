# Android application storage modes

Production managed storage remains disabled. This follow-up qualifies the normal
application paths on an isolated Android 15 arm64 AOSP emulator after the
[bootstrap and build-admission fixes](../managed-storage-android-bootstrap-2026-11-15/README.md).
It is not a physical Poco/Blackview, release-AOT, call or peer-delivery test.

## Stand and positive controls

The ordinary debug application uses a separate application ID and private
test-only data directory, testnet and the managed-storage/debug-hook defines.
All identities, passwords, certificates and notes are synthetic. Real user
applications and containers were untouched. The final APK contains the verified
Veil, hidden-volume, SQLite and media libraries; the companion report records
source selection, build isolation and verification of the stripped APK payloads.

Onboarding uses actual Flutter controls. Recovery export uses Android's native
DocumentsUI Save button and suggested filename. The resulting file must exist,
have the expected format and correspond to the complete public node identifier
shown by the wizard before its normal saved-file gate is advanced. No controller
mutation or retrieval of recovery codes is used. Debug hooks read health and
identity, save/read real CloudService notes and lock the application. An oracle
requires a positive ready state, exact full identity and exact note digest;
empty output never qualifies as equality.

Cold reopen means stopping the owned process, observing its exit and launching
the same installed APK without reinstalling or clearing data. The installed APK
digest is checked before each cold run. Storage selection, passwords and the
plaintext open action go through the normal visible lock-screen controls.

## Results

| Mode | Normal creation | Cold reopen | Data oracle |
|---|---|---|---|
| Encrypted | Default left untouched; certificate export and password setup | Correct password opens the same identity | Exact note digest; explicit wrong-password rejection also verified before warm reopen |
| Unencrypted | Explicit selection, plaintext warning, no password step | Visible no-password open control; password field absent | Same complete identity and note digest |
| Hidden | Explicit opt-in, certificate export and password setup | Explicit hidden-mode selection and password | Same complete identity and note digest |

After the hidden cold run, both the original encrypted identity and the normally
created plaintext identity are selected again, reopened and checked against
their original note digests. Each session is then locked. All three normal
creation certificates identify distinct identities.

An independent Python SQLite reader opens a copy of the closed plaintext store
without a key. It finds the SQLite header, `unencrypted` metadata and the saved
synthetic note title. The public catalog contains one encrypted and two
unencrypted entries: the second plaintext entry is the interrupted attempt
explained below. Its entries are unchanged by hidden creation; no hidden
identity is registered there. This tests catalog behavior, not deniability of
all filesystem activity against arbitrary snapshots.

## Interrupted attempt and observer corrections

One earlier plaintext setup was stopped by an operator error: a dependent cold
restart began while its onboarding observer was still running. It is not
credited as normal onboarding or as a deliberate crash-boundary test. On cold
open, the app required the visible **Finish setup** recovery action. That action
reached ready with the exact certificate identity. A note was created only
after recovery; no claim of pre-interruption note survival is made. The later
fresh plaintext creation and cold readback above completed independently.

The normal plaintext observer also expired while real native first-run mining
continued on the two-core emulator. The existing app was inspected and left
running; it reached ready without a restart. Identity/note/lock checks then
completed. This was not classified as a frozen storage worker or repaired by
lowering proof-of-work difficulty. Hidden creation used a longer observation
window and also completed normally.

The DocumentsUI observer initially counted an existing exported certificate in
the file listing as a second filename. It was corrected to inspect the native
filename EditText only, and the pending Save was completed in the existing
wizard. A hook cannot inspect Flutter semantics while native DocumentsUI owns
the screen; its explicit not-ready response is not a product failure. None of
these corrected observer attempts counts as a separate application success.

During the final switch, native Android notification permission temporarily
owned the foreground activity and Flutter exposed no semantics. Activity and
native-dialog inspection identified the prompt; it was handled only for the
isolated emulator app before continuing the existing locked session. The empty
observer result was not credited as a storage or blank-screen defect.

## Limits and teardown

Payloads are small; this does not qualify large-history workloads, compaction,
erase/rotation, cross-process recovery boundaries, quick unlock, OEM firmware
or release artifacts for the new storage modes. Those remain prerequisites
before production activation. The historical Windows camera and incoming-call
notification complaints are unchanged by this storage run.

The owned app and emulator are stopped with process-exit checks. The owned ADB
forward and exact synthetic certificate exports are removed. No owned media
build container remains. The unused duplicate WebRTC SDK is removed; private
proofs, current QA artifact and test profile remain outside the repository.
