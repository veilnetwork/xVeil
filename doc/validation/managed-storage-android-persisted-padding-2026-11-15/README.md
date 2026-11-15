# Android persisted-padding and reclamation follow-up

Managed storage remains disabled in production defaults. This qualifies the
[persisted-padding fix](../managed-storage-persisted-padding-2026-11-15/README.md)
on a separately packaged Android debug application using the ordinary entry
point and real native storage/node services. It does not activate the feature,
qualify a release artifact or migrate existing stores.

## Package and provenance

The application sources are frozen at `d8b412c6`, with hidden-volume `7b13bbb4`
and Veil `5d9884a6`. The copied input manifest contains 3,037 files. Only the QA
application ID/label and explicit managed-storage/debug-hook/testnet build
settings differ from the application under test. Generated platform config
files are excluded from the source comparison; tracked inputs remain unchanged
across compilation. A fresh Android arm64 hidden-volume library is built from
these sources in a dedicated external target. The build monitors the mounted
filesystem identity and available space, remaps personal build paths and checks
the new constructor and checksum exports before staging the library.

Unchanged Veil and media libraries are reused only after verifying their source
inputs and prior build digests. SQLite is the package-pinned Android asset from
3.5.2. All four native APK payloads match independent NDK strip reconstructions
of their verified raw inputs. The SQLite native-asset mapping, application
namespace, activity, label and testnet seed bytes are checked. The installed APK
digest is rechecked before cold starts. This is a debug arm64 package, not a
qualification of every release ABI. No published native dependency is relabeled
as containing the new constructor.

## Ordinary onboarding and maintenance

On an owned Android 15 AOSP emulator, normal onboarding creates an encrypted
identity with the default encrypted selection. Its certificate is saved through
Android DocumentsUI and the normal saved-file gate. The real native application
reaches ready, and a synthetic note is written/read through the Cloud service.
After lock, an incorrect password receives an explicit rejection. The correct
password returns the exact full identity and note digest.

All three closed application files are copied with remote length and SHA-256
checks before and after capture. Their persisted format is version 3 with
padding index zero. The keybox retains Argon2 parameters 256 MiB / 4 / 4;
content and maintenance retain 64 MiB / 3 / 1. This checks the actual application
files, rather than only a separately constructed native fixture.

The ordinary storage settings action performs owned reclamation and reports
completion. The identity and note still match. Observed logical lengths are:

| Observation | Keybox | Content | Maintenance | Total bytes |
|---|---:|---:|---:|---:|
| Ready, immediately before reclamation | 40,960 | 1,298,432 | 86,016 | 1,425,408 |
| Immediately after completion | 40,960 | 114,688 | 81,920 | 237,568 |
| Closed after subsequent application read/lock | 40,960 | 188,416 | 81,920 | 311,296 |
| Closed after cold reopen/read/lock | 40,960 | 356,352 | 81,920 | 479,232 |

These are separate observations on a tiny synthetic profile with intervening
application activity. They are not an A/B benchmark, a constant-size guarantee,
a disk-block measurement or an estimate of savings on user histories. The
keybox bytes remain unchanged and every captured managed header retains the
explicit no-padding posture. A complete process restart followed by normal
password unlock returns the exact identity/note.

## Hidden control and isolation

Normal Start over keeps existing data. A second identity is explicitly created
in Hidden space, through the normal certificate-save/password flow. Its real
native stack reaches ready and preserves a different synthetic note. After
process death, normal hidden selection/password unlock returns its exact full
identity and note digest.

The hidden file retains version 3, padding index 2 (the existing 1-MiB hidden
default), and its original KDF parameters. All three closed managed payloads
remain byte-identical across hidden creation and cold reopen. Returning through
the ordinary identity chooser to the encrypted identity preserves its exact
identity/note, while the closed hidden file stays byte-identical. A preliminary
menu capture during its animation showed only the hidden item; after settling,
the existing encrypted entry is present and selectable. No chooser defect is
claimed from that transient observation.

Header flags are public metadata; checking them does not introduce or claim
additional header authentication. Password/identity/note checks are independent
readback oracles. These checks cover separately selected roots, not mixed-roster
compaction, master/child recovery or migration of old managed headers.

## Harness observations and cleanup

An optional helper-copy command used an unresolved relative parent and failed
after the encrypted cold-read proof had already completed. The helper path was
corrected without restarting or discarding that observation; it is not counted
as an application failure. All credited creation/reopen observers finish with
actual successful exit status. A bounded structural query times out; focused
source inspection is used instead of treating it as graph evidence.

The exact two synthetic certificate exports are removed only after digest
verification. The owned QA application is stopped and its process exit checked;
the owned ADB mapping is removed, the original emulator screen timeout is
restored, and the owned emulator and its child processes exit. Synthetic test
profiles and private evidence are retained outside the repository. The normal
application package and user containers are untouched. Nothing is pushed,
tagged or released.

Physical Android/OEM, release AOT/other ABIs, remaining credential and destructive
recovery gates, mixed-roster maintenance, and the other platform native-library
rebuilds remain open. The previous Windows camera and incoming-notification
complaints are not qualified by this storage run.
