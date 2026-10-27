# Own-device transport addresses — 2026-10-27

`addressableOwnDevices` composed helpers that each loaded the device journal:
recipient membership, linked-owner detection, and marked master announcements.
The compiled regression observed two complete header reads on the master for
one lookup; a cold linked lookup could also read for owner detection.

Routing now derives membership and announcements from one fresh, fully loaded
bundle. The announcement fold still materializes validated messages and applies
the existing clock bound and deterministic master selection. The view is not
cached across calls, and a broadcaster does not supply an earlier saved bundle.
Admission caches and their invalidation rules are unchanged. There is no change
to mailbox policy, relay scheduling, media adaptation or native libraries.

## Checks

The new read-count test failed before the change (two reads, expected one).
Both master and linked-device cold/repeated lookups now read once. The extended
regression checks a replacement master announcement, exclusion of a future
announcement, storage failure followed by retry, and removal of a revoked
recipient on the next lookup. Fake-signature fixtures test application routing;
they are not a qualification of native cryptography or the full revoke protocol.

The group-service suite passed 328 tests with three existing skips. Eight
adjacent delivery, outbox, device-sync, group-content and group-call suites
passed another 135 tests. The extended routing regression also passed on the
final source. Static analysis reported no issues.

## Physical stand

A is Android on Wi-Fi and B is macOS, both identity X. C is another macOS
instance, identity Y. Encrypted profiles were retained. The application source
was copied and checked against both QA builds. Native artifacts stayed on Veil
`1d36980d` and the existing media build. No timing overlay, reduced identity
difficulty, native test hook, forced route, Rust build or server change was used.

After a fixed 30-second warm-up, C sent six spaced messages to X with all three
devices online:

| Round | First observed on A, ms | First observed on B, ms | Sender retries |
|---|---:|---:|---:|
| 1 | 5,620 | 928 | 1 |
| 2 | 18,129 | 3,915 | 0 |
| 3 | 15,437 | 1,125 | 0 |
| 4 | 14,010 | 3,155 | 0 |
| 5 | 7,888 | 773 | 0 |
| 6 | 7,814 | 632 | 0 |

Every round converged to the same logical message IDs without duplicates.
The complete visible conversation contained 468 rows on each device, with
identical ID sets and visible order. File bytes and other state dimensions
were not compared. These timings include polling and application processing,
not just network transit. There is no controlled end-to-end speedup claim:
Android propagation remains slow despite eliminating redundant journal reads.

C then initiated a video call to X. A and B rang after 479 and 492 ms,
respectively. A accepted; B stopped ringing. Both endpoints became active
6,752 ms after the answer. Across 43 samples over 89.9 seconds, A and C stayed
active on P2P with cameras enabled. Audio transmit/receive counters increased
in both directions; neither endpoint reported a stalled worker. After the
first 30 seconds, receive video FPS ranged from 15.8 to 24.9 on A (median 22.5)
and 15.6 to 25.0 on C (median 22.7), without a zero-FPS sample in that interval.
Native reported audio-delay peaks were 97 ms on A and 73 ms on C; these are
not an end-to-end speech-delay measurement. Live speech intelligibility and
headphone volume were not assessed.

## Cleanup and limits

All started apps were closed. A separate audit checked five recorded process
groups, found zero remaining processes and no Android QA process, verified
restored permissions, and confirmed removal of the owned ADB forward.
Main application data and system power settings were unchanged. Only fixed
roles, counts and timings are exported in [summary.json](summary.json); raw
logs, identifiers and credentials remain outside the repository.

Nothing was pushed, released or deployed. Windows reports, long offline cases,
the full multi-device matrix and the previously documented partial chunk-ACK
crash limit remain outside this qualification. The 7–18-second Android
propagation samples and the 6.8-second call setup require further investigation.
