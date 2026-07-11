# Group state-log compaction

## Scope

The G1 sync vector is `author -> maxSeq`; its size is proportional to the
number of authors, not the number of log rows. Compaction therefore must not
delete ordinary group messages merely to make the vector smaller. Those rows
are user-visible chat history.

Only superseded state is compacted:

- reactions: latest fold winner per `(author, target)`;
- the hidden device group: latest `DeviceSyncEvent` per `(kind, key)`;
- invalid signatures and cross-group rows are discarded during the rewrite.

Unknown device-event bodies are retained so an older build cannot erase state
introduced by a newer vocabulary.

## High-water invariant

For every author, compaction also retains the valid row with the greatest
`seq`, even when that row is not a fold winner. Consequently:

- `author -> maxSeq` is byte-for-byte unchanged;
- the author's next locally allocated sequence cannot rewind;
- a fresh device receiving the compacted snapshot reconstructs the same fold;
- an already-synchronised device needs no compaction marker or activity-revealing
  floor message.

This deliberately avoids adding an unsigned floor/checkpoint to the wire. A
peer-supplied floor could suppress another author's missing entries and become
both a denial primitive and an activity oracle.

## Trigger

`GroupService.nudgeGroupSyncAll()` compacts each known group before emitting its
boot sync vector. The operation is idempotent and persists only when row counts
actually shrink. `compactStateLogs()` and the debug `/group_compact` hook make
the same operation directly testable.

## Not covered

Control-log checkpointing and deletion/retention of ordinary chat history need
a separately signed group checkpoint protocol. They are not approximated by
local truncation.
