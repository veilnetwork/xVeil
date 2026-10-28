# Atomic ratchet publication reservations — 2026-10-29

A deterministic native regression confirmed a gap between the host's durable
reservation check and delayed native IPC encryption. Two queued sends could
both observe the last available reserved index before either command consumed
it. The second command then published beyond the exclusive durable end. After
a crash restored the preceding snapshot and recovery burned only through that
end, the next send reused the published key/nonce. The before-fix witness uses
real ratchet encryption and compares ciphertext XOR with known fixture plaintext
XOR. This is a demonstrated constrained crash/recovery defect; it is not evidence
of exploitation or exposure of a real user's messages.

The native store now checks host-committed chain floors under the same mutex
that consumes message keys. A preliminary Dart check no longer authorizes a
later command to overrun the floor. An optional trusted-host FFI attachment owns
a process-local epoch; a queued request verifies that epoch again inside the
seal lock. A closed or superseded owner cannot borrow the successor's floors.

The application starts this attachment before its traffic. It writes the
existing encrypted reservation format and attempts its existing rollback-anchor
update before installing native permissions. A bounded demand poll reserves
new/rotated chains and the actual native conversation keys, including sends
whose physical destination differs from the certificate's stable identity.
Idle polls do not write storage. Existing small reservation windows remain;
this does not replace correctness with a huge preallocated range.

A newly created PQXDH chain keeps its first ciphertext unpublished, allowing
the host to reserve that chain before retry. The existing retained prologue
lets the actual first published frame skip the unpublished index. Waiting does
not repeatedly encrypt/copy the application plaintext or burn more keys. IPC
waits within a bounded local deadline and refuses publication on a missing
reservation or retired owner, with no unratcheted/stateless fallback for that
failure. Ordinary memory-only native stores remain unchanged until attachment.

Shutdown ends publication before the final snapshot and joins an in-flight
reservation commit. An obsolete binder does not flush or snapshot its
successor. The FFI header/contract and generated Dart ABI were regenerated
with Veil commit `f031513a`. Snapshot and network wire formats remain unchanged;
matching Dart/native artifacts are required by the existing ABI check. No
mailbox route, relay media classification or relay priority is introduced.

## Deterministic checks

- Veil: 143 E2E, 187 IPC and 326 FFI tests passed; seven existing ignored tests
  remain ignored. The production-seed, embedded-node and packet-tunnel feature
  combination was used for the combined final check.
- Native regressions cover the crash/keystream witness, eight concurrent sends
  with one permitted slot, fresh prologues, DH rotation, floor bounds, obsolete
  owners, direct/relay waiting, timeout refusal and invalid FFI pointers/counts.
- Eight new host fault-injection checks cover held commits, pre-commit and
  uncertain-result failures, actual-native-key demand, rotated chains, idle
  writes, shutdown and superseded owners. Related persistence, receipt, outbox,
  large-message, fragmentation and shutdown suites passed.
- Nine checks through the built Mac library passed, including the real
  attachment/status ABI. Static analysis found no issues; Rust formatting,
  generated header and Clippy checks passed.
- A parallel anonymous-feed test fixture was corrected to take its own runtime's
  services. Deferred stub fixtures share a fixed identity; a process-wide lookup
  could pick another concurrent fixture's receive capabilities. This was a test
  isolation failure, separate from the publication defect.

The publication floor is not an independent rollback detector. Restoring the
entire container remains governed by the existing host rollback-anchor policy.
The unchanged small coalescing window can also lose recent receive progress on
crash; this cycle does not prove every ratchet/session-repair failure closed.

Physical qualification and cleanup are recorded below and in `summary.json`.
Raw logs, keys, identifiers, addresses and message bodies remain in private local
evidence; the public summary contains role labels, counts, timings and booleans.


## Three-role delivery check

A is Android/Blackview on Wi-Fi with an AOT/profile QA build, B is its Mac
sibling and C is another identity on Mac. Mac QA Dart builds are debug. Retained
profiles are used; all roles explicitly disable anonymous routing and deny
cross-identity P2P during this check. This exercises the per-contact native
ratchet rather than treating an anonymous-stream pass as ratchet qualification.
The publication-attachment log is present on all roles, real native conversation
state is nonempty, and reservation-refresh activity is observed without a
reservation-failure log in the sampled snapshots. The final application file
inventory and packaged native-library hashes are checked privately. Native
libraries use production seeds without low-difficulty or native test-hook flags.

A submits twelve messages and C submits six through six concurrent submitters.
One generated body from each origin includes 12,300 ASCII characters plus its
fixture prefix. Both bodies match exactly on all roles. The large A post is
edited and then deleted for everyone.

| Observation | Result |
| --- | ---: |
| New messages visible once on every role | 18 |
| First all-role visible sample | 76.9 s |
| Group chunk queues empty | 145.1 s |
| Edited large post visible on every role | 10.6 s |
| Deleted target absent on every role | 13.6 s |
| Equal full histories after deletion | 1,490 rows each |
| Duplicate logical IDs | 0 |
| Unrelated IDs preserved | All |

Original anonymous settings were restored through the real controller; full
history IDs, bodies and ordering stayed equal. Before mutation B still held one
control outbox row; complete control-outbox drainage is not claimed. These
observations prove sampled convergence, not a general latency improvement or
the cause of every remaining wait. They are not a controlled comparison with
the preceding anonymous-mode run.


All roles were then cold-reopened. All 17 surviving fixture messages remained
on every role: A's eleven outgoing messages, B's eleven mirrored outgoing
messages and C's six outgoing messages all had delivered status. The complete
1,490 IDs, bodies and ordering matched the pre-close state. This is a durable
readback of the sampled statuses, not measurement of individual ACK latency.
Both completed stands closed their apps and removed their owned ADB forward.


## Incoming calls on both devices

Two automatic video calls from C rang both A and B. A answered the first and B
the second; in each case the unselected sibling stopped ringing and C became
active. Both calls stayed active for the complete planned 45 seconds over P2P,
then ended by an explicit script command.

| Answering device | A ringing | B ringing | Active after answer |
| --- | ---: | ---: | ---: |
| A (Android) | 0.638 s | 0.703 s | 2.454 s |
| B (Mac) | 0.422 s | 0.473 s | 1.396 s |

These checks qualify sampled signaling, selection and call lifetime with the
new publication mechanism. They do not measure intelligibility, headphone
loudness or absence of video freezes. They do not prove the cause or repair of
the earlier unexplained 25.1-second phone termination. Relay-side admission
with a held reservation is qualified separately by native IPC regressions;
these two physical calls used P2P.


## Cleanup and outstanding scope

The call stand restored the original anonymous settings and closed its apps.
An independent final audit checked 126 recorded owned process groups across
current and earlier cycles: no owned group or Mac QA executable remained.
The Android QA package and its named subprocesses were absent, and the owned
ADB forward was absent. Main app data and system power settings were unchanged.
Raw evidence was kept private; public fields use fixed roles and aggregate
observations only. No push, release or server deployment was performed.

The remaining delivery/sync latency, anonymous file-stream pauses, original
unexplained phone termination, Windows reports, headphone loudness, Android
sleep reports and incomplete multi-device matrix remain documented in the
[open findings](../open-findings-2026-10-28/README.md). This cycle fixes the
confirmed publication race; it does not close those unrelated reports.
