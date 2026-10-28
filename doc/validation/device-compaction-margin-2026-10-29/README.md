# Device-journal compaction scheduling — 2026-10-29

A deterministic regression reproduced repeated full compaction scans after
every append when required retained state remained above the size trigger.
Distinct settings, tombstones, unresolved branches and separate retention
pools can legitimately leave more than 400 rows. The preceding predicate
treated every subsequent save as a fresh overflow, even after a no-op scan.
In the small regression, three subsequent appends produced four scans instead
of one; eight subsequent appends produced nine instead of two.

After a successful pass, size-triggered scans now require growth above the
retained count: one quarter of the configured trigger, clamped to 1–16 rows.
The initial trigger remains 400. This changes scheduling only. Retention,
signature verification, control admission and durable publication are unchanged.
Hourly/manual sweeps run independently, including expiry without new writes.
Failed passes do not install a watermark. Changing the configured budget or
shrinking below the recorded survivor count invalidates it. The RAM-only
scheduling map is capped at 64 groups and resets on restart.

Seven focused regressions cover no-op passes, renewed growth, shrinking
passes, failed attempts, changed budgets, near-threshold survivors and the
independent periodic sweep. The complete GroupService file passed 347 tests
with three existing skips. Static analysis of the changed source/test files
reported no issues.

## Limits of the performance result

This is a confirmed redundant-work fix, not a demonstrated solution to the
long delivery delay. On the same retained Android QA profile, three sequential
local journal posts took 972/2,397/3,716 ms before and 893/2,357/3,832 ms after.
These noisy observations show no meaningful improvement. Warm journal loads
still took hundreds of milliseconds; the journal held about 400 rows. Repeated
reading, validation and competing background work need further investigation.

Measurements use the existing QA API, one inert unregistered setting key and
production persistence. No temporary instrumentation was added to production
code. Raw logs, identifiers, node addresses and generated payloads remain in
private local evidence; public results contain only fixed roles and counters.

Physical convergence and cleanup results are recorded in `summary.json`.
The native SDK is unchanged. No push, release or server update is included.

## Physical convergence

A is Android on Wi-Fi, B its Mac sibling, C another identity on Mac. Retained
profiles use the exact final application inventory for this compaction change,
production native libraries, Android AOT/profile and Mac debug Dart. Anonymous
routing is disabled and cross-identity P2P denied for this delivery test; both
original policies are restored afterwards. This is not a controlled speed
comparison with an earlier run.

All 18 posts, including generated 12,300-character bodies from A and C, were
present once in the same order on every role at the 57.9-second sample. Group
chunk queues were empty at 108.0 seconds; other control queues still contained
work. The large A post's edit converged in 18.1 seconds and its deletion in
13.7 seconds. Every unrelated ID remained. After cold reopening, full history
was identical at 1,524 rows each, including all 17 surviving fixture posts.
Outgoing fixture statuses were delivered: eleven on A, eleven on B, six on C.

Apps were closed after each run. Independent cleanup checked 134 recorded
owned process groups and found zero owned Mac processes, Android package or
named subprocesses, and zero owned ADB forwards. Main profiles and system
power settings were unchanged.
