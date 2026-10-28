# Call termination evidence — 2026-10-28

The earlier `dart-final` call ended after a sampled 25.094 seconds. The user
corrected the earlier answer and states that the phone was untouched. Android
emitted its end signal 0.709 seconds before the script's hangup request in the
same device clock. The script requests hangup only after detecting that the
call disappeared. This remains an unexplained termination, not a manual hangup.

This cycle read the retained QA journals on A/B/C. All three contain the old
call, but the journal records `completed` whenever local media started, even
when a later error ended the call. The retained durations were 25 seconds on
A/B and 27 on C. Neither the original reason nor its source can be recovered
from those rows. Changing that established call-history meaning is not needed
for the diagnostic correction below.

## Confirmed diagnostic gaps and corrections

`CallService._set()` records state transitions in the opt-in anonymous journal.
`_end()` emits its terminal snapshot directly and clears the live slot, so the
final reason never passed through that recorder. A new regression failed on
the preceding source: no terminal event remained after hangup.

Every termination now records `callEnded` before clearing the slot, with only
numeric enum codes for the preceding phase, route, direction, reason, source,
and video posture. Every internal end path is tagged. Public hangup/cancel/
reject retain `unspecified` unless their source-owned caller supplies a tag;
the absence of classification must not imply a user gesture. UI, Android
notification, local API and diagnostic API callers provide their own tags.
An entry through the UI is an entry-point observation, not proof of a physical
human action.

| Origin code | Source |
| --- | --- |
| 0 | Unspecified |
| 1 | Flutter call interface |
| 2 | Android notification action channel |
| 3 | Local application API |
| 4 | Diagnostic API |
| 5 | Remote call-control signal |
| 6 | Sibling answer/decline selection |
| 7 | Ring deadline |
| 8 | Liveness deadline |
| 9 | Media start failure |
| 10 | Media repair failure |
| 11 | Negotiated/actual route mismatch |
| 12 | Route handover failure |

Origin values are append-only. No peer, identity, device label, call ID, address,
path, signature, key, payload, wall-clock stamp or arbitrary exception text
enters this event. The ordinary diagnostic ring can be evicted by busy traffic,
so one `last_call_end` snapshot survives until a subsequent termination, clear,
or process exit. Export returns copies, including its values map. An additional
regression failed before that retention correction. Disabled diagnostics retain
neither events nor this snapshot. Existing opt-in/release logging gates remain.
Debug terminal lines use the same source-owned reason/origin/phase/route names;
other raw debug logs remain private and are not the anonymous shared report.

## Verification

With `XVEIL_DIAGNOSTICS=true`, four related files passed 212 tests, including
terminal reason retention, distinct local origins, remote error versus media
start failure, delegation to cancel/reject, eviction, copy isolation and the
actual settings clipboard-report flow. Eight related files passed 234 tests
with the default diagnostic gate disabled. These counts overlap. Static
analysis of ten changed Dart files found no issues.

The existing product-AOT diagnostic fixture was extended and compiled/run with
the real product flag: controller metrics, terminal retention after 400 traffic
events and private-field exclusion passed with debug stand history disabled.
No production-only test seam or temporary timing endpoint was added.

## Physical stress check

A is Android/profile-AOT on Wi-Fi, B its Mac sibling in identity X, and C a
different identity on Mac. Mac Dart builds are debug. Diagnostic flags were
enabled; the source library trees matched the repository. Retained QA profiles
and unchanged production SDK/media/hidden-volume binaries were used. No Rust
build, relay change, main-app replacement, push or release was performed.

Eighteen initial messages were followed by two incoming C-to-X video calls,
answered on A while B remained online. Fifteen seconds into each call, another
eighteen messages were submitted across A/B/C. No physical phone interaction
was requested or performed by the driver during calls.

| Observation | First call | Second call |
| --- | ---: | ---: |
| A first observed ringing, ms | 296 | 392 |
| B first observed ringing, ms | 357 | 397 |
| Active observed after answering, ms | 3,154 | 2,471 |
| Last active sample, seconds | 179.427 | 179.951 |
| Samples | 149 | 157 |
| B stopped ringing after A answered | Yes | Yes |
| Unexpected terminal event on A/C before script hangup | None | None |

Both endpoints remained active through the planned three-minute interval and
all sampled routes were P2P. Audio receive and rendered-video counters advanced
on both sides, with no sampled worker-stall flags. These are packet/frame
observations, not human speech, headphone-volume, per-frame smoothness or
end-to-end speech-delay qualification.

For both calls, the terminal trace identified A as `diagnosticApi`/`hangup`, C
as `remoteSignal`/`hangup`, and B as `siblingSelection`/`answeredElsewhere`.
The comparison uses per-process log sequence windows before/after the explicit
script stop; a later cleanup event is not attributed as an earlier cause.

All 54 new messages appeared exactly once on all roles. Complete stored
histories contained 1,108 rows on each, with equal ID sets and order. The old
25.1-second failure did not recur in these two calls; this does not establish
its cause or prove that it has been fixed. Windows, cellular/relay-only calls,
and the full multi-device failure matrix remain outside this check.

Owned apps were closed. An independent audit checked 65 recorded process groups
with none remaining, no Mac QA executables, no Android QA process or subprocess,
and no owned ADB forward. Raw logs, identifiers and credentials remain in private
QA storage. The public summary contains allowlisted roles, counts, timings and
source-owned enum labels only.
