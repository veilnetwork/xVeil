# Cellular call and file validation — 2026-10-22

**Status: warm-only reuse fixed; the latest physical file pair completed with matching hashes. Long-transfer stability and call/video qualification remain open.**

## Separate source follow-up — distinct-rendezvous expansion

SDK **`1654a9be`** separates throughput-driven pool expansion from explicit
repair, avoiding new construction through already represented rendezvous relays.
Test assertions were strengthened in **`2a3b4999`**. The
[dedicated report](../circuit-pool-expansion-2026-10-23/README.md) records the parent
failure, ten child cases, bounded discovery/re-probe checks and native builds.
Physical requalification is pending: the phone was ADB unauthorized; no new
file/call run or speedup claim belongs to this source correction.

## Separate source follow-up — rejected-build resource rollback

SDK **`471618ef`** corrects a reproduced origin-state leak after local
`CircuitBuild` admission fails. The [dedicated report](../circuit-build-rollback-2026-10-23/README.md)
records parent failures, nine passing recovery cases and native build checks.
It does not establish the cause of this stand's `NoRelays` events; no new
physical file/call run was performed for that source correction.

## Latest follow-up — 23 October: reuse ready paths during warm-up

SDK **`7e15b372`** separates best-effort warm-up from explicit circuit repair.
Previously every completed warm-up allowed the next warm request to construct
a fresh pool, even when a usable path already existed. Warm-up now resolves the
current signed receiver ads and reuses a route only when rendezvous, receiver
cookie and receiver X25519 key match, confirmation is present, the first-hop
session and its close generation are current, and neither hop nor rendezvous is
cooled. Slow-marked routes and old quiet routes without active streams are rebuilt.
Reused circuits retain their live statistics, handshake index and traffic metadata.
Missing paths are still constructed and confirmed prefixes remain available
before the rest of the pool finishes.

Explicit repair still requests fresh paths. A repair joining a warm pass that
has reused a path triggers one fresh pass before the shared running slot is
cleared. A cold pass that has already built fresh routes needs no duplicate
pass; a failed cold attempt retains the existing one-second failure backoff.
No network wait was added to the stream driver's warm request. Relay quotas,
framing, anonymity hop count and scheduling are unchanged.

The real-services subprocess regression failed on the parent: a ready-path warm
performed **one unnecessary failed construction**, versus **zero** after the
correction. A second regression caught **two** failed cold construction passes
for an overlapping request in the initial implementation; the final version
performs **one**. All **16 child cases** pass, covering ready/busy/recent-data
reuse, empty/unconfirmed/quiet/cooled/slow/dead/generation-mismatched paths,
changed cookie/key, explicit repair and both overlap cases. All **61 anonymous
stream tests**, all-target Clippy with warnings denied and rustfmt pass.
Production macOS/Android builds retain the same **199 C export names**;
compatible frontends, frozen-library/source hashes and loaded/installed build
checks pass. No synthetic media was enabled.

### Physical result and remaining failures

The owned cellular phone/Mac stand used anonymous streams with phone Wi-Fi off
and own-contact P2P denied. No call or physical audio device was opened.

| Direction | Size | Download time | Integrity and original gate |
| --- | ---: | ---: | --- |
| Phone → Mac | 32 MiB | **136.093 s** | SHA-256 matches; **180-s gate passed** |
| Phone → Mac, afterward | 4 MiB | **11.417 s** | SHA-256 matches; **180-s gate passed** |

These are download timers. Full diagnostic durations, including fixture setup,
file offer and its delivery, were **164.346 s** and **12.046 s** respectively.
The large transfer needed two pull requests after **one manifest-first-byte
timeout**; the small transfer needed one request. Neither had a connection-setup
or source payload-write-idle timeout, and neither required harness cancellation.
This pair's completion is verified; it is **not** a controlled physical A/B
speedup or proof that all long transfers are stable.

Native process logs still contain **11 / 84 successful pool completions** and
**17 / 98 newly confirmed outbound circuits** on Mac / phone. Each process
addressed two destinations; these are process-wide counters, not attribution
to one file. On the phone, 75 completions had a 1/3 pool. Mac recorded **five
completed `NoRelays` failures** and ten associated candidate failures; phone
recorded none. Sampled local handoff waits reached **12,225 / 4,950 ms**.
Further reconstruction and the manifest timeout remain investigation targets;
the absence of an origin-table-full diagnostic is not proof of spare capacity.

The original phone APK was restored with an independently checked SHA-256 match;
contact policies and the diagnostic property were restored. Owned Mac/phone app
processes and log capture were independently verified absent. Evidence is in
[warm-ready-pool.json](warm-ready-pool.json). Call/video, live speech and the full
multi-device matrix were not requalified in this cycle. No release or push occurred.

## Previous follow-up — 23 October: bound completed circuit-open failures

SDK **`7fa3c1ec`** fixes a fast retry storm after circuit construction fails.
The existing guard suppressed concurrent openers but removed its entry as soon
as an opener finished. A synchronous `NoRelays` failure could therefore start
another whole construction on every local carrier retry.

The preceding phone capture contains **1,315 completed failed pool opens** in
two minutes, with **3,945 candidate failures**: each pool tried three relays.
These produce approximately 5,260 error lines, not 5,260 independent pool opens.
The previously reported line count must not be used as a construction count.

Completed failures now leave a **one-second per-destination retry deadline**.
The first attempt remains immediate; the next caller may try after the
deadline. There is no sleeping retry worker or automatic network retry.
Independent media producers keep separate failure state. Existing ready
circuits can still send during the pause. Expired deadlines are pruned, and
an old opener cannot overwrite a newer opener's state. Successful pool builds,
relay quotas, anonymity hop counts, framing and relay scheduling are unchanged.
After an error, construction can consequently wait up to one additional second;
this does not gate sending on an already usable route.

The new subprocess regression uses real offline node services and a valid
signed receiver advertisement, with insufficient relays for a full path. On
the parent, 16 carrier retries create **16 actual completed `NoRelays`
failures**; the correction creates **one**. Five child cases cover the burst,
retry after the deadline, another destination, another local producer and
actual outbox delivery through a healthy route published during the pause.
All **61 targeted embedded FFI tests**, all-target Clippy with warnings denied
and rustfmt pass. Production macOS/Android SDKs build and retain the same
**199 C export names**. The compatible frontends from the preceding correction
are reused; source, frozen-library and installed/loaded build checks pass.

### Physical failures and next investigation

The same owned cellular phone/Mac stand used anonymous file streams, phone
Wi-Fi off and own-contact P2P denied. No call or physical audio device opened.

| Direction | Size | Result | Retained observations |
| --- | ---: | --- | --- |
| Phone → Mac | 32 MiB | Timed out at **600 s**; last sink **21,233,664 bytes (20.25 MiB)**; original **180-s gate failed** | Three failed pull attempts including harness cancellation, one setup timeout, one source payload-write-idle event; resume requested at **4,456,448 bytes** |
| Phone → Mac, afterward | 4 MiB | Timed out at **180 s**, with **zero useful file bytes observed** | Seven failed pull attempts including cancellation; six setup timeouts; no serving request observed in the retained source log |

Neither completed, so **integrity remains unverified**. The retained source
log for the small transfer is below its line limit, but absence of that serving
request still does not prove remote refusal. No manifest-prefix timeout or EOF
was observed. This run contains **zero `NoRelays` occurrences**, so it cannot
establish that the physical failure storm was cured or explain the first path
loss. Route selection and network load were not controlled; no speed gain or
causal comparison is claimed.

There is still substantial successful reconstruction: **146 completed pool
builds on the Mac and 29 on the phone**. During the large-file observation,
the receiver requested only one content id; old file downloads were not seen.
The next controlled investigation is the warm/top-up path: Dart forwards warm
requests without a throttle, while native warming can reconstruct an already
usable pool. A failed-construction pause does not fix this successful churn.
Any correction must preserve stale-path repair, receiver-key binding, early
confirmed-prefix use and existing resource limits.

[circuit-open-backoff.json](circuit-open-backoff.json) retains aggregate counts,
failed gates, verification scope and cleanup evidence. Exact original phone APK
restoration and hash matching passed; policies and diagnostics were restored,
owned fixtures removed, and independent checks found no owned Mac app, phone
app or log capture. Long-file reliability, call/video recovery, live-speech
loudness, Windows, Android background availability and full multi-device
qualification remain open.

## Previous follow-up — 23 October: distinguish handshake from response silence

SDK **`2179c1e5`** exposes validated anonymous-stream handshake state. An
optimistic local write, or handing a SYN to a carrier, does not establish peer
readiness. The driver now retains its existing engine `Connected` event; reset
remains an error. The new nonblocking C query uses the existing typed handle
table and does not wait for network I/O or claim application-data delivery.

All four file-request paths now distinguish connection setup from waiting for
the manifest prefix. Setup uses the remaining original 60-s request budget,
capped at 25 s after the local write. The existing short first-response timeout
starts after handshake completion. **This adds a separate bounded setup stage;
it does not leave total attempt timing unchanged.** A connected but silent
source still hits the short response bound. Cancellation closes the tracked
stream, and implementations without this optional capability retain their
existing behavior. Manifest-prefix timeout and actual EOF now have distinct
errors; neither is labeled proof that the sender refused service.

Two application regressions fail with actual assertions before the correction:
a request queued behind a 300-ms handshake loses to a 60-ms response timeout,
and a never-connected stream fails before its setup budget. Four readiness
cases pass after the correction, including established-source silence and
cancellation. The selected application subset passes **76 tests**, the full
stream crate **118**, and targeted embedded FFI **60**. All-target Clippy with
warnings denied, rustfmt and changed-file Dart analysis pass. Production SDKs
and fresh client frontends build for macOS and Android. The C ABI deliberately
adds **one export**, `veil_anon_stream_is_connected` (**198 → 199**); the header
and both ABI contracts are regenerated. Older frontends must not be paired
with these new native libraries. This is local verification, not a full CI or
Windows runtime result.

### Physical failures remain

The owned phone/Mac stand again used cellular data with phone Wi-Fi off and
own-contact P2P denied. No call, camera or physical audio device was opened.

| Direction | Size | Result | Observed failures |
| --- | ---: | --- | --- |
| Phone → Mac | 32 MiB | Timed out at the **600-s diagnostic limit**; last observed sink **32,243,712 bytes (30.75 MiB)**. Original **180-s gate failed**. | Nine failed pull attempts including final harness cancellation; five connection-setup timeouts, one source payload-write-idle event. |
| Phone → Mac, after the large transfer | 4 MiB | Timed out at **180 s**; last observed sink **1,572,864 bytes (1.5 MiB)**. | Five failed pull attempts including final harness cancellation; three connection-setup timeouts, one source payload-write-idle event. |

Neither completed, so **file integrity was not verified**. Actual large-file
resume requests used offsets **1,048,576** and **30,146,560 bytes**. At 180.960 s,
the observed large-file sink was **9,437,184 bytes**. No manifest-prefix timeout
or pre-manifest EOF was recorded, but connection and payload failures persist;
the changed error classification must not be counted as a complete fix.

Native samples include a pending initiator handshake lasting beyond the old
8-s first-response bound. The phone also reports repeated `NoRelays`, and a
sampled local handoff wait reaches **35,263 ms**. These observations do not
identify the first cause of route loss. Repeated completed pool builds and
refill requests without an alternative warrant a controlled construction-count
regression before changing repair cadence. Route selection and network load
were not held constant, so this worse run does not establish a causal speed
comparison with the preceding correction. Long-file stability remains open.
[connection-readiness.json](connection-readiness.json) contains aggregate
measurements, verification scope and cleanup evidence only.

The exact original phone APK was restored and hash-checked. Policies,
diagnostic properties and owned fixtures were restored or removed. Independent
checks found no owned Mac app, phone app or log capture. Call/video recovery,
live-speech loudness, Windows reports, Android background availability and full
multi-device qualification remain open.

## Previous follow-up — 23 October: isolate file setup registrations

SDK **`14964dec`** fixes an inbound-registration displacement defect. File
outbound circuit construction reused the advertised receive key/cookie and its
epoch counter. At a rendezvous shared by receive and outbound paths, a newer
outbound setup could therefore replace the published receive binding. The
existing private-registration path already avoided this for media producers.

The new regression takes the file hub's actual configured registration policy
and submits signed registrations through the real `CircuitRendezvousRegistry`:
one advertised inbound circuit followed by three outbound candidates. On parent
SDK `1300de5f`, lookup of the advertised cookie changes from circuit **1** to
circuit **4**. With independent outbound candidate keys it stays at **1**, all
four bindings remain distinct, and outbound setup leaves the receive epoch
counter unchanged. The same isolation prevents concurrent candidate probes
from sharing one registration cookie. Exclusive setup keys use the existing
zeroization path. Advertised receive keys, identity keys, envelope format,
relay policy, quotas and scheduling remain unchanged.

All **59 targeted embedded FFI tests** pass, including the new parent-red
regression and existing stream/media isolation controls. All-target Clippy with
warnings denied and rustfmt pass. Production macOS and Android SDKs build with
the same **198 C export names** each; the frontends and media libraries are
unchanged. No manifest timeout was increased.

### Physical results and remaining failure

The same owned cellular phone/Mac stand used anonymous streams, with phone
Wi-Fi off and own-contact P2P denied. No call, camera or physical audio device
was opened.

| Direction | Size | Download result | Attempts / integrity |
| --- | ---: | --- | --- |
| Phone → Mac | 32 MiB | **314.430 s**; failed original **180-s** gate, completed within separate 600-s diagnostic | Eight pull requests, five manifest-phase failures, one source payload-write-idle event; integrity matches |
| Phone → Mac | 4 MiB | **28.997 s**; passed original 180-s gate | One pull request, no failed attempt; integrity matches |

The large transfer actually requested resume at **5,242,880 bytes**. At
180.914 s, the observed sink file length was **6,291,456 bytes**. Completion and
integrity do not close the manifest or payload-idle failures. The lower final
duration than the preceding run is not proof of a speed gain: route selection
and network load were not held constant, and this run had more retries.
[private-file-registration.json](private-file-registration.json) retains the
aggregate results, negative/positive regression gates and cleanup checks.

Investigation of the preceding run also distinguished application timeout from
remote refusal: both initial pull attempts ended approximately **8 s** after
their locally queued request. The source accepted streams but had not received
their content requests before reset; native summaries still showed an
uncompleted handshake. The existing `no manifest (sender not serving)` error
also labels a first-byte timeout, so that text alone does not prove the sender
refused service. The next investigation must distinguish transport readiness
from a silent established stream, preserving bounded cancellation and dead-
source handling. The current 8-s first-byte timer remains unchanged.

A power snapshot taken **during** this transfer found the phone awake, screen
on, charging and outside Android idle mode. This single snapshot does not rule
out transitions before or after it, nor certify background availability.

