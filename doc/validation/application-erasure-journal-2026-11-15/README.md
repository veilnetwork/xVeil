# Durable application erasure journal

## Publication and ownership

The live full-profile wipe now captures saved-entry addresses and publishes
`application-erasure.json` under the exclusively owned storage coordinator
before OS-record removal. This enclosing application journal is separate from
the native plan and terminal; their roster-free formats are unchanged.

The bounded private journal contains the exact original operation binding and
the immutable [saved-entry address set](../saved-entry-recovery-capture-2026-11-15/README.md).
It contains no password, pattern material, identity name, network address,
absolute path or hidden-space roster. The legacy container contributes one
fixed scope regardless of hidden identities. Enumerable scopes follow the
user's requested visible-count storage model.

Publication uses a restricted temporary file, flushed content, atomic
no-replace publication and parent-directory sync. An ambiguous retry reuses
the same file only if its complete contents and binding match. Failed sync
cannot acknowledge the persistence barrier. Publication happens outside the
native worker's retirement callback, avoiding reentry into an actor waiting for
that callback. Retirement then compares its capture with the acknowledged
journal; changed addresses refuse cleanup rather than silently widening it.

## Recovery and finalization

The journal survives native plan/terminal removal. Its presence, including
malformed content or a symlink, blocks ordinary coordinator/preferences/router
admission. Native finalization removes and syncs it only after payload/auxiliary
completion and before exclusive-role release. A failed last sync retains the
same live owner for retry. The kernel role closes the admission gap after the
last marker unlink.

Snapshots expose saved addresses read-only. While the original plan is available,
its scope set must match. Terminal retry with a journal reruns external absence
verification; a newly appearing OS record is preserved and refuses success.
An already unlinked native terminal remains an owned final-sync retry.

After both native markers are gone, `reconcileApplicationJournal` checks current
profile/coordinator identities, operation structure, journal bytes and known file
absence under a separate read-only owner. It can verify external absence and
finish release. It cannot retire scopes, replace the witness, remove payloads
or reconstruct a terminal mutation roster. Retained live-operation recovery
also recognizes this journal-only phase.

## Evidence

- Fifteen native checks cover binding/idempotence, publication/sync failure
  with unchanged payloads, non-application/wrong-scope refusal, repeated terminal
  OS checks, read-only worker restrictions, owned unlink-sync retry and
  corrupt/foreign/symlink preservation.
- Three of those checks SIGKILL a separately launched writer: after acknowledged
  journal publication, after native terminal publication, and after native
  plan/terminal removal. Fresh owners recover the exact address set. A synthetic
  OS-record file starts nonempty and is cleared durably during retirement.
  OS credentials are modeled; filesystem I/O, native ownership, process death
  and subsequent role acquisition are real.
- A production-composer check observes every OS-record deletion and verifies
  that the actual on-disk journal already contains exactly the original six
  fixture addresses. Successful wipe removes that journal.
- A compiled control omitting terminal external verification fails the
  reappearing-record assertion normally. Restoring the exact source passes.
  Compiler errors, timeouts and crashes are not behavioral controls.
- The old final-sync injector now arms only on native terminal publication;
  journal publication must not trigger it earlier. Its assertion distinguishes
  absent native markers from the retained application journal. Earlier missing
  import/exclusive-fixture mistakes and broad fault selection are harness
  corrections, not reported application defects.

278 checks pass across 20 serial Flutter suites; focused Dart analysis is clean.
The qualification also covers old quick-unlock read races, native
erasure, worker retry, receipt handoff, application binding, native completion and
preferences startup exclusion. Sources and four pinned native-library hashes
are frozen around qualification. No Rust/media engine is rebuilt and no user's
container, OS credential store or device installation is opened.

## Remaining work

The following [cold-start implementation](../cold-profile-recovery-2026-11-15/README.md)
connects this journal to an isolated application owner and startup UI. The limits
below describe the journal-only round.

Cold application startup still shows the refusal shell. The next standalone cold
owner must connect these journal/reconciliation primitives to platform resource
checks and fresh preferences/router/UI handoff outside ordinary providers.
User-facing automatic continuation is not implemented by this increment.

These host process-kill checks do not qualify power loss, physical disk failure
or packaged platform applications. Pre-publication staging-file crashes are not
among the three checkpoints; OS removal is never admitted before acknowledged
publication. Malformed journals are preserved rather than repaired/replaced.

The requested three storage modes and encrypted default remain unfinished and
disabled. There is no push or release in this cycle.
