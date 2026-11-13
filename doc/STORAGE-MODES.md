# Three storage modes

Status: implementation in progress; not part of the 0.13.101 release.

The owner requested an enumerable encrypted default, optional hidden storage,
and an explicitly unencrypted store. Existing hidden containers must retain
their current protection until the user requests and confirms a migration.

| Mode | Local contents | Identity directory | Reclamation |
|---|---|---|---|
| Hidden | Encrypted, deniable spaces | Never enumerate hidden spaces publicly | Preserve the unknown-space boundary; no automatic rewrite that discards unknown spaces |
| Encrypted (new default) | Encrypted, one store per identity | Opaque local locators and protection mode may be public | Reuse freed pages and reclaim only this identity's data |
| Unencrypted | Plaintext, including local identity secrets | Same independently owned layout | Reuse freed pages and reclaim only this identity's data |

Transport encryption, peer authorization, ratchet barriers and durable delivery
acknowledgements remain mandatory in all three modes. An unencrypted local
store must explicitly warn that someone with filesystem access can read its
contents and impersonate the local identity. It is never the default or an
automatic fallback after an encrypted store fails to open.

## What is implemented now

The legacy `StorageMode.plain` onboarding choice only persists a preference;
bootstrap still supplies `HiddenVolumeStorage` for both choices. It is not a
working plaintext backend. Merely relabeling this choice would misrepresent
the protection and would not solve storage growth.

The current implementation already has lower-growth padding enabled by
default. Hidden-volume also reuses retired slots under its churn rules
(`third_party/hidden-volume/DESIGN.md`, section 9.1). Unbounded growth is not a
necessary definition of hidden storage. A snapshot cannot, however, safely
attribute every unknown chunk to garbage: another hidden identity may own it.

The new `StorageProtection` contract and managed catalog are not yet connected
to production onboarding/unlock. Experimental persistence ports now exist,
as qualified below; the application still selects the legacy backend.
The catalog rejects hidden entries, credentials, network identifiers, unknown
fields, duplicate locators and paths outside a strict local ID format. It
does not silently replace malformed existing metadata with an empty catalog.
The pure layout does not claim to solve filesystem symlink races.

The plaintext-only connection now uses `sqlite3` **3.5.2** with the ordinary
SQLite hook. The current Flutter SDK pins a dependency that prevents using
3.7.1; no SDK constraint was overridden. The selected macOS arm64 asset matches
the package-pinned SHA-256 and passed GitHub attestation verification against
the upstream repository. Flutter and Dart rewrite install names and ad-hoc
sign the library on macOS. Both actually loaded copies were independently
reconstructed from the verified download with those transformations and matched
byte for byte. This does not qualify the engine on other platforms.
The SQLCipher hook, C keying symbol and key-digest code were removed. Requests
to open encrypted storage through this connection fail before filesystem I/O;
there is no fallback to plaintext.

New-file creation reserves the leaf exclusively, then opens it without SQLite's
CREATE flag. Reopen never recreates a missing file. Existing files, directories
and final-component links are refused for creation. This is not path admission:
callers must still own the containing directory, handle unpublished stubs and
protect against ancestor/rename races before exposing the backend.

The plaintext KV/log adapter keeps payload mutations, the commit sequence
and a bounded 1024-entry branch-root history in one transaction. It selects
`synchronous=EXTRA`, rollback journals, secure deletion and full auto-vacuum.
Namespace erasure does not load the whole history into Dart. Five host cases
cover connection reopen, failed COMMIT rollback, bounded growth under 64
rewrites of a fixed 2 MiB log set, shrink after deletion with a sibling file
unchanged, fork/history retention and locator mismatch. Five connection cases
cover encrypted-request refusal without file creation or modification, explicit
plaintext readback, creation/open boundaries and errors omitting SQL, bound
values and paths. One further ordinary-SQLite negative control demonstrates
that plaintext storage does not authenticate data-page replay.

**The encrypted SQLite prototype was rejected before application integration.**
A historical SQLCipher qualification replayed an old data page while leaving
fresh metadata and commit roots intact: the experimental store accepted the
old reservation under the new anchor. The first probe failed on a PRAGMA result
type and was not counted; after correcting the probe it failed on the intended
old-value assertion. That prototype and its evidence were archived before the
provider cleanup. The current plaintext replay control is not a rerun of the
removed cipher. Neither refusing encrypted requests nor changing the provider
fixes SQLCipher page replay. No released application selected this prototype.

