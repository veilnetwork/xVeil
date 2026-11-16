# Peer acceptance cannot overwrite a concurrent local block

Base: `6abf2ab8`. This is a confirmed consent race in the incoming accept path,
not an attribution of the user's one-way Windows conversation.

## Reproduction and negative control

A peer's `WireKind.accept` used the ingress `pendingOutgoing` snapshot and then
unconditionally set `accepted`. The consent epoch rejects a read begun before
a block and completed after it; two ordinary/native controls verify that this
already works and does not need a change.

A different ordering remained possible: the local block holds the real contact
write lock and awaits its contact read before committing. Ingress starts during
that write and reads the still-durable `pendingOutgoing` under its current epoch.
Its accept write queues behind the block. The block commits first, then the
unconditional accept replaces it and its decision floor. The owner did not
choose to unblock the peer.

Both the ordinary async store and the actual hidden-volume worker produce
**assertion-red** on the baseline: expected `blocked`, observed `accepted`.
The gate is inside the real storage write turn, not a network timing threshold.

## Change

`Storage.acceptOutgoingContactRequest` checks `pendingOutgoing` and writes the
accepted contact, local decision floor and pending device-journal obligation
under the same contact write lock. Other states and missing contacts are refused
without a write, a new index entry or a new floor. Existing contact presentation
and preference fields survive the transition. The messaging owner invalidates
its realtime consent cache around this operation, as for other consent writes.

A refusal does not advertise acceptance or ACK the unused carrier copy. A fresh
revision-aware read distinguishes an independently accepted contact: its peer
response is still acknowledged, without rewriting the decision. Block,
cancellation and a new incoming-only request remain refusals.

This latter case caught an intermediate regression of the new conditional path:
the first candidate also refused an already accepted peer's response. Two
ordinary/native assertions failed, then passed after preserving its ACK. Those
failures belong to the intermediate candidate, not the released baseline.

An unused private unconditional-status wrapper was removed. Explicit local
accept/unblock semantics, own-device mailbox policy, ratchet and wire format are
unchanged. This is not a global claim that every contact mutation race is closed.

## Evidence

- **359 passed, zero skips**, in 13 suites with diagnostics enabled and the
  matching native library. Coverage includes ordinary/native queued acceptance,
  block/realtime control, request/reconnect races, greeting delivery, primary
  atomic acceptance, preferences, Outbox retries and notification admission.
- The queued-block scenario verifies refused carrier processing, no receipt for
  that accept, a blocked durable floor, rejected later call control and blocked
  status after cold-open. Six focused ordinary/native cases pass after the final
  receipt/floor assertions were strengthened.
- Independently encrypted and plaintext managed stores refuse already decided,
  incoming-only and absent contacts; valid pending outgoing acceptance preserves
  local name/pin and its floor across cold-open. A repeated accept does not
  regenerate the floor.
- Full `dart analyze lib test` is clean. The native library SHA matches the
  earlier producer and all 50 Dart ABI checksum entries. No native build occurs.

All tests are headless with `TMPDIR=/private/tmp/`. No user window is launched
or focused, no mouse/keyboard/phone automation occurs, and the existing Mac
application is left running. No Windows session, production node, push or release
is involved. The original Windows camera, real toast and one-way-chat reports
retain their separately documented qualification limits.
