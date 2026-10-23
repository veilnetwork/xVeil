# Confirmed route recovery and stale cooldown — 23 October 2026

SDK correction: **`e9d3bd3d`**. Diagnostic parent: **`a67a003c`**;
previous functional correction: **`66167052`**.

## Observed failure

The preceding diagnostic cellular phone → Mac run failed both file completion
gates: 32 MiB timed out at 600 seconds, with a final sink sample of
32,768,000 bytes (31.25 MiB); the following 4 MiB timed out at 180 seconds,
with a final sampled sink length of zero. Neither completed, so integrity is
unverified. The original 180-second large-file gate also failed.

Opt-in route diagnostics distinguish worker-admission causes from sampled
selection failures. The phone admitted 20 new Refresh workers because no route
could be selected. Sampled failures reported `route_health`, including pools
with 2/2 and 6/6 receiver-compatible entries but zero usable entries. The
retained samples did not report receiver-binding mismatch or active-limit
exhaustion during this storm. These are sampled observations, not proof those
conditions can never happen. The initial cause label describes worker admission,
not every subsequently joined stronger request.

In the same phone log, 62 confirmed candidate-ready events occurred before the
previously recorded rendezvous cooldown expired (up to 44.461 seconds remained).
This uses one endpoint's timestamps; no cross-device clocks are subtracted.
The checked source had no success path removing that cooldown.

## Confirmed defect and fix

When all advertised rendezvous relays are cooled, ordinary repair deliberately
tries them as a last resort. The new path could confirm and be published while
the old cooldown still excluded every new candidate from selection. That
triggered another Refresh despite successful construction.

Publication now removes the exact cooldown observed before construction only
for a confirmed candidate with a live first-hop session, matching session-close
generation and no active first-hop cooldown. The current rendezvous deadline
must still equal the observed deadline: a more recent failure during setup is
retained. A relay error that first appears after the snapshot is also retained.
First-hop cooldowns are never cleared. Selection still checks current health,
receiver binding and active-stream limits. No relay priority, queue size, wire
field, route lifetime, deadline or mailbox policy changed.

## Regression evidence

A real NodeServices/outbox regression fails on the parent: publication leaves
the confirmed replacement unselectable. The correction covers seven cases:
recovered, newer relay error, newer first-hop error, unconfirmed candidate,
stale session generation, dead first hop, and a failure absent from the opening
snapshot. The positive case selects the new path and admits exactly one DATA
frame; negative cases admit none and preserve the recorded failure. Circuit
confirmation covers registration/probe success; it is not a receipt for file
DATA. The outbox assertion proves local admission, not remote receipt.

All **124 stream tests**, **65 anonymous-stream client tests**, rustfmt and
all-target Clippy with warnings denied pass. The preceding diagnostics are
opt-in and no native media test hook was introduced.

## Scope remaining

This fixes a reproducible exclusion of confirmed recovery paths. It does not
establish that every physical stall is resolved. Repeated no-progress/RTO
remapping, local handoff waits, explicit request-handoff deadline separation,
call/video qualification and the full multi-device matrix remain open.

Raw logs, node/stream identifiers, content identifiers, paths and credentials
remain in the private stand cache; committed evidence is numeric or boolean.

## Physical cellular follow-up

Production macOS and Android SDK builds retain the same **199 C export names**.
Compatible frontends are unchanged. Frozen/source-library hashes, installed APK,
loaded Mac dylib and the owned identities were verified before transfer and
again before shutdown. The phone used cellular data with Wi-Fi disabled;
own-contact P2P was denied, with all observed file opens anonymous. No call or
physical audio device was opened.

| Phone → Mac | Outcome | Original 180-second completion gate |
| --- | --- | --- |
| 32 MiB | Timed out at **600 seconds**, final sink sample **19,922,944 bytes (19 MiB)** | **Failed** |
| 4 MiB afterward | Timed out at **180 seconds**, final sink sample **1,048,576 bytes (1 MiB)** | **Failed** |

Neither file completed: integrity is unverified. Full diagnostic durations
including fixture/offer setup were **615.485 / 181.204 seconds**. The large file
had **13 pull attempts**, including final harness cancellation; retained logs
contain seven manifest-first-byte timeouts, five payload-read idle failures and
one reset including cancellation. Resume offsets reached 4.75, 8, 12.5, 14 and
15.25 MiB. The small file had seven attempts including cancellation, four
connection-setup timeouts and two payload-read idle failures. Endpoint failure
categories can overlap; they are not independent incident totals.

The live progress helper counted native process-log text, which did not include
the full Dart application pull-failure log. Its intermediate zero counter did
**not** mean zero full-pull retries. Final counts above come from the retained
application logs after each phase.

The corrected recovery branch fired **five times on the phone**, zero on the
Mac. No `route_health` or `receiver_binding` selection-failure sample was
recorded. Three sampled phone misses instead reported **active_limit**: one
compatible, healthy route at the unchanged limit of two active streams. These
are sampled/process-wide diagnostics, not a complete census of every selection
or proof the other conditions can never recur. Refresh-admission causes remain
visible in the numeric evidence; no active-limit policy was relaxed.

Maximum sampled local handoff waits were **3060 ms on Mac / 15,700 ms on phone**
across 297 / 546 retained driver samples. Process-wide native counters recorded
**35 / 35** successful pool completions (34 / 33 Refresh, 1 / 2 Warm) and
**0 / 3** failed completions. No `NoRelays` text was observed. Pool churn,
setup/first-byte timeouts and payload stalls remain. This run used uncontrolled
routes/network conditions relative to the preceding run: **no speedup, stability
improvement or complete provider fix is claimed**.

Cleanup restored the exact original phone APK (hash checked), diagnostic
property and contact policies. Owned fixture files and pid-only capture were
removed/stopped. A separate check verified both owned app processes and the
capture absent, original APK hash matching, and Wi-Fi/mobile-data state retained.
The installed Mac application was untouched. No push, release or relay update.