Ordinary encrypted identities therefore retain hidden-volume's existing
authenticated-state foundation, separately owned per visible identity. The
SQLite adapter is limited to explicitly unencrypted storage, where hostile
filesystem access already exposes the identity secrets. Fresh-process crash,
filesystem admission, bounded managed-file reclamation, application
password/biometric handling, UI and worker integration remain unqualified
except for the selected native boundaries described below.

A bounded maintenance blob is now implemented for the future dedicated
managed-encrypted maintenance space. Two fixed log banks stage at most 64 KiB;
a small authenticated-store head selects the complete payload only after all
chunks commit. It uses a log-only namespace rather than mixing KV and logs,
keeps at most 129 logical records, and refuses missing/corrupt published state
instead of silently initializing it. The extra SHA-256 binds the complete
chunk set; it does not replace hidden-volume authentication or make the rejected
encrypted SQLite prototype acceptable. Callers must serialize the exclusively
owned maintenance space and validate its managed role before using this port.

Six focused cases cover all before/after commit interruptions of a five-chunk
update, lost head responses, incomplete initialization, input buffer mutation,
malformed/missing/mismatching chunks, size limits and repeated maximum rewrites.
A seventh native case actually SIGKILLs three owned writer processes: before
the first new chunk, before publishing the complete new head, and immediately
after that native commit. Cold reopen returns the exact old or new 49,155-byte
payload, and a subsequent write succeeds. The final fixture is seeded random
data, not a trivially compressible repeated pattern. This qualifies selected
POSIX commit boundaries on macOS, not interruption inside native commit, power
loss, content repack, or Android/Windows managed storage.

The test library is the published macOS arm64 hidden-volume **2.7.2** asset,
SHA-256 `eb7c89a517464f059c2b8603a10b9b063b61cc5333d7188035a119bf66483571`.
Its checksum manifest passed cosign verification for the tagged release
workflow; the submodule/tag resolves to
`072b402de7435884973edac7e95a360679e8ea89`. No Rust build or cached-library
provenance assumption was needed. Temporary fixture files were deleted and
each writer's PID/exit status was observed after SIGKILL. No application or
real identity was opened. This primitive is not wired to the current app.

Managed generation/checkpoint state and encrypted role tags are now implemented.
A role tag binds a keybox, content or maintenance space to its opaque local
identity; existing files with absent/wrong tags are refused, not adopted.
The checkpoint codec shares one 1024-root history between active/prepared
generations, fitting in 41,090 bytes at maximum. It rejects malformed counts,
integer overflow, trailing data, contradictory checkpoints and unordered roots.
Roots from the copy phase before the new generation's floor are filtered rather
than assigned logical numbers belonging to the original content history.

A prepared state chooses the old or new mapping by the generation tag actually
authenticated from content. It never guesses publication from a callback or
resets the logical anchor. Current roots must agree with retained roots; wrong
owner/generation or content below the recorded checkpoint fails closed. The
existing external host-anchor policy still judges the resulting logical head;
this metadata is not an additional independent external anti-rollback device.

Thirteen policy/codec/role cases and one real native compaction case pass.
The native case covers normal completion plus actual process SIGKILL after
the durable PREPARED state and after native publication, before completion was
recorded. Cold-open preserves all four fixture records and the old host anchor,
selects the expected generation and permits the next durable write/reopen.
The first attempt was not qualified: an unresolved Future let the Dart VM exit
before the requested kill. The corrected writer retains a live event source;
PID markers, successful kill requests and exit `-9` were observed for both cuts.

This is a private macOS fixture, not the application compaction controller,
the original damaged-phone scenario, a power-loss test or a multi-process
managed-directory admission test. The probe serializes its own files; admission
and the production worker still need integration before a mode can be enabled.
The file factory below now enforces the identity lease for its sessions. No existing container or onboarding choice changed.

The native `ManagedKeybox` port now initializes role and 64 random internal
password bytes in one transaction. User-password-derived outer keys remain
those of the keybox; the actual user password is not persisted by this port.
Owned secret copies and the port's buffers are wiped at the defined close/
failure boundaries. A caller must retain copies until async native work settles
and then wipe them. Internal content and maintenance passwords are separate
32-byte CSPRNG values, not user-derived weak passwords or a plaintext key file.

