# Selected-root recovery through application storage workers

The [private recovery backend](../external-compaction-reference-recovery-2026-11-15/README.md)
could repair external references, but ordinary application opens did not invoke
it. Six native regressions reproduce the gap: completed rewrites expose old
child keys, cancelled rewrites retain their intents, and malformed intents do
not prevent opening. The same six regressions fail through the application's
ordinary `ProfileStorageRouter` against the previous source, then pass with
the integration restored. Compilation-only fixture failures are not counted
as reproductions.

## Recovery admission

After authentication, an identity worker checks only the selected store's
reserved journal declarations. Any declaration, including partial or corrupt
metadata, prevents handing the store to a caller. The bounded failure kind
`recoveryRequired` contains no credentials or identifiers. Failed bootstrap
closes the identity before releasing its root; failed close remains owned by
the existing supervised retirement protocol.

The ordinary profile router supplies a recovery callback to existing and newly
created managed facades. On that specific refusal, the facade invokes its
catalog worker and retries its original open exactly once. A standalone worker
without this coordinator refuses the pending root. Other failures do not start
recovery, probe another identity or fall back to plaintext. Password/key copies
are owned across the recovery RPC and retry and cleared when settled.

The catalog worker authenticates the same explicit identity and checks its
catalog mode. Only a pending journal requires dropping its own shared catalog
and profile grants, then obtaining exclusive existing-profile admission. The
backend verifies the actual hidden source generation and its POSIX directory
durability barrier before applying/clearing the selected private journal.
Other visible identities' journals and credentials are not read. Afterwards
the worker reacquires existing shared roles without creating a missing root.
A competing live owner refuses exclusive recovery; releasing it permits a
later retry. The worker pauses its serving subscription during the accepted
async operation, retaining FIFO ownership over queued work and close.

No journal means no hidden-source probe and no lease upgrade. An unjournaled
selected root opens with the hidden source absent while another identity's
pending journal remains untouched. Catalog metadata gains no master flag,
hidden-space index or recovery-pending marker. The Windows backend still
refuses pending recovery because its source-directory durability barrier is
not implemented; ordinary unjournaled Windows opens retain their prior path.

## Qualification and remaining scope

Thirteen new native cases use actual encrypted/plaintext masters and a real
prepared hidden rewrite. They cover normal profile routing after publication
and cancellation, successful key-based reopen, malformed intents with password
and key entry, standalone-worker refusal, wrong-password refusal, live-owner
contention/retry, missing-source preservation/retry, and the unjournaled path.
They check exact child-key generation, labels, anonymity, private journal
removal/preservation, sibling journal equality, selected metadata and surviving
hidden payload. They do not infer correctness merely from equal empty lists.

The final sequential regression run reports **94 passes, no skips**, including
existing backend process-death recovery, managed facades/profile ownership,
worker boot/close/death, reclamation, erasure lifetime and headless-import checks.
Static analysis of all changed sources and the new suite reports no issues.
The selected native library and
all 145 recorded Rust input digests were verified; no native changes or Rust
build are part of this round.

This is host-native storage-route qualification, not a new physical Android,
Windows or application release-AOT run. The new catalog RPC has not itself been
killed at every recovery boundary. All-owner authorization and prepare/resume
wiring in the compaction dialog remain incomplete. Production managed defaults
stay disabled and the general mixed-profile compaction guard stays enabled.
No push or release is part of this round.
