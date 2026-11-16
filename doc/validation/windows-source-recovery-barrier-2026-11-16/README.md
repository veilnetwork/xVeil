# Existing-source recovery barrier on Windows

Status: source recovery now uses an explicit directory barrier instead of the
generic Windows publication no-op. Managed production defaults remain OFF.

## Why this was separate from publication

An existing private repair journal may survive the process that published a
replacement hidden container. A later opener must validate the current source
generation and its directory entry before rewriting another store's references
or deleting its private recovery obligation. Merely seeing the new name is not
that barrier. `ManagedFsPlatform.syncDirectory` intentionally remains a no-op
on Windows for ordinary managed publication, which carries its own move flags.
The reference backend therefore previously refused every Windows operation.

`syncSourceDirectory` is a separate capability. On Windows it opens the existing
directory with write access, backup semantics and reparse-point refusal, binds
the opened handle's volume/file ID and type to the admitted witness, and checks
`FlushFileBuffers`. The portable owner also checks ownership, safe ancestry and
the same directory object before and after the call. A missing, substituted,
unreadable or unsupported directory is an error, not successful recovery.
The POSIX branch retains the actual directory-fsync implementation and its
existing failure injection seam.

This follows the native hidden-volume rewrite's existing Windows mechanism.
The API references are [CreateFileW directory access](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
and [FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers).
A successful OS flush is not a physical power-loss experiment or a guarantee
about storage hardware that does not honor flushes.

## Admission and completion

The reference backend probes the existing-parent capability under its exclusive
profile/catalog ownership before preparing any new private journal. It does
not require elevation or ask for broader directory permissions. It then retains
the existing authentication, exact source binding, generation proofs and roster
checks. The observed source name is flushed again before applying references
and clearing their journals; the stable-source checks surround this barrier.
A refusal at either source barrier leaves the private journals intact. No
discovery of unknown hidden spaces,
plaintext fallback, public master marker or forced migration was added.

## Evidence

- A native API experiment succeeded with write access both elevated and under
  impersonation with administrative membership/privileges disabled. Read-only
  handles failed as expected. No real application data was used.
- An independent Windows AOT probe exercised the actual Dart implementation:
  stable flush, wrong witness, file-as-directory, missing path, replaced
  directory and unchanged sibling data. All eight checks passed.
- Seven deterministic POSIX dispatch controls cover initial admission, lost
  ownership, unsafe ancestry, replacement, changed permissions and flush errors.
- The macOS regression run passed **89 tests across seven suites,
  with no skips**, including native process-death/reference repair, worker
  recovery, preference quiescence, full-profile compaction, custom source names
  and ordinary collection/controller behavior. Changed-source analysis was clean.
- The final Windows run passed **14 native recovery tests**, with **four
  explicit process-death skips**, in a restricted primary-token process with
  administrative membership and privileges disabled. It covers publication,
  abort, selected recovery, partial apply, malformed/copied journals, changed
  source, caller-buffer mutation and an actual directory-flush refusal that
  retains both journals and old references. Native hidden-volume was rebuilt
  from the current locked sources; both source and selected-library digests
  were verified. These tests run headlessly, without starting a user-facing app.
- Windows exposed a defect in the old fault fixture: a trailing separator
  prevented its string-match injection from firing. The fixture now uses the
  owner's actual canonical parent and asserts that the refusal counter advances
  exactly once. This corrected control passed separately on macOS and in the
  complete Windows run. Product source did not change after the 89-test run.
- Temporary native sidecars in the private test SDK were restored and compared
  with their original bytes. All four owned scheduled tasks and the private
  data directory were removed; no owned probe processes remained. Approximately
  543 MiB of native intermediate files were removed, retaining only the exact
  qualified DLL for subsequent probes. No release/native pin was published.

The first Windows test copy lacked Flutter assets and did not reach its tests.
Another setup used a temporary directory writable by other accounts; the
existing ancestry policy correctly refused it. The qualified run uses a new
private data directory without changing the original directory's ACL. These
setup failures are not counted as product failures or passing qualification.

## Remaining scope

The Windows process-death writer fixtures are still separately marked skipped;
host SIGKILL evidence does not qualify them. Packaged application cold recovery,
physical OEM behavior, all-target native packaging and release AOT remain
separate activation gates. This change does not enable the three storage modes
in production or authorize a push/release.