Final source/frozen SDK/installed APK/loaded Mac library verification passed.
Own-contact policies and diagnostics were restored, owned fixtures removed,
and the exact original phone APK restored and hash-checked. Independent process
checks found no owned Mac app, phone app or log capture. Long-file stability,
call/video recovery, live-speech loudness, Windows and full multi-device
qualification remain open.

## Previous follow-up — 23 October: reserve admission before sealing

SDK **`1300de5f`** fixes a controlled local-rejection/replay failure. Previously,
the origin allocated a circuit sequence and sealed a cell before checking its
session queue. Repeated QueueFull attempts could therefore move the circuit
sequence far ahead without handing those cells to the network. In the real
outbox/ReplayWindow regression, a later accepted cell arriving before two
earlier accepted cells made those still-fresh cells appear too old. This is a
synthetic reordering reproduction, not proof of the physical upload's cause.

Recoverable source cells now reserve their existing queue slot and byte credits
before sealing. Full, closed or missing admission skips construction; build and
length failures release reservations. Accepted envelopes retain their credits
through the scheduler, including a restored send. Activity and full-rejection
accounting remain in the registry. The frame uses the existing wire encoder and
ordinary header; this adds no relay role, priority, queue allowance or wire
field. Actual duplicate cells remain rejected by the unchanged replay window.
Deadline-bound media paths retain their existing admission behavior.

The same cycle fixes circuit sequence exhaustion: fetch-add previously wrapped
the atomic even when the caller received None. A later concurrent call could
reuse low sequence values. Allocation now stays exhausted permanently and asks
for rotation, including when recoverable ingress is full. Sequential and
eight-thread boundary tests verify uniqueness. Reaching the 32-bit boundary is
**not claimed as the cause of a 32-MiB transfer failure**.

Four regressions fail with actual assertions on parent SDK `3ba02e37`. The fix
adds five runtime and five session regressions. Verification passes: **666
session tests** (8 ignored), **20 circuit-filtered runtime tests**, **116 stream
tests**, **58 targeted embedded FFI tests**, all-target Clippy with warnings
denied and rustfmt. Production macOS and Android SDKs build with the same **198
C export names** each. This is scoped local verification, not a full CI claim.

### Physical upload after admission correction

The unchanged frontends used the new frozen SDK on the same owned cellular
phone/Mac stand. Wi-Fi was disabled; own-contact P2P was denied and all opens
were anonymous. No call, camera or physical audio device was opened.

| Direction | Size | Download result | Attempts / integrity |
| --- | ---: | --- | --- |
| Phone → Mac | 32 MiB | **354.450 s**; failed original **180-s** gate, completed within separate 600-s diagnostic | Three pull requests, two manifest-phase failures; integrity matches |
| Phone → Mac | 4 MiB | **29.845 s**; passed original 180-s gate | One pull request, no failed attempt; integrity matches |

At 180.351 s the observed sink file length was **14,680,064 bytes**. No positive
resume request or source payload-write-idle event was observed in this run.
Successful completion does not erase the two manifest failures or prove stable
throughput. Route selection and network load were not controlled against the
preceding run; no physical speed gain or complete long-file fix is claimed.
The next investigation remains the manifest retries and slow delivery through
the stream path. [circuit-admission.json](circuit-admission.json) contains only
aggregate results and the scoped verification gates.

Final source/frozen SDK/installed APK/loaded Mac library checks passed. The
original phone APK was restored with matching hash, diagnostics and own-contact
policies were restored, owned fixtures were removed, and independent process
checks found no owned Mac app, phone app or log capture. Live speech, Windows,
call/video recovery and full multi-device qualification remain open.

## Previous follow-up — 23 October: nonblocking cold-pool admission

SDK **`3ba02e37`** corrects a confirmed carrier-blocking defect.
`open_outbound_for_handshake`
previously awaited the whole pool build, or polled another opener for up to
10 seconds inside the carrier call. The stream driver could not service receive,
reset or protocol timers until that call returned. In the controlled registered-
opener case, parent SDK `51f71c3d` still has not returned when the **50-ms** test
deadline expires; this is a failed responsiveness gate, not a measured 10-s wait.

The send path now starts/reuses the debounced background builder and returns
local WouldBlock while no route is ready. The exact unsent SYN remains owned by
the driver. Each confirmed candidate is published before the builder starts
waiting on the next relay. Refills keep the live prefix's current handshake
markers, activity timestamps and shared stream accounting rather than restoring
the builder's earlier snapshot. Existing pool bounds, prior live-route handling,
receiver binding and retirement grace are preserved. A finishing older opener
also cannot erase a newer task's debounce timestamp.

The new registered-opener regression passes, and a synthetic ready-prefix test
locally admits one SYN before a later candidate is available, then checks that
publishing the second candidate preserves the first route's live metadata and
order. This does not certify an end-to-end remote handshake latency. All **58
FFI anonymous-stream tests**, **116 stream tests**, all-target Clippy with warnings
denied and rustfmt pass. Production macOS/Android SDKs build with the same **198
C exports** each. [cold-pool-progress.json](cold-pool-progress.json) records the
scoped gates and the physical results. No RACK default, RTO limit, wire field,
relay priority or mailbox policy changed in the retained correction.

### Diagnostic completion beyond the original gate

The earlier 180-s records intentionally said **incomplete**, with integrity
unverified after harness cancellation. A separate diagnostic now samples the
owned temporary output's file length every second and permits up to 600 s. This
distinguishes insufficient speed from a permanent stall; it **does not turn a
failed 180-s completion gate into a pass**.

On SDK `51f71c3d`, before this carrier correction, 32 MiB phone → Mac eventually
completed in **329.668 s** with matching integrity. At the original 180-s point,
the sink file length was **17,563,648 bytes**. The largest observed interval
between file-length increases was about **11.1 s**. File length is an observation
of the verified-piece sink, not a transport-byte or independently inferred
contiguous-prefix counter. See [file-progress.json](file-progress.json).

### Rejected default-floor experiment

Queue-pressure DATA recovery can use an alternate first hop even when scheduled
striping is off. A controlled split-enqueue test exposed a mismatch with the
zero initial RACK reordering floor. However, changing the default for the
multi-route pool to the existing 1,500-ms striped floor did **not** establish a
production improvement:

| Diagnostic case | 32-MiB phone → Mac result | 180-s gate |
| --- | --- | --- |
| Candidate default floor 1,500 ms | Application failed before the 600-s limit; 22 manifest-phase failures and two payload-idle failures, with actual resume requests | Failed |
| Same compiled candidate SDK/frontends, explicit former floor 0 ms | **294.475 s**, matching integrity | Failed |

Relay selection and network load were not held constant, so this pair alone does
not prove that the changed floor caused the failure. The default-floor change
was nevertheless **reverted and is not included in the retained SDK changes**.
The candidate patch stays private for further diagnosis; all temporary phone
properties were restored. [rejected-reordering-floor.json](rejected-reordering-floor.json)
keeps the negative result and its control.

### Physical results with nonblocking/progressive publication

The retained code uses the original RACK defaults and the same QA identities,
frontends, cellular default routing and own-contact P2P deny policy. All opens
were anonymous. No call, camera or physical audio device was opened.

| Direction | Size | Result | Requests | Recovery / integrity |
| --- | ---: | --- | ---: | --- |
| Phone → Mac | 32 MiB | **385.314 s**, within the separate 600-s diagnostic; **failed the original 180-s gate** | 3 | Resumed at **18,350,080 bytes** after source payload-write idle; final integrity matches |
| Phone → Mac | 4 MiB | **19.836 s**, within the original 180-s gate | 1 | No failed attempt; final integrity matches |

The long run still had one manifest-phase failure and a source payload-write-idle
event. It proves successful integrity-checked recovery in this run, **not a
stable speed gain or elimination of the long-file defect**. Its positive resume
offset comes from an actual request sent, not a final cancellation checkpoint.
Native pending-handoff maxima include route construction/retries and are not
individual carrier-call latency measurements.

Existing file logs and CLI snapshots were read on six relays without changing
remote services/configuration. All six were active with zero service restarts;
opaque global events and single cumulative snapshots do not identify losses of
specific owned cells. No media classification or prioritization was added.
A phone power snapshot was taken only after cleanup and cannot rule out sleep
during transfer.

After every physical run, tested sources/frozen SDKs/installed APK/loaded Mac
library were checked, own apps and captures exited, policies and diagnostics
were restored, and the exact original phone APK was restored and hash-checked.
The installed Mac app was unchanged. Live-speech, Windows and complete
multi-device qualification remain outside this cycle.

## Previous follow-up — 23 October: BBR RTT from first original receipt

SDK **`51f71c3d`** corrects the stream's BBR RTT sampling. The model previously
reused cumulative-ACK age as its minimum-RTT
sample even for originals already acknowledged by SACK. A repaired earlier hole
could hold the cumulative ACK for seconds after those originals were received.
Once the 30-s minimum window expired, that recovery wait could replace the
clean path estimate. SACK-only progress supplied no BBR RTT sample at all.

BBR now takes one sample from the latest actually handed-off, newly received
original in the whole ACK, including its SACK fields. Repeated SACKs and a later
cumulative ACK of those same bytes do not resample them. Retransmitted and
unhanded cells remain excluded, and disabling BBR keeps the model disabled.
The existing cumulative-ACK RTO estimator, timer limits, RACK repair policy,
wire layout, relay scheduling and mailbox policy are preserved. RACK's adaptive
base can use the corrected BBR minimum when BBR is enabled; its two-path
reordering gate now explicitly checks BBR on as well as off.

Three cases fail on parent SDK `be4c2737`; four cases pass after correction,
with ordinary and wrapping sequences, RACK on/off, differing local handoff
instants, reversed SACK field order, repeated ACKs and Karn/disabled controls.
The isolated repaired-head case held a clean **10-ms** minimum before a
40,010-ms cumulative-ACK age: the parent replaced it with **40,010 ms**, while
the fix retains the original first-receipt sample. The conservative RTO still
responds to that cumulative-ACK age. An earlier variant that shortened RTO from
fast SACK timing failed the zero-loss two-path test and was discarded.

All **116 stream tests**, **56 targeted embedded FFI tests**, all-target Clippy
with warnings denied and rustfmt pass. Both production macOS/Android SDKs build
with the same **198 C export names** each. [bbr-first-receipt.json](bbr-first-receipt.json)
records aggregate verification and every physical outcome.

### Cellular file results with the corrected model

The same own QA identities and unchanged frontends were used, Wi-Fi was off,
cellular default routing was verified, and own-contact P2P was denied. All opens
were anonymous. No call, camera or physical audio device was opened.

| Direction | Size | Download window/result | Requests | Manifest-phase failures | Integrity |
| --- | ---: | --- | ---: | ---: | --- |
| Phone → Mac | 32 MiB | **Incomplete in 180 s** | 2 | 1 | Unverified |
| Phone → Mac | 4 MiB | **29.280 s**, within 180 s | 1 | 0 | Matches |

The 32-MiB total elapsed time was 191.558 s including offer/wait; the download
gate was not extended. Its final harness cancellation is not a second
independently observed product timeout. There were no positive-offset resume
requests or source payload-write-idle events in these two recorded cases.

Across the whole capture, sampled phone BBR minimum RTT stayed at **110–251 ms**;
the preceding failed diagnostic capture had a 10,404-ms model minimum. This is
consistent with the controlled model fix, **not proof of a stable speed gain or
of the physical stall's root cause**. The 32-MiB gate still fails, and the cold
manifest failure also remains. Outbox/ordered-writer maxima are separate
observations and must not be added; the JSON reports them by local source slot.

Sources, frozen SDKs, installed APK and loaded Mac library were verified before
and after the stand. Own apps/captures exited, contact policies and diagnostics
were restored, owned phone fixtures were removed, and the exact original phone
APK was restored and hash-checked. The installed Mac app was unchanged. No
Windows, live-speech or full multi-device qualification ran in this cycle.

## Previous follow-up — 23 October: cancellation outside the DATA queue

SDK **`be4c2737`** fixes a controlled cancellation defect in the stream driver
and FFI abort path. A 6-MiB application write leaves more than the 4-MiB unsent high-water
behind a carrier rejecting DATA with local backpressure. The driver then stops
receiving ordinary app commands, including the old reset command. If the eight
command slots are also full, even the public reset call itself waits for space.
The FFI abort task additionally waited for the writer mutex held by such a write.

Cancellation now uses a separate single-value watch signal. The first reset
reason wins; repeated requests cannot accumulate control work. The driver
processes it independently of DATA's high-water guard, discards retained DATA
and makes its existing best-effort final RST attempt. FFI abort signals it
directly without taking the writer lock. The reader-only local-abort operation
retains its existing behavior. This does not cancel an unsafe in-flight carrier
future: driver teardown still waits for that operation to return, and RST
network delivery remains best effort.

Three regression cases fail on parent SDK `4a53b1c3`. Four cases pass after the
fix, including a blocked write holding the same mutex shape as FFI, release of
that write and reader, preservation of the first reason across 100 repeated
requests, and exactly one RST in the accepting test carrier. The complete stream
suite passes **112 tests**, and the targeted embedded FFI suite passes **56**.
All-target Clippy with warnings denied and rustfmt pass. Production macOS and
Android SDKs build and retain the same **198 C export names** each. Evidence is
recorded in [reset-control.json](reset-control.json). No wire format, timer ceiling, relay scheduling or mailbox policy changed.

### Failed-transfer diagnostic capture, before this cancellation fix

[failed-admission-trace.json](failed-admission-trace.json) records another
physical run using unchanged SDK `4a53b1c3` and frontends. Own-contact P2P was
denied, phone default routing was cellular, and all recorded opens were
anonymous. No call, camera or physical audio device was opened.

- Phone → Mac **32 MiB remained incomplete in the unchanged 180-s download
  window**. Its one pull request had no manifest-phase failure. The 209.051-s
  total also includes offering/waiting; it is not a longer download gate.
- The following phone → Mac **4 MiB passed in 75.417 s**, with matching integrity,
  one pull request and no manifest-phase failure.
- Across this whole capture, phone recoverable-DATA admission (local slot 4)
  reported maxima of **493.396 ms** outbox-to-transport, **182.656 ms** in the
  ordered record queue and **182.516 ms** in the record write. They belong to
  different observations and must not be added. Neither endpoint's sampled
  slot-4 reports recorded buffer/bandwidth drops or capacity deferrals. Buffer
  drop reports in this capture belonged to the separate local signaling slot 6;
  they do not establish loss of file DATA or quantify network packet loss.
- Maximum sampled unsent DATA was **253,706 bytes** on the phone, below the
  4-MiB high-water. Thus the cancellation regression is an independently proven
  resource-release defect, **not an established cause of this physical stall**.

The old receiver-generation theory was not promoted to a fix: current clients
persist the introduction key and deterministically derive their registration
cookie across restarts. No established stream was allowed to switch its receiver
binding. The remaining failure needs further transport/congestion investigation;
this capture does not establish a ping, packet-loss or provider root cause.

