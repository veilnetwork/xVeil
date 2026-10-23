# BBR sampling after a capacity drop — 23 October 2026

SDK correction: **`50fa7a2f`**, parent **`10b56236`**.

## Reproduced defect

An overestimated warm rate could never expire on a sufficiently slow,
continuously backlogged path. The sample byte floor depended on the old model's
300-ms volume, capped at 64 KiB. An 8 KiB/s path cannot deliver that amount
inside the two-second sample window when the seed is high, so no lower sample
reaches the max filter. Its nominal ten-second expiry then never takes effect.

The parent regression uses real sender/receiver engines and a serialized
8192-B/s duplex link. After 20 seconds the model still reports **131,072 B/s**
from that seed, despite **160,357 data bytes** acknowledged and sustained
application backlog. The regression fails with
`slow path model is not bounded: 131072 -> 131072`.

The source change makes the thin-sample byte floor independent of the previous
estimate: a fully backlogged observation window needs at least a segment and
the existing 300-ms minimum span. Windows crossing a known application-limited
delivery observation keep the strict 64 KiB floor. The last such observation is
retained even if checkpoint spacing suppresses that particular checkpoint.

The application-gap guard is necessary: an intermediate implementation with
only the byte-floor change lowered a 131,072-B/s seed to **81,358 B/s** on an
unchanged fast link after an application pause. With the guard, that test keeps
the **131,072-B/s** model. The guard concerns known local demand observations;
it does not establish a complete per-packet app-limited estimator.

Pacing gains, sample span/window, max-filter duration, congestion-window bounds,
session queue budgets, wire format and relay scheduling are unchanged.

## Deterministic qualification

| Scenario | Corrected result |
| --- | --- |
| 8192-B/s link, initial model 12,440 B/s | Final model **8062 B/s**, **160,768 bytes** acknowledged in 20 seconds. |
| Same link, initial model 131,072 B/s | Final model **8062 B/s**, **160,357 bytes** acknowledged. |
| Same link, initial model 1,048,576 B/s | Final model **8062 B/s**, **160,153 bytes** acknowledged. |
| Fast link, two 32-KiB application bursts separated by over 12 seconds | **65,536 bytes** acknowledged; no backlog left; seed **131,072 B/s** retained. |
| 256 KiB/s → 8192 B/s at 8 seconds, with queued packets discarded at the transition | At 30 seconds: final model **8062 B/s**, **2,215,321 bytes** acknowledged in total, including **174,080 bytes after the transition**. |

All constant-load and capacity-drop cases retain over 1 MiB of offered backlog.
The handover case uses circuit-style no-SACK rewind and RACK, so actual ARQ
repairs the lost packets; it does not substitute synthetic delivery samples.
The existing low-seed fast-path matrix still reaches **256,000 B/s** for all
three seeds and batch limits. These are virtual-clock results, not phone/network
throughput or proof that a full file completed during the handover.

All **132 stream tests / 68 anonymous-stream client tests**, all-target stream
Clippy with warnings denied and workspace rustfmt checks pass. The final
post-transition-progress assertion was added to the test harness after the
client suite; stream tests and Clippy were then rerun. Production code was
unchanged between those checks.

Production macOS and Android builds pass. Frozen source hashes match the clean
`50fa7a2f` SDK worktree. Both libraries retain the same **199 C export names**;
compatible QA frontends are unchanged, without native media test hooks or a
PCM probe.

## Physical Poco/Mac qualification

Both endpoints loaded the corrected SDK, verified by source hashes, installed
APK hash and the Mac's loaded library path. The phone was awake in the existing
owned QA profile. Cellular was its default transport, with Wi-Fi off. Own-contact
P2P was denied; recorded file opens were anonymous. No call or physical audio
device was opened.

| Phone → Mac | Result, 180-second limit |
| --- | --- |
| 32 MiB | **Failed**; last sink **2,359,296 bytes (2.25 MiB)**. Three pull requests, one payload-read idle failure and one manifest-first-byte timeout. Resume offset **262,144 bytes** was recorded. |
| Following 4 MiB | **Failed**; last sink **2,359,296 bytes (2.25 MiB)**. Two pull requests and one payload-read idle failure. Resume offset **2,359,296 bytes** was recorded. |

Neither partial file is integrity-qualified. Final resets are deliberate harness
cancellations. Including fixture/offer setup, durations were **181.914 / 180.644
seconds**. No connection-setup timeout or manifest EOF was retained. Messages
arrived once in **3.192 / 0.604 seconds** (Mac → phone / phone → Mac). Contact
state already existed; these timings do not qualify a fresh invitation exchange.

Two source payload-write idle failures were retained after the small-file
request began. Those source error lines omit the content identifier, so they
cannot be assigned uniquely to that file rather than an older serve still
timing out. The numeric evidence labels this scope explicitly.

Across the owned phone capture, two stale-session events used the corrected
retirement path, including **one with an already live session**. Neither used
the old cooldown message; no completed open failure reported a cooled first
hop. This confirms that the corrected branch ran, not that the same-R
replacement deletion race was physically reproduced or that its recovery is
fully qualified. That replacement case remains covered by its deterministic
[regression](../stale-session-recovery-2026-10-23/README.md).

Whole-runtime driver retry episodes reached **1022 / 10,066 ms** (Mac / phone),
which may include partial handoffs and multiple retained frames. They are not
one-frame queue residence or network latency. Separate phone session-queue
samples reached **311 ms** for capacity and **0 ms** for child-unavailable
observations. The source model's 196 nonzero backlogged samples ranged from
**11,872 to 162,806 B/s**, with median **45,168.5 B/s**. None of these estimates
qualifies the incomplete files or proves an underlying link capacity.

This run was worse than the preceding uncontrolled run, in which the 4 MiB
file completed. It supplies no evidence of a physical speed or reliability gain.
Network, routes and recovery events differed, so it does not isolate the source
change as the cause either. The failed gates remain release/qualification work.

Own-contact policies and diagnostic property were restored. Independent checks
verified the original Poco APK's exact hash, owned Mac/phone apps and capture
absent, Wi-Fi still off, mobile data still on and user-profile selection
unchanged before APK restoration. The installed Mac app was untouched.
No push, release or relay update was performed.

## Remaining work

The previous corrected SDK's physical run still missed the 32 MiB/180-second
gate; the following 4 MiB completed intact in 40.282 seconds. See the
[stale-session report](../stale-session-recovery-2026-10-23/README.md).
This correction alone does not establish file stability, acoustic delay,
audio/video quality, Windows behavior or the full multi-device matrix.

This is still BBR-lite: per-packet send-span bounds against ACK compression and
a full BBR state machine are not implemented by this correction. Identifiers,
addresses, credentials, content and private paths are excluded from committed
evidence, which contains only numeric/boolean measurements and commit references.
