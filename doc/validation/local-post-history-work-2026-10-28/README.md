# Repeated local-post validation — 2026-10-28

A new post verified each retained own message four times: once while retaining
valid rows, again for fork detection, again for canonicalization, and again
when selecting the accepted predecessor chain. The same operation verified a
peer's retained row once. This work grows with the local device journal, even
when writing a short text.

The post now shares one verified synchronous view between fork detection,
canonical history and predecessor selection. Raw-input callers still enter
through validation. A later operation builds a new view, including current
identity-document checks. No verification result is retained across reads,
awaits or identity changes. Earliest-fork quarantine, distinct fork hashes,
writer/channel scopes, strict predecessor links and retention cuts retain the
existing rules.

The regression uses three own and three peer rows. Before the change, posting
performed four checks per old own row versus one per peer row; afterward both
are checked once. It also checks the authored sequence/predecessor, then makes
an old predecessor fail verification and requires the next post to be refused.
These fake-signature tests prove application rules and work counts, not native
cryptographic strength. The related nine-file suite passed 458 tests with
three existing skips. Static analysis found no issues. Focused final fork,
predecessor and writer tests also passed; counts are in [summary.json](summary.json).

## Physical stand

A is Android on Wi-Fi using a profile/AOT QA build; B is its macOS sibling;
C is another identity on macOS. Mac builds use debug Dart. Both timed phases
reuse retained profiles and exactly the same production native libraries,
without native test hooks or reduced identity difficulty. Private copies add
aggregate memory-only timers in four files; repository production code has no
timing overlay. Each phase sends 12 A-to-C and six C-to-X messages with six
concurrent submitters, then waits for all three projections.

| Observation | Before | After |
| --- | ---: | ---: |
| Submit all 18 messages, seconds | 28.2 | 20.8 |
| Observe all messages on all roles, seconds from burst start | 80.3 | 92.6 |
| Android post method, 30 calls, mean elapsed ms | 649.5 | 261.6 |
| Android device batch, 14 calls, mean elapsed ms | 4,006.0 | 3,059.0 |
| Android store, 18 calls, mean elapsed ms | 10,332.0 | 7,399.0 |

All 18 logical messages converged without duplicates in each timed phase.
All visible IDs and their order matched: 658 before, 676 after. Profiles
advanced between phases. Async stage timers include nested work and waiting;
totals overlap and must not be added. The unified canonical-view timer also
covers different entry points after the refactor, so its averages are not an
isolated before/after comparison. Background work varied: Android merge calls
were one before and eleven after. These are observed workload timings, not a
controlled network benchmark or proof that all delivery latency improved.

The repeated signature work is removed and measured posting cost falls, but
the late incoming-message tail remains: total convergence was slower in the
candidate despite faster submission. This defect is not declared fixed.

## Uninstrumented final check and cleanup

Both private source copies were restored to the repository sources and rebuilt.
The Android APK is profile/AOT, lacks private timer strings, and the timing
endpoint returned 404 on all three roles. Native libraries still match the
baseline. A fresh 18-message burst submitted in 14.2 seconds and converged with
no duplicates. All 694 visible IDs and their order matched on A/B/C. This phase
did not record a precise all-roles convergence duration and does not close the
late-delivery finding.

Every phase closed its owned apps. The independent final audit checked 21
recorded process groups and both owned Mac executable paths, found no remaining
app processes, and confirmed Android QA termination and removal of the owned
ADB forward. Main app data and system power settings were unchanged. Raw logs,
addresses, identity/device IDs and credentials remain private; the published
summary contains allowlisted roles, counters and timings only.

The late incoming-message tail is the next focus. The current global inbound
queue also protects consent caps and deduplication; merely allowing handlers to
run concurrently would bypass existing safety assumptions and is not a fix.
Windows reports, partial chunk-ACK receiver-crash recovery, long offline,
revoke/split-brain, live speech/headphone volume and the full multi-device
matrix remain unqualified. Nothing was pushed, released or deployed.