Before source edits, the tested SDK/APK/loaded library were verified again.
After the stand, own apps and captures exited, contact policies and diagnostics
were restored, phone fixtures were removed, and the exact original phone APK
was restored and hash-checked. The installed Mac app was unchanged. No physical
transfer using the new cancellation fix is claimed by this capture. Long-file,
call/video, Windows and complete multi-device qualification remain open.

## Previous follow-up — 23 October: ready inbound traffic between send bursts

SDK **`4a53b1c3`** fixes a confirmed managed delay in the reliable-stream driver.
[driver-fairness.json](driver-fairness.json) records the red/green controls and
all physical outcomes. **This correction does not close phone-to-laptop
cellular file completion failures.**

A successful carrier send could await local pacing long enough for the next
engine tick to become ready. The driver then refilled outgoing DATA immediately,
repeating until a whole send window drained before reading already-ready ACKs
or reverse DATA. A real async driver fixture with a 2-ms local admission delay,
no network loss and no added propagation delay exposes **320 ms** of ACK queue
wait and **128 ms** of reverse-DATA queue wait on parent `2d34f65f`.

After each completely accepted bounded burst, the driver now returns to its
input/command/timer selection before refilling. Retained partial sends and
WouldBlock handling are preserved. Two tests fail on the exact parent source;
after correction all eight SACK-count/RACK, ordinary/wrapping-sequence and
reverse-data subcases deliver exact bytes, with ready inbound queue wait bounded
by one observed local admission. These are reliable-stream transport ACKs;
this test does not measure audio RTCP or acoustic latency.

All **108 stream tests**, **56 FFI anonymous-stream tests**, all-target
stream/FFI Clippy, rustfmt and diff checks pass. Production Mac and Android
SDKs retain the same **198 SDK export names**. No burst size, rate, timer bound,
queue budget, wire field, relay priority or mailbox policy changed.

### Cellular file checks and preceding-SDK control

The same QA identities and unchanged frontends/media engines were used. Phone
Wi-Fi was off, cellular routing was verified and own-contact P2P was denied.
All recorded opens were anonymous.

| SDK/run | Direction | Size | Download | Pull requests | Result |
| --- | --- | ---: | ---: | ---: | --- |
| Current | Phone → laptop | 4 MiB | **Incomplete in 180 s** | 3 | Two manifest-phase failures; final integrity unverified |
| Current | Laptop → phone | 4 MiB | 14.963 s | 1 | Integrity matches |
| Current | Laptop → phone | 32 MiB | **124.497 s** | 1 | Integrity matches |
| Current | Phone → laptop | 32 MiB | **Incomplete in 180 s** | 1 | Final integrity unverified |
| Parent `2d34f65f` | Phone → laptop | 4 MiB | **Incomplete in 180 s** | 3 | Manifest failure, payload-idle event and a queued 512-KiB resume request; final integrity unverified |
| Parent `2d34f65f` | Phone → laptop | 32 MiB | **Incomplete in 180 s** | 2 | Queued 8.75-MiB resume request; final integrity unverified |
| Current, diagnostic only | Phone → laptop | 4 MiB | 48.414 s | 2 | Integrity matches after one manifest-phase retry; separate 60-s capture window |

The parent also fails in the affected direction, so the new fairness correction
is not necessary to reproduce it. That is not proof of universal performance
parity. The successful shorter diagnostic capture does not replace either
failed 180-second gate. Final harness cancellation/reset is kept in inclusive
attempt counts and is not independently counted as a product timeout. Resume
requests are read from actual `request sent ... resume=` log entries; a final
resume-point checkpoint alone does not prove another request was sent.

### Where the diagnostic capture locates remaining local wait

The phone's existing session trace was enabled through its API for the separate
short capture, then disabled at cleanup. No scheduling setting was changed.
Its **42** sampled DATA admission reports used an independent **ordered record
transport**. The observed outbox-to-transport maximum was **363.296 ms**, the
record-queue maximum **178.343 ms**, and the record-write maximum **186.626 ms**.
They concern different observations and **must not be added**. The capture alone
does not identify the underlying IP transport or prove high ping/packet loss.

Those reports had zero reported buffer/bandwidth-drop and capacity-deferral
counters. Ten source admission samples reported `primary_active=false`;
the capture gives no basis to blame protection for active audio. This was a
**successful** capture, not the prior failed transfer: a failing capture is
still needed to identify what holds authored DATA before the ordered writer.
No queue budget was increased on the strength of this observation.

The driver's sampled pending-outbound waits can still include a cold circuit
open and are distinct from the ready-inbound starvation fixed here. Sources,
frozen SDKs, installed APKs and loaded Mac libraries were verified. After each
of the three stands, own apps/captures exited, policies and diagnostics were
restored, and the exact original phone APK was restored and hash-checked. The
installed Mac app was unchanged. No call, live speech, Windows or complete
multi-device qualification ran.

## Previous follow-up — 23 October: receive reassembly across sequence wrap

SDK **`2d34f65f`**, after `2b1ab108`, fixes another confirmed receive-side defect.
[sequence-wrap-reassembly.json](sequence-wrap-reassembly.json) records four
parent failures and the corrected gates.

The gap queue used numeric `u32` key order. A future block just after zero
could sort before a ready block just below the maximum sequence, preventing
the latter from draining. A 24-byte synthetic transfer exposed it: the
application received only **8 bytes**, although the remaining 16 were already
buffered and could be SACKed. This is not restricted to transferring 4 GiB:
the mux spreads initial byte sequences across the `u32` space.

Receive draining now uses modular order, with at most two BTreeMap lookups
per block rather than a scan of the entire gap queue. Actual missing bytes
still stop delivery; partial overlap and duplicate copies do not append bytes
twice. Ordinary SACK blocks are also iterated in serial order and coalesced
across zero. Four regressions fail on parent `2b1ab108` and pass after correction,
covering intact bytes, overlaps/duplicates, a real middle gap, and encoded SACK
ranges. Each includes an ordinary nonwrapping control.

All **106 stream tests** and **56 FFI anonymous-stream tests** pass, as do
all-target stream/FFI Clippy, rustfmt and diff checks. Production Mac and
Android SDKs build with the same **198 SDK export names**, and their source
fingerprints were checked. Timer limits, wire layout, relay scheduling and
mailbox policy are unchanged.

**The physical file runs below used SDK `2b1ab108`, before this correction.**
No app or call was launched for this follow-up. All six sampled stream initial
sequences from the failed file stand stay below the zero crossing for 32 MiB
plus one cell, so this defect does **not** explain that failed transfer.
Long-transfer stability, call/video quality, Windows and complete multi-device
qualification remain open. This core correction is supported by deterministic
state-machine/byte-order evidence, not a new physical-phone qualification.

## Previous follow-up — 23 October: RACK delivery accounting and duplicate feedback

SDK **`2b1ab108`** corrects the previously open RACK accounting defect.
[rack-duplicate-feedback.json](rack-duplicate-feedback.json) records the
regressions, mixed-version controls and every physical run, including a failed
large transfer. **The accounting correction is verified; long-transfer
stability and call/video quality remain open.**

### Correction and controls

The source-copy reproducer fails on parent `6875a88a`: a previously SACKed
original is reported again at cumulative ACK and manufactures a 90-ms late
delivery sample. The regression now runs in the normal production-source test
module as `rack_delivery_counted_once`. Already-SACKed originals no longer
re-enter RACK timing. New cumulative/SACK deliveries compare against the
frontier from before the ACK, so field iteration order does not create an
arrival chronology. The [original fixture](pending-rack-delivery.rs) is retained
as historical evidence.

