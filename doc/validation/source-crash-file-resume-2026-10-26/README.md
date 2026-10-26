# File continuation after a source process crash

Local qualification on the cold-reply-corrected SDK and current QA application
bundles. No release, push, main-app installation or relay modification.

## Stand and procedure

B and C are independent macOS QA processes and native nodes. B belongs to
identity X with the offline Android device A; C belongs to identity Y. Only C
holds the new source file. Both contacts' P2P policies are temporarily denied,
so the reliable file stream uses the anonymous circuit backend.

C offers a fresh random 6 MiB plus 251-byte file. B has neither its cached bytes
nor a destination file. The ordinary MessagingService file-to-file download runs
through the existing QA API. The driver watches the destination's temporary
file, rather than the sender's queued-byte count. At 3 MiB written, it forcibly
terminates only C's owned process group. B keeps running. After ten seconds, C
reopens its current encrypted profile; no prior native or ratchet snapshot is
restored backwards.

| Observation | Result |
| --- | --- |
| Expected file size | 6,291,707 bytes |
| B's written prefix at interruption | 3,145,728 bytes |
| Download start to interruption | 146.911 s |
| Source crash to application ready again | 12.334 s |
| C's physical key and shared identity after reopening | Preserved |
| Source request after reopening | Range begins at byte 3,145,728 and ends at 6,291,707 |
| Final destination | Complete; identical byte-for-byte and by SHA-256 |
| Complete download duration | 293.102 s |
| Leftover temporary destination files | None |

This verifies continuation from the written prefix instead of retransferring
the whole file after a source crash. It does not verify receiver-process crash,
Windows, cellular service, an unavailable/moved original source path, all crash
injection stages or the visible chat bubble's progress indication.

The original policies were restored and endpoint RT trace disabled. Latest
encrypted profiles were archived privately. The first teardown observer expired
while checking process exit after termination; subsequent process inspection
and cleanup verified that both owned groups were absent. The initial driver's
nonzero exit belongs to that teardown observation, after all file/data checks
had passed. No main app or system audio/network setting was changed.

## Slow establishment remains reproducible

The receiver again hit one 25-second connection timeout before the intentional
crash. For that first stream, the source admitted SYN and eventually handed its
response to the local carrier; the initiator admitted no SYN_ACK before its
deadline. No protected-introduction rejection or unknown-tag event was recorded
at the initiator. A later attempt established successfully. Therefore the earlier
cold identity-lookup correction does not establish that all handshake stalls
are fixed.

Read-only SSH inspection covered all six existing relays. Their clocks matched
the test host. Services append text logs to files, so the empty system journal
window was not evidence of absent traffic. The bounded file-log read recovered
the actual test interval without changing running services or logging settings.

Across that interval, three relays recorded seven unspliced terminus cells:
two of 203 bytes and five of 207 bytes. These sizes match the current protected
SYN and SYN_ACK splice envelopes. Endpoint route-selection and publication logs
also show different relay sets during warm-up. This is evidence to investigate
stale rendezvous advertisements or missing destination registrations. Standard
privacy-preserving relay logs do not identify each failed cell's cookie, and a
publication log is not a complete registration inventory, so attribution of all
seven cells to this transfer remains unproven.

Large and variable DATA delays also remain: eventual byte recovery alone does
not close the reported hanging/slow-transfer problem. The next investigation
must distinguish a confirmed sender-side circuit from a live registration for
the intended receiver at its rendezvous relay.

Raw logs, endpoint identities, source/destination contents, cookies, certificates,
timestamps and ownership records remain private. Public evidence contains only
roles, aggregate sizes/durations and source-owned event categories.

## Follow-up: teardown after re-registration

The next cold-start investigation kept the same current profiles and native
library. A read-only QA authorization probe found the expected contact document
and device-key bytes in both the restored native snapshot and encrypted host
storage. There was one parent-document byte match per remote physical device.
These structural observations neither authorize a sender nor invoke the proof
check that can fetch/observe documents and alter the cold state being measured.
The QA endpoint returns only booleans and counts; it does not return documents,
identities, keys or the supplied query values.

A further fresh, uncached 3 MiB plus 251-byte anonymous transfer did not finish
within its three-minute download budget. Read-only local admin snapshots sampled
DHT advertisements during the first two minutes. In those snapshots, the
non-mailbox cookies at both physical device addresses matched each device's
currently published stream registration cookie. There was one stream cookie
and one introduction public key per device. This does not expose every remote
candidate seen by the resolver and does not prove that each advertised relay
still held the intended receiver's registration. The observation rules out
simple mailbox-cookie misclassification in the sampled local mirrors, not all
route failures. Original contact policies were restored in a separate cleanup
reopen, and both owned process groups were verified absent.

Inspection of the relay teardown path then found a separate, deterministic
availability defect. A receiver can confirm a newer signed registration of its
cookie on a replacement circuit. The old circuit still records that cookie;
its subsequent teardown unconditionally removed the current subscription,
even though the registry now pointed at the replacement. Consequently, valid
post-cookie bytes arrived at the terminus without a receiver to splice to.

The regression drives the real dispatcher: signed registration, confirmed
replacement on another neighbouring link, delayed teardown of the first path,
and an encrypted sender cell that must be returned through the replacement.
Both receiving paths deliberately use the same link-local circuit number.
Before the fix, the test failed because no spliced return cell was emitted.
After the fix, both reliable CircuitData and CircuitDatagram delivery succeed.
A second regression reuses the same neighbour AND circuit number with a new
circuit incarnation, to prevent reducing ownership to just those numeric keys.
Current-owner teardown still removes the subscription and its per-link index.

Registry removal now compares the exact circuit incarnation and removes its
subscription under one registry lock. It cannot erase a fresher registration
that won before the comparison. Registration signatures, cookie binding, epoch
checks, wire format, capacity limits, relay scheduling and media opacity are
unchanged.

SDK commit `c93427ee` contains the correction. All 335 enabled veil-anonymity,
285 veil-dispatcher and 726 veil-node-runtime library tests passed, with one
existing anonymity skip and eleven existing runtime skips. Rust warnings were denied and
the external target mount monitored throughout compilation/testing. The QA
Dart hook also passed static analysis; its two owned application bundles had
already been built and exercised against the numeric-only authorization probe.

This is a local server-code fix. Running production relays have not been changed,
and the failing live transfer was performed against their previous binaries.
No post-deployment improvement is claimed. The exact contribution of this race
to that transfer or to the reported Windows 10 failure is still unproven. There
was no release, push, main-app modification or change to system audio/network
settings during this follow-up.
