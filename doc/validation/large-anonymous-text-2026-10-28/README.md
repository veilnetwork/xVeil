# Large text over authenticated anonymous delivery — 2026-10-28

After the message-record storage fix, a large text could be committed locally
but still exceed the native authenticated anonymous delivery bound. Veil caps
the encoded authenticated message at 6,144 bytes; its signature, header and
reply blocks also consume that budget. The fire-and-forget IPC path cannot
reliably expose that later refusal as an exception to the original Dart send.

Anonymous text, edits and signing requests/responses now use bounded live
application fragments when their original frame exceeds 4,500 bytes. Each
fragment is at most 1,200 bytes. The original journal/outbox entry remains the
durable source, and the recipient acknowledges the original only after its
normal persistence handler succeeds. Missing fragments or a receiver restart
are repaired by retrying that original entry. No partial delivery receipt or
durable fragment journal is introduced.

The 4,501–6,144-byte compatibility band additionally attempts the original
whole frame, preserving delivery to an older v2-aware recipient whenever that
frame previously fit. Each binary part is base64-wrapped in a structured v2
envelope with an unknown kind: older envelope decoders drop it instead of
misrendering it as legacy text. Current recipients deduplicate both forms.
Larger frames need a recipient with fragment support. Ordinary non-anonymous delivery is
unchanged. Files, avatars, calls, group/history protocols and receipts do not
use this new framing; they retain their existing admission and carriers.
There is no mailbox fallback, native library change, relay classification or
relay priority change.

Reassembly requires an authenticated accepted contact or an own device and
keeps identity, device and provenance separate. A domain-separated SHA-256
binds the exact original bytes and kind. Limits are one MiB per original,
one MiB held per peer, four MiB globally, 16 sets per peer and 64 globally;
partial sets expire using a monotonic two-minute idle clock. Completed data
remains charged until dispatch settles. Blocked text retains its held-message
semantics, including a block that ends before reassembly completes. A delayed
compatibility copy cannot recreate a held message after Show or Discard.

Every outgoing fragment follows the ordinary reservation/checkpoint path.
Identical overlapping retries share a flight, its physical destination is
pinned throughout, and shutdown stops subsequent fragments and joins the
in-flight send. Outgoing owned payloads are bounded to four MiB and 32 flights.

The serialized outbox bound also increases from 512 KiB to one MiB: a valid
large stored edit needs its immutable retry frame, whose JSON/base64 storage
wrapper can exceed the former bound. The existing small storage records and
their atomic commit protocol remain in use.

## Deterministic checks

The expanded relevant suite passed 238 tests, including a real hidden-volume
reopen of a large edit and its original outbox frame. Static analysis of all
eight changed Dart files found no issues. Tests cover corruption and quotas,
authentication and consent, route changes between fragments, missing parts,
lost ACK, receiver restart, storage failure, blocked-message decisions,
shutdown, overlapping retries, and crossing a send-reservation window.

Two regressions were reproduced against the preceding application source:
the capped anonymous transport rejected the large original post, and the
native hidden-volume test rejected the large edit's outbox wrapper. Both
pass with this change. The send-reservation test establishes the sequential
fragment path; it is not a qualification of all concurrent native ratchet
operations.

A compatibility regression also failed against the first uncommitted binary
candidate: the existing envelope decoder treated raw binary as legacy chat.
The final structured wrapper passes that exact decoder check. The initial
physical candidate was never published or deployed outside the QA stand.

## Final physical check

A is Android on Wi-Fi and B is its Mac sibling; C is another identity on Mac.
Android uses profile/AOT and Mac Dart builds are debug. All roles use retained
QA profiles, frozen production native libraries and the structured-wrapper source. Anonymous
routing is explicitly enabled on every role, with cross-identity P2P denied.
This does not infer anonymous transport from an ordinary P2P delivery check.

A submits twelve messages and C submits six with six concurrent submitters.
Both A and C include a generated 12,300-character ASCII fixture plus its prefix.
Both complete fixture bodies match on every role. The large A message is then
edited and deleted for everyone.

| Structured-wrapper observation | Result |
| --- | ---: |
| New messages visible once on every role | 18 |
| First sampled all-role convergence after submission began | 66.7 s |
| Equal complete histories before deletion | 1,440 rows each |
| Group chunk queues empty before mutation | 108.0 s |
| Large edit observed on every role | 10.9 s |
| Deleted target absent on every role | 12.4 s |
| Equal complete histories after deletion | 1,439 rows each |
| Duplicate logical IDs | 0 |
| Unrelated IDs preserved | All |

All source copies matched the application's complete `lib` inventory. Existing
send logs independently observed anonymous sends at the full fragment size.
The complete ID order agreed before and after mutations. Original anonymous
settings were restored through the real controller, the nodes rebooted in
place, and complete histories and bodies were unchanged afterwards. Before
mutation, B retained one unrelated P2P announcement; complete outbox drainage
is not claimed. These observations establish functional convergence, rather
than a controlled latency improvement. Long delivery/receipt delays remain open.

The only production-code change after this physical run tightens reflected-ID
admission to count JSON escaping, rather than raw UTF-8 alone. An additional
regression and the final 238-test suite cover it; the physical fixtures' ordinary
hex IDs are unaffected. The private inventory comparison verifies that single
post-run difference. No subsequent device run of that stricter admission check
is claimed.

All owned apps were closed. An independent final audit found zero processes
in 95 recorded owned Mac process groups, zero matching Mac QA executables,
zero Android QA package/named-subprocess instances and no owned ADB forward.
QA permissions were restored; main app data and system power settings were
unchanged. No push, release, native build or relay update was performed.

Physical results and independent cleanup counts are recorded in
`summary.json`. Raw logs, identifiers, credentials, bodies and device/network
addresses remain private. This check does not qualify the full multi-device
matrix, Windows 10, live speech quality or the cause of the earlier unexplained
25.1-second phone call termination.