Initialization requires the native bootstrap sequence **1** and refuses
already-written spaces. An earlier prototype incorrectly expected zero; the
published native test exposed that mistake before integration. A missing/wrong
role or unreadable keybox never invokes initialization as a fallback. The
native fresh-space test is not directory admission: creation ownership must
still be established by the future file owner. The port accepts already-opened
HV handles, chooses no KDF preset, and cannot replace the requirement that the
future user-password owner select the existing HEAVY preset. Tests use MIN
only for synthetic fixtures.

Five native keybox cases pass: password and pre-derived-key reopen with exact
secret preservation, caller-buffer ownership and at-rest ciphertext checks;
wrong password/keys/owner without replacement or a leaked lock; refusal to
adopt existing data/wrong roles; and atomic role+secret initialization when a
commit response is lost before or after the native write. Existing written
spaces retain their original data. No real container or OS vault was used.

The compaction fixture now uses all three files with actual keybox-generated
internal passwords. The child opens its keybox by password and retains that
lock while content is closed/prepared/published. At both kill barriers a second
process's key-based open returns `Busy`; after SIGKILL, key-based cold-open
works, supplies the original internal passwords, and the previous logical
anchor and exact fixture records remain valid. All six native cases pass on
the signed published macOS arm64 library. This verifies the keybox boundary
needed for biometric entry, not an actual OS biometric prompt or a connected
application backend. Filesystem admission and file-factory opening are now
qualified below on macOS; worker ownership, actual mode selection, password
rotation, erase and platform qualification remain
unfinished; these ports are not selectable in the application yet.

`ManagedEncryptedKvLogStore` now implements the actual `KvLogStore`, logical
commit-anchor and grouped-log-read ports over owned keybox/content/maintenance
handles. It returns stable **outer** keys, validates encrypted role/checkpoint
state and durably settles PREPARED metadata before returning an application
handle. It does not discover/open paths or prove directory admission; callers
must open the inner files with the keybox's internal passwords and transfer
exclusive ownership. Production worker/bootstrap selection is still pending.

All app operations target content. Namespaces 254/255 are reserved; the entire
batch is checked before a native mutation. App-data erase therefore keeps the
backend role/checkpoint records rather than making the remaining file look
uninitialized. Full identity/directory deletion is a separate unfinished owner
operation. Slot occupancy and hardening warnings include all three files.
A close attempts every owned handle, blocks new I/O immediately, reports an
error if one close fails and allows retrying the remaining handle.

Eight native adapter cases and the existing native compaction/blob crash cases
pass together: **10 PASS, no skips** on macOS. The selected checks cover:

- KV/log/grouped reads, durable cold reopen, logical commit results, stable
  outer keys and aggregate occupancy/warning routing.
- Reserved namespace protection, all-or-nothing rejection, malformed/wrong
  owner state preserved without reset, and recovery with a lost response.
- A controlled close failure leaving the content lock until retry while the
  other handles close; blocked app I/O during that interval.
- The current schema's 8 live base namespaces + 86 log shards + 1 role root
  fit the native limit of 95. Adding the retired namespace 3 at that ceiling
  fails atomically. Explicit migration must rebuild retired layouts as needed;
  blindly copying every historical namespace is not qualified.
- Real `HiddenVolumeStorage` profile/message operations, a 17,000-byte native
  attachment, chunked outbox and opaque synthetic ratchet-state persistence.
  Wrong password/outer keys return failure. A foreign peer's ACK does not
  retire the frame; the intended peer's ACK does. This is not a real ratchet
  handshake or a network-delivery test.
- Erasing one identity leaves its application data absent on cold reopen and
  preserves its backend roles. A second identity retains its profile, message,
  attachment, outbox and ratchet bytes; its three native files are byte-for-byte
  unchanged by the first identity's erase. External blob-tier ownership and
  actual filesystem cleanup are not exercised by this internal attachment.
- After two actual compaction SIGKILL cuts, the new adapter itself resolves
  the prepared state, recognizes the previous host root, writes new data and
  cold-opens by the original outer keys. The blob case adds three actual
  SIGKILL boundaries. Writer PIDs, kill results and terminal statuses were
  observed. The earlier shared run exposed an empty-marker race in the test
  harness; markers now publish by flushed temporary file + atomic rename.
  That failing run was not credited as adapter/crash qualification.

