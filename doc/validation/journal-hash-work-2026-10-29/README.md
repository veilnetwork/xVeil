# Repeated payload hashing in the device journal — 2026-10-29

A CPU profile on the physical Android QA device identified redundant hashing
in the local journal path. During three real sequential journal posts, 1,610
of 5,420 CPU samples contained `groupMessageHash` on their stack (29.7%).
The same canonical payload was serialized and hashed for deduplication and
fork detection, even when it had no competing row. These are overlapping stack
counts, not independent time budgets or a measurement of network delay.

The profile used the existing QA API and stock Dart VM CPU profiler on the
retained AOT/profile app. It added no production instrumentation. Other QA apps
were closed. One inert, unregistered setting key was posted three times;
product settings do not apply that key. The profiler flag and both owned API/VM
forwards are restored/removed at shutdown. Raw logs, URI authentication tokens,
identifiers and profiles remain private.

## Change

Canonical-history construction now computes full hashes only for colliding
writer/scope/author/sequence slots. Unique slots cannot equivocate; every input
row still passes the same signature and identity-document verification. A
collision compares the complete original hash, including the signature, and
quarantines the same scoped suffix as before.

Retained-history deduplication uses author, sequence and signature as a cheap
prefilter: all three are committed by the full message hash. Different signed
slots cannot be exact duplicates under the protocol's existing hash-collision
resistance assumption. A matching prefilter still requires the complete hash.
First-seen indices preserve raw order; exact repeats replace their earlier
value in place. Distinct bodies or signatures remain retained fork evidence.

Both structures exist only during the current synchronous pass. There is no
cross-read hash, authorization or decoded-bundle cache. Changed signatures,
identity documents, membership, retention cuts, lifecycle state and writer
scopes are still judged by subsequent reads/writes. Wire formats, cryptographic
hashes, signature algorithms, persistence order and mailbox/relay policies are
unchanged.

## Deterministic checks

The preceding canonical scan failed four focused work-budget checks. The
preceding retained scan separately failed the unique-slot work check. All
eight new tests pass after both changes. They cover unique slots without fork
hashes while still re-verifying rows, exact duplicates, signature-only forks,
invalid collisions, order-independent fork quarantine, retained row ordering,
and changed signature bytes on a subsequent read.

The full GroupService file passed 355 tests with three existing skips. A
disjoint six-file integration run passed 73 tests covering snapshot chunks,
retention, lifecycle, reachable-peer sync, committed group receipts and
outgoing mirror retry. Static analysis found no issues; only the changed
source/test fragments were formatted in the large legacy files.

Phone measurements, physical A/B/C convergence, cold readback and independent
cleanup are recorded in `summary.json`. A faster local journal path does not
establish that all end-to-end delivery delays have been eliminated. No push,
release, Rust build or server update is included.

## Phone A/B/A measurement

The same retained profile and production native libraries were used throughout.
The original QA APK was retained, checked against its recorded SHA-256, then
reinstalled for the final A measurement. The fixed QA artifact was restored
afterwards. No identity or main-app data was removed. Each launch warmed the
group-read API before collecting the same sequence with a 1,000-us CPU sample
period. Only the inert timing-setting rows were added between runs.

| Observation | Original A | Fixed B | Original A again |
| --- | ---: | ---: | ---: |
| First local post | 1,175 ms | 1,272 ms | 1,225 ms |
| Second local post | 3,001 ms | 1,981 ms | 3,551 ms |
| Third local post | 4,306 ms | 2,940 ms | 3,665 ms |
| Sum of three posts | 8,482 ms | 6,193 ms | 8,441 ms |
| CPU samples during those posts | 5,420 | 3,827 | 5,618 |
| Samples with `groupMessageHash` on stack | 1,610 | 0 | 1,737 |

The three-post total improves by about 27% against either original run. The
first isolated post is not faster; most observed benefit is in successive
posts competing with preceding background journal work. Zero sampled hash
frames does not mean the protocol never computes a hash: necessary predecessor
and actual collision hashes remain, and sampling can miss short operations.

This is one physical-device A/B/A sequence, not a general throughput guarantee.
Segment decoding and verdict-key construction remain prominent in the fixed
profile. Local posts still take seconds, and network delivery/convergence must
be measured separately. No 27% end-to-end messaging improvement is claimed.

## Physical convergence and cleanup

A is Android on Wi-Fi, B its Mac sibling, C another identity on Mac. All use
the exact final application inventory and unchanged production native
libraries. Android runs AOT/profile; Mac runs debug Dart. The CPU profiler is
not enabled for this stand. Anonymous routing is disabled and cross-identity
P2P denied for delivery, then both original modes/policies are restored.

Six concurrent submitters send twelve posts from A and six from C, including
generated 12,300-character bodies from both origins. All 18 logical posts and
both exact large bodies appear once on each role, with equal full IDs/order.

| Observation | Result |
| --- | ---: |
| First all-role visible sample | 58.7 s |
| Group chunk queues empty | 75.4 s |
| Edited large post on all roles | 11.0 s |
| Deleted target absent on all roles | 16.0 s |
| Equal histories after cold reopening | 1,558 rows each |
| Surviving fixture posts after cold reopening | 17 each |
| Delivered outgoing fixture statuses A / B / C | 11 / 11 / 6 |
| Duplicate logical IDs | 0 |

Unrelated IDs remain. Cold reopening returns exactly the saved pre-close IDs,
bodies and order. Two other control frames remained on B at the group-drain
sample. The observed delivery time is still long; this separate network run
does not establish a delivery-speed improvement against the previous stand.

Apps were closed after every run. Independent cleanup checked 142 recorded
owned process groups, Android package/named subprocesses, the API forward and
all three VM profiler forwards. None remained. Main app data and system power
settings were unchanged. The current QA artifact is installed after the A/B/A
comparison; no main-app replacement, push, release or server deployment occurred.
