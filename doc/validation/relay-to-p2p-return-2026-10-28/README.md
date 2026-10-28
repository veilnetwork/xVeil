# Return from relay to P2P during a call — 2026-10-28

Previously, a mid-call direct-to-relay fallback permanently cleared the original
mutual P2P consent. The existing engine-preserving direct candidate mechanism
could recover an initial relay fallback, but could not return after a later
outage in the same call.

Temporary fallback now retains the consent negotiated in the original offer and
answer. After a ten-second cooldown, the endpoints rediscover/check admission
for the selected device and exchange readiness again. Previous readiness is
cleared on fallback; subsequent readiness must be dated and cannot precede the
latest authenticated route health. Readiness is repeated until the peer reports
its active direct route. A failed candidate leaves the live relay running and
can be retried after the cooldown.

The media controller opens and qualifies a sealed direct candidate in both
directions while the existing engine continues on relay. It checks current
local policy inside the route-operation queue and again after qualification,
immediately before rebinding the engine. A retired call, superseding route
operation or withdrawn permission prevents that commit. The old receiver is
retired only after a successful rebind using the existing receive overlap.
Audio/video capture, codecs and cumulative engine counters remain in place.

Explicit peer withdrawal still prohibits further P2P attempts in that call.
Anonymous posture, local policy, original mutual consent, selected-device
admission and protocol compatibility remain mandatory. A direct posture alone
does not authorize P2P. Older peers that withdraw permission on relay keep the
previous conservative behavior. No mailbox carrier, relay media classification
or relay priority was introduced. No native library or server change is needed.

Authenticated relay health also recovers a lost fallback announcement, after a
ten-second grace for the peer's in-flight direct qualification. A failed relay
candidate that retains a working direct route preserves that grace clock, so
subsequent health can request fallback again. Such a failed candidate must not
terminate the call or change its displayed route.

## Deterministic checks

Eight related files passed 277 tests with the default diagnostics gate. Three
files passed 196 tests with diagnostics enabled; counts overlap. Static analysis
found no issues in the changed Dart files.

Regressions exercise two return cycles after both native repair and explicit
relay handover, an unconfirmed direct candidate followed by successful retry,
policy withdrawal while qualification is held, explicit peer withdrawal,
asymmetric candidate success followed by relay convergence and later recovery,
stale readiness, lost fallback announcements, and retry after an unproven relay
candidate. Five distinct regressions were observed failing before their
corrections. Existing anonymous, older-peer, identity/device and repair-epoch
checks remain green.

## Physical checks

A is an Android/profile-AOT device on Wi-Fi. B is its Mac sibling and C is a
different identity on Mac; Mac Dart builds are debug. C calls the shared A/B
identity, both devices ring and A answers. Video is enabled on both endpoints;
B remains online and idle. Retained QA profiles and frozen production native
SDK, media and hidden-volume libraries are used. No human speech qualification
is claimed.

An initial 180-second candidate run observed a complete P2P → relay → P2P cycle
on both endpoints. Phone return was observed 21.0 seconds after the fallback
request; Mac return took 17.1 seconds. A second relay candidate failed delivery
qualification, so the working P2P route was retained. The call stayed active
until the script's planned hangup. Engine epoch stayed unchanged and receive
counters continued. All 36 new messages converged on A/B/C; complete histories
contained the same 1,216 message IDs in the same order, without duplicates.

The final-source run completed two full P2P → relay → P2P cycles in one
180-second call, with four engine-preserving handovers on each endpoint and
unchanged engine epoch. All audio/video receive/send counters were monotonic.

| Final source, C calls A/B and A answers | Result |
| --- | ---: |
| A / B first observed ringing, ms | 300 / 404 |
| Active on A/C after answer, ms | 4,287 |
| Last active sample, seconds | 179.246 |
| Unexpected call end | None |
| A / C return after first fallback request, seconds | 16.6 / 14.3 |
| A / C return after second fallback request, seconds | 27.2 / 20.4 |
| New messages converged per role | 36 |
| Complete equal history rows per role | 1,252 |
| Duplicate message IDs | 0 |
| A / C maximum sampled audio jitter buffer, ms | 177 / 186 |

Return timings include cooldown, endpoint discovery, readiness and qualification;
they are observations, not a latency bound. Jitter-buffer occupancy is distinct
from packet receive age and end-to-end audio latency. Automatic traffic counters
do not establish human speech quality or performance over mobile data.

After both runs the owned apps were stopped. The final independent audit found
no processes in 73 recorded process groups, no Mac QA executable, no Android QA
package process (including named subprocesses), and no owned ADB forward.

The detailed allowlisted results and cleanup audit are recorded in
`summary.json`. Raw logs, credentials, addresses and message IDs remain private;
only allowlisted roles, counters, timings and source-owned labels are published.

This route feature does not establish the cause of the earlier unexplained
25.1-second phone termination. That incident must not be classified as a user
hangup.
