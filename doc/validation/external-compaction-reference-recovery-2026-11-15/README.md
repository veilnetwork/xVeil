# External master reference recovery and strict maintenance reads

Managed storage remains disabled in production defaults. The general
mixed-profile compaction guard remains enabled. This follows the
[storage-scope fix](../compaction-storage-scope-2026-11-15/README.md): repairing
rosters inside the hidden replacement does not repair references held in a
separate encrypted or plaintext master. The new backend is not yet wired into
the application's maintenance dialog, worker RPC or cold-start recovery flow.
The legacy strict-read correction below does apply to existing compaction paths.

## Confirmed legacy maintenance defect

The historical `loadRoster` may return null for a malformed roster or an
unreadable declared roster file. That cannot distinguish absence from damage.
Two controller regressions reproduce the consequence: password probing calls
the damaged master a successfully opened non-master, while key remapping can
report complete success without repairing that master's references. Both fail
against the original controller. A separate native control using historical
reads also lets external preparation acknowledge an unreadable master.

`RosterMaintenanceReader` now provides a strict capability. Hidden-volume's
mapping implements it without changing the historical reader's behavior.
Maintenance refuses unreadable primary data, unknown row fields, malformed
keys and unsupported anonymity fields; a missing roster and a valid empty
roster remain distinct. The controller requires this capability for password
coverage and both remap passes. An unavailable capability refuses maintenance.
The existing cancellation/publication checks remain. Gated test doubles now
intercept the strict method they actually model. Unit checks preserve exact
original metadata and the commit sequence during failed reads, including a
broken declared large-roster file.

## Private cross-owner protocol

`ManagedLegacyReferenceRepair` requires actual exclusive storage-profile and
catalog grants. Before publication, preparation authenticates every enumerable
identity and validates all relevant rosters before the first journal write.
The catalog does not gain a flag identifying masters with hidden references.
Each affected master stores a bounded, versioned journal in its own volume,
bound to its locator and outer-key digest, with old/new key pairs only. No
password, label, hidden-space identifier or reverse index is placed in public
metadata. An explicitly plaintext master protects this journal exactly as it
protects its existing child keys: its local contents are unencrypted.

Journal publication is read back before acknowledging preparation. Partial
failure preserves the old rosters and any already saved intents. Existing
incompatible or unreadable intents cannot be overwritten. Borrowed authorization
and change buffers are copied before yielding; owned copies and decoded roster
keys are cleared after use. This is best-effort buffer handling, not an erasure
claim for immutable strings, the Dart heap, swap or storage history.

After the native prepared owner has settled, recovery validates every journal
and relevant roster before applying changes. Old/new keys are tested against
the actual profile-local `xveil.store` and its authenticated tree. Uniform
old-only results retain the original rosters; uniform new-only results apply
the new references. Both/neither matches, inconsistent generations, I/O,
integrity failures or changed path witnesses retain the journals and fail.
Recovery reloads each live roster rather than restoring an old whole-list
snapshot. Independently owned child references, labels and anonymity survive.
Saving the roster precedes deleting its journal, so an already applied save
can be retried. A partial journal is not absence merely because download-style
`hasFile` reports incomplete.

A visible pathname is insufficient evidence of durable publication. On POSIX,
recovery confirms its containing-directory barrier before changing or clearing
any external journal; native prepared publication already syncs replacement
file data. A failing barrier preserves all intents and rosters. A control that
omits this barrier fails the injected directory-sync refusal. Windows' existing
directory-sync port is a no-op, so this new backend explicitly refuses there
until a durable-source recovery barrier is implemented. This refusal does not
disable ordinary Windows storage or its existing owned reclamation.

Bulk completion authenticates every visible owner. Cold recovery can instead
finish one authenticated identity without reading another private journal or
requiring another identity's keys. A later compaction still performs full
preflight and cannot bury an outstanding intent under another source generation.
An identity without an intent neither opens nor recreates a missing hidden file.

The public Dart `verifySpaceKeys` helper uses existing native methods, validates
key shape before allocation, closes every handle and arms no deferred vacuum.
Its descriptor is an exclusive read/write open, not an OS-read-only handle.
The successful scan is followed by content-dependent integrity work: it is a
maintenance proof for previously authorized keys, not a constant-duration login
or discovery API. It proves neither source freshness nor rollback protection.
Existing rollback, authorization and ratchet barriers are unchanged.

## Qualification

The final sequential compaction/controller/native run reports **109 passes,
no skips**. The plugin run reports **11 passes**, including matching/absent keys,
invalid shape, I/O refusal and an actually corrupted authenticated tree. A
broader earlier catalog/erasure/lifecycle run reports 119 passes and one opt-in
skip; that skipped native roster lifecycle case is explicitly rerun and passes.
The counts are separate runs, not an aggregate of distinct tests. Analysis of
all changed Dart implementation/test files is clean.

Sixteen native backend cases cover prepared publication/abort, two actual
SIGKILL boundaries, wrong/incomplete authority, shared-grant refusal, malformed
master data, copied/malformed/incomplete journals, unknown source, an injected
save-before-journal-delete state, mutable caller buffers, selected-root recovery
and directory-sync refusal. The killed writers are separate Dart processes,
identified at their actual live checkpoints and awaited to terminal after kill.
Before publication, cold recovery returns the old child references; after
publication it returns new references and exact original payloads. Public
catalog and lifetime-role file inventories/digests stay unchanged. Source bytes
stay unchanged during key-proof recovery. The injected partial-save case is not
misreported as another actual process crash.

The previously source-verified `7b13bbb4` Rust library is selected by explicit
path and rehashed. The plugin change is Dart-only: no Rust implementation,
UniFFI signature or checksum entry changes. All 50 binding checksums still match.
Private logs, synthetic capabilities, IDs and native evidence are outside the
repository. Owned fixtures are removed after actual native worker/process
completion; no application stand or user container is opened. Nothing is
pushed, tagged or released.

## Still required before activation

Wire the backend through an owned maintenance worker and the normal
selection/unlock/recovery lifecycle. Carry authorization snapshots until native
publication and recovery actually settle, including cancellation and lost
replies. Check private intents before hosted children or nodes can start and
before another rewrite or credential change. Add the collection/recovery UI,
Windows durable-source support, application crash qualification during
individual holder updates, and packaged/physical platform checks. The tests
above do not authorize removing the mixed-profile guard or enabling production
defaults. They do not attribute the user's historical corrupted-container case
to this newly confirmed legacy read defect.
