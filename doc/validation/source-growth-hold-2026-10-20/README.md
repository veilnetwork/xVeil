# Explicit source growth hold with independent admission health

## Implemented contract

| Assessment | DATA admission | Shared source flight | Native video pixels |
| --- | --- | --- | --- |
| Current healthy | Normal earned ramp | Real delivered credit may grow it | Fresh observations plus distinct encodes earn recovery |
| Known small damage, growth hold | Preserve earned rate and existing byte debt | Keep paid window; no growth or banked ACK credit | Preserve cap and earned active recovery; no growth/time banking |
| Measured pressure | Existing conservative allowance | Existing reduction, with primary reserve intact | Existing measured-pressure reduction |
| Unknown | Existing health lease expires | No new quality credit | No healthy recovery credit |

The application now publishes a growth hold independently of its existing
boolean measured-audio and transport-recovery states. The original event time
is retained across polls; current sampling time refreshes validated DATA health.
Known small damage still returns healthy for legacy callers, avoiding the
unknown-as-hold regression recorded in ../video-flight-feedback-2026-10-20.

One new negotiated local IPC capability and message carry only the owned app id,
current sampling time and original hold event. Both are validated: ownership,
negotiation, exact size, same-host freshness and the original three-second
hold deadline. Replays do not renew that deadline or the sampling lease.
No message is forwarded to peers. Ordinary relay scheduling and packet metadata
are unchanged; no remote media labels or priorities are introduced.

The SDK freezes DATA ramp progress at receipt, preserves earned allowance and
outstanding debt, and excludes held time from later growth. Actual primary or
DATA-path pressure remains effective. Shared flight stays paid at its current
size; held delivery ACKs cannot be banked for a burst after expiration. A new
healthy observation and ordinary delivery/demand conditions remain necessary.

Two optional native entrypoints apply the same bounded hold to direct/group
source sizing. Healthy recovery credit is preserved while held wall time and
encodes earn none. Paused video cannot bank growth. Independent actual encoded
oversize protection remains in force. The functions only touch bounded state
under the existing mutex; they do not invoke workers or perform network I/O.

Source-report futures now own just the IPC writer/app id. Both pressure and hold
FFI calls release the primary AppSender mutex before waiting on the bounded
writer. The 250 ms reporting deadline remains. Reporting queue backpressure
cannot retain the primary sender lock.

Older daemons decline the separately negotiated capability. The Dart client
retains the legacy healthy report rather than substituting unknown feedback;
older media engines retain their old source-sizing behavior. An expired/stale hold has its own result (2); only unsupported negotiation (1)
permits a legacy healthy report. Native rejection also cannot fall back to a
fresh healthy hint. Final captures below use this corrected caller bridge.
The new SDK C
entrypoint changes the generated ABI contract, so the matching SDK binary is
required with its generated Dart bindings. No app installation is part of this
cycle; tests use explicit isolated library paths.

## Verification

- 2148 Rust tests pass across bootstrap, IPC, protocol, session, client and FFI;
  16 are ignored. The final client/FFI rerun includes the owned reporting
  futures. A full-writer test proves the primary sender remains lockable while
  both report futures wait. Negotiation, ownership and clock checks are tested
  through real IPC, not only the payload codec.
- 231 related Flutter tests and production/fixture-policy analysis pass. Tests
  verify original hold time, expiration, unknown/pressure distinction, and native
  propagation while the SDK admission future is pending.
- Native budget tests pass. Real direct/group C ABI tests hold video workers,
  invoke feedback within 50 ms, retain the cap during the hold and recover later.
  The default real-Opus call-planes smoke also passes, including audio delivery
  while both video queues are stalled, restart and teardown.
- New SDK exports 203 symbols: exactly the growth-hold addition. Generated ABI
  hash is 07a6d433c34307e2089b9589cd1397a65e707e7d60e35db23160e8a9500a2638.
  Media hook/production libraries export 139/105; production has no test hooks.
  Symbol gates and separate-process dynamic loads pass.
- A pre-existing eight-epoch boundary test used keys shared with other parallel
  fixtures. It passed alone and failed in the full run. A domain unique to that
  test now isolates its keys, retaining all replay assertions. Full FFI tests
  pass; production cryptography is unchanged.

All SDK builds use a clean export plus only owned files. Foreign WIP is excluded
and its fingerprints are preserved. The original strict 200 ms acoustic fixture
gate stays visible and deferred; it is not a completion criterion for this step.
Current buffer trend/ceiling rails and DATA/video early-pressure coupling are
unchanged. The broader audio-priority/separate-interaction goal is not complete.

## Controlled captures

Initial captures, before separating expired from unsupported outcomes:

| Capture | Final minute decoded FPS | Resolution | Markers missing | Files |
| --- | --- | --- | --- | --- |
| Ordinary baseline, 180 s | 11.90 / 11.90 | 320x240 both | 0 / 348 | 2/2 complete |
| Initial candidate, 180 s | 12.61 / 11.92 | 320x240 both | 0 / 348 | 2/2 complete |
| Candidate screen slot, 180 s | 13.80 / 14.90 | 320x240 both | 0 / 348 | 2/2 complete |
| Group baseline, 360 s | 1.14–3.70 across six paths | 320x240 all | 0 / 2112 | 3/3 complete |
| Initial group candidate, 360 s | 1.38–2.43 across six paths | 320x240 all | 0 / 2112 | 3/3 complete |

Initial ordinary/screen captures met their unchanged raw fixture gates. Both
initial group captures failed their raw gates, including strict 200 ms acoustic
and/or tail-motion requirements. The candidate group's acoustic peak was
210.09 ms versus 270.17 ms baseline. Summed native recovery discards after
60 s were 70 ms versus 510 ms. These are separate measures, not a latency claim
based on the native queue alone.

