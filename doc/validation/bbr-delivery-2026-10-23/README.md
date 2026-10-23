# BBR delivery accounting and low-rate recovery — 23 October 2026

SDK correction: **`b7745be2`**, parent **`1064bc18`**.

## Physical observation before this correction

The available Blackview used Wi-Fi, with the owned Mac/phone QA profiles and
distinct receive identities. Both endpoints loaded `1064bc18`; installed APK
hash, loaded Mac library path, source hashes and foreground/awake state were
checked. Compatible frontends were unchanged. Own-contact P2P was denied, so
file opens used anonymous streams. No call or physical audio device was opened.

| Phone → Mac | Result on `1064bc18` |
| --- | --- |
| 32 MiB, 180-second limit | Incomplete; last observed sink **2,621,440 bytes (2.5 MiB)**. Integrity unverified. |
| Following 4 MiB | Completed in **108.717 seconds**, SHA-256 matched. |

The large file used one full-pull request, with no setup/manifest-first-byte or
payload-idle failure before deliberate cancellation. The small file required
two full-pull requests after one payload-idle failure; the source also recorded
one payload-write idle timeout. Automatic recovery therefore remains relevant
even though that file eventually completed. Durations including fixture/offer
setup were **184.182 / 109.816 seconds**.

Source write-idle failure lines omit the content identifier. Their count is
retained after the matching source request, but it cannot be attributed uniquely
to that file rather than an older serve still timing out.

Messages arrived once in **0.591 / 0.731 seconds** (Mac → phone / phone → Mac).
Contact state already existed, so contact helper timings do not qualify a fresh
invitation exchange. This Wi-Fi run does not qualify the original cellular or
Windows reports. Routes/network were uncontrolled; no comparative performance
claim is made against the earlier `8998746a` run.

One source stream retained an estimate of **12,440 bytes/second** across
**61 samples spanning 60,836 ms**, despite **1,189,200 bytes** of cumulative
ACK progress and at least **193,065 bytes** of application backlog in every
sample. This motivated the reproductions below. It does not independently
identify the responsible relay or prove the attainable capacity of that path.

## Reproduced defects and changes

1. **Low estimates could prevent their own replacement.** Every rate sample
   required 64 KiB, but a low pacing estimate could not deliver that amount
   inside the two-second sample window. Backlogged probes now scale the byte
   floor to the current model's 300-ms volume, bounded by a segment and 64 KiB.
   The 300-ms minimum span remains; sparse application traffic keeps the strict
   gate. Pacing gains are unchanged.
2. **SACK delivery was invisible until cumulative repair.** The model now
   credits a handed-off data byte at its first cumulative or full-segment SACK
   acknowledgment. Cumulative repair subtracts already-credited SACK overlap,
   including simultaneous fields and partial cumulative ACKs. FIN consumes a
   sequence number but contributes no application bytes. Delivery accounting
   adds no full scan of the remaining flight on cumulative-only ACKs.
3. **Small configured pacing batches had an artificial rate ceiling.** The
   interval targeted 32 cells even when the budget allowed only one or four.
   Interval calculation now respects the configured batch too; the budget is
   unchanged. This was reproduced after correcting the sample gate, when the
   default four-cell case stayed at **40,960 bytes/second** on a faster link.
   Anonymous FFI normally uses a larger batch; this third defect is not claimed
   to explain the observed phone plateau.

## Deterministic checks

The original two regressions fail on the parent: a backlogged low-seed model
remains at 8192 bytes/second, and 127 KiB of SACKed data contributes zero to the
delivery counter. After correction, real sender/receiver engines use serialized
duplex links, actual pacing/ACK transitions and a virtual clock, without source
timing mocks.

- At 256 KiB/s wire capacity, initial models **8192 / 12,440 / 24,576 B/s** and
  batch limits **1 / 4 / 256** all reach **256,000 B/s** of estimated payload
  delivery by 20 seconds. Delivered payload is **4,849,664–5,027,840 bytes**.
  The sender stays backlogged. Millisecond serialization explains the payload
  ceiling; these are not physical network measurements.
