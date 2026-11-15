# A worker-local owner for mixed-profile prepared compaction

This is an integration prerequisite, not activation of the compaction dialog.
The [selected-root recovery](../managed-reference-worker-recovery-2026-11-15/README.md)
already handles a private journal during normal opening. The missing active
operation must retain full-profile ownership through native preparation,
metadata repair and publication. The existing async native port dispatches
individual calls through child isolates; it is not itself a full-profile
transaction or the owner of the application's profile leases.

Hidden-volume now exports `HvPreparedCompaction` for an existing storage worker.
Preparation, commit and abort execute synchronously in that worker; no native
step is dispatched elsewhere. The capability is isolate-unsendable. It copies
and clears its owned password buffers while preserving caller buffers. Commit
is terminal on success or failure, matching the native consuming state machine.
Explicit close aborts unpublished work and consumes the original native owner;
repeated close does not repeat a consuming free. Typed post-publication warnings
retain their meaning. The original async port and native ABI are unchanged.

The host still must authenticate all relevant owners, repair and close staged
handles, persist external intents, check its lifecycle authorization before
commit, and retain actual profile grants until native work settles. This API
does not perform those application steps or discover unknown hidden spaces.
Omitted spaces remain outside the native keep set. It must not run on a UI
isolate; a finalizer is not proof of release.

## Qualification

Five new plugin cases cover repaired publication, repaired abort, failed
preparation, refusal with a live staged handle, terminal commit/idempotent close,
password preservation and rejection of isolate-message copying. Together with
the four existing async cases, the sequential plugin run reports **9 passes,
no skips**. Exact payload/reference and original source-byte checks support
these conclusions, not merely a returned success flag.

The application process-death harness now exercises both ports at prepared and
published checkpoints. All four real child processes hold exclusive profile
grants when the parent observes their ready marker. A competing profile open
must fail specifically with lease contention or SQLite BUSY; before publication
the original hidden source also refuses a competing open. Each child is killed
with SIGKILL and actually awaited before recovery. The new worker-local cases
recover the original source generation before publication and the new generation
after publication; all master references and exact hidden payloads are checked.
The harness runs the native owner in its own process and does not establish
application catalog-RPC crash coverage.

The final sequential application run reports **32 passes, no skips**, including
the expanded 18-case backend suite, 13 normal profile-opening recovery cases and
the headless-import guard. Analysis of changed plugin/application files reports
no issues. The 50-entry ABI checksum table matches the selected binary; all
145 recorded Rust input digests and the native binary digest were verified.
No Rust changes/build or version release is required by this Dart-only port.
Initial fixture/setup failures are not counted as product regressions.

## Remaining integration

The all-owner credential collection, full worker operation and prepare/publish/
resume wiring in the app dialog are still pending. Pending recovery on Windows
still requires an implemented source-name durability barrier. Physical OEM,
application release-AOT and worker crash-boundary qualification remain open.
Managed production defaults remain disabled and the general mixed-profile
compaction guard remains enabled. No push or release is part of this round.