Removing manufactured samples alone failed the existing multipath gate.
The receiver now optionally reports duplicate bytes in the first SACK range,
using the [RFC 2883 layout](https://www.rfc-editor.org/rfc/rfc2883.html#section-3).
A report only influences adaptation when it matches a recent, actually
handed-off retransmission. Queued-only, unmatched, stale and consumed reports
cannot inflate the allowance. No payload copies are retained: history is
bounded to 128 records, with 30-second timing evidence. New DATA does not erase
a pending duplicate report before ACK encoding.

As discussed in [RFC 8985](https://www.rfc-editor.org/rfc/rfc8985.html#section-6.2),
retransmission ambiguity can otherwise prevent learning real reordering.
This implementation uses matched duplicate-feedback span above recent
original-only minimum RTT, capped at the existing RTO when learned, with one
update per send round and expiry after 16 DSACK-free recovery exits. It is a
RACK-like multipath adaptation, **not a claim of full TCP RACK compliance**:
the measured feedback span is an allowance, not an exact route RTT, and is not
the RFC's linear multiplier capped by SRTT. The existing RTO estimator policy,
timer limits, carrier floors, wire version/range capacity, mailbox policy and
relay scheduling are unchanged.

All **102 stream tests** (11 new regressions), **56 FFI anonymous-stream tests**
in the low-difficulty test feature set, and **29** in production features pass.
All-target stream/FFI Clippy, rustfmt and diff checks pass. Production Mac and
Android SDKs build with the same **198 exported SDK names**. The existing
zero-loss 100/500-ms two-path gate passes at **335 wire cells for 300 payload
cells**, below the unchanged strict limit of **383**, with intact bytes and no
DATA RTO. Existing real-loss and staggered-repair gates also pass.

### Mixed-version boundary

A source-copy control uses the exact parent engine through real encoded cells.
Both mixed directions complete intact, including a 20% loss control. With the
existing 1000-ms carrier floor, both mixed directions use 303 cells for 300
payload cells and have no DATA RTO. With **zero** floor, however, a current
sender talking to a legacy receiver uses **432** cells, above the new/new
limit; the receiver supplies no duplicate feedback. Parent sender/current
receiver uses 347. This is verified wire compatibility, **not equal adaptive
quality with legacy receivers**. Production's existing striped-route floor
is 1500 ms and was not increased.

### Physical files: current → parent control → current repeat

The same QA identities and unchanged production frontends/media engines were
used. Phone Wi-Fi was disabled, mobile data and a cellular default interface
were verified, and own-contact P2P was denied for each transfer. All recorded
opens were anonymous, with no direct stream.

| SDK/run | Direction | Size | Download | Pull requests | Result |
| --- | --- | ---: | ---: | ---: | --- |
| Current, initial | Phone → laptop | 4 MiB | 47.901 s | 3 | Integrity matches; two manifest-phase attempts failed |
| Current, initial | Laptop → phone | 4 MiB | 19.416 s | 1 | Integrity matches |
| Current, initial | Laptop → phone | 32 MiB | **Incomplete in 180 s** | 1 | Final integrity unverified |
| Current, initial | Phone → laptop | 32 MiB | **173.770 s** | 1 | Integrity matches |
| Parent control | Phone → laptop | 4 MiB | 27.273 s | 1 | Integrity matches |
| Parent control | Laptop → phone | 4 MiB | 27.224 s | 1 | Integrity matches |
| Parent control | Laptop → phone | 32 MiB | **97.442 s** | 1 | Integrity matches |
| Current, repeat | Phone → laptop | 4 MiB | 57.429 s | 1 | Integrity matches |
| Current, repeat | Laptop → phone | 4 MiB | 14.211 s | 1 | Integrity matches |
| Current, repeat | Laptop → phone | 32 MiB | **100.725 s** | 1 | Integrity matches |

No source payload-write-idle timeout was observed in these runs. The failed
large transfer's final reset accompanies harness cancellation and is retained
in inclusive attempt counts; it is not separately counted as a new product
failure. There was no positive-offset restart in the recorded pull requests.
The 180-second window was not extended. Neither the repeat nor the parent
control erases the failed initial gate. Sequential WAN observations do not
prove a speed gain or universal absence of performance regression.

Largest sampled local file-driver waits were **3503/855 ms** (laptop/phone) in
the first current run, **54/0 ms** in the parent control, and **28/697 ms** in
the current repeat. These are sampled handoff waits, not absolute queue maxima,
RTT or audio playout delay. They show that the run conditions differed; they
do not isolate the cause of the stalled transfer.

Sources, frozen libraries, installed APK and loaded Mac dylib were verified.
After each of the three stands, own app/capture processes exited, QA policies
and the diagnostic property were restored, and the exact original phone APK
was restored and hash-checked. The installed Mac application was unchanged.
No calls, camera, live speech, Windows or full multi-device qualification ran.
Public evidence contains aggregate metrics and synthetic fixtures only.

## Previous follow-up — 23 October: staggered repairs; open RACK accounting defect

[staggered-sack-repairs.json](staggered-sack-repairs.json) records SDK
`6875a88a`. **Separate repair deadlines are fixed and the physical file gate
passes this run. A newly validated RACK accounting defect remains open; its
attempted timing correction failed an existing reordering gate.**

### Completed correction

The previous repair scan correctly excluded a retry whose own handoff had not
yet expired. If retries were handed off in different pacing ticks, however,
their expiry could trail the oldest hole by only a few milliseconds and still
inherit another exponentially backed-off RTO. Two real-driver regressions fail
on parent `92b83e48`: one for RACK and one for SACK-count recovery. An
acknowledged prefix warms pacing, and three originals plus their first repairs
are lost in separate one-cell ticks. Both normal and wrapping sequences pass
after correction, without replaying the SACKed tail.

A circuit RTO now retains individual deadlines for the already-proven holes.
Their expiry continues the existing repair decision without another network
RTO event, congestion cut or premature repetition of fresh cells. SACK,
cumulative ACK, a new emitted/handed-off retry and a no-SACK rewind clear stale
state. Per-segment metadata remains bounded by the existing flight. A cached
minimum avoids scanning that flight during ordinary send/timer polls when no
deferred repair exists. No protocol format, RTO bound, retry cap, relay priority
or mailbox policy changed.

### Gates and physical observations

All **91 stream tests** and **56 FFI anonymous-stream tests** pass, along with
all-target stream/FFI Clippy, rustfmt and diff checks. Production Mac and Android
builds retain the same **198 SDK export names**. Sources, frozen SDKs, installed
phone APK and loaded Mac library were verified. After the rejected experiment
below, every authoritative source fingerprint again matches that exact
physically verified SDK, and the final 91-test stream gate passes again.
Frontends and production media engines were unchanged.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 25.557 s | 1 | Integrity matches |
| Laptop → phone | 4 MiB | 14.962 s | 1 | Integrity matches |
| Laptop → phone | 32 MiB | **155.773 s** | 1 | Integrity matches |

The phone used cellular with Wi-Fi off and own QA-contact P2P denied. All
recorded opens were anonymous. All three transfers completed inside the
unchanged **180-second window**, with no failed pulls, source write-idle
timeouts, application resets or resumes. This does not isolate a speed gain
from WAN variation or certify long-transfer stability. The large reverse file
passed; the 32-MiB phone-to-laptop case was not rerun on this SDK.

Largest sampled local driver waits were **61 ms on the laptop** (179 samples)
and **13 ms on the phone** (173 samples), not absolute maxima or RTT. No calls,
camera, audio playout, Windows run or full multi-device qualification occurred.
QA policies and the diagnostic property were restored, own apps/captures
exited, and app process absence was verified. The exact original phone APK was
restored and hash-checked; owned phone fixtures were removed. The installed
Mac app was unchanged.

### Open finding: previously SACKed originals counted again by RACK

A source-copy regression confirms that the cumulative-ACK loop calls the RACK
delivery recorder for an original that was already reported by SACK. After a
newer original establishes a later frontier, replaying that old report creates
a **90-ms reordering sample without a new late delivery**. The reviewable
[expected-failing reproducer](pending-rack-delivery.rs) uses real local-handoff
metadata transitions and synthetic bytes. It is not counted as a passing or
ignored production test. RACK's delivery processing concerns newly reported
segments; see [RFC 8985, section 6.2](https://www.rfc-editor.org/rfc/rfc8985.html#section-6.2).

An experimental correction separated newly reported deliveries, ACK field
order and first-SACK RTT sampling. It completed the existing zero-loss
100/500-ms two-path simulation with intact bytes, but used **502 cells for
300 payload cells**, violating the unchanged strict limit of **383**. A control
retaining the original cumulative-ACK RTT policy and changing only RACK still
used **432 cells**. These findings suggest the existing adaptation needs work
beyond removing duplicate accounting. The experiments were not retained; the
passing SDK above contains only the completed deadline correction. Changing
RTT sampling policy is not presented as a separately resolved defect.

This RACK finding remains open. Its correction must preserve adaptation to
real reordering, without depending on manufactured samples or weakening the
existing gate. Public evidence contains aggregate observations and a synthetic
fixture, without observed identifiers, keys, addresses, paths, packet sequences,
raw captures or file hashes.

## Previous follow-up — 23 October: several lost retransmissions

[expired-sack-repairs.json](expired-sack-repairs.json) records SDK `92b83e48`.
**Two recovery defects are corrected. The reverse 32-MiB file completes this
run; long-transfer stability and call quality remain unqualified.**

### Controlled defects and corrections

With several head gaps and a received/SACKed tail, the sender initially repairs
the gaps together. If those repairs are lost again, their permanent
`retransmitted` marker excludes them from the SACK-count loss scanner. Circuit
RTO recovery then marks only the oldest gap. The others wait for another
exponentially backed-off RTO, even though enough higher data is already known
to have arrived. One core regression and real-driver regressions for both RACK
and SACK-count recovery fail on parent production source `b691e21d`.

At a circuit SACK RTO, recovery now also marks already-retransmitted holes whose
last actual handoff is at least the **expired, pre-backoff RTO** old, and which
have at least three higher SACKed segments. This preserves Karn's permanent
marker while separating it from a decision to repair again. Recent, unhanded
and locally pending cells remain excluded. The normal pacer, congestion-window
policy, RTO bounds and retry cap remain unchanged. No-SACK rewinds and classic
non-circuit RTO handling retain their existing behavior.

The driver fixture loses three head originals and their first repairs after
real local handoff. Five tail segments arrive and are SACKed. With the fix,
all three heads complete within one 100-ms RTO plus paced delivery, before an
additional 200-ms backed-off wait could fire. Each head is sent exactly three
times; each tail once. Both recovery modes and modular sequence wrap pass.
Controls check fresh/pending/unhanded repairs, a tail without sufficient SACK
evidence, the Karn marker and the classic-mode behavior. Staggered repair ages
and additional loss schedules still require qualification; the predicate does
not claim every outstanding segment has expired when only the oldest has.

A separate late-SACK regression failed in the intermediate implementation:
ACK admission, still unchanged from the parent, left a `needs_resend` decision
set after a late original was reported received. SACK admission now cancels
that marked but **not yet emitted** repair. It does not recall a duplicate
already admitted to the carrier. No relay media classification, transit
priority, mailbox policy, protocol format or production test hook was added.

### Gates and physical evidence

All **86 stream-module tests** and **56 FFI anonymous-stream tests** pass, along
with all-target stream/FFI Clippy, rustfmt and diff checks. Production Mac and
Android SDK builds retain the same **198 SDK export names**. Sources, frozen
SDKs, installed phone APK and loaded Mac library were verified before and after
the ordinary stand. Frontends and production media engines were unchanged.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 15.473 s | 1 | Integrity matches |
| Laptop → phone | 4 MiB | 22.212 s | 1 | Integrity matches |
| Laptop → phone | 32 MiB | **149.145 s** | 1 | Integrity matches |

The phone used cellular data with Wi-Fi off; own QA-contact P2P was denied.
All recorded opens were anonymous, with no direct stream. All three transfers
completed inside the unchanged **180-second window**, without failed pull
attempts, application resets, source payload-write-idle timeouts or resume
offsets. This is one successful reverse large-file run after the prior failure,
not proof of stable large-file completion or an isolated throughput gain from
this correction. The exact previous WAN loss schedule was not replayed. The
32-MiB phone-to-laptop direction was not rerun on this SDK.

Largest sampled local driver waits were **18 ms on the laptop** (169 samples)
and **176 ms on the phone** (164 samples). They are event-driven observations,
not absolute delay maxima or RTT measurements. No calls, camera, audio playout
or speech tests ran; the full multi-device and Windows reports remain outside
this cycle's qualification.

QA policies and the temporary Android diagnostic property were restored. Own
apps and captures exited, with process absence checked independently. The exact
original phone APK was restored and hash-verified, owned phone fixtures were
removed, and the installed Mac app was unchanged. Public evidence contains
aggregate values only, without identifiers, keys, addresses, paths, packet
sequences, raw captures or file hashes.

## Previous follow-up — 23 October: mailbox-only discovery cache

[stream-discovery-cache.json](stream-discovery-cache.json) records SDK
`b691e21d`. **A controlled cold-discovery delay is fixed. Established-stream
stalls remain, and the reverse 32-MiB file again fails the 180-second gate.**

### Controlled defect and correction

The previous physical wait was in `SynSent`: the related logs repeatedly
reported nine valid ads, all using mailbox cookies, without any stream ad.
The general positive rendezvous cache could preserve that unusable-for-streams
answer for 15 seconds. A real SDK API regression confirms the mechanism: an
initial lookup caches a valid signed mailbox ad; a new independently signed
stream slot is then available in the DHT, but another lookup after 1.1 seconds
still returns only the mailbox ad. The regression fails against parent
production source `198258ae` and passes after correction.

Resolution now distinguishes ordinary callers, stream callers and background
refresh-ahead. For a stream caller, a mailbox-only result is reused for only
one second before comparing the DHT replicas again. A usable stream result and
ordinary callers retain the existing cache TTL. Classification excludes both
the device-derived mailbox cookie and the known identity mailbox cookie at a
device address. No mailbox registration is used as a stream route. Signature,
delegation, validity and expiry checks remain unchanged.

Per-recipient locking is rechecked using the caller's cache policy. A real
recursive-query/outbox fixture confirms that eight immediate retries add no
network walks and eight concurrent waiters after the miss expires share one
full-slot refresh batch, all discovering the new stream ad. Cache controls
verify that a stream miss neither deletes valid mailbox routes nor breaks the
last-known-valid deposit fallback; an expired stream ad cannot make the
remaining mailbox set usable for streams. Empty lookup results retain their
existing behavior; this fix specifically concerns positive mailbox-only sets.

### Gates and physical observations

The runtime rendezvous test filter passes **31 tests**, and the anonymity-state
filter passes **15 tests** (one test overlaps the filters). All **56 FFI
anonymous-stream tests** pass. After tightening the regression fixture's
shutdown assertion, its final API regression also passes. Runtime/FFI all-target
Clippy, rustfmt and diff checks pass. Production Mac and Android SDK builds
retain the same **198 exported SDK function names**. Sources, frozen SDKs,
installed phone APK and loaded Mac library were verified before and after the
stand. Frontends and production media engines were unchanged; no production
test hooks were added.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 54.430 s | 2 | Integrity matches after one source application-progress timeout/reset |
| Laptop → phone | 4 MiB | 19.049 s | 1 | Integrity matches |
| Laptop → phone | 32 MiB | **Incomplete at 180 s** | 2 | Last reported committed prefix 17,039,360 bytes (16.25 MiB); final integrity unverified |

All recorded opens were anonymous, with no direct stream; the phone used
cellular data with Wi-Fi off and own QA-contact P2P denied. The first source
stopped at 262,144 queued payload bytes after a 30-second write-progress wait;
its application reset caused a fresh pull, which completed. The large-file
source likewise stopped at 15,990,784 queued payload bytes. Its receiver
recorded a 15-MiB resume point, retried, and reached the final 16.25-MiB prefix.
The second large-file failure entry is final harness cancellation; it is not
another independently observed product timeout. No no-manifest or receiver
payload-idle failure was logged in these cases. The source-side progress
timeouts and the receiver's application-reset errors are recorded separately.

The largest sampled local driver handoff waits were **18 ms on the laptop**
(169 samples) and **469 ms on the phone** (163 samples). No mailbox-only
stream-discovery miss was logged in this run. These event-driven samples do
not establish absolute wait maxima, network RTT or a universal speed gain;
path variation is not isolated. In particular, the previous SDK's successful
122.474-second reverse file does not qualify this failed run or rule out a
regression. The remaining stall is after stream establishment, with outstanding
bytes and out-of-order receive data; it still requires controlled diagnosis.
The cache correction does not claim to repair it.

QA policies and the Android diagnostic property were restored. Own apps and
captures exited, with process absence checked independently. The exact original
phone APK was restored and hash-verified, owned phone fixtures were removed,
and the installed Mac app was unchanged. No calls, camera, audio playout or
subjective speech tests ran. Public evidence is aggregate only, without
identifiers, keys, addresses, paths, packet sequences, raw captures or file
hashes.

## Previous follow-up — 23 October: stream IDs across unilateral hub restart

[stream-restart-collision.json](stream-restart-collision.json) records SDK
`198258ae`. **A controlled restart failure is corrected, and the previously
failing reverse 32-MiB file passes this run. Cold local path waiting and broader
file/call reliability remain open.**

### Controlled reproduction and corrections

Every hub previously began allocating stream IDs from the same value. If only
one endpoint restarted while its peer retained the old stream, the fresh SYN
reused that peer's old demux route. No new application accept occurred, even on
a perfect network. Two real async mux/driver regressions reproduce this for
both node-order/parity cases against the parent production source. The old
source generation is blackholed before dropping it so graceful FIN/RST cannot
clean up the still-live remote stream. After correction, a fresh accepted
stream exchanges the exact new request/reply bytes and the old application
stream receives none of them.

All hubs now share a process-wide allocator, so hub recreation does not restart
the sequence. Its initial value comes from OS randomness when the process
starts. Direction parity and the existing wire format remain unchanged. The
31-bit counter namespace is finite: random seeding removes deterministic
process-restart reuse, **not all possible collisions with remote retained
state**. The controlled restart test covers hub recreation within one process;
it is not an exhaustive cross-process namespace test.

Two related controlled defects are also corrected. Opening a stream after 64
occupied ID probes previously overwrote a live route. Allocation now installs
only into a vacant entry. A test retaining 65 route owners across counter wrap
fails before the fix and preserves every owner afterward. An opening engine
also accepted a SYN_ACK that did not acknowledge its own SYN and disabled
handshake recovery. It now requires the exact SYN ACK, including sequence wrap;
invalid older/future values leave it waiting with recovery still enabled.
That regression also fails on the parent production source. No relay priority,
media classification, mailbox policy, pacing limit or timeout was changed.

### Gates and physical evidence

All **81 stream-module tests** and **55 FFI anonymous-stream tests** pass. The
FFI gate includes `node-embedded,packet-tunnel,test-low-difficulty`, exercising
real circuit/outbox fixtures. All-target stream/FFI Clippy passes with those
features, as do formatting and diff checks. Production Mac and Android SDK
builds retain the same **198 exported SDK function names**. Sources, frozen
libraries, installed phone APK and loaded Mac library were verified before and
after the stand. Frontends and production media engines were unchanged, and no
production test hooks were added.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 17.204 s | 1 | Integrity matches |
| Laptop → phone | 4 MiB | 16.910 s | 1 | Integrity matches |
| Laptop → phone | 32 MiB | **122.474 s** | 1 | Integrity matches |

These transfers used cellular data with Wi-Fi off and own QA-contact P2P
denied. Every recorded open was anonymous, with no direct stream. All three
completed within the unchanged **180-second window**, with no no-manifest or
payload-idle failure. There were no resumption offsets or failed attempts.
This is one successful reverse large-file run, not proof of stable large-file
completion or a performance gain caused by this specific correction. The WAN
run does not reproduce the controlled source-restart packet schedule. The
32-MiB phone-to-laptop case was not rerun on this SDK.

The largest sampled local driver carrier wait was **7,584 ms on the laptop**
(144 samples), versus **178 ms on the phone** (134 samples). The large laptop
samples were in `SynSent`, with one retained initial cell, growing local
WouldBlock retries and no network handshake RTO. They show an unresolved cold
local path availability wait, **not a 7.6-second RTT** or a proven DATA outbox
stall. No new correction for this wait is claimed. No calls, camera, audio
playout or subjective speech checks ran in this cycle.

QA policies and the temporary Android diagnostic property were restored. Own
apps and captures exited; app process absence was checked independently. The
exact original phone APK was restored and hash-verified, owned phone fixtures
were removed, and the installed Mac app was unchanged. Public evidence contains
aggregate values without identifiers, keys, addresses, paths, packet sequences,
raw captures or file hashes.

## Previous follow-up — 23 October: receiver binding survives path recovery

[stream-receiver-lifetime.json](stream-receiver-lifetime.json) records SDK
`f46e6ae5`. Two controlled regressions fail with the exact parent source:
first ACK selection can choose another receiver, and stale path eviction can
forget the original receiver. Receiver cookie and protected public key now
remain bound for the stream lifetime, including independent ACK selection,
cache pressure, ACK copy recovery and slow-path replacement. A protected
binding cannot downgrade; legacy cookie-only matching remains compatible.
Unknown ACKs do not guess a receiver. Close releases the binding for a new
stream lifetime without disturbing other streams.

The route cache and separate public receiver metadata each retain a 4096-entry
bound. Cache pressure evicts optional ACK pins, preserving live Bulk pins and
accounting; a bound ACK can operate uncached. New-stream admission waits when
capacity is exhausted. Concurrent same-class selections now reuse the pin
committed while they waited and count only one active stream. That accounting
regression failed before the final cache recheck in this cycle; unlike the two
receiver regressions, its recorded failing run used an intermediate source.

All **55 FFI anonymous-stream tests** pass, together with all-target FFI Clippy,
formatting and diff checks. Production Mac and Android SDK builds pass with the
same **198 export names**. The earlier 77 engine tests were not rerun this cycle.
Sources, frozen libraries, installed phone APK and loaded Mac library were
verified. Frontends and production media engines were unchanged.

| Direction | Size | Download | Result |
| --- | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 29.153 s | Integrity matches |
| Laptop → phone | 4 MiB | 27.794 s | Integrity matches |
| Phone → laptop | 32 MiB | 123.385 s | Integrity matches |

These anonymous-stream transfers used cellular data with Wi-Fi off and own
QA-contact P2P denied. All completed within the unchanged 180-second window.
**The previously failing reverse 32-MiB transfer was not rerun and remains
open.** These observations do not establish a general speed improvement or
qualify the mixed-receiver A/B/C matrix. No calls or audio/camera tests ran.

QA policies and the Android diagnostic property were restored. Own apps and
capture processes exited; app process absence was verified. The exact original
phone APK was restored and hash-checked, owned phone fixtures were removed,
and the installed Mac app was unchanged. Public evidence contains aggregate
values only.

## Previous follow-up — 23 October: bound DATA paths and full local outboxes

[bound-data-fallback.json](bound-data-fallback.json) records SDK `4f27eba6`.
**Three DATA routing/admission defects are corrected. The reverse 32-MiB file
still does not complete in 180 seconds; general file and call quality remain
unqualified.**

### Controlled defects and corrections

Normal stripe candidate selection checked path/session health but did not check
that the candidate served the stream's exact receiver. A pool containing a
different receiver cookie or protected receiver key could select that entry
before a matching one. Candidate selection now applies the existing receiver
binding predicate before consuming its candidate limit. This covers DATA
stripes and their new local-capacity fallback; it is not certification of all
other ACK selection, cache eviction or stream recovery paths.

A full primary outbox was also treated as a terminal error for the entire
striped burst. Consequently a healthy alternate later in that burst was never
tried. Queue-full now stops only that stripe, preserving its exact unsent cells
in order while other stripes make progress. Other streams' queued suffixes
remain untouched. Local fullness does not quarantine a network route.

Finally, retained DATA below the normal striping quantum retried only the
sticky primary. When that outbox stayed full, a ready independent path could
remain unused indefinitely. On actual primary queue-full, the short/unstriped
send path now tries the bounded pool of already-open, live, non-stale,
non-cooled routes to the same receiver with distinct first hops. A failed
candidate does not stop the search for a later ready path. This is local
recovery even when ordinary striping is disabled, without changing that setting.
Only actual local admissions consume queued cells and update send activity.
When all eligible queues are full, every unaccepted cell remains queued; an
already accepted prefix is counted exactly once. Missing-session health and
fatal oversized-cell handling remain distinct.

All three new regressions fail with the previous implementation. Their fixtures
use real runtime circuits, signed relay-directory entries and genuinely full
bounded local outboxes, without public network connections. Controls cover
wrong cookie/key, a full first alternate followed by a ready third path,
accepted prefixes, unrelated suffixes and the all-full case. The existing
private DATA recovery lane and **INTERACTIVE wire priority** are checked; no
relay media classification, transit priority, mailbox policy, protocol format,
network-RTO constant, pacing budget or queue ceiling was added or relaxed.

### Gates and physical observations

All **47 FFI anonymous-stream tests** pass. FFI all-target Clippy and rustfmt
are clean. Production Mac and Android SDK builds pass, retaining the same
**198 SDK export names**. Sources, frozen SDKs, installed APK and loaded Mac
library were verified before and after the ordinary physical stand. Frontends
and production media engines were unchanged; the phone contains no earlier
credit-rejection probe. No calls or synthetic media were used.

The phone used cellular data with Wi-Fi off. Own QA-contact P2P was denied for
these transfers and restored afterward. Every recorded open was anonymous,
with no direct stream. The observation window remains **180 seconds**.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 24.786 s | 2 | SHA-256 match; one initial no-manifest failure |
| Laptop → phone | 4 MiB | 15.438 s | 1 | SHA-256 match |
| Phone → laptop | 32 MiB | **109.504 s** | 1 | SHA-256 match, no payload-idle retry |
| Laptop → phone, additional large-file check | 32 MiB | **Incomplete at 180 s** | 2 | 25,165,824-byte committed prefix at harness cancellation; final hash unverified |

The failed reverse run had one initial no-manifest failure. Its second
failure-log entry is final harness cancellation, not an additional independent
product timeout. No payload-idle failure was observed in these four cases.
The largest sampled driver carrier waits were **21 ms on the laptop** (295
samples) and **368 ms on the phone** (273 samples). These measure waiting until
some path accepts pending cells; they are not absolute per-first-hop queue ages
or end-to-end delay. Different WAN runs do not isolate network variation,
establish a universal speed improvement, or rule out a performance regression.
The successful phone upload does not qualify large-file completion in both
directions, cold startup or the full A/B/C multi-device matrix.

QA policies and the temporary Android diagnostic property were restored and
verified. Both apps and captures exited, with process absence checked
independently. The exact original phone APK was restored and hash-verified;
owned phone fixtures were removed. The installed Mac app was unchanged. Public
evidence contains only aggregate values, without endpoint identifiers, keys,
addresses, paths, packet sequences, raw captures or file hashes.

## Previous follow-up — 23 October: byte duplication after a late partial ACK

[partial-ack-rewind.json](partial-ack-rewind.json) records SDK `c56e1aee`.
**A reliable-stream byte-duplication mechanism is corrected. Long waits,
repeated opens and the 180-second file gate remain unresolved.**

### Reproduction and source correction

The earlier `invalid content stream credit` line did not distinguish malformed,
duplicate or unexpectedly advancing credit. A temporary phone-only diagnostic
frontend, built outside the repository, classified two rejections as **duplicate
credit**, with **262,144 outstanding bytes** and `finishing=false`. This was an
ordinary application credit wait, rather than only final close. Its measurement
contained numeric credit state for isolated QA transfers, not message contents,
keys or user recordings. No validation check was relaxed.

A controlled transport exchange reproduces that exact failure shape. An
original eight-byte credit arrives but its ACK is delayed. No-SACK RTO recovery
coalesces it with new bytes into a larger retransmission. The old ACK then
covers only the beginning of that larger segment. On the next no-SACK RTO,
recovery copied the whole segment back to the pending queue at the advanced
send offset, **renumbering already acknowledged bytes as new application data**.
The peer consequently receives the same credit twice. Forward application
payload can be affected by the same generic mechanism; this is a byte-stream
correction, not a special case that ignores duplicate credits.

Recovery now excludes each segment's prefix below the cumulative acknowledged
offset when rebuilding pending bytes. Existing segment boundaries remain valid
for ordinary retransmission. Modular sequence arithmetic handles wraparound.
No protocol, window, network-RTO constant, relay scheduling or application credit
validation changed. The field packet schedule was not reconstructed; the
controlled reproduction proves this mechanism produces the observed rejection,
not that it explains every field failure.

Both new regressions fail with the exact previous engine source and pass with
the correction restored. One covers both RACK modes and modular sequence wrap.
The other drives the real async driver/local-handoff path with delayed original
ACK, lost coalesced retransmission and pending new tail. It asserts that the
larger retransmission was actually formed, and checks the complete received byte
sequence through clean closure, so a fixture missing the failure conditions
cannot silently pass.

### Gates and ordinary physical stand

All **77 stream tests** and **44 FFI anonymous-stream tests** pass. Stream
all-target Clippy and rustfmt are clean. Production Mac and Android SDK builds
pass with the same **198 SDK export names**. Current sources, frozen libraries,
installed APK and the Mac process's loaded SDK were checked before and after
physical verification. The final stand uses ordinary frontends and native media
engines. Its phone application has no diagnostic-probe marker; the disposable
Dart source was restored and the owned probe APKs removed. No calls, synthetic
media or PCM overlays were used.

The phone used cellular data with Wi-Fi off. P2P was denied for the own QA
contacts during these cases and restored afterward. All recorded opens were
anonymous, including probes/reopens; no direct stream was used.

| Direction | Size | Observation window | Download | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 180 s | 65.920 s | SHA-256 match after a payload-idle resume at 1,572,864 bytes |
| Laptop → phone | 4 MiB | 180 s | 13.520 s | SHA-256 match, one pull request |
| Phone → laptop | 32 MiB | 180 s | **Incomplete** | 31,457,280-byte committed prefix at harness cancellation; final hash unverified |
| Separate phone → laptop run | 32 MiB | 600 s | **262.745 s** | SHA-256 match after recovery |

The extended observation verifies eventual completion in that separate run. It
**does not pass the 180-second gate or establish a speed improvement**. It still
needed **15 pull requests**, including **13 no-manifest failures** and one
payload-idle resume at **14,417,920 bytes**. The ordinary stand recorded zero
`invalid content stream credit` lines in its retained endpoint snapshots, but
cold-open failures, long queue waits and recovery remain present. The largest
sampled local carrier waits across the ordinary runs were **3,024 ms on the
laptop** (329 samples) and **35,288 ms on the phone** (450 samples). These are
sampled local waits, not absolute maxima or end-to-end latency.

Policies and the temporary Android diagnostic property were restored and
verified. Both apps and owned captures exited; process absence was checked
independently. The exact original phone APK was restored and hash-verified,
owned phone fixtures removed, and the installed Mac app left intact. Only
allow-listed aggregates are published here. Raw captures, endpoint identifiers,
addresses, paths, keys, packet sequences and file hashes remain private.

## Previous follow-up — 23 October: graceful close and final local ACK handoff

[stream-close-handoff.json](stream-close-handoff.json) records SDK `097e373b`.
**The 32-MiB anonymous upload is still incomplete at the 180-second observation
deadline. General file reliability and physical audio/video quality are open.**

### Two reproduced local defects

The FFI's ordinary stream close releases both application halves gracefully.
However, the driver reset the stream when late reverse-direction bytes arrived
without a reader. A controlled peer's final eight-byte credit reproduced this:
queued payload was delivered, followed by an unwanted APP reset. The driver now
drains/discards late received bytes only when both application halves are gone,
while completing queued writes and transport acknowledgements. Dropping only
the reader while keeping a writer retains its previous abort behavior.

The driver also retired after both byte directions completed even when its last
ACK remained locally rejected by the carrier. The peer then had no confirmation
of its final credit/FIN. Retirement now waits for that local ACK handoff. A
permanently unavailable carrier is bounded by the existing retry-policy ceiling
(maximum RTO times retry count plus one), rather than leaking a detached task.
Local waiting does not generate a network-RTO event; explicit reset remains
responsive. This does not guarantee delivery after a carrier accepts an ACK and
it is subsequently lost in the network.

Both regression cases fail on the previous source. The reader-only-drop
control passes before and after the correction. The new five-test suite also
checks exact queued payload, received credit, clean EOF, cancellation and the
permanent-backpressure bound. These are controlled async driver exchanges,
not a claim that a particular WAN stall has been eliminated.

### Gates and physical qualification

All **75 stream tests** and **44 FFI anonymous-stream tests** pass, with
all-target Clippy and rustfmt clean. Production Mac and Android SDK builds pass;
the same **198 SDK export names** are retained. Current sources, frozen SDKs,
installed APK and the Mac process's loaded library were verified before and
after physical testing. Ordinary frontends/media engines were unchanged; no
synthetic media, PCM probes or calls were enabled. No wire format, relay media
classification, transit priority, mailbox policy or network-RTO constant changed.

The phone used cellular data with Wi-Fi off. QA-contact P2P was denied for these
transfers and restored afterward. All recorded opens were anonymous; counts in
the JSON include manifest probes and retry opens.

| Direction | Size | Download | Pull requests | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 34.209 s | 2 | Exact SHA-256 match after resume |
| Laptop → phone | 4 MiB | 73.160 s | 3 | Exact SHA-256 match after resume |
| Phone → laptop | 32 MiB | **Incomplete at 180 s** | 3 | Final hash unverified; harness cancels the remaining attempt |

The large transfer recorded committed resume offsets of **29,884,416** and
**30,932,992 bytes**, not a verified complete file. One pull attempt failed
before obtaining its manifest; failure-log counts also include final harness
cancellation. The small reverse transfer likewise had one no-manifest failure.
No general speed improvement is established; these runs were slower than the
preceding small-file run and do not isolate network variation or rule out a
performance regression. The largest sampled local carrier waits were **335 ms
on the laptop** (207 driver samples) and **14,750 ms on the phone** (264 samples).
These are sampled local waits, not end-to-end latency or absolute maxima.

During this sequence the phone's serving log recorded **two `invalid content
stream credit` failures**. The exact cause of those rejected application credits
is not yet established. Their validation was not weakened, and correcting local
stream close is not claimed to have resolved them. This is a concrete next
investigation alongside the remaining local queue stalls and network ACK loss.

Both owned app processes and captures exited. Policies, the temporary Android
diagnostic property and exact original phone APK were restored and checked;
owned phone file fixtures were removed. The installed Mac app was unchanged.
Only aggregate evidence is published here; raw captures, identifiers, keys,
addresses, packet sequences and file hashes remain outside the repository.

## Previous follow-up — 23 October: ACK fallback after local queue rejection

[ack-copy-fallback.json](ack-copy-fallback.json) records SDK `99d0fa17`.
**Large-file stalls and physical audio/video failures remain unresolved.**

ACK redundancy selected its limited candidate set before trying local enqueue.
When the primary and first alternate shared a full first-hop outbox, a healthy
third path was never tried. A controlled regression using real runtime circuits,
signed directory entries and genuinely saturated ordinary outboxes fails with
the old implementation and passes with the correction. Candidates now consume
the copy budget only after an actual enqueue. An all-full control preserves
the pending ACK and reports backpressure; it does not manufacture acceptance.

Alternates must retain the primary's receiver cookie and protected receiver
key. Without an ACK route, the stream's existing Bulk binding supplies these
constraints; missing binding does not authorize a guessed destination. Tests
cover both binding sources, wrong cookies/keys, and the successful-copy limit.
The existing remapping predicate is shared without changing its semantics.
The ordinary local and wire priority remains INTERACTIVE. No relay media
classification, new transit priority, mailbox policy, RTO or window change is
introduced. The controlled test proves the mechanism, not a healthy third path
in the physical run.

All **44 FFI anonymous-stream tests** pass; all-target Clippy and formatting
checks pass. Production Mac and Android SDK builds pass, with the same **198
SDK export names**. Frozen libraries, current sources, installed APK and the
Mac process's loaded SDK were checked before and after the transfers. Ordinary
frontends and media engines were unchanged; no calls or synthetic media ran.

| Direction | Size | Download | Attempts | Result |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 12.772 s | 1 | Exact SHA-256 match |
| Laptop → phone | 4 MiB | 15.005 s | 1 | Exact SHA-256 match |
| Phone → laptop | 32 MiB | **Timed out at 180 s** | 2 | Incomplete; final hash unverified |

The phone used cellular data with Wi-Fi off; all opens were anonymous, with no
direct stream. First request to validated manifest took 2.432, 0.591 and 2.372 s
respectively. Neither small transfer needed a payload-idle retry. The failed
large upload still had two failed attempts. The largest sampled local enqueue
waits were **4 ms on the laptop** (163 samples) and **5,052 ms on the phone**
(190 samples). These are approximately one-second driver samples, not absolute
maxima or end-to-end delays. Separate runs and different attempted payload
volumes do not establish a general speed improvement or a unique stall cause.

QA policies and the temporary Android diagnostic property were restored and
verified. Both owned app processes and captures exited. The original phone APK
was restored with an exact hash match, preserving data; owned file fixtures
were removed. The installed Mac app was unchanged. Public evidence contains
only aggregate values, not identifiers, keys, addresses or file hashes.

## Previous follow-up — 23 October: handshake timing and actual stream route recovery

[stream-route-recovery.json](stream-route-recovery.json) records SDK
`62d6b15d`. **Cold startup, long payload stalls and audio/video quality remain
open.** The controlled fixes below do not establish that the field stalls have
been eliminated; an unsuccessful large transfer is included in the evidence.

### Confirmed mechanisms and corrections

Tracked SYN/SYN_ACK timers started before the local carrier accepted them.
A **250-ms** local wait triggered a handshake network retry against a **50-ms**
test RTO, with no handoff. The async driver now tracks handshake handoffs as
well as DATA/FIN. Only a handed-off, unconfirmed handshake can report its network
timeout. A continuously rejected local handshake still closes after the
configured handshake retry budget, without manufacturing a network-loss event.
Real network retry caps remain active. A duplicate SYN after confirmation does
not rearm handshake recovery. Standalone sans-IO timing conventions are retained.

Handshake timeouts were also absent from the driver → mux → hub → circuit
recovery path. The notification now reaches the carrier. A controlled exchange
using the real driver, mux and SDK adapter loses its first locally accepted SYN,
then delivers the exact request/reply over an available alternate. Disabling
hub forwarding makes this same exchange fail; exact source is restored after
the control. This ready wire is controlled in memory, not a WAN latency test.

The existing non-quarantining DATA recovery removed a sticky route cache pin,
but the pool's handshake-membership index immediately selected **the same old
circuit**. A real-runtime regression reproduced this despite an available
alternate. Recovery now updates both indices atomically, using pool → route
lock order to prevent concurrent refill from retiring the selected target.
The affected Bulk pin and an ACK pin using the same old circuit move together;
other streams, their active counts and the shared pool are preserved. Missing,
closed, cooled or admission-full alternatives leave the current path in place.

The new recovery path also preserves the exact receiver cookie and protected
receiver key: a valid ad for another device or key generation does not own
this stream's reassembly state. An unguarded candidate failed this regression.
Both handshake and DATA recovery now reject those changes, while matching
protected receivers remap successfully. Membership retains its existing bound.
No relay media classification, transit priority, mailbox policy, wire format,
network RTO constant or queue/window ceiling changed.

### Gates

All **70 stream tests** and **42 FFI anonymous-stream tests** pass, including
both handshake roles, accepted network loss, local backpressure/cancellation,
the local retry budget, duplicate SYN, real mux forwarding, both route indices,
other-stream preservation and receiver binding. All-target Clippy and rustfmt
pass. Production Mac and Android SDK builds pass; the **198 SDK export names**
match the prior library. Ordinary stand frontends and native media engines are
unchanged. No synthetic media, new production test hooks or calls were enabled.

### Physical qualification and unresolved failure

The phone used cellular data with Wi-Fi off. All opens below were anonymous,
with no direct stream. Source hashes, frozen SDKs, installed APKs and the Mac
process's loaded library were verified for each build.

| Build / direction | Size | Download | First request → validated manifest | Result |
| --- | ---: | ---: | ---: | --- |
| Before receiver-binding guard, phone → laptop | 4 MiB | 104.367 s | 26.402 s | SHA-256 matches; four no-manifest timeouts and one other failed attempt |
| Before receiver-binding guard, laptop → phone | 4 MiB | 9.748 s | 0.760 s | SHA-256 matches |
| Before receiver-binding guard, phone → laptop | 32 MiB | **Timed out at 180 s** | 7.162 s | Not completed; final hash unverified |
| Final guarded SDK, phone → laptop | 4 MiB | 54.630 s | 3.177 s | SHA-256 matches after automatic resume |
| Final guarded SDK, laptop → phone | 4 MiB | 28.789 s | 1.158 s | SHA-256 matches |

The failed 32-MiB run had a **20-second payload idle timeout** after
**12,644,300 received bytes**, plus another failed attempt. The final guarded
phone upload also had one 20-second payload idle timeout before successful
resume. The final SDK was retested with the two 4-MiB files, not another
32-MiB upload. **General stream stalls and large-file completion are therefore
not qualified as fixed.** These separate runs cannot isolate network changes,
prove a speed improvement or rule out a performance regression. The controlled
handshake fixes are not established as the cause of the field cold-start delay.

QA policies were restored and verified after both runs. Both owned applications
and log captures exited; process absence was checked independently. The exact
original phone APK was restored and hash-verified, owned phone fixtures removed,
and the Android diagnostic property left unchanged. Public evidence contains
only aggregate values, with no raw identifiers, keys, addresses, paths, packet
sequences or file hashes. No subjective sound, video or multi-device partition
qualification is claimed by these file tests.

## Previous follow-up — 23 October: retain cells rejected by stale or failed circuits

[local-enqueue-retention.json](local-enqueue-retention.json) records aggregate
evidence for SDK `a84f3223`. The preceding local-handoff correction could not
help when the carrier falsely declared acceptance. Further actual adapter
branches did that: a stale scalar route returned success, a stale DATA run
drained its queue, and a non-queue enqueue rejection discarded unaccepted
scalar cells or the rest of a run. None had reached the local transport.

Those branches retain the exact cells and report local backpressure. Missing
routes use the existing 25-ms retry hint; full queues retain the ordinary
1-ms retry. An oversized envelope fails permanently instead of retrying or
quarantining a healthy route. An ACK actually accepted on an alternate can
still release the pending ACK. Accepted prefixes are accounted for even when
the next cell encounters a full queue.

Striped sends now preserve the concrete enqueue error and the relative order
of all unaccepted cells, ahead of unrelated queued suffixes. Previously a
missing route was reported to health tracking as queue-full, and a later full
queue could move earlier rejected cells behind its unsent tail. Healthy
stripes still make progress, and only actual handoffs update send activity.
The lossy media-datagram path, relay scheduling, wire format, C ABI, network
timeouts and queue/window ceilings are unchanged.

### Verification

The real pre-correction scalar function and rejection behavior were restored
temporarily: both stale-route and enqueue-rejection regressions failed.
Exact corrected source was restored afterward. Fixtures create real circuits,
signed directory entries and local session outboxes, without public network
connections. Each has a distinct identity and verifies its service binding.

All **37 FFI anonymous-stream tests** pass, including eight new controls for
healthy sends, retained controls/DATA, partial admission, actual queue-full,
non-prefix stripes, mixed missing/full routes, fatal oversize, and an ACK
accepted by an alternate. All-target Clippy and rustfmt pass. Production Mac
and Android SDK builds pass. Frozen inputs, the installed APK and the Mac
process's loaded SDK were verified before and after physical qualification.
The ordinary stand frontends and native media engines were unchanged; no
synthetic media or new production test hooks were enabled.

### Physical result and limits

The phone used cellular data with Wi-Fi off. QA-contact P2P was denied for
these anonymous-stream transfers, then restored and checked. All three files
passed final SHA-256 verification within the unchanged 180-second test window.

| Direction / size | Download | Requests | No-manifest timeouts | First request → validated manifest | Payload idle timeouts |
| --- | ---: | ---: | ---: | ---: | ---: |
| Phone → laptop, 4 MiB | 64.152 s | 7 | 6 | 54.655 s | 0 |
| Laptop → phone, 4 MiB | 35.573 s | 1 | 0 | 0.740 s | 0 |
| Phone → laptop, 32 MiB | 126.166 s | 2 | 0 | 0.928 s | 1 |

The large transfer resumed automatically after **20 seconds** without payload
progress at **25,367,940 bytes**, and the final file matched exactly. This is
successful recovery, not elimination of the stall. **Cold startup and general
stream stalls remain open.** Separate runs cannot isolate network variation,
establish a speed improvement or rule out a performance regression. This does
not certify every former large-transfer failure or any audio/video quality.

Both owned applications and the capture exited, independently checked after
cleanup. The exact original phone APK was restored and hash-verified; owned
phone file fixtures were removed. The Android diagnostic property was not
changed. No call or physical audio device was opened. Public evidence omits
identifiers, addresses, raw paths, keys, packet sequences and file hashes.

## Previous follow-up — 23 October: start network timers at local carrier handoff

[local-handoff-timers.json](local-handoff-timers.json) contains aggregate proof.
The async stream driver reserved DATA/FIN as network flight before the local
carrier accepted them. A controlled **250-ms** local block triggered a network
RTO despite **zero DATA handoffs**. This manufactured loss and could collapse
the sending window while the data was still waiting locally.

The driver now confirms accepted DATA/FIN using a bounded, reusable multiset
of sequence/span/type tokens, without copying their payloads. This handles
non-prefix acceptance by striped routes. The engine reserves window space at
poll time, but starts network timing on carrier acceptance. Locally pending
attempts cannot independently trigger RTO/RACK or accept impossible ACK/SACKs;
an earlier handed-off copy can still be acknowledged. Segment matching uses
one linear pass per handoff. Standalone sans-IO callers preserve their existing
poll-as-send convention; the async driver opts into tracking internally.

Selective repair preserves the local queue during no-SACK recovery. Tests
cover late valid ACKs after rewind, sequence wrap, FIN, and real accepted
network loss while another segment is locally blocked. A separate fix excludes
only the pacing wake-up while a committed outbound queue prevents further
polling: the old due pacing deadline could spin instead of waiting for the
carrier retry. Actual protocol deadlines remain active. Wire formats, C ABI,
network timeout constants, relay policy and window ceilings are unchanged.

All **65 stream tests** and **29 FFI anonymous-stream tests** pass, with clean
all-target Clippy and rustfmt. Three real-driver local-queue scenarios cover
**12 combinations** of RACK and no-SACK rewind. Real network loss still triggers
recovery and all recovered bytes match exactly. Production Mac/Android SDK
builds pass. Physical apps used unchanged ordinary frontends, verified frozen
SDKs and no native media test hooks. Only explanatory comments changed after
physical qualification; the expanded test matrix also passed.

### Physical result and remaining defect

Both directions used anonymous streams; the phone was on cellular with Wi-Fi
off. Each **4-MiB** file passed SHA-256. Phone → laptop took **53.277 s**, with
**3 manifest requests / 2 timeouts** and **18.814 s** to the validated manifest.
Laptop → phone took **39.153 s**, with one request, no manifest timeout and
**0.676 s** to the validated manifest. **The cold-start failure is still open.**
These runs do not establish a speed improvement. Carrier acceptance also
precedes possible SDK/OS queues and peer receipt; it is not a wire timestamp.
Other adapter branches that declare success after discarding a cell need
separate investigation. No call/audio-quality or large-file-completion claim
is made. Owned apps exited; the exact original phone APK, QA policies and
Android diagnostic property were restored and verified. Public evidence
contains no raw identifiers, addresses, file paths, keys or packet sequences.

## Previous follow-up — 23 October: retain cells while a stream route is cold

[cold-route-backpressure.json](cold-route-backpressure.json) contains only
aggregate evidence. SDK `b27aa766` corrects another first-manifest failure
mechanism. **General transfer throughput and audio/video quality remain open.**

### Confirmed mechanism and correction

The real circuit-backed `CellSender` returned success when route construction
had produced no usable circuit. Its scalar path discarded the cell; its DATA
batch path drained the entire unsent run. The stream engine had already
committed those cells to flight, so the driver could only recover through
network retransmission. A locally unsent SYN therefore paid the unchanged
**six-second handshake RTO**, even after the route became available.

Both no-ready-route paths now retain the exact cells and report local
backpressure. A typed local retry hint gives cold routes a **25-ms** cadence;
ordinary queue-full errors keep their **1-ms** retry. Hints are bounded to
1–1000 ms. The delay starts after the asynchronous send attempt returns and
uses the driver's timer selection, preserving cancellation/read processing.
Network RTOs and the wire format are unchanged. An ACK copy that was actually
accepted on an alternate path can release the pending ACK; it need not be
duplicated again on every local retry of an unavailable primary.

Two new regressions fail against the old production behavior: the actual
offline SDK adapter acknowledges/drains unsent controls and DATA; the actual
mux/driver then fails to deliver a request/reply within two seconds after a
controlled route becomes ready. With the correction, the same tests preserve
the exact distinct cells and complete the exchange. The ready wire in that
second test is controlled in memory; it is not a WAN latency qualification.

All **58 onion-stream tests** and **29 FFI anonymous-stream tests** pass.
Virtual-time tests cover the slower retry after an asynchronous send and
cancellation during backoff. Clippy for both packages with all targets and
rustfmt pass. Production Mac and Android SDK builds pass. The field apps use
unchanged frontends, ordinary native engines and verified current SDK binaries;
only the trait's explanatory documentation was clarified after qualification.

### Physical comparison

The phone remained on cellular with Wi-Fi off. Both downloads used anonymous
streams with QA-contact P2P temporarily denied; no direct stream was opened.

| SDK | File | Manifest attempts / timeouts | First request → validated manifest | Complete download | Verification |
| --- | ---: | ---: | ---: | ---: | --- |
| Prior `9bfa7190` | 4 MiB | 3 / 2 | 17.957 s | 47.218 s | Exact SHA-256 match |
| Corrected functions | 4 MiB | 1 / 0 | 1.957 s | 66.827 s | Exact SHA-256 match |

The prior driver snapshots include SYN_SENT at age **6002 ms** with no local
backpressure reported. The new run has no sampled SYN_SENT interval, which
does not prove an instantaneous handshake. The controlled regressions establish
the local discard defect; these separate field runs are consistent with the
startup correction but cannot isolate every network effect. **The complete
new download was slower.** These observations do not establish a throughput
improvement or rule out a performance regression. Long local queue waits and
their interaction with data retransmission timers still need controlled
qualification.

Both QA-contact policies were restored and checked. Owned applications and
capture processes exited; owned phone source fixtures were removed. The exact
original phone APK was restored and hash-verified, and the Android diagnostic
property returned to its pre-test value. No call or physical audio device was
opened. No raw stream id/sequence, identity, address, cookie, file path/name or
credential was exported.

## Previous follow-up — 23 October: stream rendezvous ordering and anonymous files

[stream-rendezvous-ordering.json](stream-rendezvous-ordering.json) records
aggregate proof only. SDK `9bfa7190` removes a compiled preference for one
relay from a historical public stand. Outbound stream construction also used
relay-id ordering after resolution, discarding the resolver's newest-first
criterion. When a partial refresh retains older valid fallback registrations,
that can promote an earlier process's receive circuit over a fresh one.

The endpoint now ranks by an explicit operator preference, then registration
freshness, then relay id. Equal entries retain resolver order. Per-relay
deduplication therefore keeps the newer cookie; normal signed-ad validation,
fallback retention and the existing circuit cooldown filters still apply.
The relay preference has no built-in default. The local operator override
remains available.

The current-registration regression fails with the **actual old comparator**
temporarily restored in the real FFI module; it passes with the correction.
The original source is restored unconditionally after that control. The final
anonymous-stream suite passes **27 tests**, including real circuit-feed ARQ,
local producer isolation and authenticated media ingress. Equal-generation
ordering, duplicate-relay cookies and an explicit operator preference are
covered. Rustfmt and production SDK builds for Mac/Android pass.

### Physical verification

Both owned QA applications used ordinary production native engines and the
freshly built SDK. The exact installed Android APK and the Mac process's
loaded SDK path were checked; frozen build-input hashes stayed unchanged.
An obsolete disposable PacketTunnel build was stopped before it could supply
the stand's SDK. The frontend build then consumed frozen current libraries.
This was a stand construction correction, not a product-source change.

The phone used cellular data with Wi-Fi off. P2P was temporarily denied only
for the two QA contacts. Receiver logs confirm an **anonymous stream** in both
directions, with one request, no direct-stream open and no manifest timeout:

| Direction | Size | Request → validated manifest | Complete download | Verification |
| --- | ---: | ---: | ---: | --- |
| Phone → laptop | 4 MiB | 7.293 s | 87.781 s | Exact SHA-256 match |
| Laptop → phone | 4 MiB | 0.356 s | 64.412 s | Exact SHA-256 match |

These are successful first attempts on the corrected clients and updated
relay fleet, **not a controlled before/after attribution** to the ranking
change. The earlier failing capture proves the historical stand preference
was active, but its candidate ads had the same generation: stale generation
is not established as the cause of that timeout. The new cold header still
approaches the existing eight-second first-byte bound, and anonymous transfer
throughput remains low. Cold-start latency and the remaining audio/video
failures require further work; two successful downloads do not close them.

No call or physical audio device was opened in this cycle. Both QA-contact
policies were restored and checked, owned phone file fixtures removed, owned
apps exited, and the exact original phone APK was restored and hash-verified.
The disposable tunnel-build script was restored. Public evidence contains no
identity, relay address, file name/path, request id, cookie or credential.

## Previous follow-up — 23 October: delivery stages and subthreshold probe recovery

[socket-to-kernel-delivery.json](socket-to-kernel-delivery.json) and
[direct-relay-follow-up.json](direct-relay-follow-up.json) contain aggregate
evidence only. **The physical video freeze and long delivery tail remain open.**

### Separating local queues from delivery

The 179.88-second direct call enabled endpoint UDP tracing on both sides.
Encrypted datagrams are joined only by a unique matching digest and size,
on local connections accepting the owned primary source. Grouped receive
timestamps, ambiguous matches and packets outside the calibrated interval
cannot supply a one-packet delay. These are opaque datagrams on those
connections, not an audio-only measurement or a packet-loss census.

Start/end phone-wall-clock brackets form a conservative 47.19-ms offset
envelope. Assuming no unobserved clock step outside that envelope, the
matched socket-send-to-peer-kernel maxima are:

| Direction | Eligible matches | Lower bound on maximum | Upper bound on maximum | Peer kernel-to-poll maximum upper bound |
| --- | ---: | ---: | ---: | ---: |
| Laptop → phone | 230 | 1085.51 ms | 1133.70 ms | 4.89 ms |
| Phone → laptop | 276 | 1134.05 ms | 1182.24 ms | 1.69 ms |

Socket send is recorded after successful OS handoff. This span includes
sender OS transmit queues and the external network, and does not identify
the provider or NIC as the cause. QUIC acceptance is an earlier stage:
budget admission to acceptance peaked at 0.274/3.580 ms. The laptop QUIC
connection also recorded a **199.14-ms lifetime datagram queue maximum**,
mostly congestion-window blocking. Lifetime maxima are not packet latency
percentiles and cannot be added to unrelated maxima to reconstruct one packet.

The separate 179.97-second relay comparison used only temporary QA-contact
P2P overrides, which were restored and checked. Ordinary ordered relay paths
were active; no direct QUIC media path was reported. Video froze there too:
laptop/phone sent 3/3 frames and decoded 3/3, versus 5/3 sent and 2/4 decoded
in the direct capture. Both calls used continuous synthetic PCM through the
real codecs/network, real cameras, and no physical audio device. They were
separate network observations, not a controlled causal quality comparison.
Matching ciphertext across endpoint sockets cannot measure a relay path whose
hop encryption changes, so no relay one-way UDP latency is claimed.

`scripts/analyze_physical_udp_delivery.py` reproduces the direct timing
summary without exporting digests, connections, cells, wall offsets, payloads
or addresses. Its **10 tests** cover both clock directions, uncertainty,
capture boundaries, ambiguous/replayed samples, other connections, missing
kernel/GRO timestamps, clock/size contradictions and lifetime maxima.

### Confirmed recovery-policy correction

Native duration windows already distinguish small repairs from significant
speech damage when deciding video cuts. The sparse-resume gate nevertheless
rejected every fresh concealment/catch-up event, even when the same duration
measurement explicitly said the damage was below its threshold. A sequence
of small repairs could therefore keep video paused indefinitely.

Measured subthreshold repairs now allow the existing three-sample recovery
to release **only the one-fps trial**. Raw repair events still hold growth.
Significant damage, interruptions, admission/network loss, unsafe or missing
playout measurements, and unknown/partial duration support retain their
protection. Buffer and duration thresholds are unchanged.

The new public-adapter regression failed on the old code (the trial stayed
paused), then passed with the correction. Partial support in either direction
and significant-damage controls also pass. **270 tests** across the adapter,
source pressure/recovery, transient loss, buffer windows, video delivery and
group adapter pass; the two changed Dart files analyze cleanly.

These physical captures preceded the policy correction. They contain frequent
significant audio damage, so the correction is not represented as resolving
their freeze or as a new physical quality qualification. No live speech,
headphone loudness or acoustic latency assessment was performed. Owned apps
exited, QA policies and the exact original phone APK were restored; the
ordinary private stand artifact was restored as well.

## Previous follow-up — 23 October: sparse video and long Opus packets

[sparse-video-packetization.json](sparse-video-packetization.json) contains only
aggregate evidence. **Physical video freezing remains unresolved.**

The native packet-duration gate required an emitted <=40-ms Opus packet before
releasing video, even when the application had already selected its one-fps
recovery trial. On a narrow audio allocation this could prevent the trial from
starting. A source actually capped at **<=1 fps** can now coexist with 60-ms Opus.
The explicit audio pause still stops that source; larger cadences retain the
existing short-packet gate. The source cap is applied before sparse permission
opens, and permission closes before raising cadence. No audio payload floor,
route ceiling, relay role, priority or mailbox policy changed.

A new regression uses the public video APIs, two real Opus/VP8 engines and a
lossless mocked Veil boundary at a fixed 48-kbit audio allocation. With actual
60-ms packets, the old library sends **zero** video frames in three seconds;
the corrected library sends **three**, and the receiver decodes at least two.
Explicit pause, resume, blocked unfunded 3-fps mode and return to 1 fps pass.
The existing packet-policy/real-Opus gate decodes **991** valid packets. Both
production libraries build with **105** public exports and no test hooks.

The frame-sizing integration gate also exposed a pre-existing fixture defect:
both libraries failed its immediate zero-cap assertion after profile retune.
The test now waits for the asynchronous encoder update and funds the group
fixture through the real allocator, because that source-only fixture has no
receivers providing transport feedback. The original zero-cap recovery
requirements remain. Direct/group integration and frame-budget unit gates pass.
The additional allocator helper exists only in test builds.

The **179.64-second P2P phone/laptop call** with continuous synthetic PCM and
real cameras again stopped video: Mac/phone sent **5/2** frames and decoded
**1/4**. The application audio pause persisted. This field failure is retained,
not represented as a successful video recovery. Both source/render drivers
kept ticking: their maximum intervals were **11.04/18.32 ms**, with no failed
ticks or driver restarts.

Packet joins narrow the remaining delay to the interval between sender native
admission and receiver native arrival, which includes **SDK queues and the
network**. Estimated maxima were **1171.96/1166.88 ms** (Mac-to-phone/reverse),
with a combined initial clock-bracket width of 5.09 ms; clock-rate drift was not
bounded. Sender admission maxima were **0.066/2.213 ms**, and receiver-native
handoff maxima **4.994/0.094 ms**. Source RTP attempt gaps stayed below
**65.77/77.94 ms**. These measurements do not identify the wire or provider as
the sole cause, and local acceptance is not actual wire transmission. They also
do not assess acoustic latency or intelligibility. The next investigation must
separate SDK queueing from network delivery on this interval.

Owned apps exited, original phone APK/hash and ordinary private stand artifacts
were restored. No raw trace, identifier, address, payload or credential was
exported.

## Previous follow-up: packet waiting time follows actual renders

[packet-wait-render-clock.json](packet-wait-render-clock.json) contains aggregate
results only. **The video freeze remains unresolved.**

A regression using the production factory and real NetEq/PCMU proved that
catch-up aged queued packets by **170 ms within one 10-ms render callback**.
The controller's arrival history already used a separate render clock, but
NetEq's default packet-buffer stopwatches still followed the decoder clock,
which advances for every discarded block. This false waiting time also feeds
NetEq's future-packet and post-concealment decode decisions.

The packet buffer now shares the existing render clock with arrival history.
The decoder's internal clock and recovery/quality thresholds are unchanged.
The regression now reads **10, 20, 30 ms** after three successive renders;
the first render still discards the same 160 ms of queued stale audio.

The unit gates, 120-second real Opus speech/DTX/resumption scenario, recurring
jitter at both buffer capacities, and real three-party mixing/JSON gate passed.
Fresh mixed group audio measured **171.97 ms** against the unchanged 200-ms gate.
Mac and Android native builds succeeded.

An independent **179.61-second** phone/laptop P2P call used continuous synthetic
PCM through the real Opus engines/network and actual cameras, without opening
physical audio devices. Neither PCM driver restarted. Nonquiet decoded blocks
were 98.16%/99.46% in the audio-only interval and 98.77%/99.33% with cameras
(Mac/phone); the preceding field control had lower fractions. These are signal
presence observations, not a listening or acoustic-delay assessment, and network
variability prevents attributing their entire difference to the clock fix.
Video still failed: Mac/phone sent **3/0** frames and decoded **0/1**. Application
and native packetization holds persisted, so the clock correction does not
establish that video adaptation is fixed.

Owned apps exited after collection. The original phone APK was restored and
its hash verified; the ordinary private stand artifacts were restored too.
No synthetic hook or test override was added to production code.

## Previous follow-up: valid group JSON and direct audio counters

[group-stats-and-audio-counters.json](group-stats-and-audio-counters.json) contains
only aggregate results. **Video remains unresolved.**

### Confirmed production fix

Group delivery statistics used a binary 32-byte participant id directly as a
JSON object key. NUL bytes truncated the C string; quotes, backslashes and
non-UTF-8 bytes could invalidate it. The native getter now emits hex keys. This
restores complete group statistics for application parsing and adaptation.
Anonymous diagnostic export still omits both participant-keyed maps.

The real group test now uses ids containing NUL, quote, backslash and `0xff`,
parses the complete output as UTF-8 JSON, checks both expected hex keys and
requires numeric recovery fields to exist. **Its original PCM and timing gates
were retained.** Final result: fresh mixed output from both sources at **170.56
ms**, 50 warm mixed ticks, 15 recovered mixed ticks, six catch-up events, 880 ms
trimmed, no fallback. The gate exited successfully.

This also corrects earlier validation wording: the old group probe printed good
PCM timings but exited with status **5**. Its missing JSON counters had silently
been interpreted as zero. That run was not a passing gate. The cause was the
malformed native JSON; no quality threshold was relaxed to make it pass.

### Experiment removed after checking the evidence

A new local-reserve condition for preemptive expansion passed a targeted unit
case, the long-Opus and recurring-jitter experiments, but did not restore video
on the phone. It was **removed from the final code**. Final production audio
policy is unchanged from the preceding SDK commit.

Direct native `inserted_samples_for_deceleration` and
`removed_samples_for_acceleration` counters now appear in the native snapshot
and the explicit anonymous-journal numeric allow-list. The control with the old
audio policy measured only **33.94/74.44 ms** of inserted audio on laptop/phone,
while forced catch-up discarded **2,510/8,680 ms** over approximately 119 seconds.
A large expansion/discard loop is therefore not supported by these counters.
Earlier inference from rendered RTP timestamp differences was not an
authoritative measurement of added samples.

Both the 179-second experiment and 119-second control stayed connected but sent
**zero video frames**. Their routes differed (mixed P2P/relay versus relay), so
latency changes cannot be attributed solely to the experiment. Native receive
callback-to-worker handoff on the phone had p95 below **0.73 ms**, maximum below
**4 ms** in these runs. This bounds that local handoff only, not SDK, sender or
network queues. The remaining audio damage and source holds need investigation
with sustained audio input; live microphone tests were mostly quiet.

### Final verification and cleanup

- Final decoder/catch-up unit gate and real group PCM/JSON gate passed.
- Four anonymous-journal tests passed, including rejection of both real
  participant-map field names; the two changed Dart files analyze cleanly.
- Both production native builds retain **105 C ABI exports**, with test hooks
  and synthetic media disabled. Final native source matches the physical
  control build, including the retained Android disconnect recovery.
- Owned applications, native test processes and log captures exited. Owned
  phone traces/cache were removed, the original phone APK restored and its
  hash verified. No raw/native trace, identity, address or key was exported.
- Speech intelligibility and acoustic loudness remain unassessed; no relay
  classification, priority or mailbox fallback was added.

## Previous follow-up: Android device disconnect

[aaudio-disconnect.json](aaudio-disconnect.json) contains only aggregate results.
The previous apparent P2P path stall had an endpoint cause in this reproduction:
turning on the camera selected the speaker, Android disconnected **both AAudio
streams**, and the ADM had no error callbacks to reopen them. The phone's audio
RTP attempts stopped for about 15 seconds while incoming audio still advanced.
A receiver-side silence timeout then initiated relay recovery. That timeout did
not establish a broken network route.

The ADM now registers error callbacks and recreates the affected stream on one
owned worker, serialized with ordinary stop/device/start operations. Generation
checks reject retired work. Stop/destruction close callbacks and join the worker;
no detached recovery thread survives the ADM. Temporary open/start failures retry
with a delay. A failed initial `requestStart` now returns failure and closes the
stream, instead of reporting successful recording/playout. FineAudioBuffer is
rebuilt after the reopened device's actual format is known. WebRTC's control
sequence remains responsible for starting/stopping AudioDeviceBuffer.

This follows the [AAudio disconnect contract](https://developer.android.com/ndk/guides/audio/aaudio/aaudio):
stop/close/reopen must happen outside its error callback thread.

### Verification

- A host smoke test compiles the **production ADM**, real WebRTC buffer and a
  controllable AAudio backend. The old source fails both the missing callback
  and false-success startup regressions. The corrected source passes capture
  and playout recovery, temporary open failures, failed recovery starts,
  a callback racing close, explicit stop and destruction with recovery pending.
  Command: `TMPDIR=/private/tmp/ python3 flutter/veil_media/test/run_aaudio_disconnect_smoke.py`
  from the Veil repository with the normal WebRTC build available.
- The production Android library builds with the usual **105 C ABI exports**.
  No synthetic capture or test hooks were enabled in the physical app.
- During a new **179-second** phone → laptop call, camera enable again caused
  Android's disconnect error. Capture reopened in **520 ms**, playout in
  **245 ms**. Both counters reflect one successful reopen, not an engine rebuild.
- The maximum gap between encoded phone audio packets changed from **15,939.85
  ms** in the prior run to **1,009.24 ms** in this run. This measures source
  production, including DTX/capture scheduling; it is not acoustic latency.
  Both endpoints stayed on **P2P for the complete call** and audio counters
  continued after the route change. Network variability prevents a general
  latency or sound-quality guarantee from this comparison.

### Still unresolved

Video again stopped after its first frames: laptop/phone sent **3/5** frames
and decoded **4/3**; the last decode advances were at **68.44/65.36 s**, after
camera enable at **60.25 s**. Reported nonzero FPS then remained stale. Native
packetization and application audio-protection holds still need work; repeated
forced catch-up remains present. Fixing device recovery does not prove that
video adaptation or end-to-end audio quality is fixed. No live speech or
listening assessment was supplied.

Both owned apps and log captures exited afterward. The original phone APK was
restored and its hash verified. No relay behavior or transport priority changed.

## Previous follow-up: content credit and audio reserve

[credit-and-audio-reserve.json](credit-and-audio-reserve.json) contains only
allow-listed aggregate results. Raw traces, endpoint identities, addresses,
profile names, file names, device labels and keys remain outside the repository.

### Corrections and verification

- Reliable content streams negotiate a 256 KiB application-read window with
  cumulative credit every 64 KiB. The first 128 KiB implementations prevented
  queue-full markers but were too slow to finish 32 MiB within 180 seconds;
  they were not accepted as the final fix. The final sliding window retains
  bounded reads and compatibility with old clients/servers. Credit is not
  durable delivery; existing piece and final hash verification remain required.
- The native RTP-age catch-up path no longer drains below the adaptive decoder
  reserve merely because audio spent time upstream. The new regression fails
  on the old code. The independent hard local-storage budget is unchanged.
  The long-Opus and recurring-jitter gates pass; the earlier group
  probe did not pass its exit-status gate (corrected in the latest follow-up). Recurring-jitter
  arrivals now follow source RTP time to avoid unrelated callback-boundary
  variation between controls; no acceptance threshold was relaxed.
- The complete Flutter suite passes **5,777 tests, 154 skipped** for the sliding
  protocol. After changing only its window size, the final content, credit and
  idle-write subset passes **70 tests**; all six changed Dart files analyze
  cleanly. Slow sinks, cancellation, partial/invalid ACKs, final-close races,
  FIFO writes, range resume and both legacy compatibility directions are covered.

### Physical file results

| Direction | Size | Download time | Verification |
|---|---:|---:|---|
| Phone → laptop | 32 MiB | 142.09 s | Exact SHA-256 match |
| Laptop → phone | 32 MiB | 52.30 s | Exact SHA-256 match |

The phone used cellular data with Wi-Fi disabled. During the upload the owned
laptop receiver process was stopped for five seconds after at least 4 MiB and
then resumed. No queue-full marker or payload restart was observed. The first
upload attempt timed out **before its manifest**; a warmed direct-stream retry
then carried the complete payload. The reverse transfer needed one request.
The physical payload used direct streams; anonymous transport and compatibility
were also checked in the simulated transport tests. Older peers retain their
uncredited behaviour. These measurements do not establish a universal speed.

### Calls remain unresolved

Clean production native engines, real microphones/cameras and the normal SDK
were used for both calls; the temporary file-test SDK probe was removed first.

- Laptop → phone: incoming signaling took **1.10 s**, connection after answer
  **2.55 s**. The call remained connected for **139 s**, but only nine laptop
  frames and zero phone frames were sent; decoding froze. Sampled local audio
  delay peaked at **210/749 ms** (laptop/phone). The reserve correction did not
  establish recovery of video or elimination of catch-up events on this path.
- Phone → laptop: **179 s**, with cameras enabled at **60 s**. Audio trouble
  existed before video: native receive age reached **844/693 ms** and sampled
  forced catch-up totals reached **340/4,970 ms** in the first 55 seconds.
  After camera enable, the call switched from P2P to relay at about **65–66 s**.
  Sampled native receive age on the laptop peaked at **14,041 ms** around
  recovery; phone local audio delay peaked at **1,704 ms**. Only five/two sent
  video frames were counted across media epochs. The call survived, video did
  not recover. Nonzero retained FPS was not treated as decoder progress.

Audio packet counters progressed in both directions. This does not certify
speaker audibility or speech quality: the user could not listen or speak during
these tests. Local buffer delay is not acoustic end-to-end latency. A single
field network does not identify the carrier, a relay or the endpoint as the
cause. Call quality and the P2P-to-relay stall remain release risks.

All owned apps and log captures were stopped afterward; original phone APK
restoration and its hash were verified, and owned phone file fixtures removed.
No relay classification, relay priority, mailbox fallback or container change
was introduced. Commits for this cycle are local and unsigned.

## Previous follow-up: paused-source feedback and receive queues

[follow-up.json](follow-up.json) contains only aggregate measurements.

### Corrections verified

- SDK `76820278` drains already queued receive fragments in bounded reads.
  The regression failed on the old code (2,048 bytes returned for 65,536 bytes
  already available) and passes after the correction. Short reads never wait
  for a full buffer. Partial frames, empty DATA, EOF and credit accounting are
  covered. All 51 SDK unit tests pass.
- The video delivery model no longer interprets intentionally stopped source
  media time, or a retained old frame's delay, as a growing decoder queue.
  The adapter regression previously kept video paused after audio recovered;
  it now releases only the one-fps floor. Frames acknowledged during a pause
  cannot authorize growth afterward. The adaptation/privacy subset passes
  186 tests; the changed Dart files analyze cleanly.
- Anonymous reports now include explicitly allowed numeric frame counters,
  native video pause/packetization flags, receive age and catch-up/discard
  counts. They still exclude raw/native logs, identifiers and nested peer maps.

### Physical results and unresolved defects

The clean production media engines and SDK were tested with real microphones
and cameras; temporary native probes were absent in the final call. No live
speech or acoustic assessment was supplied.

- Audio transmission from the Mac returned in subsequent runs, including a
  35-second audio call and two approximately 140-second video calls. These
  stayed connected. The earlier zero-transmission startup remains unexplained;
  no capture-driver fix is claimed.
- Before the paused-source correction, false video queue pressure appeared
  in 117/135 laptop samples and 115/135 phone samples. Afterward it appeared
  in **0/135** at either endpoint. Nevertheless, video still froze: only six
  laptop frames and three phone frames were sent, and decoded counters stopped
  progressing after the first approximately eleven seconds. Stale FPS values
  are not evidence of resumed video.
- Fresh audio damage continued to hold video. The final sampled receiver
  catch-up counters recorded 2,670 ms discarded on the laptop and 10,870 ms on
  the phone. The phone remained paused for 130/135 samples. The cause of this
  frequent audio catch-up needs investigation; disabling this safeguard or
  claiming fixed video is not justified by these measurements.
- Two further phone → laptop 32-MiB files completed with exact SHA-256 matches:
  102.61 s before receive coalescing and 126.49 s afterward, including offers.
  **No speed improvement is established.** The coalesced run still reproduced
  SDK receive-queue overflow, followed by thousands of close notifications and
  successful resumption. Coalescing does not provide missing end-to-end
  receive backpressure; file-stream closure remains an unresolved defect class.

The stream-close probes were isolated in a temporary SDK worktree, which was
removed. Apps and owned capture processes were stopped; the original phone APK
was restored with an exact hash match and its process was verified absent.
Test-file caches were removed without removing the user's profiles.

## Follow-up: automatic investigation

Source correction: Veil `c5ca76b9` (unreleased).

The audio Call had a fixed 96,000-bit/s estimator ceiling. With the observed
509-byte route overhead plus a 20-byte RTP header, a 40-ms packet costs
129,800 bit/s including the existing minimum speech payload. With the encoder's
20% reserve and strict integer comparison it needs at least 162,255 bit/s of
gross allocation. Consequently, the old ceiling could never fund the short
packet required to release video's packetization hold after a yield.

The source correction derives the ceiling from framing, retaining 96,000 bit/s
on lower-overhead paths. It changes the base WebRTC constraint: client
preferences alone can only tighten the original ceiling. No minimum allocation,
new bandwidth estimate, relay priority or override of measured audio pauses is
introduced. This removes a necessary recovery obstacle; it does not prove that
the network will supply enough allocation or that all video failures are fixed.

Automated regression evidence:

- Real Opus, including DTX: reproduce the 60-ms hold at the old relay ceiling;
  decode 40-ms packets and admit video after a funded recovery on 209-, 360-
  and 509-byte routes. A requested duration alone cannot release the hold.
- Observe the actual GoogCC constraints during live overhead changes: the
  larger ceiling reaches the controller and returns to 96,000 bit/s when
  framing shrinks. Independent audio/video routes remain separate. The BWE
  handover regression also passes: only genuine committed path changes reset
  their controllers; framing corrections preserve the current path estimate.
- Four SDK stream regressions pass. A closed stream's credit now reports
  `veil stream already closed`, preserving the FFI's existing closed-stream
  classification. A second stream still writes through the same IPC writer;
  a genuinely exited writer retains its distinct failure text. The earlier
  `veil IPC writer task closed` line alone cannot diagnose an IPC-task crash.

Additional physical calls could not validate recovery: the Mac emitted no audio
packets despite authorized microphone access and successful capture-start
status, and calls ended after approximately 21–35 seconds. Repeating with the
exact previous Mac media binary (verified against the saved build hash) also
produced zero outgoing audio. This is an additional unresolved capture/liveness
failure; it is not evidence that the corrected ceiling restored moving video.
The final base-constraint correction is validated by native tests, not a passing
physical call. The failing 32-MiB upload also remains unresolved.

Both endpoints were closed after these checks. The original phone APK was
restored again with an exact hash match; its process and the owned Mac process
were verified absent. No live speech was requested or assessed.

Two physical endpoints: a Mac laptop and an Android phone on cellular data,
with Wi-Fi disabled on the phone. The phone was awake and unlocked. Test profiles
were isolated from existing conversations. The stand frontend used xVeil
`a6b7524b`, Veil `0.11.44` / `c67cfe30` and hidden-volume `2.6.3`. It used ordinary
production media engines and real microphones/cameras, with synthetic media and
PCM injection disabled. Builds finished before network measurements began.

Only aggregate observations are retained here: no peer/device identifiers,
addresses, paths, keys, message contents, camera images or audio recordings.
[summary.json](summary.json) contains the numeric measurements. Private working
captures are excluded from the repository.

## Results

| Case | Observed result |
|---|---|
| Contact request, laptop → phone | Received in 4.15 s; accepted at both endpoints by 5.29 s. |
| Text, each direction | Observed within 0.57 s, one copy each. After the failed large upload both directions still delivered within 0.57 s. |
| 32 MiB, laptop → phone, no call | Completed in 104.50 s; SHA-256 matched. |
| 32 MiB, phone → laptop, no call | Timed out at 180 s. Observed partial file reached 3,932,160 bytes (3.75 MiB); repeated stream reopening did not complete it. The source file was not moved or modified. |
| Audio call, laptop → phone, then enable cameras | Ring in 1.10 s, active 1.02 s after answering. Remained connected for 149 s. Automatically moved P2P → relay at about 35.4 s; the harness requested no route change. Sustained video failed: 2 decoded phone → laptop frames, none in the other direction across sampled media epochs. |
| Initial video call, phone → laptop, after phone restart | Ring in 1.71 s, active 4.72 s after answering. Remained connected for 179 s. Brief relay/P2P transitions settled on relay. The phone decoded 11 early laptop frames, then stopped progressing after about 14.3 s. No phone frames reached the laptop. |
| Audio-only call with two simultaneous 1 MiB files | Call remained P2P for 90 s, without ending unexpectedly. Both files eventually passed SHA-256, taking about 106 s from transfer start; completion was after hangup. |

The first 4 MiB simultaneous-transfer attempt was canceled by the harness before
completion. It is unscored as a product failure. The smaller-file recheck waited
for completion and for its request threads to exit.

## Evidence and remaining questions

### File upload

The receive side logged resume offsets, EOF mid-piece and subsequent attempts
that failed to obtain a manifest. The sending phone reported the fixed SDK
failure `veil IPC writer task closed`, a payload-write idle timeout and later an
onion-stream driver closure. These establish failure in the stream path; they
do not establish which network or application condition caused its first stall.

The ongoing ability to send short messages and establish calls after the failed
upload separates this observation from a complete node/process outage. The
32 MiB reverse transfer remains a failing case.

### Call media

The first automatic relay recovery followed a native audio-receive age above
3 seconds after cameras were enabled. Media counters were grouped by media epoch
so handover resets are not mistaken for an entire call's totals. Reported FPS
was not used as proof of moving video: frame counters stopped advancing while a
stale nonzero FPS value remained visible in one run.

Cameras continued capturing on Android while video transmission was held. Native
`audio_packetization_video_hold` / `video_send_paused` stayed set for most video
samples, with 60-ms audio packetization. This identifies a local admission gate
that requires investigation, including whether audio adaptation can release it
under these conditions. It does not prove that the gate caused the original
network/audio interruption.

Measured jitter-buffer-plus-device audio delay:

| Call | Laptop median / maximum | Phone median / maximum |
|---|---|---|
| First call with camera enable and handover | 10 / 198 ms | 151 / 1657 ms |
| Reverse video call | 32 / 242 ms | 151 / 303 ms |
| Audio-only recheck | 10 / 140 ms | 142 / 201 ms |

These are local buffer measurements, not end-to-end acoustic delay. Live speech,
headphone loudness and intelligibility were not assessed. The observed network
and one endpoint pair do not isolate the carrier as the cause of either defect.

## Cleanup

- All calls ended and owned log-capture processes exited.
- Owned Mac stand process exited; the installed Mac app was not replaced.
- Phone test caches were removed.
- The original phone APK was restored in place, with an exact SHA-256 match,
  preserving existing application data. Restored version: `0.13.88`, code `2107`.
- The phone app process was absent after restoration; the owned ADB forward was
  removed.
