# Superseded repair cannot terminate its successor — 2026-10-28

Confirmed race: a peer-requested media repair can fail while a relay handover
has already claimed recovery and is queued behind that repair's native teardown.
The old repair callback checked the call ID/peer, but not the route-operation
epoch. It therefore sent `end(error)` before the queued successor could open.
The same call ID is insufficient to prove ownership of the current recovery.

`CallService._repairMediaRoute()` now captures the existing media-operation
epoch before awaiting repair and ignores completion after that epoch changes
or the service is disposed. The successor still decides its own outcome. A
failed current repair without a successor and a failed successor without a
usable route still end the call; admission, privacy posture, watchdogs and
encryption are unchanged.

Two regressions failed before the correction, for successful and unsuccessful
successor handovers. They use the real `CallMediaRouteOperations` queue with a
held teardown and a held successor, rather than assuming simultaneous native
operations. Both now keep the call alive while the successor is pending, then
apply its result. A third check requires an un-superseded failed repair to
terminate, with the correct diagnostic origin. Five related files passed 203
tests with diagnostics enabled; eight files passed 237 with the default gate.
These counts overlap. Static analysis found no issues in the changed Dart files.

## Physical check: answer on B

A is Android/profile-AOT on Wi-Fi; B is its Mac sibling; C is another identity
on Mac. Mac Dart builds are debug. B/C share one physical Mac, so B's camera was
explicitly disabled before accepting; C's camera transmitted to B. This is a
control/routing check with one-way video, not a bidirectional camera or human
speech qualification. All actors use retained QA profiles and unchanged native
SDK/media/hidden-volume libraries. No Rust build or server change was needed.

| C calls X, B answers, A remains online | Before correction | Corrected source |
| --- | ---: | ---: |
| A first observed ringing, ms | 891 | 270 |
| B first observed ringing, ms | 99 | 523 |
| Active observed on B/C after answer, ms | 1,608 | 2,172 |
| Last active sample, seconds | 89.462 | 89.180 |
| Samples | 75 | 75 |
| A stopped ringing and remained idle | Yes | Yes |
| Unexpected call end | None | None |
| New messages converged per role | 36 | 36 |
| Complete equal history rows per role | 1,144 | 1,180 |

The corrected-source call deliberately requested `/media_repair` and
`/call_relay_recovery` on B during the active call. In B's own log clock the
second request started 81.6 ms after the first; their durations were 211.1 and
532.7 ms, so the requests overlapped. Both returned success. B/C transitioned
from P2P to relay and stayed active until the script ended the call. No media
classification or traffic priority was added at relays.

The physical run exercised successful native rebuild/handover overlap. It did
not inject the failed-old-repair result: that exact failure ordering is covered
by the deterministic queue regressions. Timings are successive workload
observations, not a controlled speed comparison. All message ID sets/order
converged without duplicates. This does not establish that the same race caused
the earlier 25.1-second phone termination; that incident remains unexplained.

Owned test apps were stopped. An independent audit checked 69 recorded process
groups: none remained, neither Mac QA executable remained, and the Android QA
process and owned ADB forward were absent. Main apps/profiles were untouched.
Raw logs, credentials and identifiers remain private; only allowlisted roles,
counts, relative timings and source-owned labels are published.
