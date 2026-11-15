# Mixed-mode ingress across process death

Status: a host-native qualification slice, not production activation or a new
user-defect fix. Managed production defaults remain OFF.

## What was exercised

An independent headless Flutter test process creates an actual hidden master
and three children: one hidden space, one separately encrypted managed store
and one unencrypted managed store. The real `MultiIdentitySession` opens them
simultaneously through `WorkerMultiSpaceBacking` and managed identity workers.
Node boot and transport are test doubles; storage and messaging ingress are real.

The probe queues 12 messages per identity before awaiting any acknowledgement.
All three identities deliberately receive the same 12 wire IDs with different
bodies. This exercises concurrent ingress, per-identity deduplication and data
isolation rather than three unrelated sequential storage writes.

The checkpoint requires the exact 12 distinct delivery ACK IDs from each
identity's test transport. No incoming-event counter or equal empty history can
satisfy it. The sender is a synthetic accepted contact, not a linked sibling;
no mailbox is added. These are application ACKs emitted to the local test sink,
not an assertion about delivery over a real network.

The parent verifies the live writer belongs to its isolated process group,
SIGKILLs that group, reaps the launcher and waits until the actual tester/worker
group no longer exists. It then cold-opens the saved master and every actual
child, checks every message ID/body and profile, and proves each child accepts
and retains another write. The writer does not read back messages or perform
graceful lock/disposal before the kill.

## Evidence and controls

- All 36 acknowledged messages survive, with exactly 12 in each identity and
  no cross-identity bodies. The post-crash writes also survive cold reopen.
- A temporary negative control replaced actual ingress with fabricated ACKs.
  The checkpoint was reached, but cold history validation failed with 0 of 12
  expected messages. That control was removed before final qualification.
- The first process fixture attempted a standalone Dart runner, which cannot
  import the application's Flutter-dependent worker/session boundary. This was
  a fixture compilation failure, not a product defect. The qualified fixture
  uses a separate headless Flutter tester, without an application window.
- The initial kill control reaped only the launcher. It observed a transient
  native busy lock while another killed process was still exiting. The final
  fixture waits for process-group disappearance before its first cold open;
  it does not conceal that gap with storage-open retries.
- The final frozen-source run passed **31 tests across 5 suites**, with no
  skips, including session ownership/teardown, mixed native storage, the new
  process-death case, file-read session isolation and master selection.
  Analysis of the session boundary and both new files found no issues.
- All owned tester/Dart processes exited. No GUI was launched or activated;
  the user's running application remained untouched.

## Limits and next gates

This is process death on macOS with an actual verified hidden-volume library,
not a power-loss, physical OEM or Windows qualification. The injected nodes
have no native ratchet, so this does not close the separate ratchet crash/
delivery-ACK recovery requirement. Pre-commit interruption, application-level
all-online routing across lock/switch/maintenance, Windows source-name
durability, packaged cold custom-source compaction recovery and release-AOT/
all-target native packaging still need their corresponding evidence. Existing
hidden data must not be silently migrated to enable the enumerable default.

No product code, native library or dependency pin changed in this cycle.