Focused analysis of seven changed files is clean. The same signed published
hidden-volume 2.7.2 macOS arm64 asset was selected and its SHA rechecked; no
native source, ABI or release pin changed. All fixtures/processes are disposable
and contain no user data. This port is a working domain-storage boundary, not
a completed three-mode feature. Filesystem/catalog admission and managed-file
opening are implemented below; production worker open/close, automatic
reclamation, all-online routing, mode/unlock UI,
biometric-vault scope, password rotation, recovery and erase still need wiring
and platform qualification. Existing containers are not converted.

## Public managed catalog persistence

`ManagedCatalogStore` now persists the strict visible-only catalog in an owned
ordinary-SQLite connection. Each registration reloads the current bounded
payload under `BEGIN IMMEDIATE`, updates payload and local revision together,
and returns after COMMIT. Independent owners do not overwrite each other's
old snapshots. Repeating an ID/mode after a lost response is idempotent; changing
the mode of an existing ID is rejected, never treated as a plaintext fallback.
Contention is an explicit retryable SQLite failure, not an empty catalog.

Opening verifies an exact versioned catalog schema and public application tag.
Missing rows, corrupt/oversized JSON, hidden entries, credential fields, extra
schema objects, future versions and non-DELETE journal modes fail closed. A
new initializer refuses an existing catalog/schema. Invalid open consumes and
closes its connection without resetting metadata. Public revision counters are
not cryptographic freshness witnesses. No automatic orphan removal or deletion
API exists at this stage.

Seven host cases exercise cold reopen, exact public payload, duplicate retry,
independent owners with stale initial snapshots, native write-lock contention,
rejected native COMMIT, count/mode/revision bounds, corrupt metadata, foreign
schemas and close/privacy boundaries. A further macOS native case actually
SIGKILLs two writer process groups: once at SQLite's pre-COMMIT hook and once
after the registration returns. Fresh processes read the complete old/new
catalog respectively, and retrying the lost response creates no duplicate.
This is process-crash qualification, not physical power-failure qualification.
The layout also names the plaintext database, all three encrypted role files
and identity-local blobs separately. A final joint run passed 32 cases with no
skips, including the existing real encrypted domain adapter; focused analysis
of 11 changed/affected Dart files is clean.

This remains an **owned-connection port**. The root/catalog admission wrapper
below now handles first initialization, and the managed-file factory handles
identity creation/opening. Catalog membership never authorizes file
ownership or cleanup; actual stores must authenticate their identity and role.
Worker boot, migration, reclamation, password/biometric and application routing
remain unfinished.

## Managed root admission and bootstrap

`ManagedDirectoryCatalog` now owns a catalog connection inside an admitted local
profile. `openExisting` returns null only when the entire managed root is absent.
An existing root with a missing catalog always fails, including a root already
containing identity directories. A corrupt catalog is preserved and refused;
neither case is silently reset to an empty list.

Explicit `createOrOpen` initializes a catalog in a newly reserved PRIVATE sibling
directory, closes it, syncs the directory and publishes the entire directory
without replacing any existing destination. Another creator's complete root
wins; the loser opens it without overwriting its catalog. A process killed
before publication leaves an unpublished sibling, never a final root with a
half-initialized catalog. Unpublished siblings are neither adopted nor swept.
Normal failed bootstrap cleanup is non-recursive and removes only the same
fresh directory and exact recorded file; a replacement or unexpected child is
preserved. Failure after publication leaves the complete root available to retry.

On POSIX the new root is created as 0700 and its catalog is restricted to 0600
before schema/payload writes. Existing ownership, permission/type and ancestor
checks refuse symlinks and unsafe paths. A trailing slash is removed before
`lstat` so it cannot turn a final-component link into an apparently ordinary
directory. Observable root/catalog replacement invalidates an open owner.
SQLite recovery sidecars (`-journal`, `-wal`, `-shm`) are admitted before SQLite
can open them. The sidecar regression's pre-guard control reached SQLite and
failed with CANTOPEN; it did **not** demonstrate an accepted escape in the pinned
SQLite engine. It verifies the earlier explicit filesystem-admission boundary.

