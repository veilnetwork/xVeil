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

## Implementation boundaries

1. Managed stores need independent directories for their database and blobs.
   A database, journal, temporary replacement or blob for one identity must
   never share cleanup ownership with another identity or the hidden file.
2. A publicly readable catalog carries only an opaque random local ID and
   protection mode. Keys, passwords, public network addresses and decrypted
   display names remain outside it. Hidden-space availability is not inferred
   from this catalog; the hidden-unlock action remains independently available.
3. Evaluate SQLite for managed KV/log persistence, with authenticated database
   encryption for the encrypted mode and actual plaintext for the unencrypted
   mode. Existing domain storage can remain above `AsyncKvLogStore`; a new
   backend must preserve atomic multi-operation commits and commit anchors.
   No database or KDF dependency has been added by this foundation change.
4. Use reviewed encryption and a bounded memory-hard password KDF. Verify the
   packaged cipher provider before encrypted creation; a missing provider must
   fail closed. SQLCipher raw-key semantics require an actual database read
   to authenticate opening, not merely a successful `PRAGMA key` statement.
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
