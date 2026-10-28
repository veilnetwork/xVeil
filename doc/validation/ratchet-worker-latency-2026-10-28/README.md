# Ratchet worker latency and export growth — 2026-10-28

This cycle separated local storage RPC waits from synchronous backend work,
removed redundant reads of confirmed ratchet run lengths, and corrected two
durability/export failure cases. It also reopened the earlier unexpected call
termination after the user corrected the manual-hangup answer.

## Measured local wait

Private QA copies timestamped request dispatch, worker operation start/end,
and receipt of the reply. The production source has no such timers or endpoint.
The baseline Android/profile-AOT workload sent twelve A-to-C and six C-to-X
messages with B, A's Mac sibling, online. Mac Dart builds were debug; all roles
used retained profiles and the same production native/HV libraries.

| Android baseline RPC | Samples | Dispatch wait, mean ms | Backend operation, mean ms | Reply wait, mean ms | Total, mean ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ratchet KV chunk read | 84 | 20.24 | 0.45 | 52.97 | 73.66 |
| Ratchet state commit | 76 | 6.31 | 37.67 | 54.92 | 98.90 |
| Settings read | 5,267 | 12.61 | 0.31 | 59.78 | 72.71 |

Dispatch includes isolate delivery/copying and worker queueing. Reply wait
includes delivery and scheduling on the app isolate. Backend time includes the
synchronous adapter/native operation, not an isolated disk/fsync measurement.
These are local measurements, not relay traversal or network RTT. Timestamps
used each process's wall clock over the short measurement window; no negative
stage intervals were observed. Request/frame times overlap and must not be
summed into an end-to-end latency budget.

The private label `ratchet.head` actually matched every 66-byte ratchet KV
chunk key, including whole-state reads for send reservations. It does not
isolate save-head reads. In the cache candidate, these reads changed from
146 to 14 on B, 49 to zero on C, and 84 to 151 on A. A still needs fresh
reservation snapshots, and the background workload changed. The physical
counts therefore do not prove a specific number of avoided save-head RPCs.
Deterministic unit/native checks below establish that optimization directly.

## Corrections

The sole ratchet-writing Storage view now remembers up to 128 confirmed
committed run lengths. Repeated saves use those lengths when pruning replaced
tails; session blobs are not retained in this cache. Pending versions of the
same conversation in a batch use the preceding pending run length. Entries are
admitted only after commit succeeds. Forgetting, space erasure, close and any
uncertain outcome invalidate the relevant entries. No send-window reservation,
dirty-generation check, state write or vacuum is skipped.

An injected lost reply after a successful state commit exposed a separate
failure: the RAM cleanup count could overwrite the newer durable count on
retry. Any ratchet operation failure now also invalidates that RAM count, so
retry first recovers the actual encrypted marker and performs cleanup if due.

The cache-candidate phone log additionally recorded a real degraded flush:
`veil_ratchet_export grew between two sizing passes`. Native receive processing
can grow a skipped-key snapshot between exports; export is non-consuming, but
its returned size is not frozen. The FFI host now grows the buffer geometrically
up to the existing 1 MiB ABI ceiling. Continuous growth reaches that ceiling
within nine calls; impossible or non-growing short-buffer sizes fail closed.
Small snapshots retain their one-call path. Native dirty marks are still
acknowledged only after the exported state is durably saved.

The same FFI fixture exposed an invalid-size cleanup overrun in the old source:
it assigned the reported size to `cap` before validating it, then the `finally`
wipe used that larger size on the original allocation. A too-large reply
crashed the old test process. Validation now precedes the capacity change, so
rejection wipes only the actual allocation. This is host-side handling of an
out-of-contract native response, not evidence of a remote exploit.

## Verification and limits

The final 44-file suite passed 595 tests, including real-library ABI checks.
Static analysis of changed Dart files found no issues. Seven new cache/count
regressions cover repeated saves, uncertain commits, cleanup-count recovery,
successive versions in one batch, identity handoff, forget/recreate and bounded
eviction. Two cache regressions and the uncertain-count regression failed before
their corrections.

Seven additional FFI regressions compile a temporary C fixture and exercise the
actual Dart FFI export method: growth, maximum/small snapshots, invalid sizes,
non-growing short-buffer answers, disappearance and continuous growth. The
growing-state regression failed on the old two-pass source; the invalid-size
case crashed that test process. These tests add no production test hook.

Seven production hidden-volume checks passed. The extended native fold test
requires one head read across 128 consecutive saves and actual vacuum, then
grows/shrinks the state and verifies that no live tail records remain. The
other six checks retain partial budgets and unfinished cleanup across real
file close/reopen via password, space keys and async views. No Rust/native
rebuild, relay update, push or release was performed.

The baseline observed all 18 new IDs on three roles after 54.9 seconds; the
cache-only candidate took 49.1 seconds. Their submission times were 24.3 and
18.4 seconds. These are successive workload observations with different
histories/background work, not a controlled overall speedup claim. The export
growth correction was added after that candidate measurement.

The `/messages` hook caps its returned tail at 1,000 even when asked for 2,000.
Baseline comparisons cover that recent window. The candidate and final normal
checks additionally use `/conv_messages` to compare complete stored ID/order
lists. The cache candidate had 1,036 equal rows on every role. Final normal
results and independent app-cleanup verification are in `summary.json`.

Long delivery/receipt queues, the thousands of settings reads, and app-isolate
reply delays remain open. Call termination is also unresolved: the earlier
25.1-second call emitted an end signal on Android 0.709 seconds before the
test script's hangup command in that same device clock. The user states the
phone was untouched. No ring/liveness timeout was logged, and that log lacks
the terminal reason/origin needed to distinguish internal error paths from
notification/UI actions. The earlier manual classification has been corrected
in the video-startup report; a subsequent 90-second pass does not explain it.

Raw records, device IDs, keys and message contents remain in private QA
storage. Public results contain allowlisted roles, counts, timings and booleans.