Darwin extended ACLs are checked independently from mode bits: only empty or
deny-only ACLs are admitted, including the usual deny-delete entry. An allow
ACL is conservatively refused even if chmod still reports 0700. Initial tests
caught incorrect treatment of Darwin's absent-ACL/end-of-list results; those
failing runs were not credited. A separate headless run created and reopened a
fixture beneath the real home-directory ancestors, outside the temp fixture tree.
This remains a conservative policy, not a complete Darwin effective-ACL evaluator.

The Android ancestor policy recognizes the platform's protected `system`
UID/GID 1000, as defined by [AOSP filesystem permissions](https://source.android.com/docs/core/permissions/filesystem).
The identity root/catalog still must belong to the current application and be
private. Other application, media/OEM groups and non-sticky world writes remain
refused. Actual ancestor ownership/modes were read from an attached Android;
this is not an Android application-backend qualification.

Windows code uses the process token's SID, the existing handle-bound ACL probe,
file identity/attributes, normalized final-path comparison and protected
current-user/System/Administrators directory ACLs. Reparse leaves and remote
profile roots are refused. Publication uses
[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
without REPLACE_EXISTING, with WRITE_THROUGH; protected ACL construction follows
[Microsoft's security descriptor format](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-string-format).
The existing pinned win32 dependency is now direct; its version did not change.
The Windows policy/path tests run on the host; native Windows filesystem
behavior has **not** yet been qualified by these tests.

A final macOS joint run passes 54 cases with no skips: the prior 32 plus 14
root/admission cases, five Windows policy/path cases, two POSIX/Android policy
cases and one actual process-crash case with two SIGKILL boundaries around root
publication. The earlier catalog-COMMIT crash case also runs in this set.
Focused analysis of ten changed/affected Dart files is clean. No user stores
or installed application were changed; no Rust build or release pin changed.

Remaining boundaries are explicit. These path witnesses do not claim descriptor-
relative backend access or defense against hostile same-user ABA substitution.
They require a private root and trusted platform ancestors. Linux/Android use
renameat2 with NOREPLACE, refusing unsupported kernels/filesystems rather than
falling back to ordinary rename. Bionic exposes that libc symbol only from
[API 30](https://android.googlesource.com/platform/bionic/+/master/libc/include/stdio.h).
The Linux/Android binder now uses libc's variadic `syscall` when that symbol is
absent; this retains the same no-replace kernel operation. Native
Android/Windows/iOS managed-file operations and full Linux backend integration,
power failure, worker boot and the mode/identity UI remain unqualified or
unwired. Identity reservation/publication and keybox/content opening are now
qualified below on macOS. The existing
onboarding default and legacy stores are unchanged.

## Managed identity file factory

`ManagedIdentityFiles` now creates and opens the actual encrypted/plaintext
backends under an admitted root. A fresh random local ID owns a private
staging directory, role metadata, permanent empty lock marker and private blob
directory. Encrypted identities own `keybox.hv`, `content.hv` and
`maintenance.hv`; plaintext identities own `data.store`. Creation commits its
initial payload, closes the files, syncs the staging directory and publishes
without replacing an existing identity. It then reopens and validates the
backend before durably registering the catalog entry and returning a handle.
A catalog entry alone never grants permission to initialize a missing backend.

The outer keybox selects the existing HEAVY password KDF (256 MiB, time 4,
parallelism 4). The two independent random internal passwords use the native
DEFAULT preset. Exported 64-byte keys remain the keybox's stable outer keys.
Plaintext reopen uses a public deterministic locator, not a password or an
assertion of encryption. Credentials are copied for synchronous native calls
and owned copies are wiped afterwards. No raw native error text, path or local
locator is included in factory failures; safe original stack locations remain.

Each session retains its root ownership and an `identity.meta` lease until
all payload handles close. Role metadata contains only local ID and mode.
An exact-schema EXCLUSIVE SQL transaction is held on all platforms. POSIX also
holds `flock` on the separate permanent `identity.meta.lock` inode; Windows
uses SQLite's handle-bound locks. Neither open nor contention recreates a
missing/invalid marker. A second root, isolate or process cannot cooperate as a
second owner while the first lease is held. Closing the root with an active
session reports busy. Failed open/close resources remain attached for retry;
the lease is released last.

A new regression reproduced an important POSIX limitation in the initial
SQL-only lease: opening and closing the database through a raw file descriptor
released SQLite's process-scoped lock, permitting a second process to open.
[SQLite documents this close/locking behavior](https://sqlite.org/howtocorrupt.html).
The independent marker lock preserves ownership when unrelated descriptors to
either metadata or marker are closed. Placing flock on the metadata inode itself
was rejected after the macOS test exposed self-contention with SQLite locking.
A native `FILE*` finalizer supplies a GC safety net; it does not replace explicit
worker teardown or promise prompt release after killing one shared-group isolate.
Live database backup must still use a coordinated, quiescent owner boundary.

Interrupted creation leaves complete pending/final files intact. Explicit
`resumeEncrypted`/`resumeUnencrypted` requires a known local ID and correct mode;
encrypted recovery authenticates the existing role and payload before publication
or registration. Retrying after a lost registration response is idempotent.
Both pending and final directories present is an ambiguous recovery failure,
with both copies preserved. No automatic orphan discovery/sweep, recursive
cleanup, hidden-store fallback or legacy conversion is performed.

The final joint macOS run passes **72 cases, no skips**, including eight lease
cases, a native independent-process contention case, eight file-factory cases
and a factory process-crash case in addition to the previous 54. Actual native
checks cover exact KV/log/anchor data, cold password/key reopening, HEAVY outer
KDF parameters, plaintext/ciphertext boundaries, duplicate/root contention,
wrong credentials, foreign role files, payload symlinks and four publication/
registration fault boundaries. The factory crash case performs three actual
SIGKILL cuts: before directory publication, after publication and after catalog
commit before handoff. Each explicitly resumed identity retains exact payload
and one catalog entry, then cold-opens by its original outer keys. The earlier
root/catalog crash tests also run in the joint set. A first factory crash run
with an unarmed bootstrap hook failed in the harness and was not credited.

This is the managed file ownership layer, not the enabled application feature.
UI/default selection, worker open/close barriers, orphan recovery UI, automatic
bounded encrypted reclamation, all-online routing, password rotation, erase,
biometric integration and native qualification on other platforms remain.
Power failure and abrupt shared-group worker-isolate cleanup are not qualified.
No real identity, installed application, native source or release pin changed.

## Older Android atomic publication

The Linux binder now admits only known ARM EABI, arm64, IA32 and x64 ABIs;
UAPI syscall numbers were cross-checked against the Android NDK headers.
Only an absent libc `renameat2` symbol selects the direct syscall path. A failed
wrapper call is returned as a failure, never retried through another mechanism.
Missing syscall support or an unknown ABI fails closed, before guessing a call
number. The binding uses machine-width `long` values, native pointers and
[Dart's explicit variadic FFI signature](https://api.dart.dev/dart-ffi/VarArgs-class.html).
`AT_FDCWD` and `RENAME_NOREPLACE` remain unchanged in both native paths.

A standalone real Linux arm64 probe passed ten filesystem scenarios in JIT and
again as an AOT executable: existing empty/populated directories and symlinks
are preserved, successful publication moves exact payload, and a missing source
cannot create a destination. Each set runs first through libc and then with
only its rename wrapper hidden from symbol resolution, forcing the actual
syscall. The old wrapper-only candidate passed five cases then failed at the
first forced-syscall case; that is the recorded red control. A first AOT build
failed because its ephemeral compiler home was read-only; it was not credited.
Both successful runs used an immutable official Dart 3.12.0 Linux image, with
network disabled and source/FFI package mounted read-only. The source needs no
new native build, main binary feature or dependency.

The macOS joint suite now passes **76 cases, no skips**, adding four ABI/binder
checks to the preceding 72. Focused analysis is clean. These probes qualify the
Linux arm64 publication primitive, not Android libc/seccomp/OEM behavior, other
architectures, the full managed backend on Linux or power-loss durability.
No connected Android was available in this round. Android packaging/runtime
qualification still precedes enabling new storage modes in the application.

## Worker close ownership prerequisite

The existing single-store worker no longer kills its native owner when close
reports an error. The serving loop admits only further close attempts after
shutdown begins. The facade rejects ordinary I/O, shares concurrent close
waits and retains one wire request after a caller timeout. Late failure keeps
the worker supervised for retry; late success is accepted only from the real
success envelope. A dead worker's uncertain release remains an error on later
close calls instead of becoming an idempotent success.

Five gated regression cases failed against the prior facade: retry after
refusal, concurrent wait, timeout/retry, late refusal and repeated close after
worker death. A sixth test exercises the production command server itself with
a disposable synchronous store that refuses its first close. The server remains
available and its second close succeeds. Together with existing close/death and
headless-import checks, **30 cases pass**. Native-close failure and abrupt
native-worker abandonment are not manufactured or claimed by these fixtures.
The domain storage facade now also retains a separate retiring owner after a
failed close. Ordinary reads/writes see a locked store, but close and both
password/key reopen paths retry that exact owner before opening a replacement.
Close errors propagate instead of being logged as a dropped handle. Accepted
file/ratchet/sequence work still drains before retirement; derived caches are
invalidated on both success and failure.

All four new facade regression scenarios failed against the former swallowed-
error path and now pass. The related facade/file/roster lifecycle suite reports
41 PASS and one opt-in native skip; the skipped real-container roster case was
then explicitly enabled and passed separately, preserving master/child keys
through promotion, shrink and cold key-based reopen. No skipped case is counted
as passed. Focused analysis of the three changed facade/test files is clean.
The managed factory is not yet wired into worker boot or the application's UI.

## Implementation boundaries

1. Managed stores need independent directories for their database and blobs.
   A database, journal, temporary replacement or blob for one identity must
   never share cleanup ownership with another identity or the hidden file.
2. A publicly readable catalog carries only an opaque random local ID and
   protection mode. Keys, passwords, public network addresses and decrypted
   display names remain outside it. Hidden-space availability is not inferred
   from this catalog; the hidden-unlock action remains independently available.
3. Use the existing authenticated-state engine for encrypted identities, one
   separately owned keybox, content and maintenance files per identity.
   Preserve its Merkle/rollback and ratchet
   guarantees. Evaluate SQLite only for genuinely unencrypted identity data;
   page authentication plus a command hash chain is insufficient for encrypted
   ratchet-state freshness. Neither backend is enabled in the application yet.
4. Reuse reviewed encryption and bounded memory-hard password derivation for
   encrypted identities. Managed-file reclamation must also work when a user
   entered using biometric pre-derived keys rather than a password; it must
   not guess that unknown spaces belong to the active identity.
5. Run database operations, KDF and reclamation off the UI isolate. Do not
   weaken delivery ACK, authorization-floor, ratchet or teardown barriers to
   improve storage speed. Measure steady-state growth with repeated overwrite
   and deletion, rather than only comparing an empty database's size.
6. Wire mode choice before opening any store; visible identity selection,
   per-identity accounting, cleanup, all-online sessions, biometric reopen,
   password rotation, erase and recovery must follow the selected locator.
7. Existing `hiddenSpace` and historical `plain` preferences both name legacy
   container-backed data. Never interpret the historical flag as permission
   to read/write plaintext or to convert the existing container automatically.
8. A migration needs an explicit source/target choice, authenticated copy,
   readback and retained source until successful publication. A crash must
   leave at least one readable copy. Migration to plaintext needs separate
   informed confirmation; a failed unlock must not trigger migration.

## Qualification before enabling the new default

- Native cold reopen for encrypted and plaintext stores; wrong password and
  missing cipher provider cannot select plaintext or create replacement data.
- Independent-process crash before commit, after commit, and after observed
  delivery ACK, with exact message/identity and ratchet-recovery oracles.
- Repeated overwrite/delete workloads with bounded journal and file growth;
  per-identity size attribution and reclamation while other identities remain
  untouched and readable.
- Catalog corruption, path and symlink substitution, interrupted creation,
  cleanup/reopen races and interrupted password rotation/migration.
- Mixed hidden/encrypted/plain identities, identity switch during I/O,
  all-online ownership, erase, content serving and one-prompt biometric reopen.
- Actual packaged native libraries, provenance/privacy checks and Android,
  Windows and macOS smoke tests. Host-only tests do not qualify these targets.

References: [SQLite reclamation and durability pragmas](https://sqlite.org/pragma.html),
[SQLCipher key and authentication semantics](https://www.zetetic.net/sqlcipher/sqlcipher-api/),
[Dart SQLite hook/provenance options](https://github.com/simolus3/sqlite3.dart/blob/main/sqlite3/doc/hook.md).
