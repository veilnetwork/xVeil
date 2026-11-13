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

The new `StorageProtection` contract and managed catalog are a foundation only:
they are not yet connected to onboarding, unlock or the persistence adapters.
The catalog rejects hidden entries, credentials, network identifiers, unknown
fields, duplicate locators and paths outside a strict local ID format. It
does not silently replace malformed existing metadata with an empty catalog.
The pure layout does not claim to solve filesystem symlink races.

An isolated native connection prototype now uses `sqlite3` **3.5.2** with its
SQLCipher hook. The current Flutter SDK pins a dependency that prevents using
3.7.1; no SDK constraint was overridden. The actual macOS arm64 asset matches
the package-pinned SHA-256 and passed GitHub attestation verification against
the upstream repository. This does not qualify the engine on other platforms.

Four native tests cover encrypted readback without plaintext in the database,
wrong-key/wrong-mode attempts preserving the encrypted file, actual plaintext
readback, and errors omitting SQL, bound values and local paths. Keying uses
`sqlite3_key` with a wiped native buffer rather than SQL containing the raw key.
The key is followed by an actual database read. These tests use fixture keys;
password derivation, durable schema, reclamation and application integration
remain unfinished. Together with the five catalog checks, nine focused tests
pass. Neither the existing onboarding default nor existing stores are changed.

The plaintext KV/log adapter now keeps payload mutations, the commit sequence
and a bounded 1024-entry branch-root history in one transaction. It selects
`synchronous=EXTRA`, rollback journals, secure deletion and full auto-vacuum.
Namespace erasure does not load the whole history into Dart. Six host cases
cover connection reopen, failed COMMIT rollback, bounded growth under 64
rewrites of a fixed 2 MiB log set, shrink after deletion with a sibling file
unchanged, fork/history retention, locator mismatch and encrypted rejection.

**The encrypted SQLite prototype was rejected before application integration.**
A native qualification replayed an old data page while leaving fresh metadata
and commit roots intact: the experimental store accepted the old reservation
under the new anchor. The first probe failed on a PRAGMA result type and was
not counted; after correcting the probe it failed on the intended old-value
assertion. The current test retains a native negative control demonstrating
that page replay remains possible and checks that `PlainSqliteKvLogStore`
refuses an encrypted connection. Passing this guard does not mean SQLCipher
page replay was fixed. No released application selected this prototype.

Ordinary encrypted identities will therefore retain hidden-volume's existing
authenticated-state foundation, separately owned per visible identity. The
SQLite adapter is limited to explicitly unencrypted storage, where hostile
filesystem access already exposes the identity secrets. The SQLCipher
connection remains an isolated evaluation primitive, not an encrypted identity
adapter. Remove unused experimental packaging before shipping the new modes.
Fresh-process crash, filesystem admission, bounded managed-file reclamation,
password/biometric handling, UI and worker integration remain unqualified.

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
managed-directory lease test. The probe serializes its own files; admission
and an identity lease across source-close/prepare still need implementation
before a mode can be enabled. No existing container or onboarding choice changed.

## Implementation boundaries

1. Managed stores need independent directories for their database and blobs.
   A database, journal, temporary replacement or blob for one identity must
   never share cleanup ownership with another identity or the hidden file.
2. A publicly readable catalog carries only an opaque random local ID and
   protection mode. Keys, passwords, public network addresses and decrypted
   display names remain outside it. Hidden-space availability is not inferred
   from this catalog; the hidden-unlock action remains independently available.
3. Use the existing authenticated-state engine for encrypted identities, one
   independently owned file each. Preserve its Merkle/rollback and ratchet
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
