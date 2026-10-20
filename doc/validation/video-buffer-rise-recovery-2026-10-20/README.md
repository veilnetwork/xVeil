# Video recovery while protecting audio

## Change

Root `2bb377c6` preserves already earned healthy video-recovery observations
across an unconfirmed audio-buffer rise. During the rise it neither earns
another good observation nor permits an applied bitrate/FPS increase. Once the
buffer drains, the remaining recovery period continues. Confirmed pressure,
actual loss, missing feedback and measurements outside the recovery limits
still reset recovery. Existing thresholds and the bounded applied ramp are
unchanged; this does not pursue a strict 200 ms acoustic target.

The earlier physical trace contains a representative reset: phone policy
observation 56 erased nine good observations while peer current delay was
103 ms, the peer reported a rising window, but confirmed buffer pressure was
false. The old snapshot does not contain every eligibility input, so this is
not claimed as its exclusive cause. New local-only diagnostics expose recovery
eligibility, pending growth and missing receiver feedback for future captures.

Two regressions, through the native-stats entry point, fail against the
unchanged old adapter in the disposable QA export. They cover local and peer
windows. Additional guards prove cached rising feedback cannot earn growth or
confirm continuing damage, and sustained growth still discards the old credit
and reduces video. **336 direct call/source/controller tests and 88 group
controller/media tests pass**; targeted analysis reports no issues.

## Physical run

Private AOT builds 12625 ran Mac ↔ Blackview for 150 seconds. The existing
calibrated synthetic ADM used real Opus/NetEq, SDK transports and cameras,
without opening physical microphones or speakers. Cameras started at 30 s,
two fresh 32 MiB file requests at 45 s, and both streams were cancelled at about
90 s. The call remained P2P with one engine generation per device. Old pending
QA downloads were cancelled first, and unique source paths retained old offers.

All **290 expected tone transitions in 5–150 s** matched actual decoded PCM.
The overall maximum point estimate was **141 ms**; during video/file requests,
p95 / maximum were 120 / 121 ms Mac → phone and 131 / 131 ms phone → Mac.
These are decoded-pipeline timings, not headphone/speaker acoustic latency or
speech quality. PCM blocks are 10 ms; observed clock-bracket uncertainty and
unbounded unsampled drift limits remain in `decoded-pcm.json`. Shorter defects
can exist between one-second tone transitions. No overall quality verdict.

The specific eligible pending-growth branch did **not** occur in this physical
run. Its changed behavior is established by the deterministic tests; this run
checks the compiled policy under load and does not prove its performance benefit.
The two physical runs below occurred at different times and are not controlled
network A/B measurements. In particular, the lower audio delay in the new run
is not attributed to this policy change.

## Actual outgoing video frame rates

Rates are differences of `video_tx_frames` over measured intervals, not a
whole-call average or requested FPS. Exact nearest-sample interval endpoints
and receiver/render counters are retained in `video-summary.json`.

| Requested interval | Earlier Mac / phone | New Mac / phone |
| --- | ---: | ---: |
| 31–45 s | 0.87 / 1.16 | 0.77 / 1.05 |
| 45–75 s | 0.55 / 0.62 | 3.73 / 5.96 |
| 75–90 s | 0.97 / 1.03 | 5.59 / 7.14 |
| 90–120 s | 2.26 / 2.50 | 2.78 / 2.57 |
| 120–149 s | 6.59 / 6.82 | 2.58 / 3.47 |

Video still reduces quality in the new run. The recorded Mac reduction is
associated with a qualified audio soft-loss witness; the phone reduction with
a fresh video RTP-loss witness. Neither records confirmed buffer pressure at
that reduction. Low tone delay alone does not invalidate actual loss evidence.
The late interval is slower than the earlier run, so no uniform FPS improvement
is claimed. Stable useful video and complete file/screen qualification remain
open. Both large files were intentionally cancelled, not hash-qualified.
Their debug-API HTTP waiters still ended at app shutdown, a retained fixture/API
limitation rather than a successful file result.

## Separately localized transport delay

The earlier run's phone → Mac RTP packet `(epoch=5b2a0288d480520f, seq=2750,
index=0, ssrc=435165122, rtp_seq=11257, timestamp=3724243222)` matches at sender
seal and authenticated receiver ingress. Both logs report 94 payload bytes.
The native diagnostic and PCM calibration clocks use the same platform clock
domains (Mach absolute time on Mac, CLOCK_MONOTONIC on Android).

Its measured seal-to-receive interval is **447.7 ms**, with an observed clock
envelope of **439.6–457.3 ms**; unsampled clock drift is not proven bounded.
This includes local IPC, scheduling, transport and network, and does not locate
the wait solely on the wire or blame a relay/provider. It is not a jitter-buffer
size or a PCM-block estimate. The matched source/receiver lines and arithmetic
are retained in `previous-packet-delay.json`.

The next transport check should trace this interval through actual outgoing
QUIC admission/send/ACK activity and the primary source budget under file load.
The video recovery change does not establish a fix for that separate delay.

## Provenance and cleanup

The QA export includes the exact committed adapter and no foreign root edits.
Native SDK/media/storage/driver inputs remain pinned to the prior verified
stand; SDK is `70a99c1f`. No relay priority, wire fields or server configuration
changed. One initial Mac build failed the provisioning gate before any app
launch; the disposable project was built unsigned and the completed stand
signed locally after native staging.

The ordinary phone APK 12622 was restored and its installed hash matches the
original. All started app/helper PIDs and the owned ADB forward were checked
absent. Mac cleanup still required SIGKILL after its grace period, retained as
exit -9. Test profiles remain. Own changes are committed unsigned, with no push
or release. The overall audio/video/screen/data isolation goal remains active.
