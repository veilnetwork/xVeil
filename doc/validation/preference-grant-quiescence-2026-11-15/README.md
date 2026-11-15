# Preference-owner quiescence during reference recovery

The [selected-root recovery integration](../managed-reference-worker-recovery-2026-11-15/README.md)
released the catalog worker's shared grants, but the ordinary application's
preference-file worker retained another shared grant on that same profile.
Consequently recovery could not obtain exclusive admission. Two native controls
fail against the previous source with `ManagedWorkerFailure(busy)`: one opens a
real preference-file owner, the other uses normal preference bootstrap and the
bound `SharedPreferences` view before opening the selected managed identity.
Both pass with the candidate restored, including correct repaired child keys
and preference read/write/reload after recovery.

## Coordinated file ownership

`ManagedProfilePreferencesFile.withProfileReleased` seals new local actor
admission for the exact profile, joins already accepted opens, then releases
each matching actor's grant around the accepted host operation. An overlapping
same-profile scope refuses. Actors belonging to other profiles stay held and
usable. Foreign/process owners are still enforced by actual native exclusive
admission; the helper does not authorize filesystem work.

Each serving subscription remains paused through its callback and grant
restoration. Already accepted file I/O and close retain FIFO order. The UI-side
admission owner joins an accepted callback even if the transport fails. Callback
errors remain errors. Reacquisition opens existing roles only and checks the
original base, profile and coordination-directory witnesses. A missing or
changed profile leaves ordinary file I/O refused; the old actor never creates
a replacement. Failed close remains available to the existing close protocol.

New actors return `busy` during the scope and require an explicit retry.
They are not deferred automatic creators that could wake after profile erasure.
A controlled test fails against the intermediate automatic-wait implementation
and passes with immediate refusal. Existing actors' reads and writes still
queue normally. No preference lifetime/backend is retired or replaced merely
for successful reference recovery; its cached values and later durable saves
remain usable.

The default router wires this scope only around pending reference recovery,
for existing and creation facades. Unjournaled opens do not pause preferences
or request exclusive ownership. No hidden-space index, public pending marker,
plaintext fallback or protection-mode change is introduced.

## Qualification and limits

Eight new native scope cases cover actual exclusive admission and restoration,
joining opens and releasing multiple actors, queued reads/writes with refused
new actors, callback failure, close during work, changed-path refusal, profile
isolation and overlapping-scope refusal. The multi-actor case bootstraps the
permanent role first, matching ordinary startup; it does not qualify competing
fresh-role initialization. Two additional native application-route cases cover
the file owner and full bound-preference bootstrap described above.

The final sequential run reports **151 passes, no skips**, including native preference startup, profile
erasure, file-owner/lifetime behavior, ordinary reference recovery, worker close
and the headless-import guard. Full `lib` and changed-test analysis report no
issues. Native artifact provenance and 145 recorded Rust input digests were
verified; no native changes/build are required.

An early candidate omitted the successful RPC reply after restoring the grant.
Its specifically identified owned probe was interrupted, its processes and
fixture were cleaned, and it is excluded from passing results. The corrected
case is included in the final run.

This is host-native/bootstrap qualification. Physical OEM, release-AOT and
fault injection at every new scope boundary remain open. All-owner compaction
worker/dialog preparation and Windows source-name durability are still pending.
Managed defaults remain disabled and the mixed-profile compaction guard stays
enabled. No push or release is part of this round.
