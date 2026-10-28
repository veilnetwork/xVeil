# Small-file publication — 2026-10-28

Creating a small content-addressed journal segment paid for two commits: first
its chunks and accounting, then its metadata/cursor and accounting. Both sets
can fit the existing conservative operation budget. They now publish atomically
in one commit in both `FileStore` and `AsyncFileStore`.

## Transaction boundary

The fast path counts every operation, including metadata, cursor, GC accounting
and any retirement. The complete transaction must contain at most 64 operations.
It also requires either no new chunks or no `DeleteLogOp` retirements. Native
hidden-volume forbids appending and deleting log records in the same namespace
in one transaction; the fake enforces this too. Nonempty replacements therefore
retain their bounded chunk commits followed by the final metadata/retirement
commit. Empty replacements have no appends and may fit the atomic path.

The existing size caps, fresh log IDs, metadata encoding and pre-write GC sweep
policy are retained. A sweep, when due, can still require its own commits. This
is one publication commit for a fitting creation, not a promise that every
store operation performs only one native commit. Existing contiguous and
streamed formats covered by the tests remain readable.

Chunks, metadata, allocation cursor and GC count move together on the fast path.
A rejected fresh-file publication leaves none of them advanced. A successful
replacement still keeps the old file until its final publication. No durable
mirror join, authentication check or relay scheduling rule was removed.

## Verification

The 34-file suite passed 803 tests with three existing skips. Static analysis
found no issues. After adjusting the old GC fixture to remain above the new
atomic threshold, the affected 18-test subset also passed; counts overlap.
The GC test now accurately names its multi-commit/reopen scope rather than
claiming a crash injection it never performed.

Nine new fake-store cases cover sync/async creation, empty and nonempty
replacement, failed creation, retry, idempotence, exact budget boundaries,
large-write publication failure/accounting, and streamed replacement. Four
fresh-creation/budget regressions were run against the preceding source and
failed there, then passed with this change. Nonempty replacements continue through two legal transaction stages.

Two additional tests ran against the production Mac hidden-volume library,
without skips. They exercise both interfaces, incompressible bytes, the 61-chunk
creation that uses exactly 64 operations, the 62-chunk fallback, replacement,
reopen and a further creation. An oversized record in a native data+metadata
transaction was also rejected: the prior log count and file stayed intact,
neither a valid prefix record nor the invalid file metadata appeared, including
after reopen. This covers observed transaction rejection and durability across
reopen; it is not a physical power-loss test.

A separate paired native benchmark compared a copy of the preceding file-store
source with the current source in the same Flutter test process and library.
Only relative imports in the baseline copy were rewritten to package URIs.
Each interface created sixteen fresh 64 KiB incompressible files per variant,
after one warm-up; before/after order alternated each iteration. Bytes were
verified after the measured write. The async interface used the synchronous
native adapter, so this fixture excludes worker-isolate IPC.

| Native Mac fixture | Before mean / median ms | After mean / median ms | Commits per creation |
| --- | ---: | ---: | --- |
| Sync | 33.45 / 32.88 | 18.75 / 18.29 | 2 → 1 |
| Async adapter | 34.14 / 33.26 | 19.02 / 18.25 | 2 → 1 |

The roughly 44% reduction applies to this isolated creation fixture, not whole
message delivery or all file replacements.

## Physical stand

A is Android/profile-AOT on Wi-Fi; B is its Mac sibling; C is another identity
on Mac. Mac Dart builds are debug. Each timed phase used retained profiles,
a fixed 30-second warm-up and six submitters sending twelve A-to-C and six
C-to-X messages. Production native/HV binaries were reused; no Rust, server or
main-app changes were made.

| Window observation on A | Baseline | Candidate |
| --- | ---: | ---: |
| Completed batch saves | 11 | 15 |
| Mean batch-save duration, ms | 1,529.3 | 1,266.0 |
| Mean batch-load duration, ms | 907.0 (11 samples) | 831.3 (16 samples) |
| Six new C messages: mean own-mirror join, ms | 2,617.8 | 2,678.2 |
| Outbound ACK sends | 6 | 19 |
| Outbound ACK send total, ms | 397.6 | 9,272.1 |
| Submit all 18 messages, seconds | 13.1 | 16.9 |
| Observe all three projections, seconds | 33.8 | 58.6 |

All six new C logical IDs were linked to their completed handler and store
samples on A. All 18 logical messages converged without duplicates; complete
visible IDs and order matched (892 baseline rows; 910 candidate rows).

Histories advanced, background frame mixes and batch sizes differed, and stage
windows include overlapping/in-flight work. Their totals must not be added or
subtracted to assign one message's latency. The lower save mean is an observed
workload result; overall delivery did not improve in this pair. The extra ACK
send time is a lead requiring frame/ID attribution, not yet a diagnosis of the
remaining whole queue delay.

## Ordinary build and next work

Both source copies were restored to repository `lib` and rebuilt. The final
ordinary Android build was profile/AOT, contained no private timer strings, and
the private timing endpoint returned 404 on all three roles. It submitted the
18-message burst in 25.0 seconds. All messages were observed by 96.7 seconds;
all delivery marks by 129.1 seconds. All 928 visible IDs and their order matched
without duplicates. Long delivery/receipt latency is still open.

Every phase closed its owned apps. An independent audit checked 47 recorded
process groups and both owned Mac executable paths, found none remaining, and
confirmed Android QA termination and removal of its ADB forward. Main app data
and system power settings were unchanged. Details are in
[summary.json](summary.json).

The `ack.transport` overlay label wraps `_send`, including its ratchet checks,
reservation and post-send flush; it is not a network-only measurement. The
ordinary A session logged 141 slow sends (the existing >=50 ms threshold):
mean measured transport call 96.2 ms, mean post-send ratchet wait 238.2 ms,
mean combined 334.4 ms. These are mixed traffic over the whole recorded session,
include overlapping waits and exclude fast sends. They cannot be summed into
wall-clock delay or attributed specifically to the six new C messages.

Existing ratchet logs further separate this lead: 229 selected slow flushes
in that ordinary session averaged 205.8 ms at the ratchet transaction gate and
180.3 ms doing work. In 61 selected slow flush steps, save averaged 441.1 ms;
peek/note/export averaged 0.0/0.7/0.6 ms. The sample sets and thresholds differ.
`flush()` already returns immediately for a trailing coalesced call inside its
200 ms window; that timer is not an unconditional sleep on each ACK.

Next, attribute outbound ACK waits to their incoming frames/logical IDs and
split reservation, native transport, ratchet coalescing and actual persistence
before changing scheduling. Any separation of ACK transmission must keep durable writes
before ACK, bound outstanding work, preserve authenticated routing/owner
lifetimes and join cleanup. Permission/state mutations must retain their
ordering. Local own-journal load/save latency also remains open.

Windows reports, partial chunk-ACK receiver-crash recovery, live speech/
headphone volume, long offline, revoke/split-brain and the full multi-device
matrix remain unqualified. Nothing was pushed, released or deployed. Public
evidence contains allowlisted roles, counts and timings. Raw logs, addresses,
identities, device/message IDs and credentials remain private.
