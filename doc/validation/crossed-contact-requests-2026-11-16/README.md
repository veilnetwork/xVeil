# Crossed contact requests retain local outgoing consent

Base: `c45b3eed`. A reproducible one-way relationship is fixed in source.
The original Windows 10 user's case is not attributed without its own evidence.

## Confirmed behavior

Both users send a request. Receiving the other request changes each contact
from `pendingOutgoing` to `pendingIncoming`, losing the fact that its owner
already requested this peer. One user explicitly accepts; the response reaches
the other, but its accept handler only recognizes `pendingOutgoing`. One end
is accepted and can send, while the other remains pending and refuses messages.

Four ordinary/native assertion-red cases reproduce this on the base, including
close/reopen before processing the actual response. The tests exchange captured
ordinary request/accept frames between real MessagingService instances, without
inserting accepted contact rows or relying on timer thresholds.

## Change and consent bounds

`Contact.hasOutgoingRequest` retains the owner's existing request through a
crossed incoming request. Pending-outgoing records, including old ones, imply
that intent. Only the extra crossed state needs an optional boolean in the
existing contact record. Copying/upserting presentation fields while still
pending retains it. Accepted/blocked states clear it; actual contact removal
removes it with the record.

Receiving an incoming request still does not accept it. Ordinary messaging
still requires `accepted`. An incoming-only or missing contact cannot use an
unsolicited peer accept to grant consent. The existing atomic accept path
checks the retained intent under the same write lock as block/accept decisions,
then commits the relationship and its durable decision floor together.

The intent is local contact state, not a peer-controlled wire flag, a pending
status mirror, an own-device mailbox message or a new network protocol field.
No native storage API change or media-engine rebuild is needed. Existing
incoming-only records whose older writer already lost the intent are not
retroactively granted consent; their owner can explicitly accept the request.

## Native pair qualification

The opt-in `profile_avatar_native_pair_test.dart` now registers a conventional
request/accept case and a crossed-request case. The latter persists both local
requests before any carrier exists, joins the real embedded nodes, waits for
both actual incoming greetings, and makes exactly one explicit acceptance.
No fake transport or inbound injection establishes the native relationship.

A separate owned checkout at `825b9672` reproduces native non-convergence after
both greetings, reaching the 90-second convergence watchdog. This older
integration is separately identified; it is not claimed to be byte-identical
to the exact unit-test baseline. After its process exits, an independent reader
opens copies of its closed encrypted stores:

| Endpoint | Contact | Received greeting | Local greeting | Durable pending request | Durable pending accept |
|---|---|---:|---:|---:|---:|
| A | pendingIncoming | 1 | 1 | 1 | 0 |
| B | accepted | 1 | 1 | 0 | 1 |

The original store hashes are unchanged by that inspection. These durable
states establish the asymmetric native result; they do not independently prove
receipt of a particular accept packet. The exact-frame controlled tests above
establish the handler's refusal mechanism. The temporary checkout is restored
and clean after the baseline execution.

On the final candidate both native cases pass without skips. Each checks four
bidirectional text controls before/after restarting a node: exact IDs, authors,
bodies, one incoming row/notice and sender `delivered` status. Avatars also
exchange/update/clear and recover through the authenticated pull after restart.
Both peers retain ratchet material. This is JIT application services on one
Mac with direct native QUIC; it is not the reporter's Windows, real Flutter
chat widget, cellular network, relay topology or final packaged application.
No speed improvement is inferred from these runs.

The selected signed Release core/storage libraries match their retained package
hashes. All 1,010 repository Rust/Cargo inputs match the verified core producer's
source snapshot. Their hashes remain unchanged after the runs; no Rust build
is started. Qualified matching hidden-volume bindings remain required for the
broader storage-mode work; published old assets are not substituted here.

## Other checks and teardown

- **375 passed, no skips**, across 13 related suites with diagnostics and a
  matching native storage library. Negative cases cover incoming-only consent,
  actual forgetting, presentation upserts and a concurrent block queued ahead
  of a crossed accept. Existing primary atomic acceptance, Outbox, request,
  device-preference and notification controls remain included.
- Managed encrypted and plaintext backends retain crossed intent after
  cold-open, accept its peer response, and clear the pending intent while
  preserving a durable accepted floor.
- Full `dart analyze lib test` is clean. Diff and staged private-pattern gates
  pass. A separate inspection test passes on the closed baseline copies.
- All native stand processes exit; owned metrics/listener ports are rebound in
  teardown and successful fixtures are deleted. The failed owned fixture and
  its inspection copies are removed after owner-exit and original-hash checks
  (about 4.2 MB). Anonymized results/manifests remain privately retained.

Tests use `TMPDIR=/private/tmp/`. No user app/window activation, keyboard/mouse,
phone, Windows session or production relay action occurs. The user's existing
Mac app remains running. Changes are committed locally, without push or release.
