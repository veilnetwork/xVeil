# Strict admission for single-password and automatic compaction

This follows the [strict maintenance-reader work](../external-compaction-reference-recovery-2026-11-15/README.md).
That work protected password probing and staged roster repair, but two other
entry points could still rely on the historical, permissive classification.

## Confirmed defects

Five regressions fail against the earlier controller. A malformed small roster
or an unreadable declared large-roster file lets both manual single-password
compaction and automatic pre-session compaction reach the rewrite callback.
The automatic cases use the public unlock method with the existing opt-in and
normal size gate. A collection with passwords but no retained old-space keys
can also reach publication without supplying a reference-repair map.

Single-password admission now requires an open source and a strict live roster
read before teardown. A nonempty roster requires the complete password
collection; damaged metadata refuses the operation. Automatic maintenance
performs the same strict read inside its maintenance admission and skips the
optional rewrite on damage or a nonempty roster. Locking during the awaited
read revokes admission. Valid absent/empty rosters remain eligible. These checks
do not discover unknown hidden spaces or expand the native keep-set contract.

Collection admission requires a complete, byte-valid 64-byte old-key map. The
controller snapshots the collected repair credentials before yielding and
clears its owned buffers after publication/recovery or rejected admission.
It does not clear the caller's buffers. This is best-effort handling of mutable
copies, not a claim about erasing immutable strings or historical storage.

A separate controlled regression replaces only these snapshots with borrowed
buffers. Clearing the dialog-owned passwords and old keys while preparation
is parked then produces `CompactionRosterRepairIncomplete`. With ownership
restored, the same test completes and the repaired child reference opens the
expected identity. No wait duration is used as the synchronization oracle.

## Qualification and boundaries

The new controller suite has 14 cases: the five original red cases, healthy
manual/automatic controls, lock cancellation, stale classification with a
live master, closed-source refusal, invalid-key refusal, and buffer lifetime.
Six additional native cases exercise actual containers and both controller
entry points. Four damaged-roster cases require zero native rewrites and
independently reopen both root and child by password with exact profile and
70,000-byte file readback. Two healthy solo controls perform actual native
compaction and independently verify the surviving profile/file. The eligible
source is a real container, not a sparse file size witness.

The final sequential run reports **152 passes, no skips**, including existing
lifecycle, wipe, roster repair, password encoding, dialog and native publication
checks. Static analysis reports no issues. Lifecycle fixtures now supply keys
from their actual fake-storage opens so they reach the intended lifecycle
barrier rather than failing the new argument validation. Wipe fixtures use an
explicit verified-empty test credential store, independent of an unavailable
host OS plugin. Native checks use a digest-verified library whose 145 recorded
Rust input digests still match the current source; no Rust changes are needed.

This qualifies host/controller behavior, not the original user's damaged
container or Android/OEM survival. There is no physical-device or release-AOT
qualification in this round. Managed defaults remain disabled and the
mixed-profile compaction guard remains enabled. Cross-owner worker/UI/cold-start
recovery wiring and Windows source-name durability remain open. No push or
release is part of this round.
