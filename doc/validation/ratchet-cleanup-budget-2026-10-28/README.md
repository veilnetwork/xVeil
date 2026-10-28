# Durable ratchet cleanup — 2026-10-28

The preceding cleanup correction retained the warm message fold and retried a
failed vacuum within one session. Its cleanup count still lived only in RAM.
This cycle confirmed five failures with new regressions against that source:

| Scenario | Before | Corrected behavior |
| --- | --- | --- |
| Save 64 states, reopen, save another 64 | No vacuum | One vacuum at the cumulative 128 saves |
| Same Storage opens identity A then B | A's count can trigger cleanup in B | Each encrypted space retains its own count |
| Threshold vacuum fails, then reopen | Failure is forgotten; open succeeds without retry | Recovery must succeed before exposing the opened space |
| Already-open multi-space view restores states | No cleanup recovery | State enumeration/reads recover first |
| Close during an accepted state commit | Native handle closes before the write finishes | Close drains accepted ratchet operations and rejects new ones |

One encrypted byte in the protected ratchet namespace now stores the count,
in the same transaction as each batch of replacement states. No additional
commit is required for an ordinary save. The count is cleared only after
vacuum and a completion commit both succeed. A failed completion can cause
one extra safe vacuum after restart. Forgetting sessions commits an immediate
cleanup obligation even when it removes the last live head. File/cache purges
do not remove this protected metadata.

Ratchet reads/writes and cleanup are serialized per Storage view. Close and
space erasure fence new ratchet operations and drain accepted work before
closing or deleting the space. Existing whole-conversation commit boundaries,
native dirty-generation handling, send reservations, and warm message-fold
retention remain intact. The production all-online path reuses one Storage
view per encrypted space.

For legacy stores with live ratchet records but no count, the first recovery
performs a conservative vacuum and establishes the new marker. Invalid marker
lengths or out-of-range counts also require cleanup. Opening recovery preserves
the pre-maintenance commit anchor for the existing rollback audit. A legacy
store with no remaining ratchet records and no marker cannot reveal whether an
older build previously left orphaned key material; this migration does not
claim to detect that historical case.

## Verification

The five initial regressions failed against the previous source. Twelve new
unit regressions now pass, including commit failure, completion failure,
concurrent writers, failed deletion of the final session, conservative legacy
migration, damaged metadata, and erasure concurrent with an accepted write.
The expanded 41-file suite passed 577 tests. Static analysis of changed Dart
files found no issues.

Six new tests used the production Mac hidden-volume library with real file
close/reopen: partial counts and unfinished cleanup, each through password,
space-key, and already-open async-view access. All passed. The existing native
warm-fold/vacuum test also passed, for seven native checks total. These test
durable state after an injected vacuum refusal; they are not power-loss tests
at every native transaction stage. No Rust build or native library update was
needed.

## Physical smoke test

A was Android/profile-AOT on Wi-Fi, B its Mac sibling, and C another identity
on Mac. Mac Dart builds were debug. Retained QA profiles and unchanged
production native/HV libraries were used. All three source trees matched the
repository library sources; the private timing overlay was absent and its
endpoint returned 404 on every role.

Twelve A-to-C and six C-to-X messages were sent using six submitters after a
30-second warm-up. Submission finished in 20.6 seconds; all roles exposed all
18 messages after 66.3 seconds. All 18 delivery marks converged by the final
observation at 76.7 seconds. Complete histories contained 1,000 logical rows
on each role, with equal IDs/order, unique local sequences and no duplicates.
These observations confirm the smoke scenario, not an overall latency win.
Long delivery/receipt latency remains open.

Owned test apps were stopped. An independent process audit checked 55 recorded
process groups: none remained, neither Mac QA executable remained, the Android
QA process was absent and the owned ADB forward had been removed. Main apps and
their profiles were not changed. Raw logs, device IDs, credentials and message
contents remain outside the repository; the public summary contains only
allowlisted roles, counts, timings and boolean results.
