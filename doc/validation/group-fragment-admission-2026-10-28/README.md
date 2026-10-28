# Group-fragment admission — 2026-10-28

A chunked group snapshot used to reload membership for every fragment from a
non-contact, including linked devices (which are not contact rows). Retries of
already committed sibling fragments did the same work before finding their
receipts. This was avoidable work in the ordinary serialized inbound lane.

## Change and authorization boundary

The transport now checks stranger admission before reserving a partial transfer,
then shares that admission only across the bounded in-memory partial. It checks
current admission again before applying the completed bundle. The group handler
still verifies and commits the bundle independently; the lease is not a durable
write authorization. A contact-created partial has no stranger lease and must
pass admission if a later fragment arrives after the contact relationship changes.

The existing eight-transfer, byte and fragment-count limits remain. A sender
revoked during assembly can finish filling its already admitted bounded RAM
partial, but the fresh final check denies apply and ACK. Refused/completed or
evicted partials cannot supply a lease for a new transfer. No partial slice is
ACKed before the full snapshot has been successfully applied.

For native-authenticated contacts and own devices, a committed slice can be
re-ACKed from the existing source-bound receipt without reading membership again.
Canonical transfers retain their content/destination digest binding; legacy
receipts retain their exact body hash and authenticated source requirement.
Claimed sibling attribution cannot take this fast path. Other strangers must
reauthorize even a committed replay. No new payload or state is accepted by a
receipt ACK.

Changing the admission callback now invalidates partials and receipts alongside
changing the apply handlers. An admission read begun under an old owner cannot
allocate a partial or authorize an apply after the owner changes. This also
protects rebuilt store/identity bindings.

## Verification

The 18-file suite passed 602 tests with three existing skips. Static analysis
found no issues. Five new regressions cover shared fragment admission with a
fresh final check, revoke during assembly, stranger replay after revoke,
admission-owner replacement while a read is pending, and a contact becoming a
stranger mid-transfer. The sibling test also rejects the claimed-attribution ACK
shortcut. The first two regressions failed against the preceding implementation.
Existing durable-write, failed-apply retry, partial receiver restart, source/
physical-device binding, handler replacement and reassembly-cap tests pass.
These fixture tests establish application behavior, not native key-revocation
strength.

A is Android/profile-AOT on Wi-Fi. B is a Mac device of the same identity; C is
a different identity on Mac. Mac Dart builds are debug. Each measured phase
sent 12 A-to-C and six C-to-X messages with six submitters after a 30-second
warm-up. All phases reused the same production native libraries and HV binary;
there were no Rust builds or relay changes.

| Observation | Baseline | Candidate |
| --- | ---: | ---: |
| Submit all 18 messages, seconds | 20.7 | 21.7 |
| Observe all three projections, seconds | 43.1 | 52.4 |
| Six new C message frames on A: queue mean, seconds | 22.7 | 21.7 |
| Six new C message frames on A: queue peak, seconds | 32.3 | 29.4 |
| Same message handlers: mean, seconds | 4.33 | 2.92 |
| B completed chunk frames | 22 | 23 |
| B chunk handlers: total, seconds | 6.95 | 2.43 |
| B membership reads: count | 44 | 33 |
| B membership reads: total, seconds | 2.63 | 0.34 |
| B group applies classified as ingest | 10 | 13 |
| B group apply total, seconds | 13.53 | 5.67 |

The private frame recorder linked each of the six new C logical message IDs to
its completed handler on A; raw IDs remain private. All 18 messages converged
without duplicates in each phase. Complete visible IDs and order matched on
A/B/C (784 baseline rows; 802 candidate rows).

This is not a controlled overall speedup benchmark: retained histories advanced,
background frame mixes differed, and the candidate took longer to converge.
Nested/overlapping stage totals must not be added. The chunk path does less
repeated work, but the long delivery tail remains open. In this baseline window,
B's group applies were state ingest, with no sync-request serving observed. In
the candidate window A also served one request (3.84 seconds); that distinction
was invisible in the previous aggregate timer.

## Ordinary build and remaining work

The source copies used for measurement were restored to repository `lib` before
rebuilding the ordinary QA apps. Final results and independent cleanup are
recorded in [summary.json](summary.json). The final ordinary build submitted
its burst in 15.5 seconds. All 18 messages and delivery marks were observed on
A/B/C by 56.8 seconds; all 820 visible IDs and their order matched without
duplicates. No per-frame queue latency is claimed for this uninstrumented phase.
The private timing endpoint returned 404 on all three roles, and the Android
profile/AOT artifact contained no private timer strings.

All owned apps were closed after each phase. An independent final audit checked
35 recorded process groups plus both owned Mac executable paths and found none
remaining. Android QA was stopped and the owned ADB forward removed. Main app
data and system power settings were unchanged.

The next useful breakdown is inside ordinary message storage/own-journal
mirroring and ACK routing on Android. The baseline A window had no completed
group applies, yet its six C message handlers took 25.98 seconds in total and
16 ACK handlers took 9.44 seconds. A group-apply timer alone cannot explain that
queue. Do not parallelize permission/state mutations or introduce a persistent
admission cache to hide the wait.

Windows reports, partial chunk-ACK receiver-crash recovery, live speech/
headphone volume, long offline, revoke/split-brain and the full multi-device
matrix remain unqualified. Nothing was pushed, released or deployed. Raw logs,
addresses, identities, message/device IDs and credentials stay in private files;
public evidence contains only allowlisted roles, counters, booleans and timings.
