# Ratchet cleanup and message-fold retention — 2026-10-28

Periodic ratchet cleanup discarded the complete in-memory conversation fold.
After every 128 saved conversations, `saveRatchetStates()` vacuumed old key
material and then invalidated the message cache. The next message/history read
therefore decrypted and folded the old message log again. Ratchet replacement
has not changed that log, and native vacuum preserves live logical IDs/values.

The ratchet-only cleanup now retains the warm message fold and its incremental
watermark. `KvLogStore.scrub()` documents the live-key/log-ID preservation
contract already implemented by the production adapters. Explicit message
mutation/deletion/recovery and identity lifecycle invalidation retain their
existing paths.

A failed vacuum also reset the in-memory cleanup budget before attempting the
erasure. Another save could then succeed without retrying cleanup, postponing
it for another 128 saves. The serialized ratchet path now clears that budget
only after vacuum succeeds. The next state save retries a failed cleanup.

## Verification

Two initial regressions failed against the preceding implementation: a warm
200-message fold was read again after ratchet cleanup, and failed cleanup was
not retried on the next save. Both pass after the correction. A further
regression verifies the enclosing `RatchetPersistence` contract: cleanup failure
keeps the native dirty mark and degraded guard set; successful retry performs
the erasure before clearing them.

The 34-file suite passed 805 tests with three existing skips. After extending
the retry check through `RatchetPersistence`, all 44 ratchet tests passed; these
counts overlap. Static analysis found no issues. Existing reservation, dirty
generation, failure/close, state-shrink, whole-conversation commit, source
attribution, durable ACK, history and storage tests remain green.

A new test also ran without skips against the production Mac hidden-volume
library. It stored/warmed 200 messages, performed 128 ratchet state writes and
one actual vacuum, then required a cache read with no log iteration. Direct
native reads before/after vacuum retained identical live log IDs/payloads. The
next post used an incremental range and all 201 messages remained visible.
The latest ratchet blob was intact. This is native vacuum/read verification,
not a physical power-loss experiment or a qualification of every crash stage.

At the time of these measurements the cleanup budget was still an in-memory
per-storage field; this cycle verified same-session failure/retry. The
[subsequent cleanup-budget validation](../ratchet-cleanup-budget-2026-10-28/README.md)
addresses persistence and outstanding cleanup obligations across restart.

## Physical measurements

A is Android/profile-AOT on Wi-Fi; B is its Mac sibling; C is another identity
on Mac. Mac Dart builds are debug. Each timed phase used retained profiles,
a 30-second warm-up and six submitters sending twelve A-to-C and six C-to-X
messages. Native/HV binaries were identical across phases; no Rust, relay or
main-app changes were made.

The private overlay now attributes ACK sub-stages to logical message IDs. In
the baseline, all six new C messages had exactly one observed ACK path on A:

| Baseline ACKs for the six new C messages on A | Mean ms | Peak ms |
| --- | ---: | ---: |
| Complete ACK send | 449.4 | 2,508.9 |
| Durable-state precondition | 0.1 | 0.2 |
| Send-window reservation | 141.9 | 748.3 |
| Transport API call | 13.2 | 27.0 |
| Post-send ratchet flush | 287.4 | 1,722.5 |

The 2,508.9 ms worst ACK was joined to the same exact logical ID for every
component: precondition 0.1 ms, reservation 748.3 ms, transport call 27.0 ms,
flush 1,722.5 ms. The remainder includes routing/ACK glue. Raw IDs remain
private. Transport API duration is not wire latency or network RTT. This
observation locates that ACK's wait in ratchet operations; it does not classify
every slow message or every network route.

| A window observation | Baseline | Candidate |
| --- | ---: | ---: |
| Ratchet saves completed | 64 | 75 |
| Mean stored-head read, ms | 65.8 (86 samples) | 67.1 (95 samples) |
| Mean ratchet commit await, ms | 86.8 | 70.4 |
| Periodic vacuums | 1 | 1 |
| Vacuum total, ms | 1,504.8 | 901.7 |
| Ratchet-triggered message-cache invalidations | 1 | 0 |
| Message-fold stage total, ms | 2,252.7 | 1,664.6 |
| Six C message frames: mean queue wait, ms | 18,617.2 | 20,452.3 |
| Observe all 18 messages on three roles, seconds | 44.5 | 49.9 |

All 18 logical IDs converged without duplicates; complete visible IDs and order
matched (946 baseline rows; 964 candidate rows). Candidate ACK sends averaged
623.2 ms (peak 3,042.3), including mean reservation 302.1 ms, transport call
14.3 ms and flush 297.5 ms. Long delivery/receipt latency remains open.

Stages are nested and can overlap. Counts, histories and background mixes
differed; these are workload observations, not a controlled overall speedup
benchmark. Head/commit awaits still include worker scheduling and I/O. They do
not by themselves separate queue time from native execution. The deterministic
regressions and native test establish removal of the unnecessary full fold.

## Ordinary build and next work

Both source copies were restored to repository `lib` and rebuilt. The final
ordinary Android app was profile/AOT without private timer strings; the private
timing endpoint returned 404 on all three roles. Its burst submitted in 23.0
seconds. All 18 messages and delivery marks were observed by 86.5 seconds;
all 982 visible IDs and their order matched without duplicates. Long delivery
latency is still open.

All owned apps were closed after every phase. An independent audit checked
53 recorded process groups and both owned Mac executable paths, found none
remaining, and confirmed Android QA termination and removal of the owned ADB
forward. Main app data and system power settings were unchanged. Results are
recorded in [summary.json](summary.json).

Next, measure worker queue/native execution separately for ratchet head reads
and commits, and audit the restart persistence of cleanup obligations. Any
reservation fast path must preserve serialization against forget/restore and
concurrent publication; bypassing the existing ratchet gate without proving
those properties is unsafe. The 200 ms trailing-coalescing branch already
returns without waiting for its timer, so shortening that window is not an
explanation or fix for these waits.

Windows reports, partial chunk-ACK receiver-crash recovery, live speech/
headphone volume, long offline, revoke/split-brain and the full multi-device
matrix remain unqualified. Nothing was pushed, released or deployed. Public
evidence contains allowlisted roles, counts and timings. Raw logs, addresses,
identities, message/device IDs and credentials remain private.
