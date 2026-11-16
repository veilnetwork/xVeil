# Persist the first ratchet root before publication

Status: a confirmed shared application persistence defect, exposed by the new
plaintext mode's fast commits. Managed-storage production defaults remain OFF.

## Failure and change

The host publication guard could durably reserve sending positions for a new
conversation without first saving a recoverable conversation snapshot. Its
ordinary snapshot flush could still be inside the 200 ms coalescing window.
Both peers could exchange messages and application delivery ACKs, then die with
reservation settings and message rows present but no persisted ratchet root.

The new two-node native crash probe reproduced this in the plaintext backend:
the cold process restored zero conversations. A separate retained capture
confirmed there were no conversation-head records in either SQLite store;
authorization and reservation records were present. This was missing storage,
not native rejection of a saved snapshot. Hidden and encrypted runs passing
earlier did not prove this window safe: slower commits can let a timer flush.
The defect belongs to the shared persistence path, not SQLite durability.

At a reservation boundary, the host now saves an absent initial snapshot before
committing or reusing a reservation and before granting a native publication
permit. A pre-existing reservation alone cannot waive that prerequisite. The
snapshot's owned exported bytes are cleared after settlement, including failure.
Existing roots retain the position-only reservation path and the warm cache;
ordinary snapshot coalescing, dirty acknowledgement, publication ownership and
rollback-anchor ordering remain in force. This adds an initial snapshot write,
not a full snapshot write for every message.

An initial-save refusal or lost reply does not grant a native permit. Retry
rereads the selected store; it does not authorize a replacement identity or
switch protection modes. No native ABI, wire protocol or library pin changed.

## Evidence

- Two deterministic regression cases failed on the old code: first publication
  with and without a pre-existing durable reservation left the snapshot absent.
  They now recover the root and burn the recorded positions without a flush,
  saveAll or timer delay. Separate controls cover initial-save refusal and a
  committed initial snapshot whose reply is lost; publication stays held.
- The opt-in native probe uses two actual embedded nodes, native crypto, local
  TCP, the real messaging/ACK pipeline and the selected real storage workers.
  Contacts are explicitly provisioned as accepted synthetic contacts. There is
  no mocked transport, fabricated ACK or manually imported synthetic ratchet.
- For each of hidden, separately encrypted and plaintext storage, each peer
  sends three distinct messages and observes their actual delivery status.
  Before any graceful shutdown the parent checks the writer's actual PID/group,
  SIGKILLs the group, reaps it and verifies the group has disappeared.
- A new process opens the same stores by their original credentials. Both
  native runtimes must restore nonempty stored conversations. Before traffic,
  their native sending positions must equal the stored snapshot positions
  advanced to the matching durable reservation floors. Retained chains also
  cannot move behind the pre-kill live checkpoint.
- Cold histories must contain every exact message ID/body. Another three
  messages per direction must then arrive and be acknowledged, leaving all
  twelve distinct messages in each peer's history. Across the three modes this
  is 18 acknowledged messages before the kills and 18 more after recovery.
- The final host run passed **102 tests across five suites, zero skips**:
  reservation, paired snapshot, persistence, native crash/continuation and mixed
  all-online application ingress/process death. Analysis found no issues.

The first revision of the native oracle incorrectly required every last RAM
chain to exist in the cold process. That contradicts the explicitly retained
coalescing policy: a DH rotation can be newer than the stored snapshot. That
oracle was corrected, not treated as another product defect. Cold admission
still requires nonempty native restoration, exact durable-floor recovery,
history preservation and subsequent real bidirectional delivery. An empty
restore cannot pass by starting another conversation after peering.

Both selected native library hashes match their previously qualified inputs;
all 1,577 recorded Veil source inputs match the corresponding package-source
manifest. No Rust build was needed. The tests are headless and do not activate
application windows. Owned tester/node processes and listeners are checked on
exit. Raw capture evidence stays outside the repository.

## Limits and reproduction

Set `XVEIL_NATIVE_RATCHET_CRASH=1`, `VEIL_FFI_DYLIB` to a compatible
node-embedded library and `XVEIL_HV_DYLIB` to the qualified storage library:

```sh
TMPDIR=/private/tmp/ flutter test --no-pub --concurrency=1 \
  test/native/native_ratchet_storage_crash_test.dart
```

This qualifies actual post-ACK process death and native recovery on macOS. It
does not claim hardware power-loss durability, external rollback-anchor/OS-vault
qualification, GUI all-online lifecycle coverage, physical Android/OEM or
Windows ratchet qualification. The native runtimes are fresh, but both peers
restart together; asymmetric live-peer recovery remains a separate scenario.
Packaged custom-source compaction cold readback, the remaining credential/model
and destructive inventory, release AOT and all-target native packaging still
precede activation of the enumerable encrypted default. Existing hidden
containers remain unchanged. No push or release.
