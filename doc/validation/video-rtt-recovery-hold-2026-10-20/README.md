# Preserve the measured ramp during marginal RTT — 2026-10-20

## Confirmed issue and change

The preceding physical trace contains five marginal-RTT observations: 156 ms
against a 13 ms baseline, with small stable audio buffers, fresh receive activity
and no recorded audio/video loss. That RTT was between the recovery and
reduction rails. It correctly withheld video growth, but also latched a further
12-observation ramp-recovery wait after the RTT returned to normal.

A marginal RTT can now hold the current native budget without erasing the
measured ramp. It must remain below the existing RTT degradation rails, and
every expected audio direction must have measured, healthy playout. Buffer
growth, missing feedback/receive activity, real media loss, source pressure or
an idle/stalled producer cannot use this exception. Both bitrate and FPS remain
unchanged throughout the RTT hold. Once all ordinary healthy-growth checks pass
again, the existing +1 FPS / up-to-10% bitrate-per-admitted-second ramp resumes.

Existing recovery debt caused by a prior real failure is retained. No new RTT,
audio-buffer or loss thresholds, transport/wire fields, relay rules or acoustic
latency targets were introduced. `rtt_growth_hold` is local-only diagnostics.

## Tests

A new regression reproduces the observed five-sample 156/13 ms case while a
native video budget is still ramping and both audio buffers stay at 60 ms. It
fails against the previous source: after RTT recovery bitrate stays 99 kbit/s
instead of taking the next bounded step. It passes with this change and checks
that none of the five marginal samples grows bitrate or nominal rung.

Six negative checks cover congested RTT, missing peer measurement, a full audio
buffer, source pressure, a stalled worker and an audio packet drop. Each then
inserts otherwise healthy playout during a marginal RTT hold and verifies it
cannot wash away the recovery debt from that earlier failure.

The selected **422-test Flutter suite passed** (adapter, call service, direct
source budget/recovery/pressure and group source/media). After strengthening the
six negative checks with that intervening hold, all six passed again. Final
targeted analysis found no issues; diff checks and both profile builds passed.

## Physical result and evidence limit

QA 12628 uses the changed adapter and the same pinned SDK/media/storage/driver
native inputs and Android signer. SDK is `70a99c1f`. The export's adapter bytes
match the worktree source; its SHA-256 is retained in `physical-summary.json`.

The same real Mac ↔ Blackview synthetic-ADM call ran 150 s: camera enable at 30 s,
two 32 MiB file requests at 45 s and cancellation at 90 s. All samples remained
P2P. Physical microphones and speakers were not used for the measurement.

**The qualifying RTT-hold branch was not exercised in this physical run** (zero
true observations on both endpoints). Its behavior is proven by the reproducing
unit test, not by the improved live frame rates below. There was also no latched
ramp-recovery wait in this run. Network/capture conditions differ between runs,
so no causal physical speedup is assigned to this patch.

Actual outgoing FPS from counter differences:

| Approximate interval (s) | Mac | Phone |
|---|---:|---:|
| 31–45 | 1.81 | 3.83 |
| 45–75 | 8.35 | 8.32 |
| 75–91 | 19.81 | 19.50 |
| 91–120 | 29.59 | 29.15 |
| 120–150 | 29.72 | 29.31 |

The nominal ladder reached level 0 at about 99.4 s of the call; that does not
prove the full native budget has applied, since the ramp is independent.

All **290** expected tone transitions during seconds 5–150 matched, with complete
source/decoded observation rows and no driver errors. With video/files, point
p95/max were **70/91 ms** Mac → phone and **100/101 ms** phone → Mac. The reverse
phase maximum's observed clock envelope was **95–113 ms**. The maximum across these analyzed phases
was 151 ms in the audio-only phase. These are synthetic decoded PCM timings
with 10 ms blocks; unsampled clock drift is not proven bounded. They do not
qualify acoustic loudness or live speech intelligibility.

Native logs show zero session violations/peer bans and two expected closed
streams on Android. Neither file request completed before cancellation; HTTP
waiters ended with RemoteDisconnected when the apps exited. This verifies
coexistence/cancellation, not completed file throughput.

Final outgoing encoded pixel counts were 230400 on Mac and 20736 on the phone,
with an explicit pixel cap of zero on both. The Android texture receiving Mac
video was 640×360. Frame rates alone therefore cannot establish comparable
image quality in both directions. Source capture versus encoder scaling on the
phone remains a concrete follow-up; do not infer its width/height or cause from
a pixel count alone.

## Cleanup and remaining scope

Owned macOS activity and Android Wi-Fi locks were present during the call and
absent before/after it. All owned app/helper processes and the ADB forward were
independently checked absent; the ordinary phone APK 12622 was restored with an
identical installed hash. Mac still required SIGKILL after its grace period
(exit -9), after call activity had already been released. Foreign work remains
unchanged. No push, release or relay change. The complete audio/video/screen/data
isolation goal remains active; this change does not claim all its verification
or the unresolved image-quality and earlier pre-kernel network wait is complete.
