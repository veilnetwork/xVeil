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
