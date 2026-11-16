# Android release/AOT: three modes and owned reclamation

Status: normal mode choice, creation, cold opening, history isolation and owned
reclamation pass on Android 15 AOSP ARM64. Production managed storage remains
OFF. This is a packaged application qualification, not a production release.

## Artifact and stand

The retained hook-free release/AOT APK from the
[Saved Messages follow-up](../saved-messages-device-address-2026-11-16/README.md)
uses the normal application entrypoint, a separate QA application ID, explicit
QA signing permission, managed storage enabled and the testnet assets. Its
signature, AOT/no-JIT form, five native payload reconstructions and both artifact
privacy scans were already verified. Its 3,045 product inputs still match the
worktree; no runtime source or native library changed in this round. The actual
installed APK digest is checked before cold runs. No diagnostic HTTP hook,
controller mutation, reinstall between modes or data reset is used.

The original synthetic encrypted identity and four notes were retained. New
plaintext and hidden identities were created through Start over, explicitly
keeping existing data. Every action used the owned headless emulator's virtual
screen and normal Android keyboard. No Mac window, physical phone, user profile
or production infrastructure was touched.

Recovery export went through native DocumentsUI Save. The resulting file must
exist and parse as an XVRC certificate; its complete public identity is compared
with the normal application drawer. Neither a suggested filename nor a saved
checkbox alone qualifies the export. Each new wizard initially exposed exactly
one selected semantic state: Encrypted storage. Plaintext and hidden modes were
chosen explicitly. The plaintext warning was visible and no password-setup step
was offered. Discovery was deliberately declined in both new identities; this
is not a peer-delivery or networking test.

Initial node preparation was observed in the existing process, including its
canonical proof-of-work, without restarting it or reducing difficulty. Its
variable first-run time is not a storage-speed measurement. An early attempt
to match a combined title/subtitle as an exact label was corrected to target
the actual control before creation proceeded; it is a stand issue, not a
failed product scenario.

## Results

| Mode | Creation/selection | Cold opening | Positive data oracle |
|---|---|---|---|
| Encrypted | Existing identity created by the earlier untouched-default release run; both new wizards also confirm this sole default | Explicit selection and ordinary password; wrong password rejected | Same full identity and all four original notes, including after its own cleanup |
| Unencrypted | Fresh explicit choice and visible warning; no password step | Normal Open unencrypted storage control; password field absent | Same full certificate identity and one exact note; independent unkeyed SQLite read also passes |
| Hidden | Fresh explicit opt-in and separate password | Explicit hidden selection and ordinary password; wrong password rejected | Same full certificate identity and one exact note, including after both other identities are cleaned |

Cold opening means force-stopping the owned application, checking that its
process exited, launching the same installed APK and using ordinary lock-screen
controls. Exact note texts are verified as visible messages with an empty
composer. Every readback excludes all known notes from the other fixtures;
empty histories cannot pass. The three complete sovereign IDs are distinct.
The UI checks establish identity and visible-body persistence, not transport
ACKs or internal message-ID equality.

The independent reader opens a copy of the closed plaintext database through
Python SQLite with no key. It verifies the SQLite header, integrity check,
`unencrypted` metadata and the actual note record. It does not weaken native
admission to make an encrypted or hidden snapshot open on the host.

Both wrong-password attempts preserve the exact digests of all five data
payloads, including the shared hidden file. Original encrypted role payloads
also remain byte-identical across creation of the plaintext identity; all
pre-existing payloads remain unchanged across hidden creation.

## Catalog and cleanup ownership

The public catalog contains exactly two entries, encrypted and unencrypted,
with opaque local IDs. Hidden creation and later operations preserve that entry
set and add no hidden record or full network identity. This checks the catalog
contract; it does not establish deniability against arbitrary filesystem
snapshots or hide that enumerable identities exist.

Both enumerable identities use the normal Settings → Data & storage → Reclaim
space action. Neither asks for another identity's password or opens a password
prompt. A positive Done snackbar witnesses completion, rather than crediting an
absent spinner or an unchanged file as success.

- Encrypted reclamation preserves all four sibling files: the plaintext
  identity's data/role files and the shared hidden file.
- Plaintext reclamation preserves all six sibling files: the encrypted
  identity's data/role files and the shared hidden file.
- The encrypted identity cold-opens with its four notes after its own cleanup.
  The plaintext identity cold-opens with its note after hidden creation and
  again after its own cleanup. The hidden identity cold-opens with its note
  after both owned cleanup operations.

Nine identity data/role files are inventoried. Before/after sibling path sets
and SHA-256 values are compared, not merely file counts. Fixtures are small:
these operations prove routing, preservation and persistence, **not** actual
space savings, steady-state growth bounds or large-history performance.

## Evidence audit and remaining scope

A final independent pass over retained evidence rechecks explicit success and
negative-control fields, seven actual UI identity/history cases, both cleanup
sibling hash sets, final catalog entries, the retained APK digest and all product
source inputs. This is an audit of those same runs, not seven extra tests.

The owned application and emulator were stopped with process-exit checks.
No ADB forward was created. The two newly exported synthetic certificates were
copied privately, matched against their saved hashes and removed from emulator
Downloads. Existing encrypted data, all three QA identities and private evidence
remain for later checks. The original Mac application stays untouched.

The later [scoped OS-vault follow-up](../managed-storage-android-vault-aot-2026-11-16/README.md)
qualifies managed/hidden entry with actual Android Keystore and virtual sensor
input. Packaged full-profile recovery/deletion including OS-record retirement,
physical OEM/hardware and other target/platform qualification remain open. This run does not repeat native crash matrices, mixed-roster
compaction, all-online hosting, physical OEM or Windows/macOS runtime tests.
Those have their own evidence and open scope. No push, official signing,
production-default change or release was performed.
