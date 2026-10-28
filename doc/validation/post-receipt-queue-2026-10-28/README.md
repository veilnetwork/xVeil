# Keep committed-post ACK transport waits off durable dispatch — 2026-10-28

An isolated regression confirmed a head-of-line defect in the serialized
inbound lane. After the first accepted contact's message was stored, its ACK
transport was held. A second accepted contact's message then remained absent
for the complete held interval, because durable dispatch awaited that outgoing
ACK. This was a transport wait after a committed effect, distinct from the
storage, own-device publication and permission ordering the lane must protect.

Stored-post settlement now submits its ACK operation to a serial bounded queue.
The durable inbound chain advances after the post's existing handler finishes;
consent, deduplication, storage and own-device publication remain ordered. This
does not move a post's ACK ahead of its durable effect. The helper also retains
existing policy-refusal and already-stored/deleted post semantics. Mutation,
group, contact and permission handlers keep their existing ordering and ACK
boundaries; this is not a universal detachment of every outgoing control frame.

Only one receipt job sends at a time. Its normal send, reservation/checkpoint,
one-time reply path, physical-device address and direct retry rules remain in
use. The queue admits at most 128 jobs and 128 KiB of charged metadata. A pending
identical receipt coalesces only when identity, device, provenance, reply handle,
direct/reply choice and both original IDs match. Keys are bounded hashes. Job
weight conservatively charges six bytes per ID code unit plus fixed metadata;
jobs retain no original payload, mailbox callback or reassembly lease.

The live listener releases its original payload/admission budget after durable
handling. Explicit `deliverInbound` callers still join receipt settlement.
The existing bounded inbound lane and pre-consent/replay gates remain in place;
durable handlers do not run concurrently. A full queue refuses a receipt and
logs bounded refusal counts. The sender retains its durable row and a later
retry receives another ACK from the stored post. Send/diagnostic failures cannot
poison the queue. No mailbox carrier, native library change, relay priority or
relay-visible media classification is introduced.

Shutdown rejects new jobs, drops waiting ACKs and joins the active send before
the final ratchet snapshot and before the owner closes transport/storage. Lost
waiting ACKs are repaired by ordinary sender retry after restart; they do not
constitute permission to retire the sender's row early.

## Deterministic evidence

Fifteen relevant files passed 245 tests. Static analysis of the four changed
Dart files found no issues. Nine new regressions cover the blocked-ACK/durable
dispatch separation, live payload-budget release, explicit delivery settlement,
count/byte bounds, coalescing and later retries, send/diagnostic failures,
physical-device targeting, one-time reply versus direct retry, shutdown and
stored-post retry after service restart. The original held-ACK regression
failed against the preceding source and passes with this change.

Existing own-device-publication and post/mutation persistence failure checks,
large anonymous-text delivery, consent/provenance, blocked messages, inbound
backpressure/replay, durable outbox, group snapshots, ratchet reservation and
shutdown checks remain green. The headless import guard also passes.

Physical results and independent cleanup are recorded in `summary.json`.
Raw logs, addresses, credentials and logical IDs remain private; public evidence
contains only fixed roles, counters, timings, booleans and source-owned labels.
An initial candidate run predates the final live payload-budget release and
is not used as final-source qualification.

## Final physical check and cold readback

A is Android on Wi-Fi with a profile/AOT QA build, B is its Mac sibling and C
is another identity on Mac. Mac Dart builds are debug. Retained QA profiles,
unchanged production native libraries and exact copies of the final `lib`
inventory are used. All three roles explicitly enable anonymous routing and
deny cross-identity P2P during the delivery check.

A submits twelve messages and C submits six with six concurrent submitters.
One message from each origin includes a generated 12,300-character ASCII body
plus its fixture prefix. Both large bodies match on every role. A's large post
is edited, then deleted for everyone.

| Final-source observation | Result |
| --- | ---: |
| New messages visible once on every role | 18 |
| First all-role visible sample after submission began | 55.6 s |
| Equal complete histories before deletion | 1,474 rows each |
| Group chunk queues empty before mutation | 114.9 s |
| Large edit observed on every role | 19.7 s |
| Deleted target absent on every role | 12.0 s |
| Equal complete histories after deletion | 1,473 rows each |
| Duplicate logical IDs | 0 |
| Unrelated IDs preserved | All |

Original anonymous settings were restored through the real controller, with
nodes rebooted in place; full histories and bodies stayed equal. Before
mutation, control outboxes still held six rows on A and three on B, while C
held none; complete outbox drainage is not claimed. The bounded final log
snapshots contained no receipt-queue failure or refusal observations.

All roles were then closed and cold-reopened for an additional readback. All
17 surviving new messages were present on every role. A's eleven outgoing
messages and C's six were marked delivered; B's eleven mirrored outgoing
messages had the same delivered status. The full 1,473 IDs, bodies and order
were unchanged. This proves the sampled receipt state after reopening, not the
time when each original live ACK arrived. The readback does not replace the
full multi-device state/failure matrix.

All apps were closed again. Independent cleanup checked 101 historical owned
process-group numbers and current QA executable/package processes, finding no
remaining owned apps, Android named subprocesses or owned ADB forward. One old
numeric group had been reassigned to an unrelated system-daemon leader; its
prior absence and current ownership were verified, so it is not counted as a
surviving QA process. QA permissions were restored; main app data and system
power settings were unchanged.

This removes one demonstrated local cause of delay. It does not locate all
remaining transport, group-publication, persistence or receipt waits and does
not establish a general delivery-latency improvement. Windows reports, live
speech/headphone volume, Android background-sleep reports, the old unexplained
25.1-second call termination and the full multi-device matrix remain open or
unqualified. No release, push, server update or Rust build was performed.
