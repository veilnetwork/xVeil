# Contact status feedback must describe the current durable decision

Base: `7e8dc400`. This fixes a local notification-ordering defect, not the
unattributed Windows user's one-way messaging case.

## Evidence

Local acceptance/unblock and mirrored acceptance committed their contact state,
then awaited request-Outbox retirement before emitting contactStatusChanges.
The local path also invoked onContactStatusChanged. A block could commit during
that wait. Access checks correctly kept the contact blocked, but the older
operation subsequently emitted accepted anyway. Conversely, a delayed block
write reply could emit blocked after a newer unblock committed.

The regression extends actual service/storage race tests rather than replacing
the consent policy with a fake. Ordinary asynchronous storage and the real
hidden-volume worker both reproduce the notification error. Gates hold either
the post-commit Outbox snapshot or the completed block's reply, then a newer
decision commits before release. On the unchanged base, **eight assertion-red
cases and four passing controls** cover primary acceptance, mirrored acceptance,
unblock, delayed block and unrelated-peer changes.

Assertions observe both the public status stream and the local callback. They
also check durable state, actual realtime offer admission through CallService,
and cold reopen in the delayed-block cases. They establish that the old events
were wrong; they do not establish an authorization bypass. The original block
was already enforced correctly.

## Change

A shared publication helper reads current contact consent after the preceding
waits and checks both the requested status and its still-current revision
immediately before notification. Service closure also invalidates publication.
Mirrored status remains notification-only and never invokes the local journal
callback. A different peer's decision does not suppress a valid event.

The storage transaction and durable publication ledger remain the source of
truth. Superseded notification suppression does not undo a committed write,
change the mirror API's applied-result meaning, remove its durable obligations
or alter acceptance responses. Boot/periodic publication can still recover a
missing callback from the ledger. No consent gate is relaxed.

## Qualification and limits

The expanded focused fixture passes **70 tests**. **540 related tests passed,
zero skipped**, across twenty-three suites covering consent, request admission
and retirement, handshake receipts, atomic acceptance, decision/preference
mirroring/publication, inbound expiry/provenance, avatars and chat feedback.
The analyzer reports no issues; whitespace checks pass.

Selected native libraries match their producer hashes and 1,144 Rust/Cargo
inputs. All 50 storage ABI checks pass. No native build, ABI or wire change is
made. Tests run headlessly with TMPDIR=/private/tmp/ and synthetic containers;
no app window, focus change, OS input, installed-app/user-container change or
seed operation is used. Original Windows 10 behavior remains unqualified.
No push or release.
