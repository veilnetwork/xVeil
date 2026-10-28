# Inbound history waiting and routing races — 2026-10-28

The long delivery tail is local queue waiting, not merely network latency.
In the baseline, six C-origin message frames queued after the window began
waited a mean 58.2 seconds (peak 65.0)
between their Dart inbound callback and handler start. Their handlers then
took a mean 2.8 seconds. This does not measure earlier native/network waits.

## Changes

Concurrent own-device routing queries previously loaded and verified the same
journal independently. They now share only an unfinished lookup for the same
group, physical-device context and routing epoch. Completion clears the lookup;
a later call still reads and verifies a fresh journal. Returned lists are
independent. Read failures remain visible rather than being masked by a cached
success. Local data-only appends retain the existing admission-neutral rules;
routing/control changes invalidate unfinished views.

This also exposed application races. A lookup begun before revoke could return
the revoked target after the revoke committed. A linked-owner query discarded
its stale result for caching but still returned it to its caller. A master
query could republish an obsolete announcement after a newer one committed.
Those successful stale reads now retry against the new state. A closed identity
session returns no routing targets. Regressions failed before the respective
changes and pass afterward. The existing fresh sequential-read, read-failure,
clock-filtered master replacement and revoke tests still pass. Fake-signature
fixtures establish application behavior, not native key-revocation strength.

The live sibling-history protocol now has a separate serialized, owned queue
behind the existing common inbound/provenance/contact/ratchet handling. It has
1 MiB total, 512-frame and 256 KiB per-authenticated-source admission budgets.
It still checks current sibling membership and binding before history effects.
It sends no ACK or mailbox copy. Overflow is retryable by the existing protocol.
Identical pending frames share one reservation without adding another owned
task per replay. Stale or already-retained response slices are discarded before
expensive authorization reads; missing tails remain recoverable.

History is serialized within its own queue. Ordinary message consent caps,
deduplication, group commits and durable ACK rules retain their original lane.
The regression holds a history authorization read indefinitely and requires an
ordinary accepted message to complete before release. It timed out before the
change and passes afterward. Additional tests cover frame/byte limits,
coalescing, queue drain during close, revoke while queued, failed-handler
recovery, large reversed pages and retry of a partially retained page.

A history task error could also abort messaging shutdown: its external error
handler reported the failure, while the owner still joined the rejected future.
Reporting now runs inside the owned future so shutdown can finish. The new
failure-during-close regression failed before this correction and passes after.

## Checks and physical stand

The expanded 18-file suite passed 639 tests with three existing skips. After
the final shutdown correction, the affected history, binding, backpressure and
ratchet subset passed 84 tests, including the added failure-during-close case.
Those counts overlap. Final static analysis found no issues.

A is Android/profile-AOT on Wi-Fi; B is its macOS sibling; C is a separate
identity on macOS. Mac builds use debug Dart. Retained profiles advanced across
phases. Each phase sent 12 A-to-C and six C-to-X messages with six submitters.
The same production native libraries and HV binary were reused throughout;
there were no native test hooks or reduced identity difficulty.

| Timed observation | Baseline | Routing reads shared | Dedicated history queue |
| --- | ---: | ---: | ---: |
| Submit all 18 messages, seconds | 21.5 | 18.9 | 24.7 |
| Observe all three projections, seconds | 83.2 | 91.4 | 87.0 |
| C message queue wait on A, mean seconds | 58.2 | 57.8 | 56.3 |
| C message queue wait on A, peak seconds | 65.0 | 66.2 | 65.1 |
| Global history-frame handler, mean ms | 1,180 | 895 | 53 |
| Global history-frame samples | 16 | 6 | 5 |

Six C-origin message-frame handlers were observed in each timed window. Queue
records have source/kind and times, not logical message IDs; per-ID latency is
not claimed. Logical message IDs were checked separately. All new IDs converged
without duplicates, and complete visible IDs/order matched on A/B/C:
712, 730 and 748 respectively. The history queue removes one cross-protocol
hold, but the overall message-wait improvement is small. Long delivery latency
is still open, not declared fixed.

Timers are private overlays and aggregate memory-only results. Async stage
windows include nested/overlapping waits and must not be added. Histories,
background traffic and frame mixes differed; these are workload observations,
not an isolated or universal speedup benchmark. The timed history-queue phase
precedes the final move of error reporting inside the owned future; final tests
and the ordinary build include that shutdown correction. Exact source patch
fingerprints and phase counters are in [summary.json](summary.json).

Both copies were restored to the repository sources and rebuilt. The final
Android APK is profile/AOT and lacks private timer strings; the timing endpoint
returned 404 on all three roles. The final ordinary build submitted its burst
in 24.3 seconds. All 18 messages and delivery marks converged by the 55.7-second
observation, with no duplicates. All 766 visible IDs and their order matched.
There are no per-frame queue timings in this uninstrumented phase.

## Cleanup and remaining work

All owned apps were closed after each phase. An independent audit checked 29
recorded process groups and both owned Mac executable paths, found none left,
and confirmed Android QA termination plus removal of the owned ADB forward.
Main app data and system power settings were unchanged. Public evidence contains
only allowlisted roles, counters and timings. Raw logs, addresses, identities,
device/message IDs and credentials remain private.

The next measurement must split group apply into sync-request serving and state
ingest, including their queue/storage waits. Eight group applies took a total
36.0 seconds in the timed history-queue window; that aggregate is a lead, not
a diagnosis of each frame. Do not parallelize permission/state mutations to
hide this wait. Windows reports, partial chunk-ACK receiver-crash recovery,
live speech/headphone volume, long offline, revoke/split-brain and the full
multi-device matrix remain unqualified. Nothing was pushed, released or deployed.
