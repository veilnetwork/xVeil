# Android release/AOT: profile erasure and cold recovery

Status: an actual Android write refusal exposed a repeatable cold-recovery
failure. The fixed hook-free release completes that same pending operation,
removes the selected profile's data/saved entries and preserves a separate
profile, which then opens its original identity/history with one biometric
request. Production managed storage remains OFF; other platform gates remain.

## Stand and artifact

The owned Android 15 AOSP ARM64 emulator from the
[OS-vault qualification](../managed-storage-android-vault-aot-2026-11-16/README.md)
is resumed headlessly. Its synthetic system PIN, enrolled virtual fingerprint,
three-mode fixture and two real saved entries are reused. Physical phones,
real application profiles and Mac windows are not used.

A second named AppProfile is created through ordinary Settings. Normal
onboarding creates a separate encrypted identity, exports its certificate,
saves a note, declines network discovery and configures biometric-only entry
with Pattern Off. Cold opening verifies its full identity and exact note via
the normal drawer and Saved Messages, using one CryptoObject-bound request.
The two original protected namespaces retain their file digests; the separate
profile adds its own third namespace. Nine protected preference files represent
three namespaces, not nine credentials.

The initial artifact is the previously verified hook-free release/AOT QA APK.
The fixed artifact is rebuilt from all 3,045 recorded product inputs, with only
the two runtime changes below and the same QA application ID/label overrides.
Its signer matches the control; the installed digest, AOT/no-JIT format, five
unchanged native payloads, native asset routing and artifact privacy are checked.
Temporary diagnostic source overrides are excluded from the final APK; its DEX
and Dart AOT payload contain none of their diagnostic markers. Existing source
and APK controls are restored byte for byte after each build. No Rust/native
library rebuild or production installation is claimed.

## Actual failure and diagnosis

After returning to the original profile through Settings, the test temporarily
removes directory write permission from this QA package's shared preferences.
A command running as the actual application UID confirms permission denial.
The normal Clear all data action and typed whole-profile confirmation are used.
An independent process restores the exact original directory/mode on completion
or observer exit; its restoration is verified before further work.

The application reports an explicit failed-deletion modal, followed by the
sealed erasure-pending screen and Retry. All nine original identity data/role
files and the six public/protected records remain unchanged at that boundary.
The real application journal has already captured three storage scopes and two
protected record addresses. The process is stopped, discarding framework RAM.
No ordinary onboarding or identity UI is admitted while erasure is pending.

Cold startup on the control refuses again: protected records are removed, but
the two public cleanup intents remain and no identity payload is deleted.
This partial state is retained for the candidate; there is no data reset or
manual record repair between control and candidate.

Temporary, private stage instrumentation locates the refusal at public record
removal. The disk snapshot is stable and has the same keys/string types as the
framework cache, but a value has four extra trailing spaces on disk. Whitespace
removal makes the encoded ciphertext equal. A read-only Android process compares
the same file using framework XmlUtils and the custom XML parser; their results
agree. The parser is not independently dropping or adding those characters.

FSS uses Base64.DEFAULT, whose encoded value ends in a newline. Android's XML
serializer can add indentation before its closing string tag, while the live
SharedPreferences map retains the unpadded string. Raw disk/cache equality then
rejects the application's own just-persisted cleanup metadata. Rewriting that
intent on each retry repeats the mismatch.

## Changes and regression checks

- Checked disk/cache comparison tolerates only ASCII space, tab, CR and LF
  differences in known record-prefix Base64 ciphertext fields. Compacted text
  must match and decode as valid, nonempty Base64 text. Keys, types, bookkeeping
  and other fields still require exact equality. The two raw disk snapshots,
  file identity/mtime checks, backup refusal and unknown-file protections remain
  exact. No missing or malformed record becomes an empty store.
- Captured scopes retire sequentially because public metadata shares one file.
  Every scope is sealed before waiting, and a refusing scope does not prevent
  attempts on the remaining scopes. This removes a separately reproduced shared
  writer conflict; it alone did not fix the Android failure above.

The shared-writer regression is red on the prior parallel implementation, then
passes while checking refusal of late enrollment and preservation of an
unrelated entry. Six Flutter suites pass 68 checks, including retirement,
read races, wipe ownership and startup recovery; focused analysis is clean.

The native backing-file regression is red on the prior exact comparison. Both
Kotlin/JVM smoke programs pass after the fix, including public-reader crypto
checks and the existing corruption, stale-map, duplicate, backup and symlink
refusals. Added cases accept the serializer-shaped indentation without changing
the file, and refuse changed ciphertext, non-ASCII whitespace, invalid Base64
and whitespace-only changes to bookkeeping. These programs are not counted as
additional Flutter tests.

## Fixed packaged recovery and isolation

The fixed release replaces only the same QA package, with its pending journal,
partial record removal, original payloads and separate profile retained. Normal
cold startup completes automatically without a biometric prompt or typed
container password, reaching positive fresh onboarding.

Independent inspection verifies:

- all nine original identity payload/role paths are absent;
- both original public records and both protected records are absent, including
  the protected entries already removed by the control's partial attempt;
- the pending plan, native terminal and application journal are absent;
- the separate profile's durable files, both public/protected values and all
  three protected-namespace file digests are unchanged before reopening;
- the OS preference-file inventory is unchanged: absence checking did not
  initialize replacement namespaces.

Fresh ordinary onboarding then creates an explicitly unencrypted identity in
the cleared profile. A new note is saved and read back after full process exit
and no-password reopening, with the exact new identity and no old fixture note.
Settings selects the preserved named profile again; its existing biometric
entry uses one CryptoObject request and shows the original full identity and
exact single note. This checks actual usable data, not only hashes or process
presence. No internal message-ID equality is inferred from UI XML.

## Evidence boundaries and teardown

The final audit re-reads explicit proof fields, actual request traces and
identity/history XML, raw record inventory/digests, old-path absence and current
source/installed artifact provenance. It is not another test run.

Early observer attempts are not credited: the profile-reveal snackbar initially
covered its row; a default-row label included additional semantics; the failure
modal initially hid the pending screen; the journal lives under the storage
coordinator rather than directly under the managed root. The nondebuggable QA
package rejects run-as, so permission verification instead uses its actual UID
on the owned rooted AVD. A temporary diagnostic compile with incorrect character
escaping is excluded. None of these issues required app-data repair or relaxed
authentication. The first sequential-only candidate also remains a failed
Android recovery result, not a passing qualification.

Temporary certificate exports and device observers are removed. Owned app and
headless emulator exit are verified, no ADB forwards remain, and superseded APK
copies are removed while retaining one fixed artifact and the original control.
The original three synthetic identities were deliberately erased; the fresh
unencrypted identity and preserved named encrypted profile remain only inside
the stopped private AVD. No Mac app activation, physical biometric test, push,
release or production-default change occurs.

This qualifies one packaged Android refusal/partial-removal/cold-recovery
scenario and foreign-profile survival. It does not prove arbitrary power-loss
behavior, every OEM, every erasure crash point or other platform storage/vault
integration. Those checks retain their own scope.

## Ordinary-erasure follow-up

The [no-fault packaged follow-up](../managed-storage-android-clean-erasure-aot-2026-11-16/README.md)
uses this same fixed APK with a complete saved entry. It verifies normal
whole-profile deletion, cold no-resurrection and exact readback of the preserved
default profile. It complements this partial-removal/recovery scenario.
