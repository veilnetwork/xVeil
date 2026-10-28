# Group ACK transport waits outside durable dispatch — 2026-10-29

Two isolated regressions confirmed another source of inbound head-of-line
blocking. A complete group snapshot, or the last slice of a chunked snapshot,
was already applied durably. Its outgoing group ACK was then held in transport.
An accepted contact's later chat message could not reach storage during that
held interval, because the group handler still owned serialized inbound
processing. Both regressions fail on the preceding source and pass here.

Group snapshot receipts now use a serial bounded worker after validation,
reassembly and terminal group application. The durable lane can proceed to
later incoming frames while the return route waits. Group application itself
remains serialized and must succeed before receipt admission. Failed or
incomplete application, digest mismatch and unauthorized fragments retain the
sender's retries. The aggregate transfer ACK still requires the complete set
of parts; this does not introduce early partial-transfer ACKs.

The worker reuses the existing committed-receipt queue implementation, with
independent group accounting: at most 128 jobs and 128 KiB of charged metadata,
including its active send. It retains compact sender/device/provenance/reply
metadata, bounded IDs and optional frozen own-device targets. It retains no
snapshot body, original payload, reassembly map, mailbox callback or inbound
admission lease. Weight conservatively charges six bytes per ID code unit,
fixed metadata and per-target overhead. Coalescing keys are bounded hashes and
include the binding epoch and exact route/retry metadata. A refused job does
not acknowledge anything; ordinary sender retry asks again after pressure ends.

All supported snapshot frame IDs fit the existing 340-code-unit bound.
Oversized legacy IDs are now rejected before group application or retention in
the committed-receipt cache; an oversized hostile ID cannot bypass worker byte
accounting by living in that older cache instead. Current transfer formats and
supported legacy IDs are unchanged.

Queued jobs recheck their group-binding epoch before transmission. Provider
replacement invalidates old queued receipts instead of sending them through a
successor's group context. Physical-device targeting, one-time reply versus
repeat/direct behavior and sender authorization remain in the existing ACK
path. Shutdown rejects new jobs, discards waiting ACKs and joins the active
send before the final ratchet snapshot and transport/storage closure.

Explicit `deliverInbound` callers still wait for receipt settlement. They now
join every receipt associated with their frame, including all legacy per-slice
ACKs. The live listener releases original payload/admission accounting after
durable handling; only compact transport work remains queued. This change does
not detach mutation, cloud-document or every other control handler's ACK.
There is no mailbox addition, wire-format change, native-library change or
relay priority/media classification.

## Deterministic checks

The focused eleven-file run passed 173 tests. Twelve new group receipt tests
cover whole/chunked blocking regressions, live admission release, durable apply
failure, obsolete binding epochs, physical sender routing, reply/direct retry,
count overflow and later repair, oversized IDs, shutdown/restart, legacy
per-slice settlement and pending-retry coalescing. Existing snapshot integrity,
stranger/revocation, handler replacement, own-device ACK fallback, post receipts,
large-message delivery, inbound provenance/backpressure, outbox and shutdown
checks remain green. Static analysis of the five changed Dart source/test files
found no issues, and formatting checks passed.

Group tests use an actual durable application marker, not transport success as
proof of persistence. Before-fix evidence is the completed regression run with
both group applications confirmed and their return transports held.

Physical qualification and independent cleanup are recorded below and in
`summary.json`. Raw identifiers, addresses, logs and bodies stay in private
local evidence. Public observations use fixed roles, counts and timings.


An additional four-file run covering binding detachment, device sync, group-call
teardown and ratchet reservations passed 42 tests (215 across the two disjoint
file sets).

## Physical convergence and cold readback

A is Android/Blackview on Wi-Fi, B is its Mac sibling and C is another identity
on Mac. Retained profiles and exact copies of the final application inventory
are used. Android is an AOT/profile QA build; Mac QA Dart is debug. Production
native libraries remain at Veil `f031513a`, with matching packaged hashes and no
low-difficulty/native test-hook flags. Anonymous routing is explicitly disabled
and cross-identity P2P denied during delivery, matching the preceding ordinary
ratchet test's mode. This is still not a controlled latency benchmark.

A submits twelve messages and C submits six using six concurrent submitters.
Both origins include one generated 12,300-character ASCII body plus its fixture
prefix. All 18 logical messages and both complete large bodies appear once on
every role. The large A post is edited, then deleted for everyone.

| Observation | Result |
| --- | ---: |
| First all-role visible sample | 70.3 s |
| Group chunk queues empty | 139.3 s |
| Edited large post on every role | 18.9 s |
| Deleted target absent on every role | 12.7 s |
| Equal full histories after deletion | 1,507 rows each |
| Duplicate logical IDs | 0 |
| Unrelated IDs preserved | All |

Original anonymous modes were restored through the real controllers, preserving
full IDs, bodies and ordering. One control row remained on B before mutation;
complete control-outbox drainage is not claimed. A later cold reopening found
all 17 surviving fixture messages on every role: A's eleven outgoing messages,
B's eleven mirrored outgoing messages and C's six outgoing messages all had
delivered status. Full history remained equal to the saved pre-close state.

Both stands closed their apps. An independent audit checked 130 recorded owned
process groups across current and previous cycles and found no owned group,
Mac QA executable, Android package/named subprocess or owned ADB forward left.
Main app data and system power settings were unchanged. No push, release,
server deployment or Rust build was performed.

## Limits and next evidence

The deterministic regression proves removal of a local transport wait after a
committed group effect. The physical run proves the sampled convergence and
restart behavior, not removal of every end-to-end delay. Delivery and group
sync remain slow. Five native planner warnings each attribute about three
seconds to route planning and zero to sealing, but correlation places all five
before submission of this test's messages. They are startup observations and
are not demonstrated causes of this series' delivery latency.

The original unexplained phone call termination, anonymous-stream file pauses,
Windows reports, headphone volume, Android sleep reports, legacy orphaned group
tails/mixed-version limits and the incomplete multi-device matrix remain in the
[open findings](../open-findings-2026-10-28/README.md).