The group's final-minute neutral FIFO admitted 93–95% of 1024 kbit/s capacity
in the candidate (92–96% baseline), without configured shaper drops. Low group
FPS persists under this saturated aggregate workload. This does not establish
that healthy headroom recovery or physical video is solved.

One ordinary and three group held observations arrived after their original
deadline. Initial callers used the legacy healthy fallback for them; these
captures are explicitly pre-correction, with their original binary hash retained.
The final correction discards expired holds without creating a healthy sample.

Final ordinary capture with explicit expiration outcomes:

- 180 s; final minute 3.09 / 3.10 decoded fps, 240x180 both directions.
- All 348 markers arrived; acoustic peak 190.09 ms. Both files completed.
- Raw fixture result is **false**, including 3 / 2 expired source reports
  recorded as skipped. The old no-skips gate is preserved, not relaxed to
  manufacture a passing result.
- At ~84 s, the local six-second soft-loss window reached 142 ms. It crossed
  the native 120 ms threshold and emitted a fresh qualified-loss report;
  buffer occupancy was 138 ms and interruption count was zero. The existing
  policy took two video rungs immediately. Its matching peer report followed
  at ~85 s. This was the cause of the observed rung reduction, rather than
  the deferred 200 ms acoustic goal.
- Both controllers later recovered to rung 2 (38 kbit/s, 3.75 target fps), but
  not the full profile by the end. Twelve healthy observations, applied-target
  ramping, three-second holds and a fresh peer report on the promotion tick
  combine to make recovery slow. Late healthy polls had earned 12+ observations
  while fresh peer reports coincided with another brief growth hold. This
  reproduction does **not** demonstrate that overall video recovery is fixed;
  it identifies a concrete next policy issue. One run cannot establish that
  the explicit-expiration correction itself caused the lower FPS.

Final group capture with the same corrected expiration bridge:

- 360 s; six directions at 320x240, final minute 1.32–2.02 decoded fps.
- All 2112 markers arrived and all three files completed with matching hashes.
- Acoustic peak 270.18 ms; summed native recovery discards after 60 s were
  1090 ms across three receivers (not a single 1090 ms audio pause).
- Final-minute FIFO admission used 91–92% of capacity. Five expired SDK holds
  and five expired native holds were rejected; none used a healthy fallback.
- Raw fixture result remains **false**. The new state distinction is verified,
  but this capture provides no evidence of an overall media-quality improvement.
  It must not be presented as a successful fix for the reported video problem.

## Next focused policy work

1. Separate a short burst of duration-measured damage from sustained loss in
   the native six-second accounting window. The current 120 ms trigger can
   spend two video rungs even with recovered, below-ceiling audio buffers.
   Investigate a higher burst limit plus duration/confirmation; retain real
   interruption, RTP loss and sustained queue protection.
2. Test recovery where fresh five-second peer reports overlap three-second
   growth holds. Earned healthy progress must not be repeatedly delayed by
   phase alignment; never create permission from stale/unknown measurements.
3. Verify final FPS/resolution after a brief imposed impairment and after the
   bottleneck is removed, with ordinary and group traffic. Keep the strict
   200 ms acoustic fixture gate visible but deferred.

## Artifacts and cleanup

`final-build-proof.json` maps the final SDK (8062a0b3…) and unchanged native
libraries to exact owned source digests. `build-proof.json` describes the
initial pre-expiration-fix candidate (2246df3a…). The initial ordinary and screen
captures preceded the group fixture clock correction; their exact caller
fingerprints remain in `pre-clock-fix-build-proof.json`.
`pair-final-comparison.json` and `group-final-comparison.json` retain all runs,
including their unmodified raw gates. Full traces remain at the cache paths
recorded in those files. Test log hashes and component totals are retained in
`test-proof-final.json`.

Final fixture/helper/worker/policy PIDs were checked absent, all embedded nodes
stopped with status zero, all threads exited and fixture sockets closed.
Independent cleanup proofs also cover every earlier completed/failed capture.
Foreign WIP digests were unchanged. No physical UI app was opened; no phone
installation, push, release or relay mutation was performed in this cycle.

An initial group attempt failed at ~21 s because the fixture used elapsed time
for policy event timestamps while native/SDK used Unix time. The argument guard
correctly rejected the span. The fixture now supplies one actual host sample
time to policy, native and SDK. Both matched group captures above use that same
fixed fixture. The failed attempt and its cleanup are retained separately;
it is not counted as a completed group quality run.

Synthetic same-host captures use real Opus/VP8, the production source policy,
neutral aggregate 1024 kbit/s FIFO and competing encrypted 512 KiB files.
Ordinary baseline/candidate runs are consecutive with the same current fixture;
the previous binaries simply lack the optional hold controls. Group comparison
uses the separately completed fresh baseline with the corrected fixture clock. The screen-slot run is synthetic
input over the actual screen transport slot, not real display capture.
These do not establish live speech intelligibility, physical cellular behavior,
headphone loudness, real screen presentation or completion of the full goal.

## Follow-up: brief damage and recovery

[The next validation](../video-soft-burst-recovery-2026-10-20/README.md) retains
the moderate-versus-burst classifier and peer-report/hold recovery correction.
It includes a failing-before regression, matched ordinary runs and a same-call
capacity increase: all six video paths recover to about 14.4 FPS, with all
1758 checked markers observed after adding a real PCM observation tail.
The strict 200 ms acoustic requirement remains deferred and visible.
