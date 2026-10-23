# Ordered-channel ready-spare recovery — 23 October 2026

SDK correction: **`1064bc18`**. Parent and measured Wi-Fi SDK: **`8998746a`**.

## Wi-Fi handset baseline, before this correction

The available Blackview used Wi-Fi; Poco was absent. This is a separate
phone/network, not another measurement of the problematic cellular provider.
The phone used its existing owned QA profile and the Mac its owned QA profile;
receive identities were distinct. User-profile selection was unchanged.

Both contacts could message. The actual nonce-marked messages arrived once in
each direction in **0.630 / 0.597 seconds** (Mac → phone / phone → Mac).
The helper recorded contact-request/acceptance durations, but preexisting contact
state was not excluded; **a fresh invitation exchange is not qualified** by
those timings. This does not qualify the Windows contact report.

Both endpoints loaded the staged SDK (installed APK hash and loaded Mac library
path verified), with unchanged compatible frontends. The phone was awake and
its QA activity resumed. Own-contact P2P was denied; observed file opens were
anonymous. No call or physical audio device was opened.

| Phone → Mac | Outcome on `8998746a` | Original 180-second completion gate |
| --- | --- | --- |
| 32 MiB | Not complete at 180 seconds; last sink **15,204,352 bytes (14.5 MiB)** | **Failed** |
| 4 MiB afterward | Complete in **69.850 seconds**, SHA-256 matched | **Passed** |

The large-file partial copy is not integrity-qualified. Including fixture and
offer setup, durations were **183.407 / 70.777 seconds**. Each file used one
full-pull request. There were no setup, manifest-first-byte or payload-idle
failures and no automatic full-pull retries. The large-file reset/failure entry
is the explicit harness cancellation at its 180-second limit, not an additional
network failure. Normal packet-level ARQ still ran.

The earlier 7.7-second zero-handoff manifest event did **not** reproduce here.
No speed or stability gain over the cellular phone is claimed: hardware,
network, paths and diagnostic limit differed.

## Local-wait observations and remaining throughput issue

Opt-in gate samples on the phone recorded transport-capacity waits up to
**402 ms**, and child-unavailable waits up to **204 ms**; no source-budget gate
sample was recorded. Capacity samples needed 2206–2330 bytes and still had
63,206–63,330 bytes available: these hit the deliberately small local backlog
allowance, not exhaustion of the whole 64 KiB transport queue. These are sampled
queue-residence observations, not exhaustive per-frame maxima.

The separate driver `blocked_age` reached **1019 / 4030 ms** on Mac / phone.
It measures a local retry episode and may include partial progress, route
warmup and several retained cells; it is not the same metric as one frame's
session-queue age or network delay. Do not substitute the 402-ms gate maximum
for this upstream measurement.

Recorded recoverable-source admissions used independent children: all 111 Mac
samples were ordered; phone samples were 276 ordered / 104 QUIC. That recorded
DATAGRAM drain path runs before the mobile outbound-batch coalescer. The
200-ms coalescer therefore did not directly defer those sampled sends; other
maintenance/power behavior is not ruled out by this observation.

The phone's 245 driver samples with at least 32 KiB app backlog had stream SRTT
estimates of **236 / 1470 / 9881 ms** (minimum / median / maximum). These are
reliable-stream feedback RTTs, including the path and protocol waits; they are
not Wi-Fi ping, an isolated relay RTT or audio latency. Slow long-file completion
remains open. Process-wide pool and route counters are retained separately;
there is no claim they all belong to one file or that the source of the delay
has been localized to a particular relay.

## Confirmed ready-spare defect and correction

The ordered pool kept an owner bound to an unavailable child even while another
already authenticated, live child was free. Readiness remained Warming and
selection returned None until the originally assigned child recovered. With
connection/binding backoff this can outlast a short first-byte deadline.

The parent regression demonstrates this failure with a real parent-bound
ordered pair. The correction relocates only an unavailable owner's assignment
to a live **unowned** channel. A healthy assignment stays put, other owners are
not displaced, and capacity is unchanged. Local readiness publication and actual
send selection use the same check. The neutral-transit path uses the same rule;
no source role, deadline or priority is sent to the peer.

Tests cover all four ordered source slots with an available spare and with the
only healthy spare owned by another flow (four positive / four negative cases).
A neutral installed-circuit case also delivers its unchanged frame through a
spare. Allocation tests retain witness/source ownership, counter attribution,
healthy assignments and the existing quota, including refusal when all
assignments are occupied. Existing circuit-isolation and seventh-flow refusal
regressions remain green.

All **669 session tests** pass, with **eight existing ignored tests**; all-target
session Clippy with warnings denied, rustfmt and **66 anonymous-stream client
tests** pass. No engine/driver changes were made in this correction.

Production macOS and Android native builds pass, with frozen source hashes
matching `1064bc18`; compatible frontend sources are unchanged. Both preserve
exactly the same **199 C export names**. No native media test hook or PCM probe
was introduced. These are build/artifact and local I/O checks; the correction
was not installed on the phone during the baseline above.

## Scope and cleanup

This is a reproduced recovery defect. **Its responsibility for the historical
7.7-second cellular incident is not proven.** The Wi-Fi run preceded the fix
and did not reproduce that incident. The correction still needs handset/provider
qualification; it does not establish reliable long transfers, audio/video
quality or full multi-device convergence. Queue budgets, first-byte/idle timers,
relay scheduling, wire headers and connection quotas were not increased.

The original phone APK was restored and hash checked. Diagnostic property,
Wi-Fi/mobile-data state, own-contact policies and user-profile selection were
retained/restored. Owned fixture files and the pid-only capture were removed or
stopped. The initial short exit probe raced Mac shutdown; a separate completed
check verified the owned Mac app, phone app and capture absent. The installed
Mac application was untouched. No push, release or relay update.

Raw logs, identities, stream/content identifiers, addresses, keys, payloads and
private paths remain in the private cache. Committed evidence is numeric or
boolean plus source commit references.
