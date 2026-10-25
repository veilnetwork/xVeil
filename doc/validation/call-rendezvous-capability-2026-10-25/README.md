# Receive-only rendezvous publishers caused stream-pool churn

## Confirmed cause

The three-node relay island has two nodes that accept onion circuits and one
mailbox/receive-anonymous node that does not hold relay circuit state. All three
can appear in a client's plain rendezvous publisher list. A stream receive
pool can cover only the two circuit-capable nodes.

The SDK counted all three publishers when deciding whether that pool needed
expansion. It repeatedly replaced two healthy registrations while trying to
reach an impossible third target. Both the initial receive construction and
private call-route workers could also attempt that unsupported node. This is
an endpoint capability-selection error; receiving anonymous introductions and
serving onion circuits are different capabilities.

In the baseline three-device run, the client logs contain ten `2->3` inbound
expansion cycles. The relay logs contain 46 circuit-install refusals, all in
64/64 buckets on the links between the two circuit relays. Audio eventually
works, but one direction waits tens of seconds.

## Fix

Before initial stream receive construction, expansion-target counting and
private receive-route construction, remove peers whose authenticated handshake
explicitly lacks `ANONYMITY_RELAY`. Ordinary `CAN_RELAY` is insufficient.
Unknown remote nodes remain candidates for normal directory discovery; no
direct session is required merely to consider them. A later authenticated
capability update is effective immediately. No publisher rows are deleted.

Relay limits, priorities, traffic classes, protocol and C ABI are unchanged.
The filter is local to stream construction; mailbox and authenticated
introduction delivery keep their existing publisher list.

## Native three-device qualification

Both runs retain one OS process per device: A/B share an identity; C is another
identity. C first rings both online devices; B answers and A ceases ringing.
After hangup, A stops and C calls the same identity again; B answers. Each call
must receive five actual **audio RTP** packets on both endpoints, keep receiving
for another five seconds, and propagate hangup. There is no explicit C-to-B
session join. Real native codecs, directional encryption and onion transport
are used; the island is sealed from external seeds.

The baseline includes the preceding per-call ownership repair (`4622b684`).
The candidate adds only this capability filter to production code. The native
media and hidden-volume binaries are identical between runs.

| Measurement | Baseline | Candidate |
|---|---:|---:|
| First call: observed ringing on all online devices | 40 ms | 57 ms |
| First call: caller observed answer after accept invocation | 3,746 ms | 3,744 ms |
| First call: five audio RTP packets received on both | 25,743 ms | **4,156 ms** |
| First call: media gate after observed answer | 21,997 ms | **412 ms** |
| Repeat with A offline: observed ringing | 20 ms | 1,640 ms |
| Repeat: caller observed answer after accept invocation | 40 ms | 38 ms |
| Repeat: five audio RTP packets received on both | 32,370 ms | **447 ms** |
| Repeat: media gate after observed answer | 32,330 ms | **409 ms** |
| Whole-fixture impossible `2->3` expansion cycles | 10 | **0** |
| Whole-fixture circuit-install refusals | 46 | **0** |

Answer/media timings start immediately before the receiver's accept request.
The fixture awaits that request before polling the caller, so observed answer
time includes accept processing and polling; it does not isolate signalling
network delay. Ringing is measured separately from placing the call. Private
wall-clock anchors align relay events with answer-relative samples to within
two milliseconds in these captures; public evidence includes only relative
times.

These are two consecutive runs with new native circuits, not a statistical
latency guarantee. The candidate's repeat-call ringing is slower, and
`cookie_unknown` events remain elsewhere in the fixture: 60 versus 53 in the
baseline. This repair does not establish that all anonymous delivery defects
are resolved. Physical phone, provider-network and live speech/loudness
qualification remain outstanding. Positive receive-counter growth does not
prove uninterrupted, audible speech.

## Verification, provenance and cleanup

- Capability tests cover explicit receive-only and zero-capability peers,
  `ANONYMITY_RELAY`, unknown remote nodes, updates and preserving registry rows.
- Full embedded FFI suite: **378 passed, 11 existing ignored**.
- Strict all-target Clippy, Rustfmt, whitespace checks and the changed Dart
  fixture's analyzer passed.
- Candidate SDK sources were hashed before and after its native build and
  checked again around the stand run. Frozen CLI/FFI binaries and the unchanged
  media/hidden-volume inputs were verified by SHA-256. Low PoW difficulty and
  empty seeds apply only to the local test build.
- External Rust target remained mounted on its distinct filesystem throughout
  monitored builds. Flutter processes used `TMPDIR=/private/tmp/`.
- Both stands closed all owned process groups and removed their private stand
  directories: five groups/nine PIDs checked per run, zero processes remaining.
  No phone app, installed desktop app, user profile or relay configuration was
  changed. Six earlier inactive generated worker compilations were attributed
  to this test, checked for open handles and removed, reclaiming 1,212 MiB.

[summary.json](summary.json) records software hashes and verification status;
the result/event JSONs contain only fixed device-role labels, relative times,
event names, counts and statuses. Raw native logs, test identities, addresses,
keys, media and absolute timestamps remain in the private stand cache.
