# Group chat XOR synchronization

Status: implemented (default `k = 5`, locally configurable per chat from
`1` to `20`).

Ordinary group chat history no longer sends every message and reaction
directly to every participant. For a local node id `S`, the group service:

1. takes the current signed/folded member set;
2. removes `S` and duplicate ids;
3. orders members by the unsigned 256-bit value `S XOR member.nodeId`;
4. connects/sends to the first `min(k, N - 1)` members.

The comparison is bytewise from the most-significant byte, so it does not need
large integers and is deterministic on every platform. Node ids are the
existing cryptographic identities; no new group-scoped identifier is exposed.

## Live propagation

Messages and reactions are sent to the configured number of XOR-closest
members. The delta
contains `ov`, a SHA-256 id derived from the group id and signed log-row
identities. A receiving member first validates and persists the rows, then
forwards its exact persisted copies to its own XOR neighbours (excluding the
source). A bounded in-memory seen set stops cycles. Durable wire delivery and
the existing `(author, seq)` merge remain the persistence/idempotency layer.

An invalid or altered row is never relayed merely because it carries an `ov`
value: the id is recomputed and every forwarded JSON row must exactly match a
validated row in the local group log.

## Repair after downtime

On startup, each chat sends its compact per-author high-water sync vector to
the same XOR neighbours instead of a fresh random sample. A neighbour replies
with only missing messages, controls, reactions and recipient epoch material.
A content-only repair reply also enters the overlay relay path, allowing a
recovered gap to continue converging beyond the first requester.

## Deliberate exceptions

- `addMember` still sends a full, recipient-tailored snapshot to all current
  members, because the joiner needs history and the overlay needs one agreed
  membership view.
- control-log changes still go to all current members. Epoch rotation carries
  a distinct sealed key envelope per recipient; an intermediate member cannot
  safely recreate envelopes for other members.
- the sovereign device group still synchronizes every linked device. It is
  infrastructure state, not a scalable public chat.
- group-call signaling and group-content holder discovery are separate
  realtime/content paths and are unchanged.

The topology is recomputed after every folded membership change. With fewer
members than the configured `k`, it naturally degenerates to the previous
all-member delivery behavior. The chat header's hub action changes `k` for the
current device and immediately starts an anti-entropy exchange with the newly
selected neighbours; it does not write a signed group control operation.
