# Late refusal after a sibling answers — 2026-10-28

Confirmed state-machine defect: C calls identity X (devices A/B), B answers,
and a refusal produced before endpoint selection reaches C afterward. An
authenticated identity-addressed refusal can alias the selected endpoint's
dialog. `CallService._onRemoteEnd()` ignored late `busy`, but accepted late
`reject` and ended the connecting/active call with `declined`.

Reject and busy responses now apply only to an outgoing call still dialing.
After an answer, these pre-answer responses cannot terminate the selected
dialog. The ordinary authenticated `end` and `cancel` paths, caller endpoint
election, sibling hush, encryption and route negotiation remain intact. A
refusal that wins the race before any answer still ends the outgoing call;
the later answer cannot revive it.

## Regression evidence

Four regressions failed before the correction: connecting/active call crossed
with an answer sent from the device address or from the identity address naming
the physical answering device. Each delivers the late refusal through the real
call-service signal handler and requires the current call and event stream to
remain unchanged. Each then sends an actual `end` from the selected device and
requires termination with `hangup`.

Two additional controls require reject/busy to terminate an unanswered offer,
record the correct reason, and ignore a later answer. Six related files passed
263 tests with the default diagnostic gate. Two files passed 198 tests with
diagnostics enabled; these counts overlap. Static analysis found no issues in
the changed Dart files.

## Physical check and limits

The exact reordered refusal is reproduced deterministically in the regression
tests, not injected through a production diagnostic endpoint. The physical
regression uses retained QA profiles: A is Android on Wi-Fi, B its Mac sibling,
C a different identity on Mac. C calls X and B answers while A remains online.
B and C share one physical Mac, so B's camera is disabled and C sends video to
B. Android uses profile/AOT and the Mac Dart bundles use debug mode; native SDK,
media and hidden-volume libraries are unchanged. No Rust build or relay change
is required.

| C calls X; B answers | Observation |
| --- | ---: |
| A / B first observed ringing, ms | 608 / 665 |
| Active on B/C after answer, ms | 1,591 |
| Last active sample, seconds | 179.094 |
| A remained idle after sibling selection | Yes |
| Unexpected termination on B/C | None |
| Engine epochs on B / C | 1 / 1 |
| Video frames rendered on B | 4,356 |
| New messages converged per role | 36 |
| Complete equal history rows per role | 1,288 |
| Duplicate message IDs | 0 |

During the call, an explicit relay recovery was requested on C using the
existing guarded diagnostic API. Both B/C transitioned P2P → relay → P2P,
returning automatically after fresh qualification, with two handovers per
endpoint and monotonic audio/video counters. The zero B-video-send/C-video-
receive counters reflect the deliberately disabled B camera.

The pre-stop terminal traces contain no end on B/C. After the planned script
hangup, B records `diagnosticApi`/`hangup`, C `remoteSignal`/`hangup`; A records
only `siblingSelection`/`answeredElsewhere`. These are source-owned entry-point
observations, not inferences about a physical user gesture.

All apps started for the stand were stopped. An independent audit checked 75
recorded process groups, both Mac QA executables, Android package/subprocess
names and the owned ADB forward; none remained. Main apps/profiles were untouched.

Allowlisted runtime observations and the independent cleanup audit are in
`summary.json`. Raw logs, message IDs, addresses and credentials remain private.
This check does not qualify Windows, cellular calls, human speech or all
multi-device failure scenarios.

The earlier unexplained 25.094-second phone termination remains open. Its
retained logs do not show a reject marker, and this newly reproduced race is
not established as its cause. An entry-point tag alone must not be treated as
proof of a physical user action.
