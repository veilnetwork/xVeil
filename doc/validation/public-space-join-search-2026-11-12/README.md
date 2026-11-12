# Public Space joining and discovery

Local changes; no release or deployment in this cycle.

| Case | Evidence and result |
| --- | --- |
| Link waits for administrator approval | Previous implementation required a manual decision. Public links now initiate the existing signed `addMember` automatically, as requested by the owner. Private invitations retain their existing policy. |
| Search reports a connection error | Confirmed on Poco with a healthy sovereign QA identity: lookup using the logical identity fails with `no embedded node running for this identity`; lookup using the transport device succeeds. GUI wiring now selects that exact device runtime, without a cross-identity fallback. |
| Sovereign holder cannot publish an XS carrier | The carrier incorrectly required its hash-bound device id to equal the logical holder identity. The final carrier keeps the device signature/key binding and separately verifies the inner identity attestation. Quorum still counts inner identities. |
| Initial membership snapshot never arrives | Three native nodes reproduced an admitted join and publisher-side membership with no requester-side group. Fragment admission required an already-held group. A separate, bounded reassembly lease now recognizes the exact approver/Space of a durable outgoing public join. Full snapshot application still requires the signed grant. |

Automatic admission retains the normal ACL, epoch, signature and contact-block
guards. Saved pending joins resume after restart. A committed grant is reused
after interrupted snapshot/decision admission; replay cannot undo a subsequent
removal or create another grant. Snapshot and decision callbacks complete at
durable enqueue rather than waiting for a network attempt.

The UI describes automatic connection instead of manual approval, and offers
retry for an interrupted admission. An administrator issuing the link must be
reachable to complete the signed admission.

## Validation

- Red regression tests reproduced missing automatic admission, waiting for the
  initial network attempt, and rejection of a pending join's fragment lease.
- 548 group/discovery tests passed before the final fragment-admission change;
  seven focused admission/restart/queue guards passed after separating that
  change from complete-frame authority.
- All 35 Outbox tests, 14 fragment/expiry/background-lane tests, and two joining
  UI tests passed. Static analysis of changed production code and tests passed.
- Admission-pressure guards also passed: a required first snapshot reports a
  full queue without deleting existing frames, then enqueues after real drain.
  The strict requirement targets the joining member; ordinary replication to
  other members retains its established backpressure policy.
- The native three-node test passed: ownership transfer, two independent
  discovery holders, read-only subscription, then explicit public joining over
  the real messaging/fragment/ACK path without a manual decision. This fixture
  uses one Mac process, loopback TCP and synthetic group-epoch envelopes; it
  does not qualify production epoch encryption or Android-to-peer joining.
- Poco profile/AOT QA used a separate package and synthetic sovereign identity,
  with a host-mined canonical-difficulty device config supplied during genuine
  onboarding. `realStack=true` was required before counting any result. Search
  became available; publication accepted 17 native DHT records without failure.
  The actual search screen reported insufficient independent holders for the
  matching query and an empty result for an unrelated query, rather than a
  connection error. The one-holder setup never satisfied global quorum.
- Diagnostic AOT verification passed with instrumentation enabled and disabled.
  Discovery evidence retains only source-owned stage/failure codes: no query,
  identity, route hash, path or native error text.

Two early Android preparation attempts had no running node after interrupted
identity creation and are excluded from search evidence. A discarded fragment
candidate reused the complete-frame authorization gate; the negative snapshot
test caught that overreach. The final implementation has separate RAM and
complete-frame gates, and rejected complete snapshots receive no ACK.

The installed production app/container and working servers were not modified.
QA was locked, stopped, verified exited, and uninstalled; its ADB forward was
removed. Local stand runtimes were closed. Global discovery from an unknown
sovereign publisher and a cross-device Android membership ceremony remain
outside this qualification.