- A genuinely 8192-B/s link finishes with an **8062-B/s** estimate and
  **160,768 bytes** delivered, without removing the sender's backlog.
- Sparse 100-byte writes keep the preexisting seed instead of substituting
  their application-limited rate.
- Fresh/overlapping/repeated SACKs, same-ACK cumulative overlap, partial ACKs,
  sequence wrap, local handoff, FIN and BBR-disabled guards pass. Repeated-RTO
  regressions also verify exactly-once data credit for late original ACKs,
  including a rewound FIN and RACK enabled/disabled.
- All **130 stream tests / 66 anonymous-stream client tests**, all-target
  stream Clippy with warnings denied and workspace rustfmt checks pass.

Production macOS and Android native builds pass. Frozen source hashes match
the clean `b7745be2` SDK worktree. Both libraries retain exactly the same
**199 C export names**. Compatible QA frontends are unchanged; no native media
test hook or PCM probe was added. These are artifact checks, not handset
qualification of the correction.

## Corrected SDK on Poco's cellular connection

Poco returned before this work cycle ended. The corrected build was installed
there using its existing owned QA profile. Wi-Fi was off and cellular was the
active default transport; neither was changed. The installed APK, loaded Mac
library, source hashes and foreground/awake state matched `b7745be2`.
Blackview was not reinstalled or launched after the user said Poco would return.

Own-contact P2P was denied and all recorded file opens were anonymous. Messages
arrived once in **1.607 / 0.546 seconds** (Mac → phone / phone → Mac). Existing
contact state means this does not qualify a fresh invitation/acceptance exchange.

| Phone → Mac | Result on `b7745be2`, 180-second limit |
| --- | --- |
| 32 MiB | **Failed**; last observed sink **4,980,736 bytes (4.75 MiB)**. One payload-idle failure, then resume from **1,835,008 bytes (1.75 MiB)**. |
| Following 4 MiB | **Failed**; last observed sink **3,932,160 bytes (3.75 MiB)**. One pull, with no payload-idle failure before deliberate cancellation. |

Neither partial file is integrity-qualified. Durations including fixture/offer
setup were **181.855 / 180.714 seconds**. Final reset/failure entries are the
harness cancellations. No setup or manifest-first-byte timeout, manifest EOF or
source payload-write idle failure was retained for these two transfers.

The phone had **219 nonzero backlogged model samples**, with rate
minimum/median/maximum **4739 / 61,937 / 276,635 B/s**. The longest sampled
unchanged backlogged estimate lasted **19.173 seconds**, with **zero cumulative
ACK progress**. This differs from the progressing frozen-model observation
above but does not prove the new estimator accounts for all real-world stalls.

Driver retry episodes reached **3058 / 19,167 ms** (Mac / phone). These may
include partial handoffs and several retained frames: they are not one-frame
queue age or network latency. Separate sampled phone session-queue gates reached
**212 ms** for capacity and **415 ms** for child unavailability; no gate sample
was recorded on the Mac. The metrics must not be substituted for one another.
Prolonged local retry and feedback stalls remain to be localized. Routes and
network were uncontrolled; no physical performance improvement is claimed.

Both original own-contact policies were restored. Poco's original APK was
restored with an exact hash match; independent checks confirmed owned Mac/phone
apps and capture absent, diagnostic property restored, Wi-Fi still off, mobile
data still on and profile selection unchanged before APK restoration. No call
or physical audio device was opened. The installed Mac application was untouched.
No push, release or relay update was performed.

## Limits and cleanup

This remains BBR-lite, not a complete BBR implementation. In particular, this
change does not add per-packet send-span bounds against ACK compression, a full
BBR state machine or proof of long-transfer stability. Audio/video, Windows,
Android background behavior and the full multi-device matrix remain open.

Before the source correction, the original phone APK was restored with an
exact hash match. Independent checks confirmed owned Mac/phone apps and capture
absent, diagnostic property restored, network settings retained and user-profile
selection unchanged. Own-contact policies were restored. The installed Mac app
was untouched. Private logs, identifiers, addresses, keys, payloads and paths
are excluded from this report.
