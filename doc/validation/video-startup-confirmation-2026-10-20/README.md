# Healthy video startup confirmation — 2026-10-20

## Cause and change

The fast startup path counted three distinct peer audio reports at each rung.
In the physical stand those reports arrive roughly every five seconds, while
local video progress/audio health is measured every second. The check added
several reporting periods to each startup rung, besides the bounded native
bitrate/FPS ramp. The previous physical run left the one-FPS floor after about
19–24 s, and reached nominal level 0 after about 107–111 s of camera activity.

Fast startup now requires three healthy **local** observations plus a distinct
current peer report confirming that measured period. It uses the existing
per-rung confirmation baseline: the same report cannot confirm a second rung,
and an unapplied native target resets the observation streaks. A report that
arrives during the measured period need not coincide with the promotion poll.

The low-latency/audio-health gates, cold one-FPS floor, source-budget hold,
maximum growth of +1 FPS / +10% bitrate per admitted second, native ACK gate,
slow recovery after real failures and video reductions remain unchanged.
Local-only diagnostics now expose startup eligibility/streak; no network
feedback or relay behavior changed.

## Code verification

The new five-second-report regression fails against the original adapter:
expected rung 3, got 4 when one new report confirms five measured healthy polls.
It passes with the change and also verifies that holding that same report for
45 more polls cannot fund another rung. A second test proves that a new report
cannot skip the three-observation startup period.

All **415** selected Flutter tests passed: bitrate adapter, call service, direct
source budget/recovery/pressure and group source/media controllers. Targeted
analysis found no issues; diff checks and both profile builds passed. Existing
regressions cover unknown or stale audio, stalled video/workers, failed native
application, packet loss, replacement engine state and bounded growth.
One initial test command included a nonexistent test path and failed loading;
it was corrected before the successful complete selected suite.

## Physical check

Disposable QA 12627 differs from 12626 only in the adapter; SDK remains
`70a99c1f`. Native SDK/media/storage/PCM-driver inputs and Android signer are
pinned to the same preceding fixture. No relay updates or priorities.

The same real Mac ↔ Blackview synthetic-ADM call ran 150 s: cameras at 30 s,
two 32 MiB file requests at 45 s, cancellation at 90 s. Both sampled routes
remained P2P. No physical microphone/speaker or subjective listening was used.

Both endpoints left the lowest nominal rung by the sample at 38.9 s, about
**9 s after camera enable** (previous samples: 49.5 s phone, 53.6 s Mac).
Nominal level 0 appeared at 112.6 s phone / 129.4 s Mac, about 83/99 s after
enable. These are sampled transitions and not proof that the final native
bitrate/FPS target has fully applied: the ramp continues independently.

Actual outgoing frame rates from interval counter differences:

| Approximate interval (s) | Previous Mac / phone FPS | Current Mac / phone FPS |
|---|---:|---:|
| 31–45 | 0.69 / 0.90 | 1.85 / 2.99 |
| 45–75 | 3.80 / 4.97 | 5.87 / 7.13 |
| 75–90 | 5.92 / 6.88 | 6.13 / 15.28 |
| 90–120 | 14.71 / 16.71 | 16.14 / 25.32 |
| 120–149 | 28.52 / 29.00 | 29.02 / 29.39 |

The deterministic regression isolates the logic change. Physical differences
also include variable network/capture timing, so the entire observed speedup
is not assigned solely to this patch. FPS counters do not prove scene quality,
physical presentation or a sustained high-resolution video verdict.

All **290** expected tone transitions in seconds 5–150 matched, with complete
capture/observation rows and no driver errors. Video/file-phase point p95/max:
**121/131 ms** Mac → phone and **131/141 ms** phone → Mac. The largest reverse
phase delay's observed clock envelope is **134–164 ms**. PCM blocks are 10 ms;
unsampled clock drift is not proven bounded. These are synthetic decoded PCM
measurements, not an acoustic latency/loudness or speech-quality qualification.
There were zero native session violations/peer bans and two expected closed
stream messages on the phone. The file requests were canceled before completion;
this is not a completed file-throughput check. HTTP download waiters still end
with RemoteDisconnected when apps exit; that behavior remains open.

## Remaining measured hold

Startup is still slow after the first improvement. On Mac policy observation 15,
RTT was 156 ms against a 13 ms baseline. Actual receiver/peer buffers were only
33/42 ms, receive age 15 ms, with no recorded audio/video loss, pressure, or
interruption. This RTT exceeded the existing recovery rail (baseline +120 ms)
and latched `ramp_recovery_needed`. Observations 15–19 were withheld; observation
20 began accumulating the additional twelve healthy ramp-recovery samples.
This explains another startup wait without establishing audible degradation.
Selected exact observations are retained in `physical-summary.json`. A future
change needs to distinguish a bounded RTT hold from confirmed audio failure,
while retaining source admission and actual audio pressure/loss protection.
This patch does not claim to solve that separate behavior.

## Cleanup

Activity assertions/Android Wi-Fi locks were absent before and after the call
and present during it. Independent checks found all owned app/helper processes
and ADB forward absent; ordinary phone APK 12622 was restored and its installed
hash matched. Mac required SIGKILL after its grace period (exit -9); call
activity had already been released before termination. Foreign work was left
unchanged. No push/release. The full audio/video/screen/data-isolation goal
remains active.
