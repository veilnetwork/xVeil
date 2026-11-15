# Compaction credential and roster storage scope

Managed storage remains disabled in production defaults. This follows the
[Android persisted-padding qualification](../managed-storage-android-persisted-padding-2026-11-15/README.md)
and removes two incorrect assumptions in legacy compaction's mixed-roster
preparation/repair. It does not enable whole-container maintenance in profiles
with managed catalog entries.

## Confirmed behavior and change

A legacy master's protected roster can name both hidden children in the shared
container and independently owned encrypted/plaintext children. Password probing
previously returned every child as requiring coverage by a shared-container
password. A managed child cannot be opened that way: its explicit locator selects
another store. The probe now includes only legacy children in this checklist and
its associated subordinate count. It does not enumerate unknown hidden spaces
or discover managed identities by trying hidden passwords.

Roster repair previously looked up every child's key bytes in the old-to-new
hidden key map. For a managed child with unrelated keys, this reported an
incomplete repair; for matching bytes, it rewrote the independent child's keys.
The stored locator now determines scope. Managed entries preserve their label,
locator, mode, anonymity setting and outer keys. Legacy children still require
a complete old/current-key mapping; unresolved legacy children retain the
existing fail-closed refusal. Repeated repair remains idempotent.

Legacy collection, probing and default-root repair now reject an actively
managed root before teardown, open, close or credential use. The rewrite guard
also checks the active root, including hosted identity views. An explicit
unpublished legacy replacement can still be repaired without reading the active
owned facade. Owned reclamation remains the maintenance route for independent
identities.

## Verification

The initial nine scope tests run against the old controller produce two passes
and seven failures: incorrect password coverage, refused/corrupted managed
references, and credential operations entering the wrong active root. They pass
after the fix. Three additional cases verify pre-teardown refusal and explicit
replacement ownership. Key-collision controls check that scope follows the
locator, rather than coincidental equality with a hidden key.

Two host-native cases create actual encrypted and plaintext child stores and a
shared hidden container with a child plus two hidden masters. The prepared
rewrite invokes the production controller repair against its unpublished
replacement. Successful publication preserves the exact hidden file payload,
reopens the child from each master's repaired key, and preserves each independent
child's original keys, locator and data. The entire managed directory's file
inventory and digests remain unchanged across the hidden rewrite. A second case
adds an unresolved legacy child: publication is refused, the original hidden
file stays byte-identical, and both masters and all independently owned children
remain usable. These are native storage/controller checks, not a GUI, physical
Android or whole-application mixed-compaction qualification.

The final sequential focused run reports **75 passes, no skips**, covering the
new scope cases, roster repair, probe/remap lifecycle, compaction lifecycle,
worker-owned reclamation and the two native cases. Changed Dart code and tests
analyze cleanly. No timing threshold is used to prove the new scope guards.
The selected local hidden-volume library is the previously source-verified
`7b13bbb4` build; its digest and external filesystem identity are rechecked before
use. No Rust rebuild or dependency/ABI change is introduced in this cycle.

## Existing harness failures found during verification

The first expanded run has 69 passes and six failures. A separate control with
the unchanged controller reproduces both failure mechanisms: a wipe fixture
omits its OS-secret-store port, producing a remaining-credential result, and
collection/lock tests await node disposal while retaining their own disposal
gate. They are not counted as product regressions or passed tests.

The fixture now uses the existing in-memory secret-store port and never reaches
Keychain/Keystore. Gated checks assert synchronous lease revocation, prohibit new
credential access, then release and await all accepted work. They verify exactly
one storage close by lock, continued refusal during unfinished teardown, and
correct recovery behavior. Wipe is allowed to join node disposal before its
collection barrier; both remain pending while the gate is held, and actual file
deletion is checked after release. This avoids requiring an obsolete teardown
order while retaining the safety oracles. The corrected full run above passes.

## Remaining boundary

The general managed-catalog compaction guard remains in place. A managed master
outside the rewritten hidden file can itself hold references to hidden children.
Those references require a crash-safe cross-owner update/recovery protocol; the
in-file repair qualified here cannot update them atomically with publication.
This change is a prerequisite for that work, not permission to remove its guard.
Hidden-default protection, known-space retention requirements, authorization,
ratchet and delivery barriers are unchanged. Unknown hidden-space retention is
not newly promised, and no old store is migrated automatically.

Only synthetic fixtures are used and removed after their actual operations
finish. No application stand or user container is opened. Native workers and
test processes exit; private raw evidence remains outside the repository.
Nothing is pushed, tagged or released.
