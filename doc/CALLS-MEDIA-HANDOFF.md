# Calls media handoff

## 2026-10-17: current anonymous/ordered real-codec coexistence PASS

`anonymous-codecs-1bd719bb` runs the existing ignored real-codec test against
SDK `1bd719bb` with explicit node-embedded/packet-tunnel/tls-boring/
production-seeds/test-low-difficulty features and `--ignored --nocapture`.
One actual test runs and PASSES (306 filtered), not a zero-test result.
The native test-hooks media is the retained unicast-floor 8fb01875... build;
the owned anonymous PCM driver passes both row/stats ABI checks. Its hash,
the complete retained test executable, exact SDK/test source hashes and raw
capture hashes are recorded privately. The test executable provides its own
SDK symbols; no second SDK shared library/channel table is loaded.

Two endpoints communicate through TWO real loopback obfs4/TCP relays; no
in-memory link substitutes. The fixture checks the actual circuit-table
forward chain and terminal entries for all four receive planes. This is
unshaped, with equal relay service allowances above the offered workload,
fixed synthetic 320x240 VP8 video at 150 kbit/s / 15 FPS, real Opus, and NO
application bitrate adapter. It is not another 1024-kbit/s contention result,
physical WAN measurement or screen-capture-device check. Phases are audio
0..20 s, camera plus bidirectional files 20..40 s, then the same encoded video
source routed through the screen plane 40..60 s. Camera and screen are NOT
concurrent encoders in this fixture.

Both full 512-KiB files complete DURING media and compare byte-for-byte with
their distinct original patterns. The existing 90-second per-file timeout is
unchanged. All four private planes make progress; there are NO new fallback
attempts during capture. Existing pre-capture control bootstrap counts are
5 per side and remain 5; other planes remain zero. Camera and screen phases
each have **17 changing decoded-frame samples per direction** at the existing
one-second observation cadence. Native audio feedback is present, with zero
sampled audio interruptions, decoded catch-up discards, audio RTP drops or
worker stalls. These are counters, not a human listening report.

**12010** PCM observations (6005 per endpoint) retain contiguous source ticks,
start-of-input coverage and end coverage through 60.043 s. Maximum driver
interval **15.027125 ms**, no dropped rows/native failures/timer errors;
existing clock/QoS checks pass. Offline analysis uses the opposite endpoint's
source_at and the unchanged group ordinal matcher starting from the first
input epoch. Decode classification uses the existing relay check's +/-150-Hz
tolerance around 500/1000 Hz, RMS >=500 and two stable rows; raw rows are NOT
rewritten. Both directions have 60 source/decoded edges. Across the existing
5..20-s audio and 20..60-s loaded measurement windows: **110 ordinal matches,
zero missing**. Audio-only peaks **53.695375 / 53.781542 ms**; loaded peaks
**53.914625 / 53.983792 ms**. The mixed window includes BOTH camera and screen
phases. This independent diagnostic does not change the original six-path
360-s acceptance gate or infer acoustic mouth-to-ear latency.

Also audited the stream-only sibling of the two repaired QUIC races:
OrderedSession selects/clones a Ready::alive sender under the pool mutex.
Outgoing warming starts only for an empty slot, with one attempt per index;
on a dial-capable parent, incoming children cannot overwrite outgoing slots.
Thus the specific cached-readiness/closed-candidate displacement mechanism
does not apply to that path. This is source evidence plus the successful
codec run, not a claim that every possible ordered-transport race is tested.

Native engines are destroyed, all four node.stop calls unwrap successfully,
and the owned test executable exits zero. Independent process inspection
finds no matching fixture. No physical app, microphone, camera, speaker,
installation, relay deployment, push or release this cycle. Retained private
artifacts/summary/timing-proof/codecs/PCM and analyzer provide the audit trail.
Goal remains ACTIVE: final real continuous-speech listening is unverified;
the participation question is pending, with no new call started for it. A
current physical mixed/anonymous WAN application check is still distinct
from this loopback SDK/codec proof and the previous same-LAN P2P phone checks.

## 2026-10-17: a closed verified candidate must not evict healthy audio

The complete original `group-selection-retirement-360` capture on SDK
`830a210d` / frozen FFI 3d3c28a6... PASSES strict qualification. All **2112
ordinal matches**, zero missing; maxima **130.166917 ms** audio-only and
**180.048667 ms** loaded. All six end-of-run video tails change **13** times.
Full authenticated 512-KiB file hashes match by **306.663587 / 352.220048 /
352.174165 s**, before the ORIGINAL 360-s deadline. Canonical fixture/policy
source copies, all clocks/rows/QoS/deadlines/startup budgets, topology and blind
shared 1024-kbit/s FIFO verify; four node stops zero, no owned PIDs or sockets
remain. `verify-selection-retirement-capture.py` differs from its predecessor
ONLY in the frozen SDK-manifest path. This is one positive capture on that
exact binary, not evidence that readiness ordering alone caused the numerical
improvement over the preceding negative run. No latency/video/file acceptance
gate was relaxed, and no source workload was reduced.

Then found a second readiness defect: connect_sender can successfully finish
authentication, but its child can CLOSE while the ReadySender waits in the
oneshot. poll_index validated the old sender before consuming that result,
then unconditionally adopted the result and closed the healthy old channel.
The subsequent readiness poll might reap it. The ordering fix prevents a
stale selection, but cannot itself preserve the working old channel.

Added a deterministic regression to the existing real TLS/QUIC replacement
fixture: complete an actual authenticated candidate, close it BEFORE polling
the completed result, require the original TLS binding and zero successful
switches, and deliver a primary probe through the original channel. The
original valid-replacement-versus-old-ACK scenario still follows it, including
retired ingress witnesses and actual delivery. No reduced idle timer, fake
transport, disabled authentication or enlarged original timeout is used.
On `830a210d` with this test-only patch, the fixture FAILS in **0.48 s** with
"a closed prepared candidate must not displace the live primary". Private
closed-candidate-red.patch and -red.log retain this reproducer.

SDK `1bd719bb` shares the old ready-sender availability predicate with candidate
adoption. Only a currently non-broken/open verified candidate may replace the
current sender. A stale result takes the existing failed-warm path: drop that
candidate, keep any healthy old sender, preserve the 500-ms backoff, and do
not increment recovery_switches. No channel count/assignment, parent fallback,
wire metadata, relay policy, rate allowance, codec or video adaptation changes.
The final exact-source suites PASS again: **578 session + 169 IPC + 141
bootstrap + 15 types = 903**, 14 preexisting ignored. This includes the new
formerly failing probe and original valid-replacement/ACK assertions.

Both platform FFI builds pass. Frozen `closed-candidate-sdk` records source
commit `1bd719bb`, complete patch/source hashes and Android artifact. Its Mac
FFI SHA-256 is `005465bbe9c65f5c76f55b9a21a4f5bfa6364e58332c1bd7b2a58ec05e0f7307`,
with the SAME 190 API / 196 total exports. The preceding positive physical
and 360-s results belong to `830a210d`; do not relabel them as qualification
of this later binary.

Final-device `call-closed-candidate-4606` also succeeds on SDK `1bd719bb`:
profile phone code **6606**, same-signature data-preserving update, every native
allocated/code section checked. Mac explicitly loads the corrected bundle's
FFI/media paths; lsof independently confirms both mappings. About a 60-second
same-LAN P2P smoke: **0.25-s** ring after the existing 90-s registration warmup,
**29 samples** through **58.19 s**, cameras enabled at **21.51 s**. Final remote
frame counts **885 / 859**, FPS **24.4 / 24.8**; final 12.25-s frame advances
**362 / 371**. Both endpoints have zero observed audio interruptions, decoded
catch-up discards, video-protection pauses and route handovers. Native sampled
buffers are **8..90 / 24..82 ms**, not acoustic delay. This shorter follow-up
does not replace the preceding late-camera test, full contention fixture,
forced-relay or continuous-speech proof. Both apps/logcat/ADB forward stop;
independent ps verifies the owned Mac PID and every Android package process
are absent. Private result/samples/loaded-library/package manifests retain it.
Final `group-closed-candidate-360` on THIS SDK `1bd719bb` / FFI 005465bb...
also PASSES strict full qualification: **2112 ordinal matches**, zero missing;
audio-only maximum **130.218667 ms**, loaded maximum **190.226792 ms** (<200).
All six end tails change **10 / 5 / 12 / 5 / 12 / 10** times: continuity, not
a claim of high FPS under this bottleneck. All three complete encrypted
512-KiB hashes match by **344.069374 / 337.835588 / 328.549329 s**, within the
ORIGINAL 360-s deadline. All clocks/rows/QoS/deadlines, fixture/source copies,
startup budgets, neutral routes/topology and shared 1024-kbit/s FIFO verify.
Four node stops zero; owned parent/workers/policy/awake helpers gone and zero
sockets remain. The verifier changes only its frozen SDK-manifest path.
Private group-closed-candidate-360-proof.json retains the complete audit.
No extra physical app or speaker was opened for this headless qualification.

Goal remains ACTIVE: current real anonymous/ordered codec traffic with
camera/screen/files and the final real Mac/Android continuous-speech check
remain to be verified. The current same-LAN phone results are not a new
cross-network/mobile-radio qualification. Keep these limits distinct from
the now-positive original full gate and the fixed, reproduced channel bugs.

## 2026-10-17: repair a physical call-start abort and verify late P2P video

First put current native code onto actual Mac/Android endpoints. Android
media is built from the cached Linux WebRTC SDK in the existing multiarch
container, and the production Android FFI is rebuilt without default TLS
features, with production-seeds/node-embedded/packet-tunnel. APK symbol
stripping changes file hashes: compare ALL allocated ELF sections with the
fresh libraries. macOS ad-hoc signing likewise changes hashes: compare ALL
file-backed Mach-O sections with the frozen tested FFI and production media.
These checks pass; exports alone are not the integrity proof. The Android
signing certificate matches the previous installation, which is backed up;
both updates use install -r, preserving the existing QA identity and data.
Final phone build is profile, explicit debug-hook opt-in, 0.13.86 code 6605
(requested build number 4605 plus the existing arm64 ABI offset 2000). This is
a local QA build, not a release. Mac uses the isolated QA profile and private
bundle, never the installed user application.

The first real call attempt, `call-current-rtcp-4604`, ABORTS ON MAC before
ringing. The hook's RemoteDisconnected is explained by the native panic at
parallel_lanes.rs:1055, sender_arc's expect("prepared sender"). Do not call this
an Android crash or mailbox timeout. prepare_frame_with_carrier cached a true
prepare_index result, THEN recover_channels could poll closed children or
retire signaling for capacity. The returned selection could therefore name an
empty slot. SDK `830a210d` moves recovery/capacity maintenance BEFORE the final
selected-channel readiness check. No wire format, lane assignments, relay
scheduling, byte allowance, media policy, startup budget or expiry changes.

The existing real QUIC source-separation regression now also closes/reopens
signaling three times with distinct TLS bindings, delivering a primary packet
while signaling is unavailable and a signaling packet after every reopen.
This covers closure/reopen/isolation; it is not claimed to deterministically
recreate the narrower asynchronous gap of the physical abort. The observed
physical abort and subsequent successful call supply the before/after evidence.
Final release suites on the exact committed sources: **578 session + 169 IPC +
141 bootstrap + 15 types = 903 pass**, 14 preexisting ignored. A preceding
focused nine-test channel suite also passes. Its actual 35-second idle test
reopens camera/screen without retiring audio. An initial standalone session
test command failed the existing release network-choice compile gate; final
commands explicitly enable veil-bootstrap/production-seeds. No gate weakened.

Frozen `selection-retirement-sdk` FFI SHA-256 is
`3d3c28a6cd5357f26add9f8a58937fc7852b2c85dafea394ba56cffac2683068`, with
the same 190 API / 196 total exports and verified source commit `830a210d`.
Android is rebuilt from those sources too. `physical-packages.json` retains
both package code-section comparisons; Mac Dart/media remain unchanged for
the repeat. Native media is the protected-unicast-floor production candidate.

`call-selection-retirement-4605` succeeds: real Mac -> Blackview on the SAME
Wi-Fi LAN, real production stack, **0.28-s** ring, **88 samples** through
**178.74 s** of the approximately 180-second call. The first minute is audio
only; both cameras are enabled at **62.40 s**, after the child idle timeout.
Both endpoints have the fixture's existing 90-second registration warmup
before placing the call; the ring number does not measure cold app startup.
The Mac trace records the late video's new connect/binding in **10/20 ms**.
Both endpoints stay P2P, no route handover, no audio interruption, decoded
catch-up discard, audio-worker stall or video-protection pause is observed.
Final decoded remote frame counts are **3123 / 3243**, final FPS **26.9 / 28.3**
at Mac/phone; the final 12.26-second window advances **363 / 366** frames.
Native sampled audio-buffer ranges are **8..90 / 27..58 ms**: BUFFER gauges,
not acoustic delay. First observations include connecting, followed by active.
No human continuous-speech listening proof, competing file/screen workload,
forced relay or cross-network phone route is claimed. Thus this does not
replace the unchanged six-direction 360-s contention qualification.

Both physical apps are stopped after each attempt. Independent ps confirms
the owned Mac PID is gone and Android has no main/colon subprocess; hook port
38765 has no listener, the owned ADB forward is removed, and logcat exits.
Private call directories retain samples, native/runtime traces and cleanup.
The Mac debug host writes a log inside its private bundle; preserve/remove
that generated log from a copied bundle before re-signing for another run.
No installed Mac app, relay service, push, tag or release changes this cycle.

An additional read-only join narrows the previous group's recurring catch-up:
at 342.33 s, source 1's two encoder outputs are **60.017 ms** apart, but their
native receive times are **174.512 ms** apart. Encoded-to-NetEq transit rises
from **35.240** to **149.735 ms**, then subsequent 60-ms media packets arrive
only **6.377 ms** apart. This is actual post-encoder jitter, not a codec
formation gap or merely a stale pressure bit. It still does not attribute
the delay to a particular secondary producer. The original gate's opaque
wire queue and source work observations are the next causal join; never
silence real decoded-loss reports to force video resume. Private
group-rtcp-cadence-360-tail-catchup-packets.json retains exact joins.

## 2026-10-17: RTCP cadence repair; distinguish recovery from a stuck guard

SDK `5c6fad2c` repairs the trusted-origin defect identified below. Before
sealing a video/screen work item, distinguish structurally valid RTCP from
RTP. Complete RTP frames, INCLUDING single-cell frames, retain typed whole-work
IPC and source cadence. Independently complete RTCP uses existing individual
sealed-cell IPC on the SAME secondary source with the ORIGINAL expiry. The
daemon cannot mistake those controls for a producer frame. No media inspection
at relays, new wire/IPC schema, changed relay service, RTCP suppression or audio
lane reassignment. Both upgraded and legacy daemon paths are tested, including
unchanged content/address/lane/no-ACK semantics and expiry on full admission.
**46 media-priority + 5 writer-freshness release tests pass.** Production FFI
build passes; frozen `rtcp-cadence-sdk` has SHA-256
`a5a044e149770115f87467d38a04dc06780486b43b7a1c0790f8c20e9c7a842f`, unchanged
190 API / 196 total exports, and verified source hashes at `5c6fad2c`.

`group-rtcp-cadence-360` is VALID but FULL NEGATIVE. The original three SDK
processes, six PCM paths, blind shared 1024-kbit/s FIFO and 360-s workload run
with the same unicast-floor native 8fb01875... binary and unchanged production
policy/startup budgets. **2112 ordinal matches / zero missing**; audio-only
maximum **120.155292 ms**, loaded maximum **200.021625 ms**: the strict <200-ms
gate FAILS, even though rounding to one decimal would hide the excess. All
three full 512-KiB encrypted files match by **352.288055 / 352.347627 /
352.236085 s**, before the original deadline. Moving video tails are
**14 / 14 / 0 / 14 / 0 / 14**: two directions FAIL. Source copies, clock/rows,
QoS/deadlines, topology and neutral routes verify; four node stops return zero,
owned PIDs have exited and no sockets remain.

Owned-work observations have **1242 rows**, no trace cap, **1182 completed
works**, no unmatched boundaries. All **60 multi-cell works** have a 100000-us
scheduled span; none reproduces the earlier few-millisecond cadence. This
confirms the observed short-span symptom is absent in this run, NOT full
audio/video qualification. The loaded peak is source 1 -> receiver 0 at capture
118.170007 s / decode 118.370029 s. Its encoder formation / encoded-to-NetEq /
NetEq-to-render join is **50.289 / 115.214 / 54.484 ms**. Packet/frame positions
differ, so these are not summands of the tone's end-to-end latency.

Do NOT assume the zero video tails establish a latched recovery-state bug.
Participant 0 repeatedly resumes and pauses. Its final pause starts at
325.020 s; encoded video frames remain at 213 through the end. Fresh local
decoded catch-up is still present at approximately 325, 332, 335, 339, 341,
343, 346 and 349 s (30/10/80/60/10/120/40/80 ms over both receivers). The
326-s decision also observes loss without a same-poll local-discard delta;
peer feedback can be a separate loss witness. Thus the consecutive healthy
recovery window has not elapsed by 359 s. This is evidence of recurring audio
loss while this sender's video is paused, not permission to ignore the loss,
shorten recovery, raise the 120-ms catch-up budget or weaken the 200-ms gate.
Private `*-reserve-episodes.json` retains exact decision inputs/counters.

The retained opaque wire trace covers the final interval. In five-second
windows 325..350 s, direction-0 offered traffic is **783.8..795.6 kbit/s**,
below the FIFO's 1024-kbit/s service, yet the 340..345-s queue reaches
**87.111 ms** (p95 **52.262 ms**). Direction 1 peaks at **41.375 ms** over those
windows. Release lateness is <=4.982 ms. Average throughput does not rule out
short bursts. These measurements do not identify the packet classes or prove
which burst caused each decoded discard. `*-tail-wire-windows.json` retains
the bounded aggregation; correlate existing origin ownership/transport
timestamps next, without assigning relay priority or reducing the stimulus.

SDK `fcd5a687` extends the existing real Opus component regression with
transition timing, matching from the FIRST input ordinal (including encoder
replacement), no startup trimming, PCM retention or new production settings.
All six 360-s simulated profiles run with DTX both on and off. At protected
24 and 32 kbit/s, **357/357 transitions** survive, zero quiet blocks, maximum
decoded sample-position lag **10 ms**, synchronous codec emission lag **60 ms**
at both rates. The existing diagnostic 16-kbit profile still has 69 consecutive
quiet blocks and up to 430-ms sample / 480-ms emission lag. These findings do
not explain every NetEq/tone position discrepancy, but provide no evidence that
raising this workload from 24 to 32 kbit/s would remove its observed peak.
The final component runner passes; no timing threshold in the full gate was
changed. Private `group-opus-transition-timing-final.log` and source manifest
retain the result. Goal ACTIVE: current full qualification and final physical
speech/video checks remain open. No physical app, installation, deployment,
push or release this cycle; owned component processes have exited.

## 2026-10-17: owned-work boundary observations and a cadence defect

Add bounded read-only observations AFTER successful local DATAGRAM admission
of the FIRST/LAST owned members. Snapshotting cannot reserve/refund credit,
release a member or alter expiry/decision. RT tracing gates it; a separate
16384-row budget preserves late coverage without changing the existing cell
trace budget. Only process-local LocalLossyCell ownership can select it.
Records contain connection trace id, existing encrypted epoch/sequence, cell
index/count, sealed and encrypted-envelope sizes, actual DATAGRAM payload size,
scheduled span, admission age and remaining ORIGINAL lifetime. This is NOT a
NIC-send timestamp; use the existing opaque UDP trace for later service.
Nothing is added to IPC or peer bytes. Scheduling/admission policy is unchanged.
Release suites: **578 session + 169 IPC + 141 bootstrap + 15 types = 903 pass**,
14 preexisting ignored; final source compiled and tested. New regressions cover
read-only snapshots, unchanged credit/deadline, late boundary visibility and
exclusion of neutral transit. FFI has the same 190 API / 196 total exports,
SHA-256 `4e42580d3cdaa3f53df66d78a15ef1de438b6db085d46827291867078d3e62d9`;
frozen `source-work-boundary-sdk` retains full source patch and manifest.

`group-work-boundary-360` is valid but FULL NEGATIVE: **2112 matches / zero
missing**, audio-only **130.149 ms**, loaded **210.138 ms** (<200 required).
All full encrypted 512-KiB hashes match by **352.387/351.548/352.239 s** before
the ORIGINAL 360-s deadline; all six tails change **14** times. Original
clocks/rows/QoS/deadlines, source copies, workload/startup budgets, routes and
neutral 1024-kbit/s FIFO verify. Four node stops zero; independent PID/socket
cleanup complete. Native remains the unicast-floor 8fb01875... candidate.

Boundary coverage is complete: **10518 rows**, no cap marker, **10376 completed
works**, no unmatched starts/ends. **10234** single-cell works and **142**
multi-cell works (140 with two cells, two with three) are observed. Seventeen
multi-cell schedules are shorter than 20 ms; one two-cell work at 66.087889 s
has a **4501-us** span and releases its second cell **4.222 ms** after its first.
This is evidence of an unexpectedly short schedule, not proof of the cause of
the global audio peak. 420 single-cell works have total encoded DATAGRAM bytes
>1200. Do not equate one sealed cell with one transport packet: observed
1555-byte encrypted-envelope members require 1659 DATAGRAM payload bytes.

The global tone peak is source 0 -> receiver 2, capture **28.280007 s** /
decoded **28.490145 s**. Its packet formation / encoded-to-NetEq /
native-to-render join is **50.504/113.065/36.524 ms**; callback/drain **26/19 us**.
Frame RTP position is 49 ms after the tone's source change, so do not simply
sum packet-position metrics into waveform latency. No >=25-ms stage fires;
1011 reliable-pressure rows are present. Near this peak, observed work releases
are single-cell, single-DATAGRAM members <=797 bytes. There is NO nearby large
multi-cell release in the retained +/-0.5-s source boundary window. Do not
claim that reducing RTP MTU or extending multi-cell spacing already explains
or fixes this particular peak.

Source inspection establishes a separate real defect. enqueue_video_control
puts independently complete RTCP into RelayVideoFrame; the common drain seals
it and calls send_relay_media_batch_before_owned, exactly like RTP frames.
The daemon's per-source SourceCadence observes EVERY typed batch, so video RTCP
can shorten the cadence later used for complete RTP frames. Work shape alone
cannot distinguish them after encryption. Fix at the trusted SDK origin:
retain video/screen lane and original expiry, but send controls as individual
sealed AppIpcSend cells so they cannot publish a frame boundary. Do not disable
RTCP, move video feedback into audio, add relay roles/priorities, or alter the
original workload/startup budgets. Also investigate whether the codec's
waveform transition lag contributes beyond its raw RTP position; this is not
yet attributed.

Private `group-work-boundary-360-{proof,feedback-details,rtp-playout-details,
scheduler-details,work-details}.json` and the immutable capture retain the
negative result. The boundary analyzer requires identical work shape and
admission time within 1 ms to pair records; it reports unmatched records and
never assumes encrypted nonces are contiguous. Goal ACTIVE; no physical apps,
installations, deployments, push or release occurred.


## 2026-10-17: protect unicast signal; current full capture still NEGATIVE

A new real Opus/ANA regression isolates the ordinary framing adaptor from the
network, NetEq and physical devices. It feeds the unchanged 1300/1700-Hz input
through the actual bundled Opus encoder and decoder, with framing overheads
209/509 bytes, DTX on/off, an initial healthy allocation followed by pressure,
and all 360 simulated seconds included. Baseline SDK 6ee3b63d permits a
16-kbit payload minimum. The 209-byte profiles have no quiet blocks; BOTH
509-byte profiles produce **96 consecutive 10-ms quiet blocks** (first at
**0.54 s**), even with DTX disabled. The minimum measured payload is 16000;
do not assume that every quiet sample began at exactly that target. This is
conditional codec attenuation, not evidence that every 16-kbit call is silent.
The RED component exits 2 (its Python runner exits 1). Source/input hashes,
the original log and a baseline source snapshot are retained privately.

Protect the opted-in unicast framing adaptor at **24 kbit/s payload**, sharing
that floor between real FrameLengthControllerV2, gross-overhead budgeting and
the codec target after ANA callbacks. The wrapper switches floors only after
successfully enabling the recognized local framing configuration. Fixed group
budgets keep their established **16..32-kbit API**; their application policy
already uses 24 or 32. Ordinary TWCC allocation also has a 24-kbit minimum.
No-feedback legacy mode stays at 32 kbit/s. No packet format, codec, relay
metadata/priority, channel topology, ceiling or packet-duration limit changes.

The identical new signal check is GREEN: all four profiles keep useful signal
through the entire run, minimum payload 24000, no quiet blocks. Existing real
ANA startup/RTT/loss/overhead tests verify the 24..32-kbit bound with actual
20/40/60-ms packets, including recovery. The separate group signal matrix is
unchanged: the explicit 16-kbit diagnostic still fades for 69 blocks, while all
24/32-kbit protected profiles pass. This preserves the public fixed-budget
contract rather than silently raising a caller's explicit group request.

The real Call allocator -> ChannelSend -> Opus test measures **32 -> 24 -> 32**
when the estimate falls and recovers, and **32 -> 32 -> 32** without feedback.
Its old exact 12-kbit expectation initially fails, then is updated to the new
exact 24-kbit floor; no wait/deadline/quality condition is weakened. The final
complete call-plane and RTCP-loss modes pass, including stalled-video audio
progress, low-rate video/recovery, independent feedback, legacy behavior and
teardown. The initial expected-value failure log remains private.

Frozen native test-hooks SHA-256:
`8fb01875b1d9e9cdc0e776a76dc3a7d4ce3656df0b95a401df3c77c4ede30fff`
(**131** unchanged exports); production:
`195894e0ca60350ab5d9d2991e42522a2b8a85b5665adc2b3073ba8901c9c2ee`
(**100** unchanged exports). Rust FFI is still the frozen 70d27678... artifact
from origin work pacing (190 API exports). Private `unicast-floor-{native,
production}/{sdk.patch,build.json,source}` retain provenance; signal baseline,
candidate, comparison and bounded/group/call-plane/RTCP logs retain evidence.

**Do not qualify the current candidate from the preceding two full passes.**
`group-unicast-floor-360`, using this NEW native binary, is measurement-valid
but FULL NEGATIVE: 2112 ordinal matches / zero missing, audio-only
**120.019 ms**, loaded **220.035 ms** (required <200). All full encrypted
512-KiB hashes match by **333.357 / 330.120 / 352.495 s** within the ORIGINAL
360-s deadline. Six tails move **14/12/9/12/9/14**. All original clocks/rows,
QoS/deadlines, harness/stimulus/policy/source copies, route/topology and cleanup
gates pass. Four node stops zero, all owned processes/sockets gone. Group
payload policy and non-ANA budget behavior are unchanged; these captures do
not establish that the unicast floor caused the different group latency.

Peak source 2 -> receiver 0 is capture **325.220012 s** / decoded
**325.440047 s**. Packet formation / encoded-to-NetEq / native-to-render is
**50.332 / 129.109 / 50.560 ms**, with the tone inside its 60-ms packet; these
are not directly additive to tone latency. Native callback/drain are **23/21
microseconds**. No >=25-ms slow-stage, aged-ingress or slow-dispatch record
fires; 988 pressure records verify instrumentation. The original FIFO trace
covers this late peak: direction 0 reaches **45.747 ms**, direction 1
**89.988 ms** in 324.8..325.6 s, release lateness <=1.309 ms. Direction 1
receives **1121.96 kbit/s** in 325.0..325.2 s on a 1024-kbit/s service. These
are opaque byte observations, not relay media classification. Decoded recovery
still discards **1610/1490/1300 ms** across each worker's two receivers.
Private `group-unicast-floor-360-{proof,feedback-details,rtp-playout-details,
scheduler-details}.json` and the original full capture retain this failure.

Goal ACTIVE. Continue attributing the remaining burst/queue to actual source
work and DATA admission before changing pacing; DATA is already paced by
exact wire bytes, so do not reimplement a bucket fix or assume a whole-file
burst. Ordinary unicast end-to-end and physical Mac/Android speech/video are
still required. The owned optional anonymous codec fixture uses
`VEIL_MEDIA_PCM_DRIVER_DYLIB=native_pcm_anon_codec.dylib` and
`test-low-difficulty` in addition to embedded-node features; keep it distinct
from the six-direction immutable qualification. No physical app/camera/mic/
speaker, installation, deployment, push or release occurred.


## 2026-10-17: second full contention pass and real idle-child audit

Repeat the exact frozen `source-work-pacing-sdk` binary with the same retained
native library and canonical root policy. `group-source-work-pacing-repeat-360`
is again measurement-valid and FULL PASS: six directions, **2112** ordinal
matches / **zero** missing, audio-only **130.165 ms**, loaded **190.070 ms**.
All three complete encrypted **524288-byte** files have correct hashes by
**344.259 / 339.459 / 333.674 s** within the ORIGINAL immutable 360-s deadline.
Six decoded tails move: **14 / 14 / 13 / 14 / 13 / 14**. The original 1024-kbit/s
neutral FIFO, exact clocks/rows/QoS/deadlines, harness/stimulus/source copies,
routes/topology and independent cleanup all verify. Four node stops zero;
all owned parent/helper/worker/policy PIDs and sockets are gone. This is the
second consecutive pass of the same treatment, not proof against every
intermittent physical-network failure.

Peak source 2 -> receiver 0: capture **124.230009 s** / decoded **124.420079 s**.
Its exact first-encoder-input / encoded-to-NetEq / native-to-render join is
**50.476 / 85.661 / 53.872 ms**; native callback/drain **28 / 20 microseconds**.
Latency recovery discards **960 / 1100 / 880 ms** across each worker's two
receivers over 360 s. Preserve these counters: passing tone positions does
not establish uninterrupted or intelligible continuous speech. Private repeat
`proof`, `rtp-playout-details`, `scheduler-details` and `feedback-details` JSON
retain the full evidence; the FFI/native hashes are unchanged from above.

Audit the late camera/screen lifecycle without adding keepalive traffic or
changing the browser-like 30-s QUIC idle limit. The SDK prepares sources at
open; later real source selection uses `ParallelSession::prepare_frame` to
warm a closed child, and negotiated cold sources cannot enter the parent's
congestion state. A new real-TLS/QUIC regression keeps primary packets flowing
through **35 actual seconds**, with ordinary parent heartbeat, leaving camera
and screen idle. It requires that BOTH unused children really close before
reopening them, within the existing five-second preparation budget. Their new
TLS channel bindings must differ from their old bindings and the continuously
retained primary binding. Actual camera/screen payloads must reach the peer.

The regression passes: **865 primary packets**, no loss/duplicate/reordering,
maximum send-to-receive **71.762 ms** including the late-source interval.
Audio's original authenticated connection remains unchanged. Both children
reopen and deliver, and all owned child handles close at teardown. The prior
screen-close/signaling/DATA isolation test also passes after sharing fixture
setup. The preceding production suite remains 901 passing tests; this new
case and the refactored existing case were explicitly run. This is transport
coverage, not PCM/speech proof. Cold source packets are still intentionally
withheld/dropped until an independent child is ready; the test does not claim
the host awaits readiness before capture or that the first late keyframe is
preserved. Current production code and frozen binaries are unchanged in this
cycle; only the regression and documentation change.

Goal ACTIVE. Next validate the unicast Opus/ANA floor and current Mac/Android
speech/video, including late capture and route changes. Blackview remains
attached but its installed app is **0.13.85 (4603)**, stopped; do not confuse
that installation with the frozen SDK candidate tested here. No physical app,
camera/mic/speaker, installation, deployment, push or release occurred.


## 2026-10-17: origin work release passes the unchanged full contention gate

Move spacing AFTER the relay frame assembler, into the origin session runner.
Authenticated, rate-accepted `AppIpcLossyBatch` requests now receive bounded
process-local cadence metadata, keyed by source/destination app, destination,
endpoint and local lane. Track at most 64 entries. The first observed interval
is 33 ms; later IPC receipt intervals cap at 100 ms, sub-2-ms drain bursts keep
the previous interval, and idle/backward observations reset. This estimates
local receipt cadence; it is not a claim to know camera capture cadence.
Nothing is added to IPC layout or inter-node bytes, and a remote producer
cannot request this local scheduling policy.

Reserve the complete encrypted-envelope cost ONCE before releasing a member.
Release times use each member's cost prefix, beginning at actual reservation.
A scheduled wait restores the FIFO envelope and wakes the existing runner
timer; it does not reject the frame, repeat credit, sleep in IPC, or hold an
IPC handler permit. Both DATAGRAM and ordered compatibility paths enforce the
schedule. Other local sources and neutral transit keep their own progress.
The original daemon receipt + 200-ms deadline survives destination/handler
waits, frame queueing and datagram driver handoff; expired work cannot acquire
a new lifetime. The preexisting SDK/native freshness checks remain. This new
daemon-stage bound does not establish an absolute 200-ms native-capture to
receiver deadline across every preceding IPC stage.

Eight type tests, two cadence tests and two real encrypted scheduler regressions
cover whole-cost reservation, release retries, immutable expiry, bounded local
history and independent source progress. The runtime tests distinguish actual
payloads: audio and neutral transit pass between video members, and the rest
resume without new producer input, on both carriers. The complete release
suite passes: **576 session + 169 IPC + 141 bootstrap + 15 types = 901**;
14 preexisting ignored cases remain ignored. No harness/stimulus/policy,
transport window, startup allowance or audio quality threshold was changed.

`group-source-work-pacing-360` passes the ORIGINAL full qualification:

- 3 real SDK processes, neutral shared FIFO **1024 kbit/s**, full **360 s**;
- six PCM directions, **2112** strict ordinal matches from capture start,
  **zero** missing; audio-only peak **130.163 ms**, loaded peak **180.007 ms**;
- three complete encrypted **524288-byte** files, SHA-256 all correct, by
  **352.199 / 352.211 / 305.458 s** within the original immutable deadline;
- all six decoded tails move: **14 / 13 / 14 / 13 / 14 / 14**;
- exact clocks/rows, original QoS/deadlines, source copies, routes/topology
  and independent cleanup all pass; all four node stops return zero, all
  owned parent/helper/worker/policy PIDs are gone, remaining sockets zero.

The tone peak occurs at source 2 -> receiver 0, capture **20.200008 s** /
decoded **20.380015 s**. Its packet formation / encoded-to-NetEq / native-to-
render join is **50.539 / 82.023 / 67.422 ms** (the tone lies inside a 60-ms
packet; do not sum these as if it were the packet's first captured sample).
Callback/drain handoffs are **7 / 6 microseconds**. No >=25-ms stage, aged-
ingress or slow-dispatch record fires; 991 pressure records are present.
Decoded latency recovery still discards **1160 / 1120 / 1010 ms** across each
worker's two receivers over 360 s. Tone matching is not proof of continuous
speech quality, and one passing capture is not proof against intermittent
failures or statistical attribution of the baseline's 230-ms peak.

Frozen FFI SHA-256:
`70d27678ea8721d4bbacc18f181b35566b9925aaaf5674198e6addacdcaf6fa8`.
All 196 exported symbols match the preceding artifact, including all 190
`veil_` API exports. The native library remains `group-rtp-timing-native`
(642ee4ee...), video 4x/25-ms pacing and canonical 24-kbit group policy intact.
Private `source-work-pacing-sdk/{sdk.patch,build.json,source,exports.txt}` and
`group-source-work-pacing-360-{proof,feedback-details,rtp-playout-details,
scheduler-details}.json` retain exact provenance and diagnostics.

Goal ACTIVE. Still required: recurrence checks, direct/fallback and late idle
camera/screen preparation audit, unicast low-bitrate validation and current
Mac/Android continuous-speech/video tests. ADB sees Blackview BV6600Pro at the
end of this cycle; no physical app/call/camera/mic/speaker was started. No
installation, server update, push, tag or release occurred.


## 2026-10-17: reject pacing before the relay frame assembler

A native-pacer experiment confirms a real component mechanism. WebRTC's
`MaybeUpdateMediaRateDueToLongQueue` raises the pacing rate to flush a frame
inside its queue ceiling. With the existing 4x/25-ms video profile, all
5060 bytes of a low-rate test frame leave immediately inside the ordinary
40-ms burst allowance. A candidate 4x/100-ms video profile reduces that burst
to 2024 bytes, finishes at 97 ms, preserves all packet bytes/order and still
sends small/healthy-rate frames immediately. The independent audio Call is
unchanged. The real-pacer component check is first RED, then candidate GREEN.
It does not prove that the complete relay path retains that pacing.

`group-video-pacing-360` is measurement-valid and **NEGATIVE**: 2112 ordinal
matches / zero missing, audio-only **140.297 ms**, loaded **210.046 ms**
(source 2 -> receiver 0, capture 122.210 s / decoded 122.420 s). All three full
encrypted 512-KiB hashes match by 352.182/312.512/352.364 s within the original
immutable 360-s deadline. Video tails **14/6/13/6/13/14** all move. Exact
clock/rows, real QoS/deadlines, original harness/stimulus/startup budgets,
canonical production policy, route/topology and independent cleanup gates
pass. Four node stops return zero; all owned processes and sockets are gone.
Do NOT round 210.046 ms into a pass or infer a statistical improvement from
one comparison. The preceding 24-kbit baseline remains negative.

At the new tone peak the exact encoder/accepted-packet/render join is
50.363/117.844/41.748 ms. Native callback-to-drain and drain-to-NetEq delays
are 17/15 microseconds. No >=25-ms slow-stage, aged-ingress or slow-dispatch
record fires; 991 pressure records confirm probes were active. The remaining
path wait is real; bounded native buffer/age alone still cannot establish
healthy end-to-end latency.

Further source inspection invalidates the proposed repair location for relay
traffic. The ORIGIN SDK's `MediaVideoIngress::RelayFrames` assembles RTP until
the frame marker, retaining the earliest original deadline. Its
`drain_relay_video_batches_on_plane` then publishes every fresh sealed cell
as ONE IPC work batch. The daemon constructs `LocalLossyWork` and reserves
its whole cost before releasing members. Consequently native RTP spacing
before this assembler does not become spaced relay cells: it can instead
consume freshness time and then emit the assembled frame as another burst.
The fixture uses exactly this path (`veil_media_open_relay_channel`, compact
batching mode 2). A codec-boundary pacer check cannot qualify that SDK path.

The 100-ms native treatment, helper and treatment-only test were therefore
**REVERTED**. Current runtime retains its original 4x/25-ms profile, codec
budgets, transport windows, routes, relay neutrality and wire formats. The
rejected native/production binaries (131/100 unchanged exports) and complete
source/patch manifests remain private, SHA-256:
`0a6d84d49010b2030319e2a6ec68ef028410b96018e393d1371a19eb66b81006` and
`4648ea0418df31cae5696de6d9d3998f64eef94fc7110b53a4ac6bb93be25dba`.
The matching current native artifact is again `group-rtp-timing-native`
(642ee4ee...), with the canonical 24-kbit group policy from da90dd51. Rust
FFI remains c2c02c23... from d7591687. Do not ship the rejected treatment or
reintroduce the earlier rejected generic 2400-byte QUIC-window experiment.

A separate retained test fix addresses an older VAP1 expected-value bug. The
standalone call-plane test read the compound RTCP packet's final four bytes,
which now belong to VAP2, as VAP1 delay. The identical assertion fails against
the preceding frozen native artifact. It now captures the named VAP1 block's
delay atomically with the WHOLE compound and still requires exact equality
at the receiver. VAP2 is retained; no quality gate or group-process fixture
is changed. Main and RTCP-loss modes pass against both the candidate and,
after reverting the treatment, the matching current native artifact
(`vap1-reader-current-call-planes.log`).

Private `group-video-pacing-360-{proof,feedback-details,scheduler-details,
rtp-playout-details}.json`, `video-pacing-{red,green}.log`, both original
failed call-plane logs, `group-video-pacing-rejected-source` and the frozen
build patches retain the result and the reason for rejecting it.

Next put pacing AFTER complete-frame admission at the origin, while retaining
whole-work credit/ownership, original expiry, FIFO/order and free progress
for audio/control. Use actual local frame cadence and real cell cost; avoid
a fixed low-bandwidth cap on healthy P2P. The relay must still receive only
neutral opaque traffic. Audit direct/ordered fallback and competing authored
control too. Unicast audio-floor validation, idle mid-call plane preparation
and current physical-device/speech checks remain required. Goal ACTIVE.
No physical app/camera/mic/speaker, installation, relay update, push or release
occurred.

## 2026-10-17: separate codec attenuation from queued audio

SDK `19b73191` extends opt-in receiver timing with the accepted RTP SSRC,
sequence/timestamp and the actual rendered AudioFrame RTP position, speech
type and mute state. Packet insertion and rendering retain separate bounded,
preallocated metadata arrays; neither writes the other's storage. Failed
inserts are excluded. File formatting/I/O waits for teardown, after both
callers stop. Disabled tracing samples no clocks and reserves no arrays. No
PCM, payload, key or remote media/priority label is added. The wrapper's
decode, catch-up, jitter targets and network scheduling remain unchanged.
The native smoke verifies bounded traces, accepted-only ingress, actual frame
timestamp propagation and speech preservation on PLC/mute/error. Test/native
and production builds retain exactly 131/100 exports, with SHA-256
`642ee4ee4743da12b28d342537ff42611ebd8fdd53fa41a34c4f1a8426b80179` and
`67c7c7aecd304b385f6ce2c1c2185c75b99edacdd0219599620c6062170e5870`.

`group-rtp-timing-360` is measurement-valid and **NEGATIVE**: 2112 ordinal
matches / zero missing, audio-only **110.350 ms**, loaded **560.267 ms**,
video tails **0/0/1/0/1/0**. All three full encrypted 512-KiB hashes match by
331.303/328.656/300.922 s, before the original immutable 360-s deadline. Exact
clock/row, real QoS/deadline, source snapshot, topology/route and independent
cleanup gates pass. All workers, policy processes, parent and awake helper
are gone; four node stops return zero and no sockets remain. There are no
>=25-ms slow-stage/aged-ingress/slow-dispatch records; 959 bounded pressure
records confirm the probes were active.

At the 560-ms tone peak, source 1's signal disappears below the fixed detector
threshold at BOTH receivers for roughly 400 ms. Accepted packets continue;
concealment/discard counters do not advance in the surrounding samples. The
rendered frame's RTP capture age is about 132 ms, with roughly 92-96 ms from
accepted NetEq insertion to render. This RTP position is not the waveform
latency and must NOT replace or relax the original PCM gate. The source's
older encoder trace stops at its 4096-packet limit before this late event, so
it cannot directly prove that particular packet's encoded contents.

A separate real Opus encode/decode experiment, without transport or NetEq,
does reproduce deep attenuation of the sustained 1300/1700-Hz input: at
16 kbit/s the longest below-threshold interval is 690 ms, with DTX either on
or off. At a representative low point decoded total RMS is only about 40,
not merely a frequency-detector mismatch. The initial private comparison at
24/32 kbit/s has no below-threshold intervals after its observation window;
the final committed regression retains the bitrate-only encoder and checks
the ENTIRE capture from the first block, with the same 690-ms negative at
16 kbit/s and zero quiet blocks at 24/32, DTX either on or off. Its standalone
runner passes all six profiles using the current pinned encoder/decoder. This
rules out disabling DTX as the repair for this component case. It does not
prove continuous-speech quality or attribute every pause to the codec.

There is separate transport evidence. At 214 s, source 0's packet takes
50.916 ms from its first encoder input to encoding, **153.949 ms** from
encoding to NetEq insertion and **35.121 ms** there before render. Source 2
similarly spends 50.624/128.201/61.143 ms. The actual tone gates for these
paths fail at 220.040/250.341 ms. Direction 0's blind FIFO reaches 98.908 ms
in that second despite an 818-kbit/s one-second average. Sender 0 produces
a 4814-byte fanout video increment then, while sender 1 is already paused;
this is evidence of a coincident burst, not a causal packet-to-wire mapping.
End-to-end quality needs both codec preservation and bounded competing bursts.

The group production ladder now keeps a **24-kbit payload floor**:
20/32, 40/32, 40/24, conditionally 60/24. Initial 40/32, capability checks,
actual applied-floor/packet-duration evidence, cooldowns and room-wide recovery
remain. The new floor regression is first RED at 16000, then **138 focused
Flutter cases pass**. Native APIs retain compatibility with 16-kbit callers;
the unicast ANA floor is not changed by this group-controller patch and still
needs evaluation. The standalone `group_opus_signal_smoke` preserves the
negative profile and checks the protected profiles from capture start, with
no network/NetEq or retained audio.

`group-opus24-floor-360` is measurement-valid and still **NEGATIVE**:
2112 ordinal matches / zero missing, audio-only **110.224 ms**, loaded
**230.038 ms** (source 1 -> receiver 2, capture 214.120 s / decoded 214.350 s).
All three full encrypted 512-KiB hashes match by
347.132/335.818/338.782 s within the original 360-s deadline; video tails
**0/14/14/14/14/0** still fail because source 1 ends paused. The original
40/32 startup is verified on all senders; every applied payload budget is at
least 24 kbit/s. Longer actual packets begin at 28.010/5.014/21.010 s. The
complete harness/stimulus, original clock/rows/QoS/deadlines, topology/routes,
ordinal matching and independent cleanup checks pass, with four zero node
stops and no remaining owned process/socket. The post-capture Dart change is
only a comment qualifier and required braces around an existing single
assignment; its exact bounded diff is retained separately. Analyzer is clean.

The worst new tone peak has an exact encoder/accepted-packet/render join:
**50.273 ms** from first encoder input to its packet, **163.604 ms** from
encoding to NetEq insertion, then **16.118 ms** to render. Native callback to
drain is 13 microseconds; drain to insertion is 12 microseconds. Thus this
episode's over-limit delay already exists before the playout buffer; lowering
NetEq's target cannot repair that path wait. The blind direction-0 FIFO peaks
at 94.429 ms at second 214, with an 855.112-kbit/s one-second offered average.
Release lateness is <=4.308 ms there. No >=25-ms slow-stage/aged-ingress/
slow-dispatch event fires; 990 pressure records are present. The larger
explicit 32768-row encoder/ingress diagnostic limit retains late samples too;
no quality gate or workload is changed. Preserve the earlier 560-ms waveform
negative and do not infer a causal network improvement from this pair of runs.

Full contention qualification remains required; goal ACTIVE. Next investigate
short competing bursts and packet formation, including endpoint-owned control
and direct-send credits, without granting relay priority. Native unicast
payload protection, idle mid-call camera/screen preparation and current device/
continuous-speech checks remain outstanding.

Private `group-rtp-timing-360-{proof,feedback-details,scheduler-details,
rtp-playout-details,wire-214}.json` and `opus-tone-isolation-bitrates.log`
retain the distinction. Corresponding `group-opus24-floor-360-{proof,
feedback-details,scheduler-details,rtp-playout-details,wire-peak,
post-capture-lint}.json` and `group-opus-signal-regression-final.log` retain the
new candidate and original negative evidence. Rust FFI remains c2c02c23...
from d7591687. No
physical app, call, camera/mic/speaker, install, relay update, push or release
occurred.

## 2026-10-17: adapt group Opus framing after measured floor pressure

`GroupCallAudioAdapter` now consumes fresh authenticated peer decoded-recovery
events as pressure, including consuming them while muted so unmute cannot
replay a cut. An active peer-loss witness also prevents false healthy recovery.
The original startup remains 40 ms/32 kbit/s, followed by the existing
40/24 and 40/16 pressure budgets. Only a fresh valid engine advertising the
new endpoint-local `audio_max_packet_ms:60` statistic can enter a final 60/16
budget. It must already have applied 40/16, actually emitted more packets at
40 ms, and observe new pressure after the existing cooldown. Local decoded
catch-up cannot skip that measured floor. Unsupported/unknown/stalled engines
do not enable it; an explicit legacy maximum cancels an unsupported pending
retune. The existing native API already supports 60 ms. No initial profile,
codec payload floor, cooldown, relay behavior, transport format or export is
changed. A longer packet reduces framing frequency at the cost of longer
packetization; it is an endpoint fallback, not proof of better speech quality.

Focused Flutter policy tests pass **137 cases**, and the two changed Dart files
analyze cleanly. Coverage includes actual floor duration/packet advancement,
unknown/stale capabilities, failed retunes, legacy downgrade, fresh peer loss,
muted consumption, cached witnesses and healthy recovery. Native and production
builds retain exactly 131/100 exports; SHA-256 values are respectively
`61589862fcde3757b929b76878dff10ba76b318f805ef4a2fb49210dbfba24d4` and
`029ce416fdbde8e1a7ffab55ae3e9ba9de3b8d23654c043603b2da96c6177dc5`.
The FFI remains the frozen direct-app artifact c2c02c23... from d7591687.
Complete native source/patch and production-policy hashes match the capture.

`group-opus60-adapt-60` is measurement-valid but not a full qualification:
330 ordinal matches / zero missing, audio-only 170.048 ms, loaded 250.208 ms,
moving tails 14/6/13/6/13/14, and only partial files. The earlier fixed-60-ms
experiment with 55 missing transitions remains a negative; this adaptive run
does not erase it or authorize changing the fixture's startup.

`group-opus60-adapt-360` is measurement-valid and still **NEGATIVE**:
2112 ordinal matches / zero missing, audio-only **120.239 ms**, loaded
**270.048 ms** (source 1 -> receiver 2, capture 311.080 s / decoded 311.350 s).
All three full encrypted 512-KiB files match hashes by
305.176/326.600/326.982 s, within the original immutable 360-s deadline.
Video tails **1/13/0/13/0/1** fail the six-moving-tail gate. Sender 0 ends
paused; final decoded discard totals are 1750/1500/2030 ms. A single pair of
runs does not establish a causal improvement over the earlier 480-ms peak.
All three senders begin at 40/32; actual packets reach 60 ms at
22.000/6.013/22.010 s, and each retains one RTP origin throughout. The earlier
fixed-60 transition loss does not reproduce, but audio latency and sustained
video remain unqualified. No >=25-ms slow-stage, aged-ingress or slow-dispatch
record fires; 956 pressure/head records confirm diagnostics are active.

Private `group-opus60-adapt-360-{proof,feedback-details,scheduler-details,
duration-details}.json` retains the result. Original harness/stimulus, blind
1024-kbit shared FIFO, topology/routes, exact clock/row counts, real QoS and
deadlines, ordinal matching from capture start and independent cleanup gates
all pass. All workers, policy processes, parent and scoped awake helper are
gone; four node stops return zero, file threads exit and no sockets remain.
No physical app, call, camera/mic/speaker, installation, relay update, push or
release occurred. Goal ACTIVE. Remaining work includes shared-wire backlog
and competing local production, stalled video recovery, idle mid-call media
preparation, and current device/continuous-speech validation.

## 2026-10-17: negotiate direct App records on the reliable child

SDK `d7591687` closes a gap: the reliable plane previously carried AppOpen/Data/Close/Receipt/
WindowUpdate streams and negotiated Delivery records, but streamless AppSend,
AppSendSealed and AppSendChunk still selected the canonical writer. The new
SUPPORTS_RELIABLE_DIRECT_APP bit (extra_flags2 bit 1) independently negotiates
those records and their empty AppSendUnopenable re-key hint. It requires the
existing authenticated reliable-parent permission. Full handshakes advertise
it; authenticated fresh-key resume metadata carries and verifies it. The
complete original 20-byte capabilities prefix, extension lengths, transcript
and old-peer fallback are preserved. A Delivery-only peer does not receive
App records on a child. No connection/pool/quota, application-role wire label,
relay priority or codec/quality change is introduced.

QUIC and ordered runtime offers carry the permission to the canonical runner.
Eligible records are streamless, fully framed and fit the existing child
record limit. AppSend payload lengths are checked without copying application
bytes. AppRtData remains on its datagram path; AppData still requires its
AppOpen ownership, and own network control keeps its original parent path.
Malformed/nonzero-stream records cannot bypass stream ownership on the child;
oversized compatibility records and a not-yet-ready child retain the parent.
Direct records have no App stream pin and do not inherit another stream's
failure state. The ordinary dispatcher still checks ratchet, sender, chunk
reassembly and budgets using the authenticated canonical peer.

A regression is first RED with Canonical where Child was required, then GREEN.
Routing tests cover independent permissions, legacy/absent-child fallback,
network control, malformed lengths and hints, RTP exclusion, nonzero stream
IDs, record-limit boundaries and stream-pin separation. Real QUIC and obfs4/TCP
children transfer all four App record types both ways. Ordered re-key tests
retire the old handle, preserve parent viability and transfer new records on
the new generation. Full and resumed capability tests include the new bit;
flipping it invalidates the resumed proof. Release results: **574 session,
836 protocol, 141 bootstrap passed**, with 8/0/1 existing ignored. FFI build
uses node-embedded,packet-tunnel,tls-boring,production-seeds and keeps the exact
190 exports. Frozen `direct-app-child-sdk` SHA-256:
`c2c02c23d9d1df8bcc4b89d349eca2d9462654f1a7688b133698ca0216ebf288`;
its complete patch/source manifest is based on e7a9ef57.

New `scripts/direct-record-process-preflight.py` uses actual veil_send and
application callbacks on the direct root/leaf link of a fresh loopback star.
`direct-app-sdk-final` passes: two complete 512-KiB payloads and four bracketing
messages each arrive once with matching hashes, node/application IDs and
SessionPeer/Signed provenance. Metadata confirms four direct AppSendSealed
child admissions and 294 existing sealed-Forward child admissions. An earlier
probe delivered all six payloads too, but its final assertion incorrectly
required AppSendChunk: large SEALED sends use addressed Forward chunks, while
AppSendChunk is the distinct arbitrary-unsealed-byte format. The assertion
was corrected to require the actual encrypted SDK path and the complete test
was rerun; retain the earlier failed assertion as such. Types 3/9/8 are covered
by real transport record tests, not by pretending this encrypted API case
sends them. The first cold message takes 6.015 s, files 14.093/9.858 ms and the
other warmed small messages 0.137-0.538 ms. The cold delay is observed, not
explained or claimed fixed. Source snapshots and the SDK hash are frozen with
the final probe. All four nodes stop zero, no sockets remain and the owned
Python process is independently gone.

`group-direct-app-360` preserves the original harness/stimulus/policy hashes,
blind shared 1024-kbit FIFO, original topology/routes, native clocks/QoS/
deadlines and immutable 360-s/file deadline. Native media is the unchanged
7e63b64e... peer-recovery artifact. It is measurement-valid but **NEGATIVE**:
2112 matched transitions / zero missing, audio-only peak 110.118 ms, loaded
**480.041 ms** (source 1 -> receiver 0, transition 259.570 s / decoded
260.050 s). All three encrypted 512-KiB hashes match by
352.131/340.125/351.968 s, without missing/auth/duplicate/late/write/async
failures. Video tails **0/12/14/12/14/0** fail the six-moving-tail gate, even
though all three source policies end nominally unpaused at 8/8/15 kbit/s.
Native pause flags end at zero. Source 1 nevertheless stays paused through
356 s, resumes at 357 s and emits only one additional encoded frame by the
last sample (139 -> 140); its two zero decoded tails cannot be dismissed by
the final unpaused flag. Decoded discards total 2800/880/860 ms; peer feedback support is exercised on
all workers, with 13/22/26 distinct observed loss witnesses. Native receive
age maxima 66/58/57 ms do not measure encoded capture-to-playout delay and
must not be used to call this healthy.

This time the full wire ring retains the actual peak. Direction 0 offered
1126.4/1126.2/1076.7 kbit/s at seconds 257/258/259, above 1024; FIFO maxima
115.5/207.4/208.2 ms, still 202.7 at second 260. Release lateness there is
only 1-2 ms. The opposite FIFO stays below 42 ms in that window. Deterministic
UDP pairs reach 204 ms before kernel arrival with approximately immediate
socket reads. There are no >=25-ms slow-stage, aged-ingress or slow-dispatch
records; 1011 bounded pressure/head records confirm diagnostics were active.
Thus this late episode has direct evidence of shared-wire queue buildup,
not the previous rare ~140-ms socket-read episode. Do not attribute the
single-run difference to the direct-record feature. The new feature is
verified for its routing scope; sustained media quality remains unqualified.

At the peak, source 0 is already paused and source 1/2 produce near 8 kbit/s /
1 fps, without the previous large video growth burst. Receiver 0's reported
playout buffer instead falls toward 35 ms while packets wait on the wire;
its actual capture delay is growing. Source 1 still sees a small peer playout
buffer and only later observes loss. This confirms that a bounded or shrinking
receive buffer cannot alone prove a healthy end-to-end path. Next account for
wire occupancy, pacing/bursts and endpoint-owned competing traffic, preserving
relay neutrality and the 200-ms gate. Also audit ordinary small direct sends:
reg.send_to lacks the reliable source credit used by packetized files; merely
moving a record to the child does not prove all competing local production is
paced. A possible endpoint-only efficiency direction is longer Opus packets
AFTER measured congestion (keep the original startup/base profile), since the
current 40-ms packet cap plus fixed encrypted-cell overhead leaves little
headroom for six paths. This is a hypothesis to evaluate, not implemented or
permission to change the fixture's initial stimulus/profile. Mid-call idle
camera/screen preparation and current physical-device/speech validation remain
required. Goal ACTIVE; no completion claim.

Private `group-direct-app-360-{proof,feedback-details,scheduler-details,
wire-peak}.json` preserves the gates and peak evidence. Strict clock/row,
real QoS/deadline, topology, route and independent cleanup checks pass;
parents, workers, policy processes and scoped awake helper are gone, all four
node stops zero, file threads exit and no sockets remain. No physical app,
call, camera/mic/speaker, installation, relay update, push or release occurred.

## 2026-10-16: distinguish socket-read stalls from session queue delay

The preceding measurement-valid `group-peer-recovery-360` log has stronger
local evidence than its cumulative outbox maximum alone. Joining deterministic
1/16 encrypted-UDP fingerprints yields 443 matched samples in the 108-121-s
window, all with kernel receive timestamps. One 912-byte packet on local
connection 73 is handed off at 116.164 s, reaches the receiving kernel around
116.175400 s, but is logged at socket read at 116.315 s: approximately 11.4 ms
to the kernel plus **139.6 ms waiting for user-space read**. Millisecond-floor
log timestamps introduce <1-ms rounding, not a 140-ms ambiguity. Other paired
packets in that window show up to about 91 ms before kernel arrival. These
samples distinguish two different waits; do not label every pause as carrier
loss or infer that this one reverse-direction packet proves the worst voice
path's cause. `group-peer-recovery-360-peak-udp-pairs.json` preserves all pairs.

SDK `e7a9ef57` opt-in session diagnostics measure wall time of synchronous ingress drain,
maintenance/rekey, datagram drain and ordered drain, logging stages >=25 ms.
A bounded per-runner window reports aged ingress before the priority queue,
at most once per second. Existing source-pressure records include at most
one header-only head per local queue (family, message, byte count and opaque
carrier presence). Reliable-child dispatch now has the same >=25-ms slow
handler coverage as canonical dispatch. No body, key, carrier ID, remote
media role or scheduling privilege is exposed. All scheduling, admission,
transport selection, source budgets, deadlines and packet formats remain
unchanged; disabled probes do not sample clocks or allocate header strings.
These probes narrow the next investigation; they are not a latency fix.

Release tests: `cargo test --release -p veil-session -p veil-bootstrap --lib
--features veil-bootstrap/production-seeds` with
`CARGO_PROFILE_RELEASE_PANIC=unwind` passes **569 session + 141 bootstrap**
tests (8 + 1 existing ignored). The release seed marker is necessary even
for these local tests; selecting veil-session alone without the network marker
fails the bootstrap compile guard, not a regression test. SDK production
features remain node-embedded,packet-tunnel,tls-boring,production-seeds.
Frozen `group-scheduler-trace-sdk` has FFI SHA-256
`06b4e1a5a44e8a94f397151d912cd875983c36099d7073df39371bf97af8cc79`,
exactly the prior 190 exports and a full three-file source patch against
07a3e8d1. Native media stays the exact peer-recovery artifact (7e63b64e...);
all harness, stimulus, production-policy inputs and 360-s deadlines stay fixed.

`group-sched-trace-360` is **NOT measurement-valid for full qualification**:
participant 1 captures 36002 ticks / 108006 rows instead of the required
36001 / 108003. Participants 0 and 2 retain the exact counts. Keep the original
count gate; do not trim the extra end tick or relax the verifier. All three
clocks have zero late intervals, deadline misses, dropped rows or capture/
playout failures, with maximum intervals 10.057/10.063/10.059 ms; the failure
is the extra final tick, not evidence of a >25-ms device-clock pause. Observed
2112 matched transitions / zero missing, audio-only 130.204 ms, loaded
230.131 ms (source 2 -> receiver 1, transition 30.300 s / decoded 30.530 s),
video tails 9/11/11/11/11/9, and three full correct 512-KiB hashes by
352.121/352.269/352.040 s do NOT turn this into a valid full pass. Files have
no auth/duplicate/missing/late/write/async failures. Retain the valid negative
prior capture as the qualification evidence.

Diagnostics were active (1013 source-pressure/head records), but no slow-stage,
aged-ingress or slow-dispatch record fires anywhere in the new run. Deferred
heads are principally this endpoint's paced reliable Forward records in the
background queue, not proof of a neutral voice cell blocked behind a file.
At the observed 30-s peak, 431 paired sampled UDP packets show up to 96 ms
handoff-to-read, principally before kernel arrival; there is no newly increased
>=25-ms outbox maximum in that window. Across the full immutable capture,
13896 sampled pairs all have kernel timestamps; maximum kernel-to-read is
10.375 ms, none >=25 ms. Thus the old ~140-ms socket-read episode did NOT
reproduce, while an over-limit voice observation still occurs. Do not attribute
the different observed peaks to the passive diagnostics. More than one wait
still needs investigation, including the UDP endpoint/driver wakeup and locks,
shared wire bursts, and original required independent direct-record/mid-call/
physical-device scope. Primary source allocation is one physical child per
local selector, not one per remote recipient; the current single-primary
relative RTT observer cannot be declared broken merely by assuming recipient
alternation. Actual source_data_delay probes fire in this run.

`group-sched-trace-360-{proof,scheduler-details,feedback-details,
udp-read-details}.json` and the frozen SDK manifest preserve these limits.
Independent cleanup passes: parent, workers, policies and awake helper gone,
all four node stops zero, file threads exited and no remaining sockets.
No physical app/call/capture/speaker, installation, relay deployment, push or
release was started. Goal ACTIVE.

## 2026-10-16: per-receiver decoded-loss feedback; long contention still fails

SDK `07a3e8d1` attributes intentional decoded-audio discards to the
actual receive NetEq and its first successfully accepted RTP SSRC. A weak,
bounded call registry retires counters with the decoder; a recreated stream
gets a new monotonically allocated origin. The render callback only updates
atomics and takes no registry lock or allocation. PLC/mute/error fallback
without an actual skipped speech frame does not claim remote decoded loss.
Existing target ceilings, catch-up limits and aggregate diagnostics remain.

An optional 48-byte VAP2 RTCP APP block carries the target audio SSRC, report
sequence, receiver origin, cumulative discarded milliseconds and bounded event
age inside the existing authenticated encrypted media channel. It adds no
relay role, preference, connection, public ABI export or remote clock. VAP1 is
unchanged. Both unicast and group stats publish receiver-specific samples;
stale/unknown samples do not claim fresh loss. The receiver validates the whole
compound before publishing any feedback. SSRC binding, report sequence, origin,
counter high water and expiry prevent replay or a repeated old event in a new
report from renewing the loss witness. The sender uses local ingress time,
not the later stats-query time. Group diagnostics also retain per-receiver
known/cumulative-discard fields so attribution can be checked on the real path.

Production video adaptation and local source-pressure policy consume a
separate freshness ledger for the peer's decoded loss. One real new event
uses the existing two-rung audio-protection cut and brief producer yield;
cached/expired reports and events observed while sending is off cannot replay
at resume. The group stand bridge passes the same new native field as both
production controllers. No harness, source stimulus, base profile, FIFO,
clock, matching rule or qualification deadline is changed. Exactly three
captured production-policy input hashes change: call_bitrate_adapter.dart,
call_audio_source_pressure.dart and the group_codec_policy.dart bridge.

Evidence: real NetEq-wrapper source-attribution/catch-up regression, real RTCP
codec/parser tests, real production-shim compound/legacy/replay/malformed/
video/stopped-source tests and the existing RTCP lane-filter regression pass.
The initial shim test failed because it queried an unstarted shim (whose
getter intentionally returns empty); starting the test endpoint fixes that
setup error. Dart policy tests pass **116**, and analysis of all six changed
production/test Dart files reports no issues. Ordinary native exports remain
exactly the prior 100; instrumented exports remain the prior 131.
Frozen pair: `group-peer-recovery-{native,production}`; native SHA-256
`7e63b64e85123999283b3c7c15a59a519447ffa4413fae539fb2b71487247ed2`,
production `2d9a48f1606d43cba05b5021ec81599223bc4c7699cd80584a421c37135263d8`.
Both freeze the full SDK patch and changed-source hashes against 19589f40.
Network SDK is the unchanged 214c3a67 artifact (FFI SHA e2bca2f9...).

`group-peer-recovery-60` is measurement-valid: 330 matched transitions, zero
missing, audio-only peak 140.133 ms, loaded peak 190.081 ms; six video tails
move 9/10/10/10/10/9. Its three 59392-byte prefixes do not prove complete-file
delivery. All three workers recognize two feedback-capable peers and consume
fresh decoded-loss witnesses (2/4/2 distinct observed witness times).

`group-peer-recovery-360` is measurement-valid but **NEGATIVE**: 2112 matched,
zero missing; audio-only peak 150.063 ms, loaded **340.076 ms**, source 1 to
receiver 0, capture transition 116.150 s / decoded 116.490 s. All three complete
encrypted 512-KiB files match full hashes by 351.606/351.871/351.883 s, without
chunk/authentication/duplicate/late/write/async failures. Video tails
**0/4/2/4/2/0** fail the six-moving-tail gate; source 1 ends paused and sources
0/2 at 8 kbit/s / 1 fps. Decoded discards are 1690/1730/1780 ms. Each worker
recognizes both peers, with 23/29/22 distinct fresh witness times. Native
receive-age maxima are 60/63/68 ms. These runs prove the new signal is actually
exercised, not that latency or video freezing is solved. The short pass and
lower long peak than the preceding single run do not prove repeatability.

At the long peak sources already protect audio: source 1 has been pressured
at 8 kbit/s / 1 fps and pauses at 116 s; source 0 drops 15 -> 8 at 115 s;
source 2 runs 8 after a paused-floor trial. Their receiver buffers are bounded,
but real decoded loss still advances. The transport trace also records a new
132.865/140.511/148.535-ms outbox-to-transport maximum at 116.486-116.534 s
on three connections toward endpoint acbe946e (participant 1); QUIC queue,
pacing and event/timer maxima there remain small. This is a new pre-transport
lead, NOT proof of the worst path's cause or permission to prioritize relays.
The bounded 100000-row wire trace retains only 197.871-360.615 s, so it cannot
establish FIFO occupancy at the earlier 116-s peak. Private feedback/transport
window JSON retains this distinction. Investigate the producer/dispatcher/
canonical-runner waits and packet scheduling before changing another codec
threshold. Direct AppSend/AppSendSealed/AppSendChunk records also remain on the
canonical path: reliable_streams scopes AppOpen/Data/Close/Receipt/WindowUpdate
and negotiated Delivery records only. Moving additional records needs explicit
compatibility negotiation, not an unannounced acceptance-policy expansion.
Mid-call idle camera/screen preparation and current physical-device validation
remain required; no claim closes those gaps.

Both captures use scoped awake helpers; strict ordinal matching, original
routes/topology, native clocks/rows/QoS/deadline checks and independent cleanup
pass. Long clock maximum intervals are 10.073/10.085/10.080 ms, zero late
intervals. All workers, policy processes, parents and awake helpers are gone;
four node stops return zero, file threads exit and no sockets remain. Proofs
are `group-peer-recovery-{60,360}-proof.json`, with separate native/policy
manifests and captured-source-copy verification. Blackview remains visible
via read-only ADB; no physical app, call, camera, microphone, speaker, install
or relay deployment was started. Goal ACTIVE; no push/release.

## 2026-10-16: honor source adaptation and enable real VP8 rate control

SDK `fabf3d3d` replaces the push-only VideoBroadcaster with a source that
actually applies its combined sink requests. The previous camera/screen path
never reduced pixels or honored encoder cadence requests. A real bundled
VideoAdapter now chooses crop/scale/alignment and cadence before the encoder;
unchanged frames retain their original buffer, and adaptation preserves the
capture timestamp. Its decision lock is released before pixel scaling and
sink callbacks. Original capture feeds preview separately. All common I420
paths, including Android's latest-only dispatcher, group and unicast camera,
screen and synthetic capture, use this source. It introduces no timer, extra
thread, wire label or relay preference. The source regression first fails on
the old pass-through behavior, then passes real reduction/alignment/recovery,
cadence and preview-buffer ownership checks.

The unchanged `group-source-adapt-60` capture is valid but NEGATIVE: all 330
control transitions match, zero missing; audio-only peak 140.060 ms, loaded
220.048 ms, tails 4/13/14/13/14/4. Its 360-s counterpart is also NEGATIVE:
2112 matched, zero missing; audio-only 120.233 ms, loaded **200.132 ms**. Do not
round this into a pass. All three 512-KiB encrypted files match their full
hashes by 351.595/352.222/352.126 s; six tails move 14/2/14/2/14/14. All decoded
frames in these captures remain 320x240: the source fix alone does not prove
network-driven resolution reduction. Frozen native/production pair is
`group-source-adapt-{native,production}`, with 131/100 unchanged exports;
test native SHA-256 `e882702ee80cd3740a28412e1bb5f6a8bb30f8081a14e298711177534ccfba12`.
Independent clocks/routes/topology/cleanup checks pass for both captures.

Follow-up SDK `19589f40` repairs two disabled parts of the codec contract:
GetDefaultVp8Settings disables automaticResizeOn, and VideoEncoderConfig
starts with frame_drop_enabled=false. VP8 exposes QualityScaler thresholds
only with automatic resizing AND frame dropping enabled. A common production
configuration now enables both for all four start/retune sites (unicast and
group), retains the 240-frame recovery interval, Android denoiser choice and
QP limits, and permits a 6144-pixel floor through the supported video-only
WebRTC-VideoRateControl field trial. This lower floor permits coarse images
under a very small budget; it does not force healthy sources to shrink.
The real bundled VP8 regression first fails because its scaling thresholds
are absent, then passes with the production configuration and lower pixel
floor. It initializes a real 8-kbit/s / 1-fps encoder, rather than mocking
EncoderInfo. The original source regression still passes. There is no audio
field-trial change, packet/payload modification or relay policy change.

Both native artifacts are independently frozen with complete patches and
source hashes, and ordinary builds retain 100 exports with no test hooks.
The final configured pair is `group-resize-on-{native,production}`; test native
SHA-256 `4091df2b5dc09354536bc90720ddee2510b415096272ebcc7a52064411979f72`,
production SHA-256 `c77ec6a507325d105fcd286ac78ad83b92f4f3dde8a7f64f6ec11699bd9dcc65`.
Rust SDK remains the exact `214c3a67` artifact (FFI SHA e2bca2f9...), so the
native comparison does not bundle a new network implementation. No Dart policy,
fixture, synthetic source or qualification deadline is changed.

`group-resize-on-60` is valid: 330 matched, zero missing, audio-only peak
150.110 ms and loaded peak 170.153 ms. All six tails move 8/11/9/11/9/8. Short
file prefixes 61440/59392/59392 bytes do not prove complete-file delivery;
decoded frames remain 320x240 within this short observation. Full qualification
is FALSE because the full immutable 360-s/file/hash gate is still required.
`group-resize-on-360` is measurement-valid but NEGATIVE: all 2112 control
transitions match without misses, audio-only peak 110.065 ms, loaded peak
430.030 ms at source transition 298.960 s (receiver 1 from source 2). Three
complete encrypted 512-KiB files verify by 351.545/351.980/350.269 s, with no
missing/authentication/duplicate/late chunks, sender async failure or write
error. Video tails 14/0/0/0/0/14 FAIL the six-moving-tail gate. Sources 0 and 2
end paused; source 1 ends at 15 kbit/s / 1.5 fps. Actual 240x180 decoded frames
now appear on receivers 0 and 1 alongside 320x240, proving that resolution
adaptation is exercised; this still does not prove good sustained audio/video.
Decoded discards total 1390/5990/1180 ms across each worker's two receivers.
Native receive-age maxima 64/68/74 ms do not reproduce the earlier long outage.
At seconds 296 and 298 relay-to-endpoint offered traffic reaches 1077.7/1057.0
kbit/s and the shared FIFO 197.3/202.7 ms; the opposite FIFO stays below 36.5 ms
in this window. Keep this result alongside the passing short latency sample;
do not claim a repeatable sound-latency improvement.

A more specific next defect is now source-confirmed. Encrypted VAP1 playout
feedback sends only target SSRC, sequence and current remaining buffer delay.
It does NOT tell the sending endpoint that the receiver has intentionally
skipped decoded audio to catch up. Normal RTCP packet loss stays zero because
the network delivered those packets. Consequently the bounded receiver buffer
can hide actual decoded loss from the sender's quality/source-pressure policy.
In this trace receiver 1 repeatedly reports local catch-up at 294, 298, 299,
300 and 302 s while its own video is already paused. Sender 2 nevertheless
reads peer buffers around 81-83 ms, peer_pressure=false, sourcePressured=false,
no local catch-up and zero tx loss at 294-300 s; it raises 15 -> 38 kbit/s by
296 s and does not reduce to 8 until its OWN catch-up at 302 s. The receiver's
audio pain is real (the independently decoded 430-ms peak) but is absent from
that sender's feedback. This is a stronger lead than blindly shrinking the
8192-byte secondary allowance: when the sender is not marked pressured, that
allowance does not apply at all.

Next carry fresh decoded-recovery information from the affected receiver to
its sender INSIDE the authenticated encrypted media feedback, bound to the
correct audio SSRC, with legacy compatibility, freshness and replay guards.
Prefer per-receiver recovery attribution; current recovery counters aggregate
both receivers. Do not disclose an audio role/priority to relays, blame all
remaining pauses on this one observation, loosen the 200-ms gate, or hide loss
by increasing the playout budget. Wire/frame burst limits may still be needed.

All four captures preserve the original harness, policy hashes, topology,
blind 1024-kbit FIFO, immutable durations, codec/source stimulus and strict
ordinal PCM matching. Changed native binaries are explicit in each manifest.
Clock row/tick, real QoS/deadline, route and independent process cleanup checks
pass; workers, policies, file threads, parents and scoped awake helpers are
gone, four node stops return zero and no sockets remain after every run.
`group-{source-adapt,resize-on}-{60,360}-proof.json` and the configured long
`-timing-details.json` preserve these results. Final configured verifier also
requires the original fixture/worker verdicts and <40-ms clock intervals.
Blackview BV6600PRORU000182 is visible via ADB; the tool daemon was started for
read-only availability inspection. No physical app, call, camera, microphone,
speaker, Android install or relay deployment was started in this work cycle.
Goal ACTIVE; no push/release.

## 2026-10-16: negotiated reliable Delivery records; contention still unqualified

SDK `214c3a67` fixes a remaining separation gap: the pre-existing reliable
child carried whole App streams, while self-contained Delivery records still
shared the canonical session writer. Forward, DeliveryStatus, Transit,
RecursiveRelay and RelayPath now use that existing authenticated child when
both peers negotiate support and the child is ready. No additional connection,
pool quota, relay traffic role, remote priority or special admission is added.
Session/control/discovery remain on the parent. Existing App stream pins,
including failure/rekey ownership and no midstream fallback, are preserved.
Delivery records retain their own content/chunk identities and dispatcher
validation, peer budgets and authentication; this does not turn a local write
receipt into an end-to-end acknowledgement. Oversized records retain the
parent rather than failing a healthy child. Expiring loss-tolerant Forward
fallbacks retain their existing lifecycle rather than entering a reliable FIFO.
The trusted LOCAL network-control selector also retains the parent.

The second marked capability extension preserves the entire original 20-byte
prefix. Missing/truncated/random markers cannot enable it, and it requires the
original reliable-child permission. Resume adds a separately marked proof
bound to fresh directional keys and the original authenticated prefix. Old
verifiers skip that extension and retain their previous permissions; forged,
orphan and duplicate recognized metadata fails verification. Full and resumed
handshakes assert negotiation in both directions. Old peers retain canonical
Delivery. Direct AppSend/AppSendSealed/AppSendChunk are not moved by this
capability; auditing those reliable semantics and the idle camera/screen-enable
lifecycle remains necessary for the full goal.

Tests: 835 proto cases, 141 bootstrap cases, final 569 session cases pass
(8 existing session manual tests ignored). Actual ordered TCP and punched
QUIC tests transfer complete Forward records both ways, preserve the parent,
and cover rekey/capacity/retirement. Routing tests cover legacy peers, invalid
families, unopened App streams, obsolete chunks, malformed lengths, record
size boundaries, expiring fallback and stateless child replacement. The first
new route test failed semantically before implementation. Separate earlier
compile errors (a scripted fixture syntax edit, and one command missing the
required production-seeds feature) were corrected before final verification.
A broad runtime run passed 654 cases but four admin-socket startup tests timed
out under parallel execution; all four passed sequentially in 6.63 seconds.
Do not describe the full parallel runtime suite as green or claim its cause
proved. Frozen final SDK/source patch is `group-delivery-child-final-sdk`,
FFI SHA-256 `e2bca2f9b3661feccd81719deb4183bc4d83e04de394e216ebe02ba5bac52447`;
190 C exports match the previous candidate. The earlier frozen
`group-delivery-child-sdk` predates the final size/loss-tolerant guards and was
not used for a contention capture. Native media remains `a9961d4a`.

Unchanged `group-delivery-child-60` is measurement-valid but NEGATIVE: 330
control transitions match without misses, audio-only peak 110.109 ms, loaded
peak 230.221 ms at 47.470 s. Video tails change 14/14/0/14/0/14 times: participant
0 remains paused in both outgoing directions. Three short file prefixes are
59392 bytes, not complete-file proof. Six first-send events with 1110-byte
records prove all participant/relay legs actually use the reliable child;
there are no ineligible-child-frame errors. Both blind FIFO directions peak
near 120 ms; at second 47 relay-to-endpoint offered traffic reaches 1063.7
kbit/s and 120.3-ms queueing. Audio-only offered traffic at seconds 10-20 is
627/629 kbit/s; loaded ten-second averages are roughly 857-912 kbit/s. This
single comparison with the earlier 207-ms short FIFO peak does not establish
a repeatable improvement. All clocks/rows/QoS/deadlines, neutral routes,
3/1/1/1 topology and independent cleanup checks pass. Short intentional decoded
catch-up remains: matched control transitions do not prove lossless speech.

Unchanged `group-delivery-child-360` is also measurement-valid but NEGATIVE:
2112 control transitions match, zero missing; audio-only peak 130.123 ms,
loaded peak 460.062 ms at 323.200 s (receiver 0 from source 1). The same receiver
also peaks at 460.045 ms from source 2 at 144.430 s. All three encrypted
512-KiB files complete with matching full hashes by 351.711/351.832/351.756 s,
zero missing/authentication/duplicate/late chunks, no async failure or write
error. Six video tails change 14/14/6/14/6/14 times. Participant 0 nevertheless
ends paused again; a moving last-15-second tail does not prove continuous video
or eliminate the policy hold/recovery issue. Final decoded discards total
7410/1280/1410 ms across each worker's two peers. Native receive-age maxima
76/80/75 ms do not reproduce the older 11.8-second outage.

A concrete next lead differs from the earlier flat-video capture. Around
322-323 s participant 2's video budget rises 15 -> 38 kbit/s and its cumulative
video payload counter grows 24644 bytes / four frames in about one second;
participant 1 also rises 8 -> 15. Participant 0 stays paused throughout that
window. Relay-to-endpoint offered traffic reaches 1180.8 kbit/s at second 322,
FIFO peak 202.0 ms, then 206.8 ms at second 323; the endpoint-to-relay FIFO
stays below 42.6 ms. Around the other 144-s audio peak participant 1 similarly
rises 15 -> 38 and emits a larger payload burst. These are measured correlations,
not yet proof of which encrypted wire bytes caused the backlog. Next trace the
local secondary connections and bound quality-recovery/frame bursts at the
producer, preserving audio freshness, full file deadlines and relay neutrality.
Do not simply increase the sound-latency gate or disable buffer protection.

All long clocks have 108003 rows / 36001 ticks, no late/drop/failure/timer or
deadline errors, actual QoS 33 and verified active deadline parameters. Max
interval <10.132 ms and callback <2.597 ms. Driver last event queue max is
0.307 ms (historical 9.610), last timer lateness max 13.288 ms (historical
38.313). Both runs retain the same frozen fixture/policy source hashes and
native media, scoped awake assertion, immutable durations and 1024-kbit blind
FIFO, neutral routes and 3/1/1/1 topology. Independently verified workers,
policies, file threads, parents and caffeinate helpers exited; all node stops
return zero and no sockets remain. `group-delivery-child-{60,360}-proof.json`
records a separate strict full qualification: FALSE. The long timing-details
artifact retains all six peaks, wire bins, native receive ages and actual video
counter/budget observations. Audio goal ACTIVE; no push/release.

## 2026-10-16: encrypted forwarding preflight; long qualification remains negative

SDK `fee1947f` prepares the real direct/ordinary-relay path during production
media open, after local independent-source readiness and before capture.
Three random per-plane challenges use a reserved subtype of the existing
AEAD-sealed VMP1 control. They traverse the actual source connections and
opaque forwarding witnesses; no fake RTP, wire role, scheduling hint or relay
priority is added. The old VMP1 parser rejects the extension and its existing
handler consumes it without passing it to RTP. Unsupported local independent
preparation skips this step; an old remote peer's silence only expires a
best-effort one-second observation. Existing SDK opens run on worker isolates;
no new C entry point or changed C signature is introduced (190 exports match).

One deadline covers all three independent challenges and their at-most-two
250-ms retries. Each request retains the minimum of its original observation
deadline and the existing 200-ms packet freshness budget. Echoes use only
call-pinned destinations and the receiver's authorized outgoing posture, not
a packet's claimed address/route. They are bounded by three permits and a
200-ms per-plane throttle. Only exact nonce/route/plane replies qualify.
Closing cancels attempts and prohibits later replies. The 64-context bound
is enforced at installation. Exact-size alternate control decryption supports
bring-up before the engine installs an RTP callback and preserves old/candidate
challenge ownership when keys match. Decrypted controls are consumed once,
before RTP counters/callbacks; this also preserves existing route probes.
Anonymous circuit preparation is unchanged. Mid-call camera/screen enable
still needs an explicit preparation lifecycle; unused children can idle out.

Final tests pass 66 media-FFI and 40 seal/route-probe cases. The new real
SDK/Unix-IPC test covers all three source lanes before any RTP callback,
then with an old callback owner sharing keys, zero audio accounting, pinned
echo destination despite a forged envelope source, and no echo/revival after
close. It does not claim Internet timing. One test compile failed for moving
a non-Copy path out of an array; array destructuring corrects that before the
final tests. Exact release/patch manifest is `group-forward-preflight-sdk`,
FFI SHA-256 `1d05390354bebad4cac233abe9afa2c7368329c80df28bcd2734d29b69c8153a`.
Committed native media remains `a9961d4a` / `group-neteq-loss-native`.

First `group-forward-ready-60` is INVALID for latency qualification: the host
enters Idle Sleep at 18:44:10, then Dark Wake Thermal Emergency / Maintenance
Sleep. All clocks report six late intervals and approximately 247330-ms wake
lateness, only 17019/17022 rows. SystemTime advances across sleep while the
fixture's monotonic origin differs, so wall-clock phase bins are invalid too.
Retain its raw results, `group-forward-ready-60-invalid-proof.json` and
`group-forward-ready-sleep-power.log`. This proves this capture's sleep;
it does NOT establish the cause of the older 11.8-second outage.

Repeat captures wrap the identical production fixture in scoped `caffeinate
-is`, with the live helper/assertions recorded and independently verified gone
afterwards. No persistent power setting/display change, physical app or audio
hardware is used. `group-forward-awake-60` is valid but NEGATIVE: 330 matched,
zero missing, audio-only peak 130.038 ms, loaded peak 230.103 ms at 27.270 s.
All six tails move 14/13/7/13/7/14 times; short files are only 59392 bytes each.
33 child starts precede capture, three occur during audio-only, three at
29.333/30.858/31.005 s; none occur at load activation. At second 27, direction-0
offered wire traffic reaches 1128 kbit/s and the blind FIFO reaches 206.9 ms,
versus 860 kbit/s / 55.3 ms in second 26. Per-worker video increments stay near
700-900 payload bytes / one frame / second, not a demonstrated keyframe surge.
Do NOT assign the residual spike to video without identifying its wire source.

Full `group-forward-awake-360` is also NEGATIVE, not qualification: all 2112
expected PCM transitions match without misses, audio-only peak 120.151 ms,
loaded peak 420.103 ms at source transition 310.070 s. All three encrypted
512-KiB files complete by 343.991/351.727/351.919 s with matching full SHA-256,
zero missing/authentication/duplicate/late chunks, no sender async failures
or write errors. Video tails change 14/0/14/0/14/14 times: participant 2 remains
paused (last budget 1 kbit/s, 0.02 fps), so both of its outgoing tails freeze.
Other participants end at 8 kbit/s / 1 fps. Moving tails remain a required gate.

Native receive-age maxima are only 81/62/78 ms: this run does not reproduce the
old 11.8-second receive outage. Last intentional decoded discards total
2260/2220/5200 ms per worker across two peers. Driver last event-queue delays
max at 4.574 ms (historical max 8.564), timer lateness max 12.134 ms. Child
starts are again 33 before capture, three audio-only and three loaded, all
loaded starts at 28.768/30.459/30.485 s, not near the late 310-s audio peak.
Remaining work: identify endpoint/ordinary/control bursts on already warm
connections, bound their impact on primary delivery, examine the video-policy
hold/recovery using actual captured inputs, then cover idle enable and phones.
Preserve full six-path/file/hash/video/deadline gates; do not substitute a
narrower test or exclude startup. Do not treat one shorter run as proof of a
repeatable improvement over earlier individual captures.

Both valid runs preserve the 1024-kbit blind FIFO, production adaptation,
three processes/six PCM paths, VP8 and three encrypted 512-KiB files. Long
clocks verify 108003 rows / 36001 ticks each, no timer/late/drop/deadline errors,
max interval <10.133 ms, max callback <2.640 ms. Short clocks similarly verify
18003/6001, zero errors. Both verify routes and exact 3/1/1/1 topology. Workers,
policies, file threads, parent and awake helpers exit; all four node stops
return zero and sockets disappear. Private per-run `*-proof.json` and
`group-forward-awake-360-timing-details.json` retain these outcomes.
Audio goal ACTIVE; no push/release.

## 2026-10-16: local source preparation; fix capacity-driven QUIC churn

SDK `9add1b65` adds production direct/ordinary-relay preparation. Media opens
now request the existing local
source readiness through authenticated IPC before starting capture. Capability
8 / HELLO_OK 0x0400 gates additive local messages 95/96. Exact 66-byte requests
validate an owned app, five allowed LOCAL selectors and flags; request ids
correlate reordered replies. Reply 3 means the existing query bucket requests
a retry. Old daemons receive no new RPC. The provider prepares only verified
direct destinations or at most two existing ordinary-relay candidates, without
discovery, mailbox, dummy RTP, remote traffic labels or relay scheduling changes.
The shared readiness type retains its existing veil-session public path.

A new preparation invalidates stale Ready once; polling does not restart it.
Prepared-but-unused closed QUIC children are detected without requiring a failed
send first. FFI preparation has one 3-second best-effort budget (DATA/control
continue in the background), respects query backoff, and retains legacy opens
when readiness is unsupported. Both existing Flutter open functions already use
Isolate.run; this does not add a UI-thread wait. Anonymous/onion preparation and
its encrypted circuit echo remain unchanged. Local Ready is NOT end-to-end
readiness, and idle video/screen activation still needs lifecycle integration.

The first real combined run `group-prepared-1024-60` exposes a capacity churn
bug: 1310 child connection starts (909 repetitions of one physical slot during
seconds 0-20), versus 31 in frozen baseline control
`group-prepared-control-60`. First-20-second offered direction-0 traffic is
2007 versus 739 kbit/s; 3403 versus 110 datagrams have length 1200. Physical
indices are not media labels. The candidate has 257 matched / 73 missing strict
PCM transitions; native receive age reaches 4697 ms. Its ordinal peaks up to
6610 ms are NOT a measured jitter-buffer size. Control has all 330 matches,
no misses, audio-only peak 150.143 ms and loaded peak 400.030 ms. Both are
NEGATIVE and retained, with complete cleanup/clock/topology proofs. First
fixture invocation rejected an overlong Unix address before starting nodes;
the shorter owned directory fixes the path without altering any test gate.

At the two-slot reserve, prepare_index previously retired optional signaling
BEFORE checking whether the selected child was already ready or warming. Its
pending preparation immediately reopened that child, without cancellation
backoff. Now existing children reuse their allocation; actual new allocation
can still reclaim signaling, and the critical one-slot reserve still reclaims
it. Capacity cancellation observes the existing 500-ms retry delay. No generic
connection limit, reliable reserve, replacement reserve or relay rule changes.
A real TLS/QUIC regression consumes capacity down to two slots and repeatedly
uses ready primary/signaling children: semantic RED at the ready-child assertion,
then GREEN. The first regression fixture attempt timed out because raw reserved
streams had no preface bytes; explicit incomplete prefaces let the peer accept
them. Retain that fixture failure separately; it is not semantic RED evidence.
The closed-unused-child and retained-parent/lifetime checks also pass.

Initial focused suite passes 68 tests; the additional actual legacy-daemon test
passes with the two actual IPC tests. Final session/QUIC suite passes 55 tests
and one bootstrap test; eight pre-existing manual tests remain ignored. This
includes full-duplex source/neutral capacity and real recovery under load.
Release FFI builds; all 190 C exports remain identical. Exact artifacts/patches
are frozen in `group-channel-preparation-sdk` (failed candidate FFI `9547e398`)
and `group-prepared-reserve-sdk` (corrected FFI `22aa392d`); committed media
`a9961d4a` / `group-neteq-loss-native` is unchanged.

Corrected `group-prepared-reserve-60` removes the churn: 15 starts before
capture, 12 during audio-only, six during loaded operation; offered audio-only
traffic is 691/710 kbit/s. All 330 expected PCM transitions match with no misses;
audio-only peak 140.146 ms, loaded peak 470.036 ms at 20.200 s. Native receive
ages peak at 58/117/62 ms. All video tails change 14/14/13/14/13/14 times, but
files are only 59392 bytes each at the unchanged short deadline. This is still
NEGATIVE, NOT full file/hash or 360-second qualification. Do not infer a
repeatable latency improvement/regression from individual captures. The six
loaded connection starts at 20.123-20.173 s target the relay's endpoint neighbors;
local source preparation leaves cold forwarding connections. Inspect actual
opaque end-to-end preparation before capture / mid-call enable next. Do not
replace this with fixture-only warmup or excluded startup samples. The earlier
11.8-second runtime outage also remains unresolved.

All three runs retain the same six PCM directions, native clocks, 1024-kbit blind
FIFO, production adaptation, VP8 and three encrypted 512-KiB files. Each has
18003 rows / 6001 ticks per worker, zero timer/deadline/row failures, verified
routes and exact 3/1/1/1 topology. Workers, policies and parent exit; four node
stops return zero, sockets are gone and independent PID checks pass. Corrected
run max callback <0.296 ms, max interval <10.064 ms. Private
`group-preparation-churn-comparison.json` and the per-run `*-proof.json` files
retain negative outcomes and cleanup. No physical apps/audio or relay services
changed. Audio goal ACTIVE; no push/release.

## 2026-10-16: fresh-path pacing experiment fails; source reverted

Fresh inspection of `group-target-runtime-profile-1024-360` confirms six new
QUIC child setups during seconds 20-22. First three bindings complete at
20.265/20.289/20.348 s, next three at 21.128/21.163/21.217 s. Ready snapshots
report roughly 6-10 KiB of QUIC UDP payload accounting per child before its
application sender is published. Three ML-KEM instance-certificate walks also
complete at 20.370/20.384/20.432 s. Physical slot indices do not establish
media roles; these observations do not apportion every startup wire byte.
The full capture's bounded wire tail excludes startup. Generic eager pool
preparation was considered but NOT implemented: its idle connection/battery
cost, replacement reserve and real call/mid-call behavior require design and
verification rather than benchmark-only prewarming.

A separate prototype limits only a new path's unearned pacing credit to two
MTUs. The original 12000-byte congestion window, refill rate and earned
bucket capacity remain. A configurable zero default preserves vendored Quinn;
Veil context uses two for both controllers and every local/transit path,
without application classification or wire fields. The setting survives path
migration/reset. This is distinct from the earlier failed small-CWND treatment.
The new pacing test fails before credit limiting is applied (actual semantic
RED, retained); the first workspace-package test command failed before testing
because the vendored crate is excluded, then its direct manifest runs correctly.
All 313 protocol tests pass. Targeted session/transport tests pass 45/10, plus
one bootstrap test; eight PRE-EXISTING manual characterization tests stay
ignored. Release FFI build passes, 190 C exports remain identical.

`group-startup-pacing-combined-1024-60` is NEGATIVE: all 330 transitions match,
audio-only peak 150.170 ms, combined peak 430.049 ms at source transition
22.220 s. Video tails change 0/14/14/14/14/0; files receive only
67584/67584/59392 bytes by the short immutable deadline. Do not infer a
statistical improvement or regression from different individual captures.
The experiment does not qualify or solve the startup peak. All clocks/rows,
route assertions, exact 3/1/1/1 topology, worker/policy/node exits and independent
PID/socket checks verify. No physical apps/audio or external relays changed.

ALL four experimental source files are restored to SDK `a9961d4a`; no unused
pacing API or changed default remains. Preserve the exact patch/binary/source
manifest privately in `group-startup-pacing-sdk` (FFI SHA-256
`0ccda86b9fdca3c4384d92cd375736f7866f8dc8444178a13b4383b3845bbe1a`),
with `group-startup-pacing-combined-proof.json`, RED/GREEN/protocol/QUIC test
logs and build log. Do not install the experimental raw target-cache binary.
Use the explicitly frozen baseline FFI `64615683` for further controls.
Next inspect actual production call setup and the existing unused local
`SessionTxRegistry::{request_local_datagram_channel,local_datagram_channel_state}`
readiness API. Any preparation must serve real callers, include mid-call
video/screen enable, honor routing policies and connection/recovery bounds,
and run through the same production path in the stand. Preserve all six PCM
paths, startup samples, full file hashes and changing-video/deadline gates.
The intermittent 11.8-second transport outage also remains unresolved.
Audio goal ACTIVE; no push/release.

## 2026-10-16: long runtime profile does not reproduce the transport outage

Follow-up `group-target-runtime-profile-1024-360` uses the same committed
native target fix (`a9961d4a`, frozen `group-neteq-loss-native`) and SDK FFI
`64615683`. It retains the full 1024-kbit blind FIFO, 360-second deadline,
six PCM paths, VP8 and all three 512-KiB encrypted files. The parent is
explicitly sampled at 10-ms intervals during seconds 200-265, with a passive
process CPU/RSS window at 195-275. Treat it as DIAGNOSTIC, not qualification.

All 2112 expected transitions match without misses. The run is still
NEGATIVE under the unchanged <200-ms gate: audio-only peak 150.199 ms,
combined peak 390.025 ms at source transition 21.210 s. All three complete
file hashes verify before the deadline (306.177/305.722/323.915 seconds),
with no missing/corrupt/duplicate/late chunks, async failures or write errors.
All six video tails change (14/5/14/5/14/14). Final intentional decoded
discards total 3.47/3.29/3.46 seconds per worker across their two receivers.
None of this cancels the prior unprofiled failed capture.

The earlier 11.8-second receive outage does NOT reproduce anywhere in this
capture: per-worker sampled native receive ages peak at 74/85/93 ms.
In the sampled window, active per-second driver snapshots show event queue
last delays below 0.8 ms and timer last delays below 31.2 ms. Parent stacks
mostly park/wait for I/O; they contain short synchronous durable outbox
prunes and log writes but no seconds-long blocking stack. Therefore the
profile does NOT establish storage, logging, App Nap, route TTL or CPU as
the cause of the earlier outage. The retained sample file is
`parent-profile-200-265.txt`; process metadata is
`parent-process-window.jsonl`. Reproduce the actual delay and capture stacks
on its onset instead of assigning a cause from normal stacks. Also keep
working on the separate cold video/file activation peak near second 21.
Any preparation must be part of real production call/transport setup and
exercise the same path in the fixture, not prewarm this benchmark alone.

All native clocks/capture rows verify: 108003 rows/36001 ticks each, no
failures/dropped rows/timer errors/deadline misses, max interval <10.136 ms,
max callback <0.473 ms. Route assertions and exact 3/1/1/1 topology verify.
Workers, policies, parent, profiler/process observer and four embedded nodes
exit; independent PID/socket checks pass. Private
`group-target-runtime-profile-proof.json` retains the diagnostic qualification
caveat and cleanup. No physical apps/audio or relay service was changed.
The source/patch manifests now identify verified SDK commit `a9961d4a`.
Audio goal remains ACTIVE; no release/push.

## 2026-10-16: reconcile NetEq target with catch-up; qualification remains open

Optional bounded per-render traces reproduce a target/catch-up conflict. In
`group-video-playout-trace-1024-60` (baseline media `033d0f45`), 624/692/750
of 687/771/795 loaded catch-up ticks occur while NetEq itself requests more
than the wrapper's 120-ms catch-up boundary. Across each worker's two peers,
9.97/11.27/12.07 seconds of decoded audio are deliberately removed. The run is
NEGATIVE: 275 matched/55 missing transitions, 500.172-ms peak, six frozen video
tails. Traces retain all 36,006 render rows; clocks/routes/cleanup verify.

SDK `a9961d4a` bounds the native desired target below that same 120-ms
boundary, reserving one decoded packet's duration for normal arrivals. Actual
normal, non-muted output supplies the packet size; PLC/CNG/unknown output
cannot overwrite it. A 40-ms Opus packet gives an 80-ms target ceiling.
Stricter initial factory and later caller bounds are preserved; rejected
maximum-delay updates restore the prior request. Actual storage, FEC, forced
catch-up limit, renderer clock and RTP are unchanged. The new regression fails
against the old constructor; a separate failed prototype exposed PLC resetting
the known packet size and was corrected before the final builds.

`group-video-target-budget-1024-60` is an initial instrumented candidate,
not the final binary: loaded intentional discards fall to 0.40/1.00/0.38
seconds, all six video tails change 14 times, and target observations stay at
or below 80 ms. This isolated run remains NEGATIVE: 275 matched/55 missing,
320.026-ms peak, no file load. Do not present it as full qualification or as a
statistically repeatable improvement. The extra early decoded transitions in
some captures remain unexplained; strict ordinal matching is unchanged.

The final pre-diagnostic candidate `group-target-budget-combined-1024-60`
remains NEGATIVE with 313 matched/17 missing transitions, audio-only peak
150.064 ms and combined peak 1490.010 ms. Native diagnostics were off; source
Opus stayed at 40 ms/16 kbit/s. Current receive ages reach 1380 ms although
native render callbacks stay below 0.357 ms and the blind FIFO's release
lateness stays below 7.45 ms in the two affected intervals. New QUIC event
queue/timer stalls occur in the same 43-48-second interval. This localizes
an additional delivery/processing problem; cumulative maxima alone do not
prove its cause. Preserve `group-target-budget-combined-proof.json` and
`group-target-budget-driver-window.json` in the private artifact directory.

Group stats now retain per-peer concealment, output/received sample counts,
packet discards, interruption duration and desired jitter target, alongside
existing deliberate catch-up counters. These are endpoint JSON diagnostics,
not media hints on the wire. Optional renderer traces retain packet headroom
and the applied ceiling; they still require both explicit environment
switches, remain bounded, and write only after rendering stops. The fixture
adds `--playout-trace` and an origin/PID metadata file for external observers;
it does not change the PCM matcher, workload, gates or immutable deadline.

A first profiling attempt fails BEFORE capture because a selected UDP listener
port is occupied at node startup. All four nodes stop, no sockets remain.
The fixture now retains listener reservations through setup, uses ports below
the default macOS/Linux ephemeral ranges and releases each immediately before
its node starts. This prevents its shaper/earlier outbound sockets from taking
later listeners. It does not change the closed star or measured link budget.

`group-target-loss-profile-retry-1024-60` uses the final target cap plus new
group diagnostics, with two explicitly recorded 12-second/10-ms parent stack
profiles at seconds 22 and 42. It is diagnostic, not qualification: all 330
transitions match, peak 510.050 ms at loaded startup; all six video tails
change (4-14), files remain incomplete at the short deadline. The earlier
1.49-second stall does not reproduce. Profiles do not establish its cause;
they also show synchronous durable outbox pruning in maintenance, which is
an investigation lead, not a proven explanation. All clocks/routes/topology,
three worker/policy exits, four node stops and independent PID/socket checks
verify. No physical app, speaker or microphone was used.

Final helper, call-plane isolation/teardown, RTCP loss and real decoded-group
recovery regressions pass. Production media still has the identical 100
exports, zero test hooks; the instrumented media has 131. No release/push.
The unprofiled diagnostic control `group-baseline-loss-combined-1024-60`
uses the old recovery header with the same new group diagnostic fields. It is
NEGATIVE: all 330 transitions match, 740.121-ms peak, all six video tails
frozen. End-of-minute intentional discards are 22.09/25.01/24.60 seconds per
worker across two peers; concealed counters are 362738-374958 per peer.
In the first minute of the final candidate below, discards are 2.85/2.96/3.51
seconds and concealed counters 87486-119027. These separate captures support
fixing the target conflict but do not establish overall quality or causality
for subsequent transport outages. Both binaries/source snapshots are retained.

`group-target-loss-combined-1024-360` is NEGATIVE, not qualified. It matches
1726/2112 expected transitions, misses 386 and reports a 13950.067-ms maximum
under unchanged strict ordinal matching. Extra/missing decoded transitions
shift ordinals, so that figure must NOT be described as a measured 14-second
jitter buffer. Actual sampled receive inactivity reaches 11823 ms around
second 222; all six directions show an outage starting near second 210.
An additional shorter interruption occurs near seconds 254-256. Native
render clocks remain valid throughout (108003 rows/36001 ticks per worker,
zero dropped rows/deadline misses/timer errors, max interval <10.085 ms,
max callback <0.430 ms). Native targets stay bounded; this does not solve a
network delivery outage.

In the main outage, QUIC local event-queue maxima reach 5207055 us and timer
lateness reaches 6928772 us. Available blind-FIFO trace rows cover seconds
182.911-360.592; their max release lateness is <1.156 ms during seconds
210-220. The audio/QUIC delays cannot be attributed to this FIFO alone.
Recovery attempts start near second 216.9, parent keepalive reaps a session
at 222.087, and authenticated reconnect recovers it at 223.396-223.517.
This establishes a transport/runtime outage and reconnect, not its original
cause. Do not assume route TTL, CPU, App Nap, blocking logs or durable storage
without a stack capture during the outage. The previous short profiles ended
long before this interval. Next diagnostics should sample the parent near
seconds 205-225 and retain the existing PCM/file/video/deadline gates.

All six final video tails change (14/4/14/4/14/14). Only sender 2 -> receiver 0
completes its 512-KiB SHA-256 before the deadline (299.152 s). Sender 0 -> 1
misses 6 chunks; sender 1 -> 2 misses 107 chunks and its outgoing callback
records 107 asynchronous failures with raw code 2. The fixture's file summary
previously copied the receiver worker's outgoing failure/write counters while
already mapping queued bytes from the sender. Those two fields now map from
the sender too. This corrects attribution only; per-worker gates and all raw
captures/failures remain. Preserve the raw summary and derive corrected
attribution explicitly, rather than silently rewriting an old capture.

All six route assertions and exact final topology verify; workers/policies,
parent and four nodes stop, independent PID/socket checks pass. Bounded wire
metadata contains 100000/207750 observed rows, so it cannot establish startup
packet attribution. Private proofs: `group-baseline-loss-combined-proof.json`,
`group-target-loss-combined-proof.json`. Audio goal remains ACTIVE. Commit the
candidate and negative evidence for review; do not claim full qualification
or release it as a completed audio fix.

## 2026-10-16: earlier DATA-only transport guard and urgent decoded recovery

The current candidate keeps source isolation and neutral relays. A sustained
relative RTT increase on an authenticated local primary connection now restrains
only this endpoint's ordered DATA, before the older absolute/loss/playout
pressure path. The minimum observed RTT is per connection ordinal, reset after
an idle gap or ACK counter reset. The threshold is max(20 ms, baseline/4), with
at least three changed authenticated ACK snapshots spanning 100 ms. Cached
snapshots cannot fill the window or renew the two-second DATA pressure lease.
Stable 120-ms RTT is covered independently. Existing DATA byte debt and neighbor
turns remain; video, signaling, recovery RPCs and neutral transit do not consume
this new lease. The sparse optional diagnostic includes its own UNIX clock.

Final Rust verification passes 83 focused tests, with one pre-existing ignored
experimental matrix. Coverage includes independent physical signaling/DATA
connections, cross-neighbor primary protection, normal transit, ten-second
video/file delivery, tracker freshness/reset/idle, and DATA-only pressure/debt.
The release FFI build passes. Private logs: `group-data-delay-final-tests.log`,
`group-data-delay-final-ffi-build.log`.

The first isolated prototype capture `group-files-data-delay-1024-60` remains
NEGATIVE. Its loaded phase matches all 240 transitions below 140.213 ms, compared
with 350.047 ms in the earlier split-reply capture; this single observation does
not establish a statistically repeatable improvement. The audio-only phase has
a 260.079-ms peak. All 330 transitions match overall, clocks/rows/routes/topology
verify, workers/policies/four nodes stop, and independent PID/socket checks pass.
No file finishes in the short 40-second loaded phase. Preserve this failure.
Private `group-data-delay-file-proof.json` identifies the prototype binary and
its pre-clock diagnostic limit; `group-data-delay-sdk` retains its source.

Offline ordinal matching localizes every audio-only path's worst transition to
5.05 seconds. Actual encoder snapshots show 32-kbit/s startup, a first decoded
catch-up cut to 24 kbit/s at about 2 seconds, then another cooldown before
16 kbit/s at about 5 seconds. New decoded catch-up now takes two budget rungs;
isolated loss still takes one. It preserves native apply/failed-retune gating,
cached/reset counters, recovery evidence and cooldown. The new regression fails
on old source (24 rather than 16 kbit/s); all 17 adapter tests and targeted
analysis pass. The reset test restores a rung before resetting counters so it
cannot pass vacuously at the floor. Timing diagnostics now retain the exact
source/decoded times and ordinal of each phase's maximum without changing
matching, counts, limits or qualification; three existing timing tests pass.

`group-data-delay-combined-1024-360` uses the final diagnostic and actual
updated Dart controller, unchanged 1024-kbit blind FIFO, six PCM paths, VP8
and three encrypted 512-KiB files. It is NEGATIVE: all 2112 transitions match,
audio-only peak 160.087 ms, combined peak 480.049 ms at source transition
21.210 s (source 0 -> receiver 1). Every file passes its complete SHA-256 at
the actual receive callback before the immutable deadline: 338.016, 343.339
and 280.075 seconds, with zero missing/corrupt/duplicate/late fragments or
async send failures. This verifies file progress, not the full audio goal.

All six video paths fail the changing-tail gate. Actual sender samples show
243-292 of the 340 loaded samples paused, repeated resume/pause cycles, and
48/99/51 total logical video frames; this is not established as a camera crash.
Receiver native recovery counters reach 2289/2356/2393 and report about
29.95/30.29/31.00 seconds of discarded decoded audio across their two peers.
Matching all tone transitions therefore cannot establish continuous speech
quality. Inspect why native NetEq repeatedly refills beyond the 120-ms bound
in `flutter/veil_media/src/veil_playout_recovery.h`, alongside target delay,
40-ms packet framing and repeated video holds. Resume already calls
GenerateKeyFrame in `veil_media_engine.cc`; do not assume that call is missing.
Do not remove real recovery protection just to make the video-tail gate green.

Worst startup audio is at seconds 21-22 with video/channel activation. Further
loaded peaks remain 250.046 ms (seconds 25-60), 300.114 ms (60-180) and
240.077 ms (180-360), so do not blame only handshake or exclude startup.
The next source work must address the initial physical/video work burst and
the sustained decoded-recovery loop without relay priority or weaker gates.

All clocks/capture rows/routes/topology verify. Three workers, three policies,
the parent/resource tracker and four nodes are independently gone; zero sockets
remain. Final library SHA-256 is
`6461568339ce8362c3b5b7d1d3c172a2b63483332baacb5929aa2cf5a15483b5`.
Private `group-data-delay-final-sdk` retains source/patch/hash; verification is
`group-data-delay-combined-proof.json`. Wire metadata is bounded: 214068 events
were observed but only the last 100000 rows retained; do not claim full initial
packet attribution from that tail. All negative evidence is preserved, no
physical app/speakers/microphone used, no push/release. Audio goal ACTIVE.


## 2026-10-16: wait for route AND key; steady file congestion remains NEGATIVE

A second route-discovery race is reproduced independently: the small signed
RecursiveResponse publishes a route before the larger piggybacked RouteResponse
has supplied its verified ML-KEM key. The shared discovery gate used to release
on either answer or any unrelated route notification. The next sender then
asked for another proof while the first was still arriving.

`c18d12d7` keeps the gate through both verified cache conditions or one fixed
500-ms deadline. It re-arms notification before checking caches and consumes
the matching oneshot only once. Cancellation, route-policy isolation, the
no-E2E path and legacy route-only fallback at expiry remain. Three focused
regressions cover split replies with concurrent senders (fails before the fix),
unrelated target notifications and a non-extending deadline. All 68 send-handler
tests pass; the release FFI build passes. No wire format, key verification or
relay scheduling change.

`group-files-split-reply-1024-60` proves 3 logical key proofs / 6 admitted hop
copies / 8274 plaintext bytes, versus 6 / 12 / 16548 after the first coalescing
fix. Admission is not remote delivery and excludes wire overhead. The executed
library is SHA-256 `89d11e65846144c817bdc5620301f83a8b9ced00866b64c10806e943bfbc3d75`;
private `group-route-split-reply-sdk` keeps its parent, patch, source and hash.

The capture is still NEGATIVE: all 330 PCM transitions match, audio-only peak
160.086 ms, loaded peak 350.047 ms. It is a 60-second FILE-ONLY isolation, not
a video/complete-file/speech qualification. None of the three 512-KiB files
finishes inside this short observation. All clock/route/topology checks hold;
three workers, three policy processes and four nodes exit, with independent PID
checks and zero sockets. Private proof: `group-split-reply-proof.json`.

The peak is now localized to source 0 -> receiver 1 at the 28.28-second capture
transition, rather than the initial key exchange around second 20. The blind
FIFO's receive direction observes 1187.7 kbit/s in second 27 against 1024 kbit/s
capacity, queue maxima 187.6 ms there and 196.7 ms in second 28. Six admitted
routing announcements total only 972 plaintext bytes during seconds 26-29;
this diagnostic observes families 2 and 8, so it does not prove absence of
other control traffic. Source reports remain healthy until about second 28
on participants 0/2 and second 29 on participant 1. This points the next
investigation at steady DATA ramp, complete physical wire cost and feedback
response, rather than claiming duplicate key proofs explain all latency.
Do not use absolute RTT alone to cut video, lower a ceiling merely to fit this
fixture, relax PCM gates, prewarm only the fixture or prioritize relayed media.
Private attribution: `group-split-reply-attribution.json`. Audio goal ACTIVE.


## 2026-10-16: nickname deferred-boot regression and durable contact requests

The user cannot obtain OS/profile provenance or diagnostic reports beyond
"last published release" (xVeil 0.13.86). Do not request those details again.

A hermetic native regression reproduces the exact nickname exception with the
previous library: marked deferred boot suppresses its placeholder sovereign
identity, but promotion of a real legacy Ed25519 config never creates the
standalone identity needed by nickname lookup. Certificate provisioning passes
on that same old library. Runtime reload now applies the ordinary standalone
bootstrap when no document/state exists and the real config is non-ephemeral.
It uses the existing key/address; it does not mint a replacement identity or
repair a present corrupt document. Old Falcon-only profiles remain outside this
Ed25519 bootstrap, as on ordinary startup.

`test/native/nickname_identity_boot_live_test.dart` passes all three cases with
the rebuilt native library: legacy deferred promotion, certificate owner distinct
from device, and corrupt document left unchanged with no new device key file.
No seeds/meeting points/external peers; each controller stops, its IPC socket
vanishes, and temporary directories are removed. Logs and binary hash are in
private `nickname-identity-boot-{red,green}.log` and
`contact-nickname-verification.json`.

Contact source inspection and failing regressions independently prove that an
outgoing request had no durable retry row, including empty greetings. Requests
now persist with a stable `request:` frame id before live/mailbox attempts;
ordinary outbox replay survives a messaging-service restart. Acceptance and
cancellation retire the request. Manual resend keeps one wire id and uses fresh
mailbox content ids, avoiding stale ciphertext reuse; a successful manual
deposit settles the logical frame's deposit bookkeeping. Pending counts are
idempotent for replacement rows (the new manual-retry regression caught 2
pending entries for one row before that adjustment).

Four focused Flutter suites pass 128 tests, including failed deposits, request
restart/retry with and without a greeting, acceptance/cancellation, manual
mailbox deduplication and consent gates. Targeted analysis has no issues. This
proves those concrete recovery fixes, not the unobserved users' complete
Windows/Android transport scenario. Acceptance already had durable replay;
without their logs or a faithful network reproduction, its reported failure
is not independently attributed. Pre-upgrade pending requests acquire a durable
row on manual resend; no automatic migration of those rows is implemented.
Mailbox policy stays limited to requests/acceptances.

These changes are local and unpushed; no release or physical app was started.
The separate audio contention goal remains active (330.033-ms loaded peak in
the most recent file-only diagnostic), and these report fixes do not qualify it.

## 2026-10-16: coalesce concurrent local route discovery; audio goal remains ACTIVE

Successful writer/child admission now records the local node, exact observation
clock and a short full-frame fingerprint under the existing optional bounded
metadata diagnostic. Failed attempts remain separately labeled. No payloads,
roles or priorities go to relays. Local writer admission is not remote delivery;
raw plaintext lengths exclude encryption, framing, padding and QUIC overhead.

`group-files-admission-baseline-1024-60` proves 12 logical key/route responses,
each admitted on two relay-star legs: 24 copies, 33,096 plaintext bytes, between
20.024 and 20.259 seconds from origin. Four distinct responses per sender/
recipient pair explain repeated local discovery. It is NEGATIVE: all 330 PCM
transitions match, peak 340.073 ms. All native/route/cleanup gates verify.

A new concurrent-send regression fails on old source (3 queries instead of 1).
The fix serializes only local discovery for (local node, destination, route
policy), then rechecks the verified cache/miss state. Weak gates are bounded to
128 live keys; unrelated destinations retain normal recovery at capacity.
Cancellation releases the lock so a queued caller can perform recovery. The
ordinary and relay-only policies remain separate. No relay scheduling changes.
Both concurrency and cancellation tests plus all 65 send-handler tests pass;
seven frame-diagnostic tests also pass.

`group-files-route-coalesce-1024-60` confirms 6 logical proofs / 12 admitted
hop copies (16,548 plaintext bytes), half the baseline. It remains NEGATIVE:
all 330 transitions match, loaded peak 330.033 ms; audio-only peaks below 200 ms.
This single comparison proves reduced repeated discovery, not a statistically
established latency improvement or completed combined file/video qualification.
Workers, policy processes and four nodes exit; independent PID checks and zero
sockets verify. Source/binary snapshots and proof JSONs are private:
`group-admission-metadata-sdk`, `group-route-coalesce-sdk`,
`group-admission-baseline-proof.json`, `group-route-coalesce-proof.json`.

Current user reports take the next investigation step: last published xVeil
0.13.86 on Windows/Android loses contact requests/acceptances toward Android;
a nickname claim reports no sovereign identity. Their follow-up findings and
verification are recorded above; the original Windows/Android transport failure
is not independently reproduced. Keep provisioning/deferred-load and contact
delivery evidence separate, without silently replacing identity keys or routing
ordinary traffic via mailbox.
The audio goal remains active; remaining source/control and video handshake
bursts still fail the original quality gate. No new release/push or physical
app/microphone/speaker use in this cycle.

## 2026-10-16: isolate the file-start routing exchange; attribution still open

Two additional diagnostic captures remain NEGATIVE. Discovery-only metadata
`group-files-control-metadata-1024-60` has a 470.125-ms known peak and 32
ordinal misses on one path; its audio-only phase also exceeds 200 ms. Preserve
those failures. `group-files-routing-metadata-1024-60` matches all 330
transitions, audio-only peaks below 200 ms, but loaded audio reaches 370.085 ms.
Neither short file-only capture completes the three files or qualifies the full
workload. Workers/policies are independently verified exited, all four node
stops return zero and zero sockets remain for both.

The discovery-only filter cannot explain the burst: its ordinary FindValue
responses are only 221 bytes. With routing included, the startup log has 24
RouteResponse observations of 1379 bytes (33,096 bytes total), plus recursive
responses. These are ATTEMPTS: `note_outbound` runs before queue admission and
even before checking whether a direct session exists. Failed direct sends and
successful fallback/relay sends may record the same logical proof repeatedly.
Do NOT call this 33 KiB of wire traffic or 24 independent delivered proofs.
The prototype has no explicit observation clock: its approximate 20–20.5-second
association comes from adjacent timestamped log lines, not exact byte timing.
The final diagnostic now includes its own UNIX-microsecond observation clock.

The new optional `VEIL_DIAG_FRAME_METADATA=2,8` records only destination prefix,
frame family/type, request id and length, with a 20,000-observation process cap.
No payload head, backtrace, media role or scheduling change. It is off by
default. Existing backtrace diagnostics remain separately controlled. Seven
frame diagnostic tests pass with explicit production-seeds feature selection;
the first release test command without a network feature correctly failed the
build guard, rather than testing anything. Current timestamp addition compiles
and passes the seven tests; captures use its frozen pre-timestamp prototype.

Source inspection identifies two relevant paths, not a finished transport fix:
`mlkem_resolver.rs::recursive_dht_get[_candidates]` sends its authored queries
through SessionTxRegistry INTERACTIVE, bypassing the existing local network
control lane used by SessionOutbox. Separately, the self-addressed FIND_NODE
handler in `veil-dispatcher/src/routing.rs` piggybacks a signed legacy key/route
proof on each answer. Request-id/cached-route recovery and legacy E2E behavior
must remain correct; do not remove proofs or change transit priority blindly.

Next add successful-admission provenance (including local node) to distinguish
failed direct attempts from actual fallback and forwarding, then verify whether
repeated own discovery/proofs can be coalesced/paced safely. Retain the six PCM
paths, immutable deadlines, all-file hashes and changing-video gates. Relays
remain neutral. Private source/binary snapshot: `group-control-metadata-sdk-source`;
per-capture `*-verified.json` records exit and timing evidence. No physical
application, microphone or speakers were opened; no push or release this cycle.

## 2026-10-16: prepare the group video budget before encoding; contention remains NEGATIVE

The new optional fractional group budget API accepts preparation before video
starts. The controller mounts paused, supplies the selected budget before start,
and retries after start with older engines. A consumed budget is one-shot;
restarting without another preparation keeps the legacy 30-kbit/1-fps default.
The integer legacy setter still rejects stopped video. Its existing native
assertion caught an accidental compatibility regression, now repaired.

New local counters distinguish each fanout copy's RTP payload, padding, accepted
queue submission and rejection. Queue acceptance is not remote delivery. Optional
local QUIC diagnostics record peer, physical slot, handshake/binding duration,
UDP bytes, PTO and loss, without adding wire metadata or relay priorities.
Physical slot indices are not stable media-role labels.

The 60-second video-only control `group-video-startup-trace-1024-60` is NEGATIVE:
390.071-ms known peak plus one ordinal mismatch. New connections consume roughly
6–8 KiB outbound before application data and more during binding, while the
first encoded frame contributes only 1490 payload bytes and 2040 padding bytes
per sender's fanout. Startup handshakes are therefore a material part of the
burst; exact contributions still need attribution.

A generic 2400-byte initial congestion-window treatment did not qualify:
`group-video-small-cwnd-1024-60` peaks at 490.024 ms. That treatment and its
specific test were reverted; its binary and patch remain private evidence.
Do not reintroduce it or claim a statistical comparison from one capture.

`group-video-cold-budget-1024-60` confirms preparation on all three engines,
first encoder targets about 7.8 kbit/s and lower initial padding (510 bytes at
the first sample). It is still NEGATIVE: all 330 transitions match but peak age
is 380.069 ms. Six changing video tails, clocks, routes, worker/node cleanup and
zero sockets verify. This does not qualify combined files/video or speech.

156 focused Flutter tests, targeted analysis and the full native call-plane
suite pass. The production library has 100 exports, no test hooks, and passes
the Dart symbol gate; the private instrumented library has 131 exports.
No physical applications,
microphones or speakers were opened. Published tags and engine cache remain
unchanged. Next isolate file startup with the peer/PTO diagnostics, and address
source emission bursts while keeping the original full-workload gates intact.

The fresh `group-files-startup-peer-1024-60` is also NEGATIVE: all 330
transitions match, peak 300.143 ms (one audio-only sample is 200.065 ms).
There are no new child connection starts during seconds 19–25. Traffic during
20–20.45 seconds reaches about 1082/1042 kbit/s, queues 81/122 ms, before the
first file data admission at 20.457 seconds. Certificate resolution completes
at 20.456–20.495 seconds. Thus this file-start burst precedes file data and
is independent of video's new handshakes. Exact control request/response byte
attribution remains open. All owned worker/policy PIDs are independently gone,
four node stops return zero and zero sockets remain. Private verification:
`group-files-startup-peer-verification.json`.

## 2026-10-16: full group workload exposes source bursts; goal remains ACTIVE

Previous turn made progress: live group Opus adaptation/API passed audio-only
gates. This turn replaces the invalid one-process full fixture with a compatible
entrypoint to three isolated workers, real VP8 and three authenticated encrypted
512-KiB files. Deadline, complete-file hashes, six PCM paths, native clocks,
route/topology, tail video and cleanup gates remain intact. Fixture unit tests
also reject late completion, duplicates and corrupt/foreign fragments.

`group-full-process-1024-360` is NEGATIVE: all 2112 transitions match but peak
audio age is 490.095 ms. Three complete files match hashes by about 353.3 seconds
from origin, all six video tails change, and clocks/routes/cleanup verify.
Unrestricted 60-second baseline also remains negative because files are incomplete.
Do not replace these findings with the successful narrower audio-only preflight.

Fixed a real adapter defect: repeated fresh decoded discards now protect an
actually tested one-fps floor and cannot earn video resume. Isolated catch-up,
cached counters, actual floor-frame and healthy recovery guards remain tested.
154 focused Flutter tests and targeted analyzer pass. Native follow-up confirms
all three senders pause by sample 25, but is still NEGATIVE: startup audio age
480.041 ms, one ordinal mismatch path, incomplete files and missing tail images.
The new guard alone does not establish the full requested quality.

Isolated 60-second cases also fail: audio+files peaks at 340.051 ms, audio+video
at 440.033 ms, with all 330 transitions matching in each. Their full neutral wire
traces show average audio traffic about 625–630 kbit/s; file startup causes up to
163.6-ms queueing, video startup fills both 200-ms FIFOs at about 1180/1174 kbit/s.
The remaining defect is source emission bursts despite a small average budget.
Exact responsible records/handshakes/keyframes are not yet proven. See the new
full-load section in doc/GROUP-PROCESS-PREFLIGHT.md for private capture names,
unaltered gates, candidate SDK paths and next steps. No relay priority changes.

All workers/policy processes/file threads/nodes are stopped, zero sockets remain;
independent PID checks pass. No physical app/speakers were opened this cycle.
SDK remains local e3b9c156; current shared Dart policy/fixture changes are after
the already published Veil 0.11.41 / xVeil 0.13.86 tags. No new push/release.

## 2026-10-16: live group Opus adaptation passes the audio-only preflight

Progress on the ACTIVE audio-priority goal, after the completed release below.
Veil adds an optional live group audio-budget API; xVeil applies measured
fresh-feedback adaptation even in audio-only groups. Defaults retain full
32-kbit payload with 40-ms framing; congestion steps down to 24/16 kbit, and
room-wide fresh healthy feedback permits recovery to 20-ms framing. Native
reconfiguration preserves the sender, RTP timeline, microphone and receivers;
held video queues do not block it. Old engines keep their codec via an explicit
optional lookup and ABI fallback. No relay priority, media hints or fake BWE.

Process-isolated `group-budget-live-60` passes all 330 transitions on six
paths, peak 80.227 ms, with five real codec changes per sender and continuous
RTP origin/sequence/timestamps. Held audio rejects in 20.3 ms without a later
mutation; held video allows retunes in under 0.2 ms. The actual production Dart
policy then passes `group-adaptive-audio-1024-60` under the unchanged 1024-kbit
blind FIFO: all 330 transitions, peak 170.057 ms, all senders at 40-ms/16-kbit
by about six seconds. There are still 61 FIFO drops and decoder recoveries.
These results prove the bounded audio-only timing case, not speech quality or
full video/three-file contention. See doc/GROUP-PROCESS-PREFLIGHT.md.

Focused Flutter tests pass 63 cases; targeted analysis and the complete native
call-plane suite pass. The decoded group backlog regression still passes
(168.047-ms fresh marker, zero fallback). Production exports 100 functions and
zero test hooks, private instrumentation 131. Published 99-export engine cache
and release tags remain unchanged. All owned workers, policy processes and
four nodes are closed, independently verified; zero sockets remain.

Next: extend the isolated fixture with production video/source policy and
three complete encrypted files; preserve the immutable completion deadline,
six-path capture coverage, changing video tail and 200-ms PCM age bound.
Private evidence: group-audio-control-verified.json and the two named captures.

## 2026-10-16: release 0.11.41 / 0.13.86 complete; group audio work continues

The release subtask is complete. Veil v0.11.41 is published from immutable
source 2d7d3ed6 with 43 assets. Its source CI passes all six jobs, including
6490 default tests and the additional feature, Windows, benchmark and devnet
gates. Mobile CI passes eleven jobs with one intentional skip. hidden-volume
has no edits and stays at v2.6.1 (46251ddf).

The original Veil publish job failed because preparation used a bracket-style
changelog heading while its extractor expects `## vVERSION —`. Recovery on
branch release/recover-0.11.41 (workflow source 9a9243f2) checks out the original
product tag, verifies its seven successful builds and their checksums, then
signs/publishes the same artifacts with a compatible notes extractor. Recovery
and its hygiene CI are successful. The old failed run remains historical; no
product tag was moved. That branch is recovery-only and must NOT replace the
default build/release workflow. The canonical heading is restored in a later
local documentation commit.

xVeil v0.13.86 is published from immutable source 19640228 with 12 assets.
Final source CI passes 4/4 jobs and release CI 9/9; no unsuccessful intermediate
steps are hidden by those green conclusions. Both source/release Dart runs
pass 5519 tests with 132 intentional skips. The fresh engine-2026.10.16 cache
contains all seven target binaries from Veil source 2d7d3ed6, with verified
SHA-256 records and exactly 99 production exports each. Veil publication at
02:36:45 UTC precedes xVeil publication at 03:41:00 UTC. The published macOS
Veil CLI matches its checksum and reports 0.11.41. No relay deployment is part
of this release cycle.

Later research is committed on local main, outside these release tags, and
has not been pushed: root 47f618d5/6e9dbfff/838c50ab/998a7f7f; SDK test hook
88ce5c34 and heading fix 60ee1831. Temporary worktrees are removed. Every owned
stand process and socket is verified closed.

The full audio-priority goal remains ACTIVE. The process-isolated three-party
baseline now measures each sender's actual capture separately from each
receiver's mixed decoded PCM. A closed relay star enforces exact 3/1/1/1
sessions and all sampled media routes. At the unchanged 1024-kbit FIFO limit,
20-ms packets are NEGATIVE (six missing transitions, 630.049-ms peak); 40-ms
packets PASS the audio-only timing gate (all 330 transitions, 190.040-ms peak);
60-ms packets are NEGATIVE (55 ordinal misses and a sample above 200 ms).
These are controlled test-only switches in the SAME instrumented engine,
not a production adaptive policy. The 40-ms run still has drops and many
recovery events; it is not speech-quality proof or completed video/file QoS.

See doc/GROUP-PROCESS-PREFLIGHT.md for the complete retained negative/positive
evidence and fixture ownership. Next: implement measured group audio adaptation
with correct feedback/fanout and compatibility, then qualify all six voice
paths, video and three complete encrypted files under the same link budget.
Keep relay traffic opaque and neutral, preserve all negative evidence and
retain the original timing, source coverage and complete-file criteria.

## 2026-10-16: release preparation and three-party preflight remains negative

The draining-window guard in 5b8d37c7 rejects the recorded falling-latest
buffer sample [80,80,88,101,128,110] ms. The focused suite has 208 passing
Flutter tests. Repeating the full seven-minute QUIC/file workload preserves
all 822 tone edges below 200 ms (peaks 160.037/190.008 ms). Both encrypted
files eventually match their hashes, but the immutable 360-second checkpoint
still lacks two chunks per file; completion is later, 342.223/342.651 seconds
after enqueue. One video path still has an approximately 14-second gap caused
by actual sustained buffer growth and fresh decoded recovery events. This
is progress on false pressure, not a claim that all image pauses are fixed.

Private AOT build 2603 packages the current group catch-up engine on both
Android and macOS. The two-minute physical call completed and both owned apps
are verified stopped. Analysis now confirms zero policy cuts and zero sampled audio interruption
counters. During video, sampled rendering medians are 29.56 fps on Mac and
29.41 fps on Android with no zero-rate intervals. Complete render traces cover
12,115/12,115 and 12,158/12,158 observations respectively. Steady buffer peaks
are 68/77 ms; full-capture peaks are 93 ms on both. These are ambient-sound
and native timing observations, not continuous-speech listening proof or a
completed physical group qualification.

The new scripts/group-codec-control.py is an experimental three-party fixture:
four owned SDK nodes, six remote Opus paths, VP8 and three encrypted files.
The native synthetic clock identifies both remote tones independently in each
receiver's actual mixed PCM. Ordinal transition matching rejects whole-period
stale audio. Unit tests cover the six paths and stale-audio detection.

The unrestricted 40-second preflight group-preflight-40 is NEGATIVE: three of
six audio paths receive nothing. All four nodes stop with status zero and no
sockets remain. Source inspection confirms the process-global RECV callback
map is keyed only by remote node: multiple local SDK participants in this one
fixture process replace each other's registrations to a shared remote node.
This explains the observed three-of-six pattern; it does not establish failed
delivery between independent physical app processes. Preserve this failed evidence and first fix/validate basic
delivery before running the shaped three-party load. The fixture is not a
release qualification gate and is not used to assert successful group QoS.

Release preparation targets Veil 0.11.41 (group decoded catch-up), unchanged
hidden-volume 2.6.1 and xVeil 0.13.86 (buffer trend guards and recovery feedback).
Publish fresh engine binaries before moving app release pins. The broader
audio-priority goal and three-party qualification remain active afterwards.

## 2026-10-16: SDK 0.11.40 contention gates; repair group decoded catch-up

Previous cycle is progress: ca3432e7 removed false buffer-growth pressure and
the physical five-minute comparison recovered approximately 29 fps both ways.
This cycle keeps the full audio-priority goal active and qualifies contention
with the updated SDK runtime, then repairs a separate group receiver defect.

qos40-quic-420 PASSES seven minutes with real Opus/VP8, the production Dart
adapter, two encrypted 512-KiB files, 1010-ms tone transitions and the unchanged
aggregate 1024-kbit/s blind UDP FIFO. All 822 tone edges match; mixed decoded
PCM peaks are 180.005/180.048 ms, p95 150.014/150.076 ms. Both files match their
hashes and complete 317.808/332.568 seconds after file enqueue. The immutable
360-second checkpoint also has both complete files. This is a new positive
checkpoint, not a rewrite of the earlier incomplete six-minute evidence.

qos40-ordered-360 PASSES six minutes with the same byte/rate/tone workload over
authenticated independent obfs4 TCP channels and a process-isolated blind FIFO.
All 704 tone edges match; mixed PCM peaks are 180.000/170.051 ms, p95
150.085/150.129 ms. Files complete 284.558/285.838 seconds after enqueue with
exact hashes. Native independent ordered audio/video sends are verified.

Both runs use the preserved Rust FFI at ba242a9f (SHA256 006cf831...), whose
runtime is equivalent to release tag 487ad756; intervening changes are tests
and CI. QUIC uses the preserved dtx-arrival-clock-test engine c5cff07c...;
ordered uses the freshly compiled group-catchup-after engine. Source changes
in this cycle affect group creation/stats and test hooks, not 1:1 transport.
No packet size, byte count, PCM timing bound or relay scheduling is relaxed.
Each fixture uses a synthetic native device clock with its explicit Mach
deadline policy read back; this is fixture clock validation, not a network
priority or production scheduling change. Full sample coverage, zero clock
row loss and correct policy read-backs pass. Audio interruptions, missing tone
edges, authentication failures and async file failures are zero.

Both images change near the end of each run. Ordered maximum sampled decoded
image gaps are about two seconds. QUIC has a 13.001-second sampled image gap
on one receiver (three seconds on the other); its positive audio/file verdict
does NOT establish uninterrupted video. Preserve and attribute that observation
instead of suppressing loss feedback or raising generic relay/endpoint quotas.
All six owned nodes stop with status zero, both fixtures leave zero sockets,
and the ordered shaper/codec PIDs are independently absent. Private evidence:
qos40-contention-verified.json plus each fixture's complete summary/PCM/video,
file receipts and native logs.

The group defect is real: GroupWebrtcState used the default NetEq factory,
while 1:1 already installed RecoveringNetEqFactory. The new three-engine
regression uses real Opus and AudioMixers with two remote sources per engine,
synthetic ADMs and a FIFO mocked Veil boundary. During a 500-ms pause of one
render callback, both other participants keep capturing/receiving. Their two
tone frequencies change 150 ms before rendering resumes. The first mixed
output containing both new bands therefore bounds actual useful audio age;
it is not inferred from packet counts or a filtered jitter estimate.

SDK f9908e4c attaches the same bounded catch-up factory to every group audio
receiver, retaining its lifetime through Call destruction. Room-local atomic
recovery/discard/fallback counters are exposed through additive JSON fields.
Production retains exactly 99 exports and includes no test hooks.

The regression additionally starts real VP8 in all three engines and holds
both video Call queues of the observed participant during the entire audio
measurement. With catch-up active, both new remote bands appear after two
render ticks: measured marker age 171.267 ms, all 15 subsequent checked mixed
frames fresh, 850 aggregate discarded milliseconds, eight recovery batches,
zero fallback frames and a 14.794-ms maximum fixture clock gap. The SAME
library with only the test catch-up disable switch set fails as expected:
marker age 557.607 ms and no fresh frames in the recovery window. The original
pre-fix binary also failed. Every engine/callback is torn down before exit.
The new regression is included in the default native call-planes command.

xVeil consumes only fresh room recovery-counter deltas. A real decoded catch-up
reduces video once and briefly yields competing local producers; repeated
counter snapshots cannot repeat the cut. Engine restart and counter reset
establish new baselines. The new policy regression fails before this wiring,
then all 206 focused Flutter tests and targeted analysis pass. The complete
native call-planes/RTCP/decoder-outcome suite also passes. Private group logs
are group-catchup-{before,after,marker-before,marker-after,held,held-disabled},
group-catchup-complete-native.log and group-catchup-policy-{before,after}.log.

These commits are LOCAL and unpushed; the published releases remain unchanged.
The released engine cache still predates the group factory fix. Before the
next publication, rebuild/publish native engines and update their cache pins.
The private Android/Mac apps installed in the preceding cycle remain build
2602: this cycle builds the new production macOS library but has NOT installed
the group fix on the phone. Remaining required work includes a shaped
three-party group/file SDK workload and updated Android/device qualification.
Group transport still uses the built-in Opus factory without the 1:1 framing
adaptation API; assess its actual bandwidth demand in that group workload
before proposing any change. Keep all relays opaque and neutral.

## 2026-10-16: reject overlapping buffer oscillations; physical video recovers

The release subtask is complete: Veil v0.11.40 and xVeil v0.13.85 are
published with successful CI; hidden-volume stays at unchanged v2.6.1.
The following fixes are later LOCAL commits, outside those release tags.

The preceding physical capture identifies a feedback loop at the endpoint.
The six-sample buffer window [36,56,36,36,56,56] ms was classified as growth.
This activated the shared local producer budget despite healthy audio,
discarded video RTP, then generated genuine video-loss feedback that cut
quality. The first correction, 69e25735, requires the newest delay to exceed
the earlier peak. New regressions failed before that change and passed after.

That correction alone is INSUFFICIENT. Private AOT build 2601 reproduces the
same problem on overlapping ranges such as [31,1,31,31,51,51] and
[1,19,19,19,39,39] ms. Its five-minute capture records eight Mac quality cuts,
at least 365 local video drops and a median sampled Mac TX marker rate of
5.39/s. Audio interruption counters remain zero. This negative run is retained
as call-buffer-trend-2601-300, with complete native traces and decisions.

Commit ca3432e7 additionally requires the ENTIRE recent half of the window
above the earlier peak. Its medians must still differ by at least 20 ms, the
latest value must exceed the earlier peak by at least 20 ms, and the recent
half must still rise. Smooth and staircase growth continue to trigger below
the 200-ms ceiling; ceiling and fresh audio-loss protection retain immediate
reaction. Cached/replayed reports retain only the verdict of the accepted
fresh observation. Cached-growth fixtures now use a sustained ramp rather
than a short step followed by a plateau.

The exact recorded counterexamples fail before this additional guard. The
five focused buffer/source-pressure/receive/feedback/bitrate suites then pass
155 tests, and group-media/teardown pass another 50. Targeted analysis reports
no issues. Private logs are buffer-separated-regression-before.log,
buffer-separated-regression-final.log, buffer-separated-group-regression.log
and buffer-separated-analyze.log.

call-buffer-trend-2602-300 verifies ca3432e7 on Mac and Blackview: real AOT
Profile builds, 298.94 seconds of observations, audio first and both cameras
at 61.93 seconds. Both stay P2P throughout. Incoming call detection takes
0.25 seconds; this is one observed call, not a ringing-latency distribution.
Both phone updates preserve application data and the signing certificate.
The three packaged and actually mapped Mac native libraries are byte-identical
to build 2600; both Android native libraries also match. Rust is ba242a9f,
runtime-equivalent to tag 487ad756 because the intervening changes are tests
and CI. These builds compare the Dart policy with the same native runtime.

The corrected run has ZERO quality cuts on either endpoint and zero sampled
source-pressure observations during video. Median sampled Mac TX marker rate
is 29.90/s; the phone's actual rendered-frame counter advances at 29.41/s.
The reverse rendered rate is 29.56/s. All 113 video sampling intervals show
rendered progress in both directions. Both endpoints retain the 60-fps policy
ceiling over the final minute; their camera/codec output is approximately
30 fps. Logs contain one startup audio and one startup video drop per endpoint,
with no subsequent logged producer-drop events. These event totals are lower
bounds, not proof of zero unlogged transport drops.

Full playout traces contain 30060/30060 and 30088/30088 rows, spanning
300.609/300.864 seconds. Full actual buffer maxima are 105/121 ms; after the
first second they are 105/112 ms, with target maxima 80/60 ms. Maximum render
gaps are 21.391/48.056 ms and callback work maxima 0.583/2.715 ms. Both registered
audio interruption counters remain zero. The different startup maxima between
runs do not establish a startup fix. Ambient-input calls do not qualify
continuous-speech quality, other networks, or a group/file contention workload.

Both native call owners closed before termination. Independent checks confirm
both app processes and the owned ADB forward absent; the owned logcat reader
also exited. Private buffer-qualification-summary.json files retain all three
comparisons. The broader goal remains active: new-SDK full-codec contention
qualification and decoded group-audio stress remain outstanding. Keep relay
service opaque and neutral.

## 2026-10-16: releases published; video loss localized before QUIC admission

Veil v0.11.40 is published at 487ad756. Its main CI passed all six jobs,
including 6490 default tests, the additional feature suites, Windows native
tests, devnet and benchmarks. Both release workflows succeeded; all 43 public
CLI/checksum/signature/manifest assets are present. The macOS and Linux ARM64
musl CLIs report 0.11.40, and eight public binary digests match their tested CI
artifacts. rustls 0.23.46 and the patched quinn-proto 0.11.18 passed the audits.
hidden-volume remains unchanged at v2.6.1. No relay deployment was performed.

xVeil v0.13.85 is published at ef29d49f, with the released SDK pointer and
engine-2026.10.15. Main CI passed 5513 Flutter tests with 132 platform/explicit
skips; all nine release jobs passed and all 12 app assets are present.

Continued with private diagnostic build 2600 on Blackview and a real AOT
Profile Mac app. The former Mac stand app contained a Debug/JIT kernel; the
new app has an AOT snapshot. These QA packages were built at root b6e614c7
and SDK ba242a9f; subsequent SDK changes are test/CI changes, and ef29d49f adds
the release pointer and changelog. The three actually mapped Mac native
libraries match the prepared package hashes. Phone installation retained its
data and signing identity.

call-native-api-both-300 captures 298.92 seconds of observations: audio first,
both cameras enabled at 61.90 seconds, both endpoints P2P throughout. Incoming
call detection took 1.09 seconds with a one-second polling interval. Both
native traces are complete: Mac 29858/29858 render rows spanning 298.564 s,
phone 30104/30104 spanning 301.015 s. Native receive RTP clock residual maxima,
excluding empty padding, are 30.126/34.059 ms relative to each first payload;
these are not synchronized one-way delays. The previous 720-ms burst was not
reproduced. Registered interruption counts stay zero. Speech quality remains
unqualified because the run used ambient input rather than continuous speech.

The full Mac buffer peak is 340 ms at the FIRST render callback, reduced to
170 ms by 16 extra decoder pulls in that callback. After the first second,
buffer peaks are 89/93 ms; target peaks are 80/80 ms. Maximum render gaps are
10.979/43.712 ms and GetAudio work maxima 0.246/4.710 ms. RPC snapshots peak at
59/74 ms and again miss the startup maximum. Several build/runtime changes
separate this run from the previous one; this does not assign the improvement
to AOT or to an individual patch.

The remaining negative result is Mac video. Sampled TX marker-rate medians
are 5.85/29.56 per second. Mac records five quality cuts (four video-loss
witnesses and one receive-buffer-growth witness), spending much of the run at
1 or 6 fps targets; phone records no cuts. Mac native producer-pressure logs
contain at least 285 video drops and one startup audio drop; phone has one of
each. Mac video QUIC loss and expired-datagram counters remain zero in the
captured records. A burst of 263 local video drops occurs around 152 seconds,
after the first cut is already visible at 151.53 seconds. Inspect endpoint
producer admission, large RTP bursts and quality reconfiguration at this seam.
Keep relays opaque and neutral.

Private evidence includes both native logs, immutable buffer decisions,
next-findings.json and mapped-library proofs. Both native call owners closed
before app termination. Both app processes, the owned logcat reader and ADB
forward are independently verified absent. The broader QoS goal remains
active; source-drop repair and new-SDK group/full-codec qualification remain.

## 2026-10-15: late audio burst localized before native Mac ingress

The previous goal turn made progress (root 49c60b25): complete-file evidence
and separate endpoint producer-budget rejections changed the next action.
SDK 8f77e5af adds opt-in playout timing, not an audio-policy fix. It requires
both VEIL_MEDIA_PLAYOUT_TRACE=1 and an explicit VEIL_MEDIA_DIAG_PATH, reserves
65536 metadata rows before render, and writes only at NetEq teardown. Rows
contain monotonic callback entry/exit, actual queued samples in milliseconds,
target, discarded decoded blocks and fallback; no PCM is retained. The eight
decoder-outcome/clock cases still pass. A regression verifies both opt-ins,
the hard row limit, truncation count, and absence of file creation during
capture. The production Mac build retains 99 exports.

call-playout-trace-300 uses private Mac build 2597 with this native diagnostic
variant, unchanged Rust SDK 11f4dfe3 and hidden-volume, and unchanged phone
2598. Both stay P2P; ring delay is 0.43 seconds. The call has 298.92 seconds of
RPC observations, while the complete native render trace covers 300.6172
seconds: 30063/30063 rows, below the 65536 cap. RTP receipt/send traces use
the existing optional 32768-row limit rather than cutting off after 4096.

This is a NEGATIVE quality run, not a successful latency/full-cadence gate.
Video-phase sampled median TX marker rates are 6.34/15.27 per second, and
registered audio interruption counts finish at 2/1. Decoded catch-up finishes
at 35/18 batches and 1450/800 discarded milliseconds. Two-second RPC snapshots
show audio_delay_ms peaks of 117/201 ms, but the complete render trace exposes
an ACTUAL queued-buffer peak of 441 ms and a target peak of 450 ms. A low
sampled maximum is not proof that the queue stayed below the budget.

Mac render does not stall: maximum gap is 13.302 ms and maximum complete
GetAudio work is 0.474 ms. Around 140 seconds, actual nonempty incoming Opus
RTP packets arrive in a burst with a relative timestamp/arrival residual up
to 720.883 ms. This is relative to the first actual payload, not a synchronized
absolute one-way delay. Their native ingress-to-drain queue peaks around
9.287 ms; first decoded catch-up is at render time 140.218 seconds. The large
delay precedes native Mac ingress, so this run does not justify attributing
the late buildup to a stopped renderer or its extra catch-up pulls.

Source timing analysis must exclude padding. Audio RTP padding reuses an old
timestamp and produced misleading 300–400-ms residuals with no encoder frame.
Matching the first send for each encoder timestamp after the initial RTP
offset gives 12726 packets, all with exactly 20 header bytes beyond the
encoder payload; maximum encode-to-SendRtp time is 28.348 ms. The receiver
analysis likewise excludes zero-payload packets. Do not infer a Mac capture
freeze from the padding rows. Phone source timing remains unmeasured.

A subsequent preflight attempted to enable the existing phone encode/send
trace with a temporary lldb-server. Attach worked, but this host LLDB could
not evaluate the target setenv call, even after loading the device executable
and resolving the actual libc symbol. No diagnostic environment was enabled,
and no additional call was placed. The waiting runner was explicitly stopped;
its finally block closed both apps. Temporary server files, both owned ADB
forwards and the empty fixture directory were removed. Independent process
absence proofs cover the measured call and the stopped preflight.

Next: obtain Android encode/send/native-admission timings through a supported
diagnostic mechanism before the call, then correlate identical RTP packets
with the Mac receipt burst. This distinguishes phone capture/encode/SDK delay
from transport delivery. Do not change relay priority, blame Android power
saving, or relax buffer/loss triggers without that boundary evidence. Group
decoded catch-up and the new SDK's ordered/screen full-codec coexistence
qualification also remain outstanding; keep the full goal active.

## 2026-10-15: Android SDK update and endpoint pressure accounting

Phone profile build 2598 now carries SDK 11f4dfe3, built locally with NDK
28.2.13676358 for arm64/API 24. Its signer matches the previous installation;
the update preserves both fixture identity and data. Native media remains
the same 9e binary (99 exports), and unrelated native dependencies are
byte-identical to build 2595 apart from the generated Dart application.
The installed SDK ELF SHA-256 is
7f6df9c52ef1fa8bb5eff6be78950a8a0473122c36f0461498682e8edd232585.
This is a private QA build, not a published release.

call-mac2597-phone2598-retry is a negative physical video result: both stay
P2P for 178.30 seconds, ring delay is 0.30 seconds, but sampled median TX
marker rates are 5.85/29.41 per second. Mac has four adapter cuts, each
recording fresh video RTCP loss; phone has none. Sampled audio buffers remain
5–55/47–77 ms, with no registered interruptions, catch-up or audio admission
drops. These measurements do not establish perceptual speech quality.

Do NOT describe this as zero endpoint video drops. The datagram_admission
counters cover transport capacity and bandwidth, but a separate
local_source_pressure event records producer-budget rejection. Mac reports
at least 371 secondary drops there; phone reports at least 25. Both report
zero secondary buffer/bandwidth drops and zero QUIC packet losses in their
sampled admission windows. Mac also has at least 59 capacity deferrals.
In the previous good Mac2597/phone2595 call, the corresponding logged lower
bounds were only one secondary producer-budget rejection on each endpoint.
These counters can retain an unlogged tail, so sums are lower bounds.

Sparse Mac video-channel cells 1400, 1450, 1500, 1550 and 1600 have all four
sender IPC milestones but no matching authenticated receive sample. Their
direct_queued times fall within 1792080751024–1792080751423 ms, and the same
sender logs 292 secondary producer-budget rejections at 1792080751789 ms.
This localizes a plausible source of missing cells before transport admission;
it does not prove the fate of each cell individually. Video RTCP shares this
local channel, so sealed sequence counts are not pure RTP packet counts.
Do not infer a new Android SDK regression from this single run or blame the
network solely because a peer RTCP report observes loss. The existing source
pressure follows measured audio buffer growth and has a recovery hold.
No relay policy, buffer ceiling or loss trigger is relaxed to hide this result.

call-mac2597-phone2598-repeat uses the SAME installed binaries and identities.
Ring delay is 0.33 seconds, observation span 178.06 seconds, both stay P2P.
Sampled median TX marker rates are 29.90/29.34 per second, but this is NOT a
stable full-cadence pass: both adapters cut at about 137/145 seconds and end
at the one-fps rung. Phone has six sampled audio-protection pause observations.
Mac's cuts include fresh video RTCP loss, while phone's include measured
buffer growth and subsequent audio catch-up. All 117 adapter observations
are retained per endpoint without gaps. Mac logs at least 510 secondary
producer-budget rejections, phone at least one. This disproves treating the
earlier asymmetric median alone as a persistent Android transport regression.

Video-phase sampled audio_delay_ms ranges are 9–135/19–120 ms; registered
interruptions, audio admission drops and handovers stay zero. Both endpoints
nevertheless perform decoded catch-up: final audio_latency_recovery_count is
227/183 and audio_latency_discarded_ms is 2940/2310; each also reports one
audio_jb_flushes. Do not claim this run has no audio recovery merely because
audio_discarded_packets is zero (that field excludes decoded catch-up).
The remaining question is why the queue grows late in an initially healthy
call and whether its protection/recovery cycle unnecessarily suppresses video;
the current evidence is insufficient to relax the protection or blame the OS.
Both physical calls' app processes, logcat readers and ADB forwards are absent
after hangup, independently verified. No source fix is claimed in this cycle.

## 2026-10-15: file tail under sustained primary pressure

Previous cycle made progress (root cc6d8da1, SDK 11f4dfe3), fixing the physical
Mac video admission loss. Its 360-second QUIC run ended with incomplete files.
Current work keeps that negative result and adds a bounded per-fragment receipt
trace (4096 observations per direction) plus an optional immutable in-run file
checkpoint. The checkpoint is diagnostic and never substitutes for the final
complete-file/hash gate. No sender rate, byte count, latency/clock threshold or
relay scheduling changes. Snapshot regression tests and Python compilation pass.

secondary-retry-quic-observe-420 PASSES the complete gate over seven minutes
with the SAME SDK/media libraries, blind aggregate 1,024-kbit/s UDP FIFO,
real Opus/VP8, two full 512-KiB encrypted files and 1010-ms tone transitions.
Its immutable checkpoint at 360.001 seconds still FAILS file completion:
direction 0 has 512000 bytes and indices 250–255 pending; direction 1 has
516096 bytes and indices 252–255 pending. This does not turn the earlier
six-minute workload into a pass.

Both files then complete while audio/video remain active: receiver times
364.907/362.837 seconds after workload start, or 344.898/342.828 seconds after
file enqueue. Every one of the 256 fragments arrives on each side, both hashes
match, and authentication errors, duplicates and async send failures are zero.
The traces are complete, with maximum inter-fragment gaps 5.995/5.594 seconds;
fragment arrival order differs from index order and is handled by assembly.
This run establishes eventual completion under the existing pressure budget.
It contradicts irreversible loss in this observed tail; it does not promise
that every configuration finishes a 512-KiB file in six minutes.

In the earlier 360-second run, sourcePressured is true in 342/340 of the 360
endpoint observations. The existing reliable secondary allowance under
pressure is 1024 wire bytes per 200 ms; actual encrypted frame cost determines
the per-frame delay. Current evidence is consistent with slow background DATA
admission while preserving audio, and does not justify raising that allowance
merely to meet the private six-minute cutoff.

All 822 tone edges match in the 420-second run, with no missing edges, quiet
PCM frames or registered interruptions. Mixed PCM peaks 159.934/190.017 ms;
p95 is 150.030/150.131 ms. Current buffers peak at 140/143 ms. Native clock
maximum interval is 10.19 ms, wake lateness 0.138 ms and full callback 1.944 ms.
All 42000 ticks and 422 exact policy read-backs are present; dropped rows,
timer errors and policy misses are zero. Both synthetic images change at the
end, sampled maximum gaps are about three seconds, and no audio-protection
pause samples occur. All three nodes exit zero and no fixture sockets remain.
The result measures synthetic media timing, not perceptual speech quality.

## 2026-10-15: independent video capacity retry

The preceding cycle made progress (root ed066ec2, SDK 9e933061), but its
physical clean calls still had asymmetric video. Follow-up inspection of the
saved physical 2595 traces identifies endpoint admission loss: Mac local slot
2 on an independent QUIC child reports at least 173 buffer drops, versus zero
reported QUIC packet losses/expired outgoing datagrams on that child. Phone's
corresponding producer has no admission buffer drops. The 4-KiB local backlog
bound rejected the tail of a short RTP burst despite an otherwise healthy
path. One sampled video RR loss is 64%; the audio tx_loss_pct field and a later
healthy video report must not be used to label these video losses sub-percent.
Raw Mac baseline logs and bounded aggregate counters are retained privately
in call-blackview2595-clean before the next launch replaces its runtime log.

SDK ca5b7e4e retains a fresh local secondary/screen envelope when its negotiated
independent child's capacity is temporarily unavailable. It retries after two
ms, preserving the original admission time, expiry, credit and FIFO position.
The 4-KiB backlog bound, transport capacity, sender bandwidth limits and packet
deadlines are unchanged. Only that source is deferred for the scheduler pass;
audio, other local channels and neutral transit remain eligible. The canonical
ordered drain also skips that waiting datagram, so it cannot escape onto the
shared stream. No-carrier, independent child, local secondary class and an
explicit trusted deadline were required by this initial candidate.
Legacy/shared and transit paths retain their existing behavior. Endpoint
source credit is checked after
capacity readiness, preventing a retry from consuming it repeatedly.

The optional endpoint admission trace separately counts capacity deferrals;
it does not label network traffic or alter relay scheduling. Fifteen focused
session tests pass, including actual independent connection isolation, primary
delivery with competing endpoint producers, primary expiry/control admission,
FIFO/capacity separation and retry deadline preservation. The retry test also
excludes a transit carrier, absent independent support, primary/control/data
classes and a missing deadline. Expired deferred video is still discarded.

The first controlled physical run (Mac 2596, phone 2595) confirms this initial
candidate does NOT activate for P2P: the new trace schema is present, but it
records zero capacity deferrals and at least 233 secondary buffer drops, again
with zero reported QUIC packet losses. The SDK AppRtSend deadline bounds its
writer before IPC; it is not serialized into the daemon's session envelope.
This is a verified negative result, not a qualified video improvement.

SDK 11f4dfe3 therefore uses the session's existing implicit 500-ms secondary
queue lifetime, based on original queued_at, even when AppRtSend supplies no
explicit deadline. An earlier explicit expiry still wins. The same deadline
now follows secondary packets into QUIC; no retry can renew it. Transit
carriers and the neutral INTERACTIVE class remain excluded. The full session
crate passes: 557 tests, zero failures, eight explicitly ignored manual
characterizations. This includes both primary and secondary expiry, isolation,
writer-pressure and reconnect tests. The first physical run's applications,
logcat and forward were removed and process absence verified.

The corrected physical run (Mac QA 2597, phone profile 2595) verifies activation
and fixes the asymmetry in this controlled Wi-Fi P2P case. The SDK alone is
replaced on Mac; native media and hidden-volume bytes match build 2595, and
the receiver phone is unchanged. Ring delay is 0.32 seconds, observation span
178.16 seconds. Both directions stay P2P. Video-phase sampled median TX rates
are 29.90/29.56 FPS, versus Mac's 0.98 FPS before the fix. Source/peer native
delivered RTP-frame counts match at the final observation: 3308/3308 from Mac,
3253/3253 from phone. These are transport-frame counters, not proof that every
pixel was displayed. Mac reports at least 1346 capacity deferrals and zero
secondary buffer/bandwidth drops or reported QUIC packet losses. Its observed
outbox-to-transport maximum is 25.508 ms; Quinn queue maximum is 5.624 ms.

Audio during video has sampled buffers 5–55 / 14–54 ms, with zero registered
interruptions, catch-up/discard/fallback counts, audio RTP admission drops and
route handovers on both endpoints. Neither adapter reduces its rung or pauses
video for audio, and the complete histories have no observation gaps. No
speech/listening quality is established. Both owned app processes, logcat and
the test ADB forward are confirmed absent after hangup. Android's session
sender binary has not been updated in this cycle; the cross-platform SDK
source includes the fix, but this result qualifies the changed Mac sender.

secondary-retry-quic-full-360 exercises the new SDK with real Opus/VP8 and
two 512-KiB encrypted competing files, behind a blind aggregate 1,024-kbit/s
UDP FIFO. The complete gate FAILS because the two files are still incomplete
at the end of the workload; neither final hash is available. Do not describe
this as a passed full coexistence gate or claim missing chunks were lost
irreversibly. Async send failures, authentication errors and duplicates are
zero, but eventual file completion is not established by this stopped run.

Its timing/media components pass: all 704 PCM edges match without missing
markers, mixed PCM peaks 180.010/170.068 ms and p95 150.027/150.083 ms. No quiet
PCM frames or native interruptions occur; current audio buffers peak at
141/141 ms. The independent native clock has maximum interval 10.26 ms, wake
lateness 0.139 ms, full callback 0.436 ms, no missed policy read-backs, dropped
rows or timer error. Both synthetic images change near the end, but sampled
gaps reach 13 seconds and audio-protection pauses occupy 12/22 samples. This
does not establish uninterrupted/high-FPS video on the constrained link.
All three nodes exit zero and no fixture sockets remain.

This failed run also exposes a measurement race: live file callbacks still
mutate received-byte/hash fields after the script computes missing_indices.
The resulting summary can have inconsistent counts. The harness now freezes
file data, recomputes completion/hash from those bytes, and copies failure
counters under the callback lock immediately after the measured workload.
Analysis/teardown arrivals cannot change that verdict. Three focused Python
tests pass for late-callback isolation, actual-byte hash verification and
failure-counter isolation; the script compiles. No workload size, clock,
latency, image-progress or complete-file gate is relaxed. Follow up with the
frozen evidence to distinguish insufficient six-minute file throughput from
loss/retry failure, and compare the prior SDK on the same QUIC workload if
needed. The earlier complete obfs4 gate remains a separate recorded result.

## 2026-10-15: catch-up arrival clock and physical diagnostic control

SDK 9e933061 fixes a regression exposed by the new production catch-up path.
NetEq advances its internal ten-ms timer on every GetAudio call. Decoding
several old blocks during one render callback also advanced the arrival-delay
estimator, inventing jitter and rebuilding the removed backlog. The original
default controller now receives a separate timer advanced once per outer
render callback. Codec, FEC, PLC and packet bookkeeping retain their original
timer; there is no timer rewind, buffer flush or relay change. The clock is
owned before the inner decoder so it outlives its controller.

The real Opus DTX regression now starts silence at five seconds: the injected
burst ends at four seconds but its final packets can arrive 300 ms later.
This isolates ten healthy DTX seconds from the injected loss tail; the
unchanged resumed-PCM gate remains below 160 ms. With the SAME updated test,
the old library fails at 280 ms and the corrected library passes at 140 ms,
with zero additional concealed samples/interruptions. Healthy DTX discards no
extra decoded audio. Perfect-network DTX passes at 100 ms. The decoder-outcome
unit additionally verifies one arrival-clock tick even for seventeen decoder
pulls, and two ticks for two render callbacks, including a decoder error.

Private call-blackview2594-playout is an INTRUSIVE diagnostic run: immediately
after enabling video it invokes macOS sample plus Android dumpsys/thread
inspection. It reports Mac/phone catch-up discard totals 340/6490 ms and low
video FPS. A clean same-build repeat, call-blackview2594-clean, removes those
operations from the timed observation. It rings in 0.26 seconds and stays P2P
on both devices for 178.30 seconds, with zero registered interruptions or
route handovers. Mac/phone catch-up discard totals are 0/10 ms, with 0/1
recovery batches. Video-phase sampled audio buffers are 3–53 / 57–87 ms.
The earlier intrusive run does not establish ordinary-call behavior or
identify which diagnostic operation caused the perturbation.

The clean repeat still exposes asymmetric video performance: sampled median
TX rates approximately 0.99 FPS from Mac and 29.41 FPS from phone. Its complete
adaptation history attributes the Mac cuts to fresh video RTCP loss witnesses,
not growing/capped audio buffers or intentional catch-up. Follow-up above
locates loss inside endpoint admission; the audio loss percentage alone did
not describe these video events. This agrees
with the user's instruction that actual image loss may reduce quality, but
does not qualify high-FPS recovery. No listening/speech quality is established.
Both owned applications, logcat and the test forward were removed, with
explicit process-exit/read-back proof stored in the private result directory.

The corrected default native call-planes suite passes, including its RTCP
loss/expiry tests, group isolation, held video queues and eight-case catch-up
regression. Both production media builds retain 99 public exports. Private
Mac QA and Android profile build 2595 contain the corrected media library;
Android update uses the same signing certificate and preserves identity/data.
The packaged Android media hash is
474b227190d84fa5dbb7c573232fad160d57798f784e38162fe6909acd3928ca;
Rust remains byte-identical to build 2594. No release or push was performed.

arrival-clock-full-360 PASSES the unchanged complete gate with the corrected
library: six minutes, aggregate 1,024-kbit/s blind FIFO, separate ordered obfs4
channels, real Opus/VP8, and exact 512-KiB encrypted files in both directions.
All 704 PCM edges match with no quiet frames or registered interruptions.
Mixed PCM peaks are 180.019/170.069 ms; p95 is 150.143/150.169 ms. Current
buffers peak at 130/139 ms. Both images move at the end; maximum sampled image
gaps are approximately three seconds, with no video-protection pause samples.
Files finish at 339.125/340.160 seconds. Clock maximum interval is 10.18 ms,
wake lateness 0.142 ms and full callback 0.551 ms; all 36,000 ticks and 362
matching policy read-backs are present, without timer errors or dropped rows.
Catch-up intentionally discards 14,090/7,450 ms in 1,101/603 batches; fallback
counts are zero. The gate establishes timing and continued video/file progress,
not perceptual speech quality or high FPS under this constrained workload.
All three nodes exit with status zero and no fixture sockets remain.

Physical call-blackview2595-clean then runs the corrected production media on
both owned endpoints: ring 0.25 seconds, 178.35 seconds of observations, P2P
throughout, zero route handovers, RTP audio admission drops, registered audio
interruptions or catch-up/discard/fallback counts on either device. Camera is
enabled at 62.11 seconds; sampled video-phase buffers are 29–59 / 55–75 ms.
Identities match the preceding build. Mac/phone sampled median video TX rates
remain asymmetric at 0.98/29.41 FPS. All seven Mac rung cuts have a fresh video
RTCP loss witness and no gaps in the adaptation history; the phone has no rung
cuts. There are no audio-protection pause samples on either side. This confirms
the installed build and healthy quiet-call behavior, not speech audibility or
resolution of the remaining Mac video rate/recovery issue. Follow up by
correlating Mac video RTP/RTCP loss and recovery eligibility, without weakening
the actual-loss trigger. Both owned app processes, logcat and the test ADB
forward are confirmed absent after hangup.

## 2026-10-15: explicit synthetic audio deadline scheduling

Previous turn made progress (root 6d5e42a3, SDK e60b6421); the guarded catch-up
candidate remained unqualified after ordinary-QoS fixture wake delays. Local
source confirms the production Mac ADM pulls from an AVAudioSourceNode render
callback, and Android requests AAudio LOW_LATENCY callbacks. The latter is a
request, not read-back proof of the phone's effective scheduling. The synthetic
clock formerly requested only USER_INTERACTIVE QoS. This cycle adds an opt-in
`--native-pcm-priority deadline` fixture mode; the default stays `audio` and
no application, SDK/relay worker or host-wide priority changes.

The requested Mach time-constraint period/computation/constraint is 10/3/5 ms.
The local SDK header explains why the initial 10/2/5 request was not exact:
kernel computation is forced to at least half the constraint, so read-back
returned 2.5 ms. The final 3-ms request matches exactly. The ignored preemptible
field is not used as proof. Requested AND actual timing fields are exported,
with checks at startup, each hundred ticks and shutdown; any mismatch or
read-back error invalidates the gate. Native/Python Stats ABI sizes are
verified before starting the writer. Unknown modes and deadline mode without
a native macOS clock fail before the fixture starts. This is a representative
real-time timing model, not proof that CoreAudio uses these exact parameters.

Four Python tests pass for default QoS, deadline policy read-back, invalid
mode rejection and stale ABI rejection. Native stall/publication regressions
also pass in explicit deadline mode: deliberate 65/70-ms blocking still appears
as a clock failure; it is not hidden by priority or catch-up samples.

bounded-playout-deadline-full-360 PASSES the complete unchanged quality gate
with the guarded receiver candidate: 360 seconds, real Opus/VP8/Dart, blind
aggregate 1,024-kbit/s obfs4 shaping, exact 512-KiB files in each direction,
native PCM and all input positions. Mixed PCM peaks 150.122/170.083 ms, p95
150.052/150.131; audio-only peaks 70.095/110.111. All 704 tone edges match,
quiet frames and reported interruptions are zero, current buffers peak at
130/130 ms. Maximum driver interval is 10.20 ms, wake lateness 0.149 ms,
maximum full callback 0.244 ms. All 36,000 ticks are recorded without dropped
rows or timer error. All 362 policy read-backs match, without a single miss.
Both files finish with exact hashes at 339.689/337.418 seconds; both directions
show changing images at the end, with sampled gaps 3/13 seconds and video pauses
12/0 seconds. Intentional discarded audio totals 2250/4220 ms in 202/360
batches; fallback counters remain zero. Three nodes stop with status 0 and
no fixture sockets remain. No continuous speech quality is established.

Before production enablement, compare the same library and full workload with
the catch-up factory disabled under the SAME explicit deadline mode. Otherwise
improving the synthetic source clock could be mistaken for a receiver fix.

The matched baseline-deadline-full-360 FAILS the unchanged latency gate:
mixed PCM peaks 190.049/220.055 ms, p95 180.018/190.016. Its clock is valid at
10.15 ms, wake lateness 0.135 ms, with all 36,000 ticks and 362 matching policy
checks. Catch-up/discard counters are exactly zero, proving the control was
disabled in this same test library. All 704 edges match, quiet/interruptions
are zero, both exact files finish at 308.448/300.876 seconds, images move at
the end, and nodes/sockets clean up. Video pauses are 36/38 sampled seconds.
This controlled configuration comparison supports a receiver benefit in
addition to the timing-model change; it is not a repeated statistical trial.

SDK 5d482ffe promotes the same catch-up implementation to production UNICAST
calls, with its explicit recovery/discard counters. Room receive streams still
use their previous factory and remain outstanding. Test libraries now enable
the production default, with only VEIL_MEDIA_TEST_DISABLE_AUDIO_DRAIN permitting
an explicit baseline opt-out. The old opt-in was solely the earlier prototype;
its archived libraries preserve the recorded commands. The default real-native
call-planes suite, RTCP loss regression and eight-case catch-up regression pass
after promotion, including audio delivery with stalled video queues and safe
restart/teardown. Production Mac/Android media builds preserve 99 public
exports; Rust/hidden-volume code and all relay binaries are unchanged.
Raw NetEq sample/output-duration counters also include decoded catch-up blocks;
use the separately exported discarded duration when interpreting playout rate.

## 2026-10-15: bounded receiver catch-up candidate

The preceding goal turn made progress (root b6c7293f/SDK 8b217c44, installed
2593) and identified large receiver residuals after prompt packet delivery.
This cycle tests a distinct mechanism from the rejected small-buffer/cap-only
changes. A NetEq factory wrapper delegates the original codec, FEC, PLC,
capacity and time-stretching policy. After a successful normal-speech pull,
only when actual queued samples exceed 120 ms and another decoded block or
the next packet is available, it decodes/skips old ten-ms blocks. Work is
bounded to sixteen extra pulls per callback; errors retain the last successful
frame. No full buffer/decoder reset or forced PLC is used. This is TEST ONLY:
VEIL_MEDIA_TEST_HOOKS plus VEIL_MEDIA_TEST_AUDIO_DRAIN, unicast fixture only.
Production libraries and installed build 2593 remain unchanged. Do not enable
this for production or claim room support from the unicast experiment.

The wrapper exports exact cumulative audio_latency_recovery_count and
audio_latency_discarded_ms diagnostics. The first full 360-second run,
bounded-playout-full-360, retains the prior ordinary-control obfs4/1,024-kbit/s
aggregate FIFO, 512-KiB files in each direction, real Opus/VP8/Dart policy,
native PCM clock and all input positions. Mixed PCM peaks are now
151.643/151.931 ms (p95 150.193/150.053), versus the preceding accepted
production-media run's 251.497/280.445 ms. This is separate-run evidence, not
a deterministic paired causal estimate. All 704 tone edges match, no quiet
frames or reported interruptions occur; current buffers peak at 130/133 ms.
Clock passes narrowly at 39.35-ms maximum interval, without dropped rows or
timer errors. The maximum driver callback is 18.306 ms, not an isolated
single-stream drain measurement. Recovery batches number 66/86, dropping
710/890 ms over six minutes (about 0.2 percent, not a speech-quality proof).

The WHOLE gate nevertheless fails. One direction has no changing picture at
the end, sampled video pauses occupy 227/188 mixed seconds, and files reach
only 516096/514048 bytes by the deadline instead of 524288 each. All nodes
stop with status 0; no fixture sockets remain. Treating each intentional
catch-up as a hard interruption falsely declares the one-fps floor broken
and prolongs background throttling. Desired-buffer targets exceed 120 ms in
only 6/41 and 6/62 catch-up polling samples, so a blanket target cap does not
explain most events and was not added.

The next policy separates deliberate catch-up from unplanned interruption:
the existing encrypted feedback's total interruption count remains conservative
for older peers, with an optional validated `lr` subset counter for upgraded
peers. Actual interruptions cannot be hidden by this subset, replay cannot
renew it, and repairs retain monotonic application counters. Catch-up lowers
video but does not itself prove the sparse floor failed. Only pure catch-up
gets three healthy samples of source-pressure recovery; genuine congestion
keeps twelve, and catch-up cannot shorten an existing genuine fault's lease.
Five focused Flutter suites pass 149 tests, including wire compatibility,
invalid subset rejection, real-versus-planned loss and unchanged hard-failure
floor protection. This policy is being qualified with the same complete gate.

The second complete run, bounded-playout-separated-full-360, lowers mixed PCM
peaks to 160.185/160.510 ms, p95 150.955/151.501 ms. All 704 edges match;
clock is valid at 33.11 ms, with no dropped rows or timer errors. Both exact
512-KiB files finish in 339.115/339.756 seconds and both receivers show changing
images at the end. Sampled video pauses fall to 24/0 seconds, with maximum
sampled decoded gaps 3/13 seconds. Intentional discarded audio increases to
2350/3590 ms (208/308 batches) over six minutes, about 0.65/1 percent.
This remains a STRICT gate failure: one ten-ms output observation at second
310.264669 has RMS 298.308 versus the unchanged 500 threshold. The same
one-second observation interval contains new catch-up batches and one NetEq
concealment event, but that is not an exact causal join. No zero-loss gate
has been weakened to call this a pass.

An independent decoder-outcome regression exposes/fixes a definite wrapper
bug: successful GetAudio may return PLC/CNG or muted audio, not usable speech.
Extra catch-up pulls must retain the last actual speech block in those cases,
as they already do on errors. A fallback counter records such attempts
separately from discarded old speech. The new native unit verifies normal,
PLC, mute, error and sixteen-pull work limits; it explicitly undefines NDEBUG
so the WebRTC release flags cannot compile its assertions away. The default
call-planes runner includes it. This does not prove the one quiet sample's
cause; the guarded variant requires another complete qualification run.

bounded-playout-speech-full-360, with the guard, meets the media criteria but
still fails the WHOLE gate: driver interval reaches 53.41 ms (bound 40), with
45.017-ms wake lateness and 27.921-ms maximum full driver callback. No dropped
rows or timer errors occur. Mixed PCM peaks are 185.953/186.013 ms, p95
151.336/151.276; all 704 edges match, quiet frames and registered interruptions
are zero. Buffers peak at 130/130 ms. Both exact files finish around 339.3
seconds; both directions move at the end, with sampled gaps 2/14 seconds and
video pauses 13/0 seconds. Catch-up discards 2780/4390 ms in 246/377 batches;
fallback counters stay zero. Thus the fallback guard is verified by the native
decoder-outcome regression, not exercised in this full capture; do not claim
it caused the quiet sample to disappear. All nodes stop with status 0 and
no fixture sockets remain. An unchanged repeat is justified by the concrete
clock-validity failure; no pacing, fixture priority or quality bound is changed.

The unchanged bounded-playout-speech-repeat-full-360 also fails: interval
68.98 ms, wake lateness 60.119 ms, maximum full callback 12.761 ms. Mixed PCM
peaks are 190.598/201.163 ms (p95 151.090/151.469). All 704 edges match,
quiet frames and interruptions remain zero; both exact files finish around
336.6/339.1 seconds, both images move at the end, sampled video pauses are
zero, and maximum decoded gaps are 3/2 seconds. Discarded old speech totals
2320/2510 ms in 207/222 recovery batches; fallback counters remain zero.
Nodes stop with status 0; no fixture sockets remain. This is not a qualifying
clock or a green latency gate. Do not repeat unchanged runs hoping for green.

The next concrete risk is now synthetic audio scheduling: two guarded runs
miss the 40-ms clock bound through 45/60-ms wake lateness, whereas maximum
full callbacks are 28/13 ms. Any new timing mode must be justified against
actual CoreAudio/AAudio thread scheduling, explicitly requested/read back in
the fixture, and reported without silently changing priority or quality gates.
The current stand uses its existing audio QoS class 33, not a hard real-time
deadline. No real-time mode was introduced here and host-wide scheduling was
not changed. The eight-case native regression now also verifies no extra
pulls on a healthy buffer, unavailable next audio or an explicit action
override. Production enablement, room integration and physical qualification
remain outstanding; installed build 2593 is preserved and no apps are launched
on the physical endpoints this cycle.
Targeted analysis of the seven changed production/policy Dart files reports
no issues. All four stand processes are terminal, their three nodes report
successful shutdown, no fixture Unix sockets remain, and no relay-codec
driver or Dart policy process remains. The candidate is retained behind its
explicit test-only guard for the next investigation rather than installed or
presented as a production fix. No commits are signed or pushed.
The guarded native prototype and its regression runner are committed in SDK
e60b6421. Its default production path remains the preceding accepted behavior.

## 2026-10-15: consume fresh fractional RTCP loss at endpoints

The preceding goal turn made concrete progress (root 1fe89ece, installed
2592); qualification remains open. SDK 8b217c44 now exposes additive local
audio_loss_report_us/video_loss_report_us fields in unicast and room stats.
Each records the local arrival time of the last valid authenticated RR/SR
block with nonzero fractional loss for our corresponding SSRC, even when the
displayed integer percentage rounds to zero. A later healthy block retains
the old loss time; it cannot renew it. Witnesses expire after fifteen seconds
from the lossy observation itself. Room stats aggregate only those loss
witnesses, so another participant's healthy report cannot refresh old loss.
Malformed compound packets publish no partial observation; foreign SSRCs do
not create evidence. No relay role, wire extension or network priority changes.

Dart consumes each lane's loss timestamp once, retaining its high water over
expiry, missing fields and room member removal. Reports while a source is
off are consumed without deferred cuts when it resumes. Engine replacement
resets the tracker. Fresh audio/video network loss now cuts video by two
rungs alongside actual RTP admission failure and registered interruptions.
Audio loss also restrains our background producers in unicast and rooms and
cannot earn recovery of paused video. Older peers without playout telemetry
still protect audio when the native receiver reports actual loss. RTCP packet
loss is congestion evidence, not proof of audible loss after FEC/redundancy.

The focused real-native call-planes --rtcp-loss regression passes against the
protobuf-free Mac archive. It injects RR and SR through the actual shim
callback and verifies sub-one-percent loss, stream binding, malformed compound
rejection, cached reads, healthy reports and two-participant room expiry. The
default call-planes runner now includes this regression. The four targeted
Flutter suites pass 118 tests, including repeated/expired/older room witnesses,
mute/camera-off consumption, floor protection with an older peer, and the
requirement that ongoing fresh loss cannot resume paused video. Production Mac
and Android media build successfully with their accepted protobuf-free WebRTC
archives and preserve all 99 production exports. Android compilation uses a
new owned throwaway Linux container with read-only source/SDK mounts; an initial
direct host invocation rejected the Linux compiler and produced no library.

The stand policy driver now passes the same audio loss witness to background
source pressure and records its immutable adaptation decisions. Historical
primary/dual-framing/cold-video full captures had no integer audio RTCP loss,
but their video RTCP loss peaks were 50/60/37 percent, respectively. Thus the
new video loss trigger can actually affect this workload; a full qualification
run is warranted, unlike blindly repeating the prior zero-admission-drop test.

rtcp-loss-full-360 completes the full 360-second Opus/VP8/Dart mixed workload
with independent ordered obfs4 channels, blind aggregate 1,024-kbit/s shaping,
two 512-KiB encrypted files, native PCM clock and full tone-position coverage.
This uses the driver's ordinary encrypted health carrier, not the optional
compact-call-health diagnostic from the prior primary run; it is an absolute
qualification, not a matched causal latency comparison. The gate FAILS: mixed
PCM peaks 251.497/280.445 ms, p95 201.718/191.007 ms; audio-only peaks are
111.529/91.501 ms. Driver clock is valid at 31.93 ms maximum interval, with
zero dropped rows, timer errors or native/poll/health/control failures. All
704 tone edges match, no edges are missing, no quiet PCM frames or registered
interruptions occur. Sampled mixed buffers reach 216/249 ms. Video moves at
the end but sampled decoded gaps reach 34/26 seconds. Both files arrive with
exact hashes in 283.965/256.355 seconds. Three nodes stop with status 0 and no
fixture sockets remain.

Each endpoint records all 360 immutable decisions. Fresh RTCP video-loss
events number 14/17; audio-loss events are zero. Three video-loss events on
side 1 cut the rung; all remaining events occur at the floor or while paused.
Thus the new signal really reaches the application policy under congestion,
but reacting to loss alone cannot remove the existing mixed-load latency
failure. Do not relax the latency gate or remove audio guards to call this
goal complete. Further work must address accumulation/transit and receiver
recovery while preserving useful video cadence and relay neutrality.

Exact native pipeline attribution covers all 704 tone edges, with zero
unmatched payload rows, missing edge witnesses or reached trace limits. The
worst 280.445-ms edge is source 0 at second 256.546303 on a 40-ms packet:
capture-to-encode 30.293 ms, encoder-to-send 0.022, send-to-SDK 0.012,
SDK-to-ingress 12.893, ingress-to-WebRTC 0.016, residual-to-PCM 237.209 ms.
The following packet arrives at second 256.628873, nearly 198 ms before that
PCM edge. The preceding 279.899-ms edge has only 13.150-ms SDK-to-ingress and
266.490-ms residual. This residual includes codec lookahead/following-packet
requirements, buffering and rendering; it is not a direct NetEq-only gauge.
The next investigation should target receiver recovery after accumulation,
with the user's tolerance for partial audio loss, rather than attributing
these particular peaks to ongoing 200-ms network flight. Prior blanket
receiver-capacity reductions failed; do not restore them without a distinct
measured recovery mechanism and qualification.
The pinned receive-stream Stop/Start seam already calls ChannelReceive's
StopPlayout -> NetEq::FlushBuffers (packet and sync buffers, first_packet reset)
and resets NACK state. A conditional, bounded recovery through that seam is
only a candidate, NOT implemented or qualified here. It must explicitly report
locally discarded audio to the existing loss/peer-quality policy: RTCP network
loss alone does not account for packets already received and then discarded.

Build 2593 is installed in place on Blackview and staged in the private Mac
QA bundle, with SDK 8b217c44 media and unchanged Rust/hidden-volume artifacts.
APK signing certificate matches the prior installed debug/profile build;
packaged media matches its freshly stripped production artifact. Existing
identities on both endpoints match the previous fixture. Physical artifacts
are call-blackview2593-rtcp-loss: incoming signaling 1.12 seconds (one-second
ring polling), 179.94 seconds observed, video enabled at 61.84 seconds. Both
endpoints stay active over P2P with zero sampled audio interruptions, audio
admission drops, discarded audio or route handovers. Both production libraries
expose the new loss fields. Sampled video-phase audio buffers peak at 50/69 ms;
no continuous speech or acoustic latency is measured.

This physical call is NOT a higher-FPS qualification: Mac sends about 1 fps,
phone about 6 fps (coarse TX medians), despite low audio buffer occupancy.
There are 6/2 fresh video-loss witnesses; Mac's four cuts and two of phone's
three cuts are loss-driven, with one further phone cut from local buffer
growth. All sampled integer video loss percentages are zero; coarse gauges
can miss reports and also round nonzero fractions below one percent. Keep
the sparse cadence/recovery issue open rather than calling this very low FPS
good video quality. No video pauses occur in this call. All 118/119 recorded
decisions are immutable and gap-free. Both apps and logcat exit; process
absence and removal of the owned ADB forward are independently verified.
No relay deployment, release, signed commit or push is performed this cycle.

## 2026-10-15: trace exact adaptation inputs; honor fresh media loss

The user now explicitly accepts losing parts of an image or sound during a
call, provided actual loss triggers lower quality. This extends the earlier
buffer-growth/ceiling-only rule. The Dart ladder now reduces video by two
rungs on a fresh audio/video RTP admission failure or a registered audio
interruption, even with stable measured buffers. Initial historical counters,
unchanged counts and counter resets do not represent new loss. Camera-off
video drops are consumed as a baseline, not deferred until camera resume.
Engine replacement also starts new media-drop baselines. Fresh audio failures
at a measured one-fps floor can pause video after two failing observations;
video-only loss does not suspend audio. Actual audio failures also restrain
the endpoint's competing background sources until sustained recovery. Relays
remain opaque and neutral; no wire roles or server priorities were added.

Partial network loss reported in RTCP is NOT fully covered by this change:
the native audio_feedback_reports/video_feedback_reports fields describe
report availability, not monotonic report counts. Cached loss percentages
alone remain insufficient to reduce video with healthy measured buffers.
Next, expose a fresh loss witness from authenticated RR/SR observations,
including nonzero fractional loss that rounds below one percent. Do not
refresh an old lossy peer's witness when another room participant reports
healthy reception. Local RTP admission failure is congestion evidence, not
proof of audible loss (the redundant audio copy may still arrive, and RTP
admission counters also include padding probes).

Local diagnostics now retain sixteen immutable one-second policy input/output
snapshots: the actual receive/peer windows, current/target/peak delay, peer
sequence/freshness, pressure, loss events, rung and streaks. These fields never
enter peer feedback or relay traffic. This closes the gap between a later
debug-API native snapshot and the input which actually caused a policy change.
The adapter exists after video starts; its absence during audio-only baseline
is expected. A bounded history lets a two-second observer retrieve every
one-second policy decision without inferring it from stale gauges.

Physical diagnostic build 2590 completes 178.34 seconds of Mac/Blackview P2P
observation, with video enabled at 61.83 seconds and incoming signaling in
0.21 seconds. Both endpoints stay active; no audio interruption, discarded
audio, audio TX drop or route handover is observed. Video-phase sampled audio
buffers peak at 93/76 ms. Both directions present camera frames. The trace
contains 118 immutable decisions per endpoint, without missing observations.
Both owned apps/logcat exit and the ADB forward is removed. Native artifacts
remain the accepted SDK 618a6d6c media, including the real protobuf-free ANA
factory. No rejected cold-start, framing or receiver-capacity candidate ships.

Exact traces explain remaining P2P FPS reductions, not yet their remedy.
Mac observations 55 and 57 consume peer growth sequences 115 and 117, while
cached 115 at observation 56 correctly cannot advance the bad streak. The
second fresh pulse cuts 60 to 15 fps. The receiver's native windows include
healthy samples between growth pulses; whether skipped feedback sequences
should break a below-ceiling bad streak needs a regression and qualification.
Do not call repeated cached feedback an unfixed defect. A later local buffer
step, windows [6,36,36,36,65,73] then [36,36,36,65,73,73], cuts 15 to 1 fps;
the next window is stable. Desired target also rises from 40 to 80 ms. This
does not yet establish whether the step is genuine network accumulation or
receiver target adjustment. RTT is 6–20 ms and reported loss is zero in that
video phase. No buffer thresholds or production FPS limits changed here.

Targeted Flutter suites pass 111 tests with TMPDIR=/private/tmp/, including
fresh-versus-cached audio/video drop counts, counter resets, engine replacement,
camera-off baselines and actual audio-failure recovery. Physical build 2591
then completes 179.97 seconds with video from 61.80 seconds and incoming
signaling in 0.19 seconds. Both identities match the prior fixture; no data
reset is performed. Both endpoints remain active over P2P, with no route
handover, registered interruption, discarded audio or RTP admission drop in
the sampled call. Thus the new loss branches are tested by regression, not
exercised by this healthy-network capture. Audio-only buffer maxima are
109/68 ms and video-phase maxima 111/77 ms; these are gauges, not acoustic
latency. Each endpoint has 119 immutable decisions, without missing records.
Coarse video TX medians are about 15 fps. Phone still has six protective
video-pause samples from the existing buffer policy; higher sustained FPS
remains open. Both apps/logcat exit, the ADB forward is removed, and Mac/phone
process absence is independently verified. Final build 2592 adds the engine
counter-baseline regression fix and freezes diagnostic latest to the last
recorded snapshot; its media/SDK native artifacts are unchanged.
Build 2592 is installed in place on Android (versionCode 4592, matching signer
and accepted stripped native hashes) and staged in the private Mac QA bundle.
Both final apps reach real-stack ready with their existing identities intact.
Startup smoke finishes without another call; both owned processes and the
test forward are independently verified absent. No release, push or relay
deployment is performed in this cycle.

The unchanged mixed relay qualification still fails its PCM latency gate;
fresh-drop handling alone cannot fix runs with zero such events. Prior primary,
cold-video and dual-framing captures all have zero observed audio/video RTP
admission drops and registered audio interruptions. Keep that failure open;
healthy short physical calls are not substitute qualification.

## 2026-10-15: reject cold-video seed candidate; resume Blackview calls

The preceding cycle made progress (SDK 618a6d6c/root 72c80614), including
installing Android build 2589 with adaptive Opus available. Qualification is
still open. This cycle tested a separate startup hypothesis: a video Call's
default estimate is 300 kbit/s and the stream then seeds the entire selected
profile before measuring spare capacity. A candidate seeds both video Calls
at 30 kbit/s and seeds feedback-capable streams at min(30 kbit/s, selected),
retaining their maximum, later discovery, audio Call and legacy stream floor.
A real ProbeController regression fails against the prior helper and passes
with the candidate: initial clusters stay at/below min(selected,180 kbit/s),
while profile/allocation-driven discovery and the original ceilings remain.

The unchanged full mixed gate still fails: cold-video-full-360 uses the real
Opus/VP8/Dart adapter, independent obfs4 channels, a blind 1,024-kbit/s aggregate
FIFO, two exact 512-KiB encrypted files and native PCM/tone-position coverage.
PCM peaks are 291.205/220.350 ms (p95 219.909/200.359 ms), versus audio-only
peaks 71.885/90.431 ms in the same run. The clock passes (33.40-ms maximum
interval); all 704 edges are attributed, no quiet frames or reported
interruptions occur. Current buffers reach 242/200 ms. Video has 55/49
protective pause samples and maximum sampled gaps of 20/17 seconds, though
both directions move at the end. Files finish exactly in 282.6/292.2 seconds;
all 95/99 feedback reports plus bootstrap arrive. All workers exit, three
nodes stop with status 0 and no fixture sockets remain.

The candidate is rejected and all three SDK source/test edits are restored.
Its exact patch remains private as rejected-cold-video-start.patch, alongside
cold-video-before/after.log and the media-cold-video library. This was against
the protobuf-free Mac archive; do not interpret differences from older,
protobuf-enabled bench binaries as a matched causal comparison. The absolute
quality failure suffices to withhold the candidate.

Attribution covers all 21,108 captured owned primary cells across both hops,
with zero ambiguous/incomplete routes or in-window uncaptured witnesses. The
largest 205-ms flight is at second 71.462: source-to-relay 92.392 ms, relay
residence 0.150 ms, relay-to-target 112.458 ms. The worst PCM edge is later,
at input second 73.731, on a 40-ms packet: capture-to-encode 31.876 ms,
SDK-to-ingress 12.416 ms, post-WebRTC residual 246.886 ms. The following packet
arrives at second 73.815. As before, that residual is not a direct NetEq-only
measurement. Initial seeding alone does not remove steady-state flight bursts
and their receiver recovery tail; do not reduce receiver capacity or relabel
transit traffic to make this gate pass.

The user supplied a replacement-phone password; it successfully opens the
existing Blackview identity and reaches real-stack ready. No new identity,
profile or container reset is needed. Password material remains only in the
private local fixture. Physical call artifacts are call-blackview2589-aot;
the private Mac bundle uses the accepted 618a6d6c production media, not the
rejected cold-video candidate. Initial incoming signal arrives in 0.17 seconds,
and both endpoints become active over P2P. Native stats confirm adaptive audio
is actually enabled on BOTH endpoints (209-byte hint, real 20-ms packets and
28.4-kbit/s target in the early sample), rather than inferred from build flags.
The first call completes 177.97 seconds of observation, enabling video at
62.03 seconds. Both endpoints stay active over P2P throughout, with zero route
handovers, reported interruptions, discarded audio packets or audio TX drops.
A single jitter-buffer flush is already present in the early audio phase and
does not increase with video. Sampled audio-buffer maxima after warmup are
96/91 ms for audio-only, 93/93 ms with video. These are buffer gauges, not an
acoustic end-to-end latency measurement; no continuous speech is supplied.
Both directions encode, decode and present camera frames. Lifetime video TX
rates finish around 21/20 fps; coarse inter-snapshot medians are 17/16 fps.
Do not mistake the lifetime native video_tx_fps field for the current rung's
cadence. Direct profile permits 60 fps, while observed local previews run
around 30. The ladder varies through 1/6/15/30/60 fps and drops to 1 fps on
Mac near the end despite all observed audio buffers being below 100 ms.
Fresh-window growth still triggers that policy; higher sustained P2P FPS needs
investigation of those actual windows, not a blanket higher maximum or removal
of audio guards. The user reports the P2P image/overall result looks very good
and would prefer higher FPS. Both owned apps and the logcat process exit, and
the ADB forward is removed. No existing identity is reset.

A second call deliberately sets both QA endpoints' P2P policy to denied, with
the prior effective policy saved and restoration wired before process cleanup.
Its first setup attempt never places a call or changes a policy: the private
Mac launcher's naive bind preflight mistakes the just-closed port's TIME_WAIT
for a live listener. The old PID is absent and lsof shows no listener; the
private preflight gains SO_REUSEADDR and the next attempt starts normally.
Artifacts are call-blackview2589-relay2-aot. Both native endpoints confirm an
active RELAY call; incoming signaling arrives in 0.15 seconds. Audio adaptation
is enabled on both, with actual 20/40-ms packetization observed. Final relay
counters confirm 179.67 seconds of active relay observation, with video from
61.66 seconds. Both endpoints retain enabled ANA; there are zero reported audio
interruptions, discarded audio packets, audio TX drops or route handovers.
After warmup the sampled current-buffer maxima are 157/144 ms for audio-only
and 186/164 ms with video. Video-phase RTT ranges are 90–117/87–117 ms. These
are sampled buffer/RTCP gauges, not acoustic latency or measured speech quality.
Both directions deliver/present camera frames, but cadence is lower: coarse
inter-snapshot video TX medians are 6.4/1.0 fps, corresponding received medians
1.0/6.4 fps. Phone has six sampled protective video pauses. This is not proof
of sustained high-quality relay video or constrained file coexistence.

The previous effective P2P policies are restored AND read back successfully on
both endpoints before shutdown. Both owned app processes, the logcat process
and the ADB forward are gone. The private Mac preflight fix is retained only
in the QA launcher. No relay binary, privacy policy or production video ladder
was changed this cycle. Installed Android remains build 2589/SDK 618a6d6c;
rejected cold-start code was never installed on either physical endpoint.
relay-codec-control's help now correctly requires the local ANA factory rather
than protobuf, matching the prior accepted SDK fix. Root/SDK working trees are
committed/clean at cycle end; no commits are signed or pushed.

Next action: inspect actual fresh buffer-window inputs and current peer values
behind sub-100-ms P2P rung reductions, and qualify any improvement against both
real calls and the still-failing mixed relay gate. Current mediaDiagnostics
exposes peer retained delay/growth but not its current/target/sequence, so the
existing physical snapshots cannot exactly replay every adaptation input.
Do not present higher FPS as merely raising the already-60-fps profile ceiling.

## 2026-10-15: enable adaptive Opus in protobuf-free Android builds

SDK 618a6d6c fixes the confirmed platform gap. The engine formerly rejected
nonzero audio_packet_overhead when WEBRTC_ENABLE_PROTOBUF=0, so standard
Android bundles never entered the adaptive Opus path tested on the Mac bench.
The prior installed app was protected by that rejection; do not label the
standalone regression's crash as an observed phone crash.

The pinned WebRTC ControllerManagerImpl translation unit is retained with its
LICENSE/PATENTS and upstream source hash. Its only source changes are one
include and an exact versioned-local-config branch before the original parser.
That branch constructs the same real FrameLengthControllerV2 (16-kbit/s floor,
fast adaptation), then BitrateController (zero offsets). It uses Opus's actual
supported frame lengths and initial state. The unchanged upstream protobuf
path remains available. All five platform builders compile this member before
the normally extracted WebRTC archive; iOS puts it in the force-loaded Veil
archive. Do not force-load WebRTC or omit the replacement object. No test-only
encoder API, header-access workaround, new codec, relay metadata or scheduler
priority is used. This removes a build dependency, not the existing payload,
allocation, audio-buffer or video-policy limits.

Real Opus regression passes against both pinned macOS archives:
ana-protoless-after.log and ana-protobuf-after.log. Each checks supported
maxptime 20/40/60, every allocation transition's 16–32-kbit/s payload bound,
and actual encoded packet durations under the four framing profiles. Without
the replacement factory, explicitly enabling the same config against the
protobuf-free archive crashes the standalone encoder: ana-protoless-before.log.
Again, production previously refused to enable that configuration.

The complete protobuf-free Call engine passes --dual-framing isolation
(audio 509/video 536 retained across video startup). Its unchanged
--adaptive-encapsulation decoded-PCM smoke also passes: current-delay peaks
83/132/152 ms, reverse 71/159/179 ms, zero dropped wire packets or reported
interruptions, source-clock lateness 6.24 ms. Actual tone-edge peaks are
229.95/261.20 ms; the smoke gates current delay. This is functional/native
qualification, NOT a passing full relay actual-PCM quality gate. The earlier
full-capture failures remain unresolved.

The Android production library builds successfully against the verified
standard arm64 SDK (protobuf disabled), with 99 public media exports. Added
DT_NEEDED libveilclient_ffi.so on the host because the isolated builder lacks
patchelf. Profile/AOT app 0.13.84+2589 (split APK versionCode 4589) is installed
on Blackview BV6600Pro via adb install -r. Its signing certificate matches the
previous installed debug app. Both packaged media and Rust SDK bytes exactly
match the fresh outputs after the same NDK --strip-unneeded step used by
Gradle; phone2589-native-proof.json records hashes. The SDK Rust binary is the
fresh same-day release build from the previous section, unchanged by this
C++-only fix. Existing storage library and application data are preserved.
The pre-update APK is backed up as blackview-before2588.apk.

The phone's local API starts after both upgrades. Its existing personality
remains locked; the cached Poco test password fails to open that container.
Asked the user to unlock it, without resetting data or guessing passwords.
The attempted physical call stops before placing a call. Both test app
processes exit; the phone ADB forward is removed. There is no new physical
voice/video quality result yet. Do not imply that native tests prove speech
quality or solve all pauses on real networks.

A fresh Mac QA app was built with TMPDIR=/private/tmp/ and the current Rust
SDK. Its Dart build is 2588; its final production media is 618a6d6c against the
protobuf-free Mac archive (99 exports). The app-generated MacOS/xveil-debug.log
was moved outside the bundle before re-signing; final strict/deep signature
verification passes. This private QA bundle is not an /Applications update.
No app remains running from these tests, no Docker builder remains, no relay
was deployed, no tags/releases/pushes were made. Audio/video qualification
remains active; the phone unlock request is pending.

## 2026-10-15: reject codec-ceiling fix; retain isolated framing probes

The real Opus characterization now covers separate framing/allocation profiles.
At a 509-byte route hint plus RTP overhead, the stock 160-kbit/s controller
ceiling settles on 60-ms packets; 183,736 bit/s permits 40 ms while preserving
the 16–32-kbit/s payload bounds and a 25% control allowance. Scarcity still
selects 60 ms and recovery returns to the profile's healthy packet length.
This mechanism is tested, but raising the production ceiling did not pass
end-to-end qualification. The production encoder and engine changes were
restored; SDK ada10011 contains tests and stand-only hooks, not that fix.

framing-audio-ceiling-full-360 fails the unchanged gate: actual PCM peaks
181.953/291.560 ms, p95 170.330/200.062 ms; current buffers 156/250 ms.
Video gaps reach 16 seconds with 15/14 protective pause samples. The source
clock also fails (63.18-ms interval, 53.521-ms wake lateness), but the worst
PCM edge is at 33.331 seconds, before the clock stall at 147.334 seconds.
That edge spends 276.158 ms after WebRTC reception. A separate early owned
source-to-target path takes 218.156 ms: source-to-relay 143.592 ms, relay
residence 0.130 ms, relay-to-target 74.434 ms. This does not identify one
network cause, but relay processing itself does not account for that path's
waiting time. All 704 tone edges are matched; both files are exact and all
health reports arrive. There are no quiet frames or reported interruptions.

An exploratory first-hop model estimates video overhead at 535.609 bytes per
RTP packet for the complete joined source frames in this capture. It uses the
verified Forward/OVL/VDF framing, a 1,200-byte ordered-record limit and the
expected obfs4 padding, not measured padding or TCP/IP bytes. Sequence traces
are bounded: 5,851 of 5,894 observed frames join completely, the last at
309.807 seconds. Missing joins are unknown, not observed packet loss. The
early 20–35-second subset has all 187 frames complete and estimates 531.564
bytes/RTP. Do not present this as a full-capture wire census.

The stand-only constructor independently configures video overhead; actual
controller getters verify audio 509 and video 536 before and after video
startup. relay-codec-control.py records the native applied video value rather
than echoing its argument. dual-framing-controller-full-360 also fails:
PCM peaks 249.883/289.951 ms, p95 181.109/218.641 ms, current buffers 211/260 ms,
with a valid 18.60-ms source interval. Video keeps moving (maximum sampled
gaps 2.002/2.003 seconds, no protective pauses); both files are exact, all
704 edges and all health reports arrive. Buffer feedback is received and
reduces the sender's video budget on the next policy tick. This is not an
accepted remedy. Both full runs stop all nodes with status 0, reap workers
and leave no stand sockets. No relay scheduling or privacy policy changed.

Rejected binaries, exact patches and logs are retained privately under
xveil-physical-20261014/{media-framing-audio-ceiling,
media-dual-framing-controller,framing-audio-ceiling-and-video-model.patch}.
The restored-production stand library is media-framing-diagnostics; its
--dual-framing smoke and the real Opus profile characterization pass.

A further build gap needs investigation: the pinned standard Android WebRTC
bundle sets rtc_enable_protobuf=false, while Veil currently gates adaptive
Opus setup on WEBRTC_ENABLE_PROTOBUF. The Mac adaptive bench uses a different,
protobuf-enabled build. Native ANA controllers exist in both builds, but the
stock ControllerManagerImpl::Create factory returns null without protobuf.
Do not infer that the phone exercises the Mac adaptive packetization path.
Possible follow-up is a programmatic factory for the same real controllers,
with identical pinned-source build integration and tests on both variants.
Do not call a test-only encoder factory from production or pass an unsupported
marker to the unmodified protobuf parser.

Blackview remains connected, replacing Poco; no cellular phone is required
for these endpoint investigations. Fresh Android media (99 production exports)
and Rust SDK release builds succeeded. The downloaded Android WebRTC SDK was
verified against pin 4ef980bc2c70834276c791e71e7834b8809f24ad and its manifest.
The media build lacked patchelf in its container; the host added and checked
DT_NEEDED libveilclient_ffi.so before staging. A profile/AOT APK 2588 with the
explicit local debug-hook opt-in is being built; installation and physical
quality are not yet verified. The installed APK was backed up first. No app
was started during these synthetic experiments; no servers were deployed.
The audio/video qualification objective remains open.

## 2026-10-15: reject packet-shortening hold and audit relay framing

The proposed one-second sustained-headroom requirement before shortening
Opus packets was implemented privately and tested with the real ANA/Opus
encoder. Its burst, sparse-callback, threshold and immediate-scarcity checks
passed, but the unchanged native adaptive-encapsulation PCM test did not:
candidate current-delay peaks were 81/211/231 ms, versus 56/178/198 ms for
the stock library on the same test. Candidate/stock source-clock lateness was
3.41/3.45 ms; neither run dropped wire packets. Tone-edge delays reached
310.15/280.04 ms respectively (the native smoke's existing gate checks current
delay; the full relay gate independently checks actual PCM edges). This is
not a replicated causal study, but the candidate fails qualification. Both
encoder files were restored. Do not adopt that hold or its anti-flap test as
a product requirement. The exact rejected patch, binaries and logs remain in
the private cache under rejected-opus-one-second-hysteresis.patch and
opus-hysteresis-*.log.

The 209-byte hint is NOT wholly lost: native code supplies NetworkRoute's
packet_overhead, the transport feedback adapter counts it and AudioSendStream
propagates it to ANA along with RTP overhead. Its value describes the direct
QUIC model: seal 36 + authenticated AppRtData 89 + OVL 24 + datagram AEAD/header
40 + opaque-flow prefix 20. The comment saying both non-onion routes use that
framing is inaccurate. A compact Delivery/Forward uses next-hop 32 + envelope
197 + suffix 9 and optional marker pairs (2 bytes each); the fixture's neutral
class adds one pair. Its fixed overhead is consequently 360 bytes on a single
QUIC flow datagram, or 316 bytes on an ordinary session stream before carrier
framing, for one unbatched RTP packet. An independent ordered channel uses
the same 60-byte flow/datagram codec as QUIC, plus a two-byte record length;
it does NOT use the ordinary stream's 16-byte session seal instead. RTP itself
and QUIC/TCP/IP are separate.
These are per-hop costs, not their sum across two hops. Multiple RTP packets
may share a seal; fragmentation or bucket padding needs separate accounting.

For unfragmented, unbucketed obfs4 writes, encrypted length 2 +
pad-length 1 + AEAD tag 16 + uniform 0..255 padding adds a mean 146.5 bytes:
462.5 in total on the ordinary stream. The independent ordered channel in the
fixture instead costs 360 + 2 + 146.5 = 508.5 bytes. The diagnostic comparison
was launched with 463 before this extra codec layer was established; preserve
it as an intermediate estimate, NOT a complete wire-accounting correction. The padding
reservation constant 1024 is NOT the random padding range. No privacy padding
is removed. A one-value replacement is not yet an app fix: direct routes,
carrier choice, batching and route handover need a truthful model.

Capture now retains the already validated sealed payload length. Primary-hop
analysis reports known/unknown source-cell size counts, Delivery wrapper
counts and OVL-frame bytes. It explicitly excludes the session codec, carrier
padding/QUIC/TCP/IP and does not equate cells with RTP packets. This avoids
calling an ordinary-stream AEAD estimate a measurement of a parallel channel.
Legacy captures lacking the field remain unknown; ambiguous source records
cannot establish a size. No ciphertext preview, plaintext or new role leaves
the reader, and relay scheduling/wire formats are unchanged.

The prior SDK cache path rust-target/debug/libveilclient_ffi.dylib is absent.
The current SDK source (17e5b731, clean) was rebuilt in the repository's own
third_party/veil/target with the same embedded/production/packet-tunnel features;
overhead-audit-sdk-build.log records success. Do not claim byte-for-byte identity
with the older full capture solely from the source commit. No physical app or
relay is updated. Blackview BV6600Pro is visible over ADB; no phone or GUI app
is started during these synthetic controls.

Intermediate relay-overhead-463-full-360 completes with FALSE status. Its PCM
peaks improve to 171.342/180.165 ms, with no missing edges or quiet frames,
but the source interval reaches 45.30 ms (unchanged gate: below 40 ms).
One sampled video gap is still 13 seconds, with 12 protective pause samples.
Both 512-KiB files are exact (189.2/201.5 seconds), and all 84/90 health reports
plus bootstrap arrive. This capture cannot qualify a product change.

The corrected-model relay-overhead-509-full-360 also completes FALSE, now with
a valid 37.96-ms source interval: PCM peaks 205.710/215.807 ms, p95
171.891/188.418 ms. Current-delay peaks are 158/172 ms, all 704 tone edges
are matched, and there are no quiet PCM frames or reported interruptions.
Video moves through the end with no protective pause samples; maximum sampled
pull gaps are 1.015/1.018 seconds. Both files are exact (224.8/200.3 seconds),
and all 91/90 health reports plus bootstrap arrive. The improved distribution
does NOT satisfy the unchanged 200-ms actual-PCM gate. No blanket replacement
of the application's 209-byte hint is adopted.

The new capture metadata verifies all 12,244 owned primary source cells have
a 240-byte Forward wrapper, with no unknown/ambiguous sizes. All 12,244 also
have complete two-hop capture paths. OVL-frame total is 6,754,549 bytes for
3,522,133 sealed-payload bytes. These counts include primary RTCP/batches and
are not per-RTP overhead or a measurement of obfs4 padding. Both full captures
stop all three nodes with status 0, reap policy/audio/file/shaper workers and
leave zero fixture sockets. Thirteen scoped Python capture/analyzer tests pass.

Next separate candidate: the 1000-byte RTP and compact-cell ceilings were
chosen for 1382-byte QUIC datagrams, while independent ordered records permit
1200 bytes. A 1000-byte RTP packet becomes a 1360-byte flow datagram on the
neutral relay path and splits. With an 840-byte RTP/cell ceiling it fits
exactly; smaller batched packets must ALSO obey that cell limit. Merely
lowering the batch cap can add another Forward/seal, so fragmentation counts
alone do not establish a bandwidth or quality improvement. A new actual
seal/Forward/fragment-codec regression checks the full record boundary and
retains fragmentation for old 1000-byte raw packets. The stand's optional
--max-rtp-packet-size uses the existing native setter before video starts,
without restarting audio; the default constructor behavior is unchanged.
This candidate was compared with both audio hints before changing the app
ceiling. The SDK cell-limit experiment was NOT accepted:

* relay-cell-840-audio-209-full-360: valid 16.91-ms source interval, PCM peaks
  211.147/183.366 ms (p95 170.657/172.129), current buffers 156/152 ms. No
  protection pauses, missing edges, quiet PCM or reported interruptions; video
  moves at the end with maximum sampled gaps 1.999/2.003 seconds. Exact files
  finish at 215.9/194.4 seconds and all 87/91 health reports plus bootstrap
  arrive. Overall FALSE: actual PCM still exceeds 200 ms.
* relay-cell-840-audio-509-full-360: valid 14.71-ms source interval, PCM peaks
  191.910/211.644 ms (p95 179.413/189.194), current buffers 162/168 ms. Again
  no protection pauses, missing edges, quiet PCM or reported interruptions;
  video moves at the end with maximum sampled gaps 2.000/3.000 seconds. Exact
  files finish at 202.2/200.4 seconds and all 85/87 health reports plus
  bootstrap arrive. Overall FALSE: the combined change is also insufficient.

Both captures attribute all 704 PCM edges without unmatched attribution.
The 840/209 worst input at second 160.591 uses a 60-ms packet: capture to
encoded 39.467 ms, SDK flight 20.842 ms, post-WebRTC residual 150.790 ms.
For 840/509 the worst input at 125.241 similarly uses 60 ms: capture to
encoded 50.007 ms, flight 69.443 ms, residual 92.117 ms. The residual can
include following-packet/FEC lookahead and rendering, not only NetEq. Both
full captures stop nodes with status 0, reap every worker and leave no sockets.

The exact candidate patch and library are preserved privately as
relay-cell-840-candidate.patch and relay-cell-840-sdk/libveilclient_ffi.dylib
(SHA-256 5e164a8d4c26997804893cc6fece54750b8f24228cec52fe21e9596f9ef36d3f).
The candidate patch is against SDK 17e5b731, not the final test-only commit.
Production RTP and compact-cell limits remain 1000; no runtime behavior is
promoted from these failed gates. The retained SDK test documents the actual
boundary with real seal/Forward/fragment codecs: 840 bytes uses one record,
841 and old 1000 use two. Its header and traffic-class marker are neutral.
The full 47-test media-priority module passes after restoring runtime settings;
the restored SDK is rebuilt into the normal repository target. Python's 13
scoped capture/analyzer tests and script syntax check also pass. No whole CI
or physical speech-quality qualification is claimed.

Next concrete investigation: a 509-byte route hint reaches ANA as 529 bytes
including RTP, as witnessed in native encoder rows. The controller's 160-kbit
ceiling and the encoder's 25% control headroom permit at most 120 kbit/s there.
At 40 ms the strict payload-floor threshold is already 121.8 kbit/s, so the
ceiling itself prevents choosing 40 ms even if the path has headroom. Testing
a framing-aware controller ceiling that can admit 40 ms is justified; it is
NOT a reason to force short packets, remove control headroom or reduce receiver
capacity. A product remedy still needs route/carrier-aware framing estimates
and safe handover rather than applying the obfs4 mean to every QUIC route.
SDK 207c641b retains the boundary test and corrected source comment only.
The goal remains active and quality unresolved. Blackview currently has
0.13.84 (2572); it and the user's desktop app were not launched or replaced.

## 2026-10-15: trace owned primary cells through both relay hops

Previous cycle made progress in SDK `7a8988b1` and xVeil `361ce0ee`. Quality
is still unqualified: prior full captures fail the unchanged 200-ms PCM gate
and contain long video pauses. This cycle changes observation only: codecs,
playout capacity, video/source policies, wire formats, forwarding/scheduling
and the blind 1,024-kbit/s aggregate limiter are unchanged. No physical app or
relay deployment is performed.

The old source-cell diagnostic recognized direct AppRtData primary frames,
but not their authored Delivery/Forward form. Explicit source tracing now
recognizes a COMPLETE, locally owned primary Forward with the existing VME1
seal. Wire hints and neutral forwarded queues cannot establish ownership.
Explicit bounded tracing covers late primary sequences instead of stopping
at 4,096; ordinary sparse RT tracing retains its original sequence/sample
budget. Each owned-source row contains the SHA-256 of the same encrypted
body preview used by the observer (maximum 256 bytes), never payloads, keys,
node IDs or a role sent to the relay. SHA-256 was already in the lockfile;
it is now a direct veil-session diagnostic dependency. Six focused trace
tests include late relayed primary ownership, foreign queue rejection,
truncation/trailing-byte rejection and the existing source bounds.

The fixture observer can explicitly request up to 131,072 sanitized records
per node; its default is still 4,096. It reports raw event counts and nodes
that reach the cap. Existing nonce/routing metadata is parsed ONLY on the
host from known fixture Forward previews, not by relay service. A new analyzer
joins a source's PRIVATE owned-preview witness to that cell's two hop pairs.
It refuses ambiguous/partial routes and inverted clocks, prints no nonce or
hash, and does not claim full-body equality or interpret missing capture as
loss. Repeated source epochs across opposite directions cannot cross-label
ownership. Twelve Python tests cover these joins, privacy/bounds and legacy
observations.

The initial real-SDK `primary-hop-smoke-22` (no video/files) passed its scoped
quality/control/cleanup gates and joined 1,530 primary routes with sub-26-ms
capture-to-target maxima. It also exposed two more observation limitations:
100 events/sec/peer is shared between directions and silently samples capture;
and incoming frame headers sometimes retain the 16-byte session AEAD tag in
body_len although the observed body excludes it. The 54 incomplete routes are
not audio loss evidence. That short capture and its original result remain
unchanged; do not retrofit an inferred 16-byte correction into old evidence.

CaptureEvent/AdminResult now retain the original header body_len AND provide
optional observed_body_len measured before the preview is clipped. Older
serialized events still deserialize with None. The CLI ignores the optional
extension; the host normalizes only when the measured field exists and keeps
wire_body_len for auditing. A separate unit test verifies legacy JSON reading
and extended serialization. Debug event sampling remains 100/sec/peer by
default; the trusted VEIL_DIAG_CAPTURE_EVENTS_PER_SEC environment override
allows 1–1,000 for owned fixtures only, with the same bounded peer map. The
public limiter constructor clamps that diagnostic ceiling; tests check both
its cap and peer isolation. It changes no service/data allowance or role.

Verification: dispatcher-state 8 tests, session 555 passed/8 existing ignored,
node-runtime 657 passed/11 ignored plus 8 integration tests. The newly added
admin compatibility case separately passes after the full suites. Session
and dispatcher-state Clippy pass all targets with denied warnings; default
CLI check (including RocksDB/BoringSSL) and production embedded FFI build pass.
Private cache logs: primary-capture-suites.log, primary-capture-admin-compat.log,
primary-capture-clippy.log, primary-capture-cli.log, primary-capture-sdk-final.log.

The full comparison is primary-route-full-360: stock media, the complete
mixed/file profile, native clock/tone-position coverage and every unchanged
quality gate; capture begins at second 1, record bound 131,072/node and debug
sampling budget 1,000/peer/sec. Source-cell tracing is explicit. Evaluate its
terminal result and attribution limits before claiming the worst audio path
is localized. No compilers or other load tests run during its timed phase.

SDK `17e5b731` contains the diagnostic changes above. The full
primary-route-full-360 completed with FALSE quality status: mixed PCM peaks
221.398/251.678 ms (p95 210.346/218.789), still above 200 ms. All 704 tone
transitions are attributed, the source clock passes at 27.750 ms, no quiet PCM
or interruptions are reported, and native current-buffer maxima are 188/221 ms.
All 85/99 controls arrive exactly once plus bootstraps; both 512-KiB files are
exact (291.3/277.1 seconds). Video moves through the end, but one direction has
a 13-second sampled gap and 12 protective pause samples. Runtime drop/failure
deltas are zero. All nodes return zero on stop; audio/file/policy/shaper workers
exit and no fixture sockets remain. No physical speech quality is qualified.

The new observation covers the actual bad interval. Capture records
81,149/40,564/40,586 events for the relay/endpoints, with no cap reached,
reader errors or rejected records. 15,671 received rows have different header
and observed lengths; the measured length corrects their grouping without
rewriting old captures. There are 19,847 distinct private primary witnesses;
only 84 lack a source TX capture, ALL before capture started (0.011409–0.991884
seconds). No source witness lacks its clock. Every one of the remaining
19,763 owned primary cells is matched across BOTH hops, with zero incomplete
or ambiguous routes. Capture continues through second 360.3, source trace
limits are not reached. This is a census of the emitted source witnesses in
the recorded interval, not an assertion of full-body equality or a general
adversarial traffic classifier. See primary-hops.json for clock/boundary counts.

Primary capture-to-target maxima are 156.428/146.088 ms. The worst cell is
source node 1 at second 256.472: 53.504 ms source-to-relay, 0.130 ms relay
residence, 102.794 ms relay-to-target. Across all matched primary cells relay
residence p95 is 0.199/0.200 ms; maxima are 10.259/2.433 ms. Both transport legs
contribute; the data do not justify prioritizing a user or recognizing media
at the relay. These legs include the blind proxy's buffers and kernel queues,
not just propagation on a physical network.

The native worst PCM edge is source 0 (fixture NODE 1), input second 263.611,
251.678 ms total. Its packet flight is only 10.876 ms and its post-WebRTC
residual is 240.675 ms. At second 256 the receiving side had a 100-ms target;
after the preceding 156-ms primary flight, concealment increases, then its
target/current buffer reach 180/221 ms. They stay elevated for several seconds
and recover to 100/123 ms around second 265. Publication warmup is at 265.951,
AFTER this burst, so that publication is not its initiating event.

Next controlled candidate: stabilize adaptation's brief packet-duration
improvements, while retaining immediate efficiency changes under low bandwidth.
In the complete native trace source 0 changes duration 135 times and source 1
112 times. 25/32 and 29/36 bouts at 20 ms last at most one second of encoded
audio. Around the worst edge source 0 runs 60 ms for 4.68 seconds, then 40 ms
for 2.12 seconds, briefly 20 ms for 340 ms, then returns to 60 ms. The current
BoundedAudioEncoder mirrors FAST FrameLengthControllerV2 without hysteresis.
Those facts justify testing a sustained-headroom requirement before shortening
packets; they do NOT prove duration switching is the sole cause. Do not force
20/40 ms or lower receiver capacity: rejected controls remain documented below.
The next candidate needs native packet/PCM and full video/file coexistence
comparison with the same gates. Current product quality remains unresolved.

## 2026-10-15: inspect transport burst and restore session lint gate

Previous cycle made progress in SDK `12816b7c` and xVeil `a87980e8`, closing
proxied write-admission bypasses. The original mixed audio/video quality failure
remains open. No handset or GUI app is started in this cycle, and no relay is
updated. The preserved `pcm-bg-ctrl-360` is still the failed evidence, not a
passing result to reinterpret.

At the original 106–108-second flight spike, existing SDK diagnostics across
observed channels show cumulative outbox-to-transport admission maxima under
8 ms, ordered-record queue maxima 5.053 ms, write/flush maxima 3.762 ms,
receive-queue maxima 0.474 ms and dispatch maxima 0.167 ms. These sampled and
cumulative diagnostics do not uniquely join an RTP packet to a child, but do
not explain the full 181-ms flight. Socket snapshots in this interval report
queued high-water marks below 4 KiB. The blind shaper independently observes
reader-buffer residence, which must not be mistaken for an SDK queue or the
same audio packet. Follow-up capture is `pcm-hop-capture-360`: SDK binary built
at `12816b7c`, stock media, full unchanged 360-second stress profile, both files,
accurate 100-ms control polling, isolated 1,024-kbit/s aggregate FIFO and native
PCM clock. Bounded opaque preview capture starts at second 100 to separate
capture-before-write and dispatch on each hop. Missing captures are not losses
and preview matches do not prove full-body equality.

While that immutable binary runs, session cleanup removes the eight previously
reported library Clippy violations without suppressing the gate. Queue helpers
carry the existing complete `FrameEnvelope` instead of separately passing eight
metadata fields; original lossy ingress time, deadline, source cell, signaling
reservation and reliable credit stay owned until the same admission/drop point.
The existing metadata-preservation test now enters through `push_envelope`.
Both large parallel-session enum variants move behind one Box each, reducing
the enclosing runner's inline state; no pool count, owner, worker or wire changes.
Pool default is derived, an unnecessary carrier lifetime is elided, and identical
admission conditions/nested receipt guards are combined. Queue policy and
transport selection are unchanged. Verification and final capture results must
be recorded below before claiming any green gate.

The completed `pcm-hop-capture-360` remains FALSE. Mixed-phase PCM peaks
210.731/221.310 ms fail the same 200-ms gate; p95 is 189.847/191.372 ms.
All 704 tone transitions are attributed, no quiet PCM or reported interruptions
occur, and the native source clock passes at 14.360 ms. Native current-buffer
maxima are 166/176 ms. All 90/93 controls arrive exactly once by nonce (plus
bootstraps); both 512-KiB files are exact in 243.4/242.7 seconds. Images move
through the end, but sampled gaps reach 13/14 seconds, with 13/24 protective
pause samples. Node stops return zero; native audio, files, policy and shaper
exit; no sockets remain. None of this qualifies physical speech quality.

Opaque capture accepts all three observers, has no reader errors/rejections,
and closes all readers. Its 4,096-row-per-node limits fill normally: relay
TX coverage ends at second 121.677, endpoint TX coverage around 142.4. Within
that CAPTURED SUBSET, unique preview matches show endpoint-to-relay maxima
159.875/126.605 ms and relay-to-endpoint maxima 66.905/67.393 ms. There are two
ambiguous groups and 6,706 incomplete groups; these are NOT packet-loss counts.
No captured body exceeds 1,220 bytes. The largest actual PCM edge is at second
213.111, OUTSIDE capture coverage. Neither that edge nor the former run's
181-ms RTP peak can be assigned to one hop from this partial observation.
The native RTP trace remains complete; its 100–125-second flight maxima are
114.053/130.064 ms. They must not be equated to opaque-preview maxima, which
can include OTHER producers and different timestamps. Per-hop attribution of
the worst audio edge remains open; do not use a random matching small frame
as an audio witness. Next tracing needs bounded coverage through the actual
bad window and an endpoint-only correspondence to the audio source, without
adding roles/priority to relay service or the wire.

Session Clippy now passes `--all-targets -- -D warnings`. After the original
eight library findings were fixed, all-targets additionally found an existing
`feedback_tests` module before production items in `local_reliable_admission`;
that unchanged test module is moved to the end. No allow is added. The full
session suite passes 554 tests (8 existing ignored, one doc test ignored).
SDK `7a8988b1` contains this session refactor. The complete node-runtime suite
passes 657 unit tests (11 existing ignored), plus its 8 integration tests; its
two doc tests remain ignored. The final embedded production-feature FFI build
passes. Logs are `session-admission-runtime-tests.log` and
`session-admission-sdk.log`. This final binary includes the refactor; the full
mixed capture above intentionally used the pre-refactor `12816b7c` binary.
No whole-workspace CI result or new physical/relay quality qualification is
claimed. All owned test processes and fixture sockets are gone.
Private artifacts: the capture's `hop-analysis.json`, `pipeline.json`,
`shaper-timing.json`; `session-admission-clippy-final.log` and
`session-admission-tests.log` in the same cache root.

## 2026-10-15: close the SOCKS write-admission bypass

Previous turn made progress in SDK `410c1516` and xVeil `4f1090b7`; the
accurate-control 360-second mixed capture remains a quality FAILURE, not a
qualified build. This cycle keeps its audio/video gates, codecs, RTCP and
receiver capacity unchanged. No physical app/call or relay was started/updated.

SDK `12816b7c`: ordinary `socks://` and `sockstls://` transport connections now
use the same Darwin write-admission wrapper as direct TCP/TLS. SOCKS tunnel
sockets also receive the established TCP send-buffer/unsent threshold and MSS
settings on supported platforms. The transport honors its context's NODELAY
setting. TLS still selects BoringSSL or rustls exactly as before, and proxy
DNS resolution stays remote. The public raw bootstrap socket API retains its
return type and gains the socket settings; it does not promise the stream
wrapper's partial-write bound. These are uniform local transport bounds, never
media-role detection or preferential relay service. A 4-KiB write bound is not
a claim that total in-flight/socket/TLS buffering is 4 KiB. SOCKS' returned
connection still does not expose independent auxiliary-session capability.

Two tests exercise the PUBLIC transport over an actual loopback SOCKS handshake,
with a domain-only target (`peer.invalid`) and optionally real TLS. The proxy
stops reading: a 512-KiB reliable write must wait while a message in the reverse
direction still arrives. Releasing reads must deliver the exact complete byte
sequence and EOF. On Darwin the first application write must be partial and
at most 4 KiB. Reverting just the production implementation to its parent,
while retaining the tests, produces two expected failures: original first
writes accept 327,212 and 393,216 bytes. The fixed source is restored before
final verification; the failure artifact is an intentional baseline witness.

Complete transport results: rustls 152 unit + 5 integration + 2 doc tests;
BoringSSL 160 unit + 5 integration + 2 doc tests, all passing. Transport Clippy
with all targets, BoringSSL and denied warnings passes. The production embedded
FFI SDK builds successfully. These scoped green checks do NOT erase the eight
previously documented session-Clippy findings or prove full workspace CI.
Private cache logs: `socks-admission-before.log`,
`socks-admission-rustls-full.log`, `socks-admission-boring-full.log`,
`socks-admission-clippy.log`, `socks-admission-sdk.log`.

Receiver analysis of the preserved `pcm-bg-ctrl-360` narrows the next action.
Before the 269.700-ms PCM edge at second 110, both paths have their maximum
flight delay around second 106.85–106.89 (154/181 ms). The receiver gauges then
fall to 4/20 ms around second 107; concealed samples increase, followed by
140/200-ms requested buffer targets and 188/234-ms current buffers. By seconds
116–117 current buffers recover to roughly 104/107 ms. This is consistent with
receiver recovery after a transport burst; the later worst edge's short flight
does not establish an isolated receiver bug. Adaptive Opus packet durations
also change through this interval, but their causal contribution is unproven.
There is no justification yet for reducing capacity or forcing 20-ms packets.
The source's video padding increases by only seven packets (1,785 bytes) during
one upgrade in this interval: that observation alone cannot explain the whole
stall. Follow-up must isolate the original flight burst and recovery, and
separately verify whether below-ceiling video pauses are justified growth.

## 2026-10-15: pace this node's own DHT publications

Previous goal turn made authoritative progress in SDK `e5b108de` and xVeil
`ab565a7f`: group source admission and native fresh-snapshot revisions. Full
constrained quality is still unproven. No playout capacity, codec duration,
RTCP or acceptance threshold is changed in this cycle.

Further analysis of `pcm-process-fifo-adaptive-stress-360` finds both directions'
150–185-second flight maxima at seconds 176.156/176.159 (134.658/156.483 ms).
The three nodes queued identity publications around second 175.955. Receiver
target increases already began around second 175, so correlation with publication
does NOT establish a complete causal explanation. Source input, flight and
rendered PCM remain separately attributed; the worst later edge has only
25.394-ms flight and a 225.614-ms post-WebRTC residual.

Code inspection finds a concrete independent burst source:
`identity_local/publisher_dht.rs::replicate_dht_value` synchronously offered
every full background STORE copy to peer outboxes, outside own DATA admission.
It also appended ALL live sessions after the K closest candidates, exceeding
the documented replication factor. Own routing/recovery RPCs already have a
different allowance; this maintenance publication path did not use it.

SDK `410c1516`: `SessionTxRegistry` now owns one bounded publication worker shared across all
neighbors and publisher instances. Only explicitly authored, best-effort
background records use it. It emits at 8,192 bytes/second of encoded DHT frame
data (not a wire-byte promise), charging from actual emission rather than
planned deadlines. Executor pauses cannot accumulate catch-up credit. Pending
work has 64-frame/512-KiB payload bounds and a 60-second age limit. Admission
overflow and expiry increment the existing drop counter. Failed destinations
do not spend another neighbor's byte allowance. A weak registry reference and
an owned abort handle prevent the worker from retaining the node; a captured
node runtime also supports synchronous maintenance/FFI callers on plain threads.
Local DHT storage and queue admission remain synchronous; remote copies are
best-effort and may be rejected/expire, as outbox failures were before.

This pacing is identical at idle nodes and nodes making calls. It does not
inspect traffic, alter wire classes, prioritize a remote user or change transit
service. The original BACKGROUND frame remains byte-for-byte the same. Live
replication candidates prefer reachable closest peers, then live bootstrap
fallbacks, with an actual maximum of `DHT_REPLICATION_K=8`.

Eight deterministic paused-clock tests verify shared pacing, exact frame bytes,
unaffected ordinary sends, no catch-up burst, frame/byte bounds, expiration,
drop metrics, disconnected destinations, plain-thread publication and task
teardown. The complete session suite passes 554 tests (8 existing ignored).
Publisher tests pass all seven cases, including cold routing-table fallback and
fanout with more than eight connected peers. The complete node-runtime suite
passed 657 tests (11 ignored); its original single-retry fixture incorrectly
offered 32 frames without consuming a four-credit ingress. That fixture now
asserts backpressure, drains before retrying admission and retains every one
of its 32 wire/E2E/order/primary/transit checks. Production retry logic is
unchanged. The production embedded SDK was rebuilt after the final changes.

Clippy with denied warnings reports eight existing sites in untouched session
files (`priority_queue`, `ordered_lanes`, `runner`, `parallel_lanes`,
`reliable_streams`); it is NOT a green gate. Do not claim CI/release readiness.
Private logs under the existing cache: `local-replication-pacing-qualified.log`,
`local-replication-session-qualified.log`, `local-replication-publisher-qualified.log`,
`local-replication-runtime-qualified.log`, `local-replication-clippy.log` and
`local-replication-sdk-qualified.log`.

Full quality comparison: `pcm-bg-paced-360`, using
stock adaptive 20–60-ms media, the actual Dart policy, independent obfs4 source
connections, isolated neutral aggregate 1,024-kbit/s FIFO, two 512-KiB files,
native timing, full PCM capture, source clock, moving-image and cleanup gates.
This control must finish and be analyzed before attributing quality gains to
the publication change. Running relays and handset/GUI applications have not
been modified or started by these checks.

The initial, longer-named `pcm-paced-publications-adaptive-stress-360` failed
BEFORE measurement: its admin socket path was 104 bytes, exceeding Darwin's
103-byte pathname limit (the 104-byte field needs a NUL terminator). Runtime tasks exited,
all node stops returned zero, and the independent shaper exited. Three stale
IPC socket files remained; after the process exited, lsof confirmed no open
descriptors and they were removed. Original evidence/summary is preserved,
with a separate `cleanup.json`. This is not a quality result or evidence of a
publication-policy failure. The shorter fixture above is a separate run, not
a restart after an observation timeout. The harness now checks actual encoded
socket-path lengths before creating an explicit stand directory; Darwin/Linux
boundary and multibyte-path tests pass. Default `/private/tmp/` fixtures remain
short. This does not claim to repair production IPC startup error reporting.

The shorter `pcm-bg-paced-360` completed. Full capture and all 704 tone edges
are attributed, with no quiet PCM, missing transitions or audio interruptions.
The source clock passes at 22.410 ms. Audio-only PCM peaks at 130.830/150.118 ms;
mixed-phase peaks at 190.156/172.026 ms (p95 171.172/169.872 ms), below the
unchanged 200-ms gate. Current native buffer maxima are 150/153 ms. Both files
are exact (248.5/245.8 seconds), all source feedback is queued, runtime drop
counter deltas are zero, node stops succeed and no sockets remain. Images move
at the end, but protective pauses still occupy 24 one-second samples in one
direction and sampled image gaps reach 13/2 seconds. Audio improvement in this
capture is not proof that publications were the sole cause of earlier tails.

The combined result is nevertheless FALSE: receiver counts are 90/93, versus
89/93 sent plus one bootstrap per side. The final side-0 control was submitted
at second 359.002, AFTER the last compact receive poll at second 359; the old
stand never polled again. It consumed compact control only with 1-Hz stats,
whereas `VeilCallMediaController._startControlPolling` uses a separate 100-ms
timer. The stand now follows that 100-ms cadence and drains once at the end;
the complete-control gate is unchanged. Bounded metadata records source nonce
and local receipt time, without plaintext or peer identifiers. The original
failed summary is preserved; do not edit its result to green retroactively.

`bg-control-tail-22` is a scoped real-SDK/crypto control check, not mixed-video
qualification: one ordinary report per second, urgent schedule disabled, no
video/files, default 1,000-ms tones. All 22 reports per side arrive, including
nonce 22 submitted at second 21.003 and consumed at 21.100. Both bootstraps are
present (23/23 total), the scoped result passes, all nodes stop and no sockets
remain. The full unchanged 1,010-ms tone/video/file comparison with accurate
control polling is `pcm-bg-ctrl-360`; evaluate that completed capture separately.

The completed `pcm-bg-ctrl-360` rejects any claim of stable audio qualification.
All 88/96 ordinary controls arrive at the opposite sides, exactly once by
source nonce, plus each bootstrap; bounded metadata is not truncated. Final
reports sent at second 355.004 are consumed at 355.101. Both 512-KiB files are
exact, without duplicate chunks (218.8/199.0 seconds). The independent native
clock passes at a 17.390-ms maximum interval; all 704 expected tone edges are
attributed, with no quiet PCM or reported interruptions. However mixed-phase
PCM peaks are 221.641/269.700 ms, failing the unchanged 200-ms gate; p95 is
171.933/180.986 ms. Native current-buffer maxima are 188/234 ms. Video is moving
at the end, but sampled image gaps reach 13/20 seconds and protective pause
samples total 31/12. The aggregate combined result remains FALSE.

The worst edge (source 0, input second 110.093) has 39.681-ms capture/encoding,
17.843-ms SDK-to-ingress flight, and 212.105-ms post-WebRTC residual. Neighboring
edges have the same elevated residual; this is not solely a network-flight
peak. That residual includes receiver buffering, codec/FEC dependencies and
rendering, and must not be called NetEq delay alone. Across all packets, flight
maxima remain 181.446/154.173 ms. The blind shaper trace independently records
up to 293.284/70.866-ms reader-arrival-to-read spans; opaque chunks are not RTP
packets, so this does not assign those spans to the worst audio edge. It is
unsafe to infer that DHT pacing solved the complete quality problem from the
preceding single passing audio capture.

All node stops return zero, the isolated shaper and audio/file/policy workers
exit, and no fixture sockets remain. Blackview `BV6600Pro` is available over
ADB; no physical app/call was started in this cycle. Public relays and installed
applications are unchanged. Next work must separate receiver recovery and
false-positive video growth from remaining flight stalls using the retained
trace, without relaxing gates or adding relay traffic recognition.

## 2026-10-15: group source admission and fresh playout revisions

Previous goal turn made progress in `5acafe82`: the blind FIFO is independent
of the codec driver's GIL. Its full 360-second adaptive control still fails at
260.954/240.927-ms PCM peaks and 22/16-second sampled video gaps. Those quality
failures remain open; this cycle does not qualify them away.

`GroupMediaChannelTransport` now forwards the same local source-feedback API
as ordinary calls. `VeilGroupCallMediaController` runs `CallAudioSourcePressure`
before its video-only branch, so audio-only rooms also constrain competing own
DATA/file admission. Any known listener at the buffer ceiling establishes
pressure even with other reports absent. Recovery requires native fresh report
coverage for the entire intended fanout and current audio for every expected
incoming source. A muted microphone does not exempt incoming audio; no active
audio source means no lease renewal. Older listeners without optional playout
reports cannot prove source headroom, while unsupported local IPC simply
rejects the report and preserves the existing transport fallback.

Roster changes, channel invalidation and microphone changes reset earned
headroom. Missing/pending channels cannot borrow the prior roster's recovery.
One report may be in flight across stop/restart, retaining its ORIGINAL
sampling time. Completion from another media epoch cannot update the new
call's diagnostics, even if a test reuses the same engine object. Rejections,
synchronous exceptions and asynchronous IPC failures do not break the stats
timer or audio. Stop ceases reporting; the existing 1,500-ms SDK lease expires
naturally. No relay priority, traffic class, media metadata or new network
message is introduced. The application's shared call slot prevents ordinary
and group calls from independently clearing one bound media app's lease.

SDK `e5b108de` adds native group JSON `audio_playout_sequence`: a local monotonic revision
of accepted remote playout snapshots, support/freshness transitions and roster
size. Polling cached RTCP and replaying an old report leave it unchanged. New
reports, unknown samples and expiry update it. Both group source admission and
the video adapter consume this revision rather than filling a growth window
with repeated polls. Older native libraries without it retain ceiling
protection but do not manufacture a below-ceiling remote growth trend.
The encrypted RTCP format, negotiated codecs and C ABI exports are unchanged.

The pre-edit group suite was rechecked at `5acafe82`: eight existing tests
failed there too. Several expected the superseded rule that gaps, interruptions
or missing reports directly cut video. Those cases now assert holding an earned
rung for unknown/non-growing measurements, and inject an ACTUAL buffer ceiling
where they test overload/mute/peer isolation and recovery. The PCM stress gates
are unchanged. This also exposed and fixed a real legacy-library fanout gap:
adding an audio participant previously reset video's earned budget only with
native receive-age support; the reset now happens before adding that fanout
with either library capability.

The focused Flutter suite passes 151 tests (group controller, source pressure,
receive activity and bitrate adapter). Static analysis of the two edited root
files has no issues. New controls cover audio-only reporting, all-peer recovery,
local/remote mute, roster changes, stale completed epochs, bounded pending IPC,
rejected/throwing IPC, malformed counts, cached-report video stability and six
fresh growing source observations. The native call-plane smoke also passes:
actual WebRTC/Opus, independent audio/video workers, replay/expiry/revision
checks, sparse video encoding, group fanout and teardown. It uses a MOCK Veil
boundary, not a shaped group/file network or physical handset.

Use `TMPDIR=/private/tmp/ WEBRTC_OUT=out/mac-arm64-call-adaptive bash
third_party/veil/flutter/veil_media/test/run_call_planes_smoke.sh`. The first
attempt with the build script's older default `out/mac-arm64` correctly refused
its protobuf-disabled cache; the explicit adaptive cache built and passed.
Private logs: `group-source-baseline-tests.log`, `group-source-admission-red.log`,
`group-source-admission-qualified.log`, `group-source-admission-analyze-qualified.log`
and `group-source-native-planes-adaptive.log` under the existing private cache.

Still required: full group/native SDK file-contention qualification, optional
group target-delay telemetry, SOCKS gate coverage, constrained-network receiver
tail diagnosis and physical application checks. No release, remote branch,
running relay or phone profile was changed by these headless controls.

## 2026-10-15: isolate the blind FIFO runtime

Previous goal turn made authoritative progress in SDK `673a76fd` and xVeil
`5c029f1f`/`477a047d`: real Darwin write accumulation is fixed, but complete
audio/video quality still fails. Repeating fixed-20-ms audio with that SDK
was rejected; do not restore that candidate merely because transport changed.

The previous capture has unexplained same-process Python shaper release stalls
up to 109 ms. An independent real-socket witness now proves a fixture coupling:
holding the codec/test runtime's GIL for 0.9 seconds delays traffic through the
thread-based FIFO by about 795 ms. Moving the identical FIFO to a child process
reduces that witness delay below one millisecond. Both the timed sender and its echo
endpoint live in another process, so the witness itself does not share the
blocked GIL. This proves the coupling, not that GC caused an earlier burst or
that the application has no transport backlog.

`ProcessTcpShaper` uses the existing `TcpShaper` without changing reservations,
the aggregate rate, socket bounds, byte order or connection treatment. A
private inherited pipe carries only setup/rate/snapshot/stop, never media.
The codec harness opts in with `--shaper-process` and records distinct worker/
codec PIDs. The worker exits on stop or pipe EOF; a control deadline fails
the fixture and cleans up, without restarting it or accepting an older result.
Snapshots are retrieved after stopping production; stop failure no longer
skips SDK node cleanup. The original thread mode remains available explicitly.
The shaper analyzer now labels the clocks same-host, rather than same-process.

All fourteen socket/arrival/lifecycle tests pass: both implementations share
capacity across competing connections, honor per-target grouping, transfer
all bytes, deliver EOF and close idle connections. Eight stage-analysis tests
pass, including independent-process metadata and shared monotonic origin.
Private evidence: `process-shaper-tests-final.log`. A killed-worker regression
reports failure, observes the child terminal, joins its response reader and
closes both control handles rather than reporting a successful stop.

The full comparison is `pcm-process-fifo-adaptive-stress-360`, using unchanged
production SDK/media binaries, adaptive 20–60-ms Opus, actual Dart policy,
independent obfs4 channels, a neutral aggregate 1,024-kbit/s FIFO and two
512-KiB files. It adds `--shaper-process --gc-timing-trace` to the previous
command; capture, source-clock, PCM, image, file and cleanup gates are unchanged.
No phone/GUI app, running relay, release or remote branch is changed here.

The isolated full capture still fails quality. Both directions cover the full
360 seconds, all 704 expected tone edges are attributed, the source clock
passes at 36.150 ms, and there are no missing transitions, quiet PCM samples or
reported audio interruptions. Mixed-phase PCM peaks at 260.954/240.927 ms
(p95 181.045/190.293 ms), native delay at 225/206 ms, and sampled video gaps at
22/16 seconds. Files pass byte-for-byte (256.0/247.1 seconds), control reports
arrive completely, decoded images move at the end, every worker exits, node
stops return zero and no fixture sockets remain. Distinct actual codec/shaper
PIDs are recorded; the child exits successfully. The PCM/source/video/file
acceptance gates were not relaxed.

At the largest edge (second 177.768, 60-ms packet, source input at position
40 ms), capture-to-encode is 9.912 ms, SDK-to-ingress 25.394 ms and the
post-WebRTC residual 225.614 ms. It includes lookahead/playout/rendering.
All-packet mixed-phase SDK-to-ingress maxima are still 140.911/156.483 ms;
do not claim transport has no bursts from a prompt containing packet. The
blind FIFO's maximum ready-to-write spans are now 31.039/31.207 ms, while
reader-arrival-to-read reaches 405.162/84.230 ms on opaque chunks of unknown
role. These maxima are not matched audio packets. The driver records forty
GC events, maximum 2.579 ms; GC in this run does not explain the quality tail.
Process isolation fixes a proven fixture coupling, not the whole product.

Prioritize the concrete group source-admission gap below and continue receiver
playout attribution with the isolated FIFO. Do not disable RTCP, raise audio
quality gates, classify relay payloads or globally force a rejected duration.

Read-only follow-up: `VeilGroupCallMediaController._pollStats` adjusts the group
video adapter but never calls `reportLocalSourcePressure`; the group channel
transport interface has no corresponding method. Only the one-to-one controller
reports `CallAudioSourcePressure` to the SDK. Thus group audio's feedback does
not constrain this endpoint's competing file/DATA admission as a normal call
does. This is a concrete remaining product gap, in addition to optional group
target telemetry. Implement and verify it before claiming all call types are
covered. This control's passing one-to-one source report counts cannot prove
group source admission.

## 2026-10-15: Darwin TCP write readiness

Previous goal turn: progress in `f9c8af2c` (separate authenticated requested
buffer telemetry and endpoint admission), with the complete quality goal still
unproven. The current cycle addresses kernel send accumulation, preserving
video cuts only on measured buffer growth/ceiling and neutral relay service.

Two real-kernel regressions initially failed on macOS. The SDK configured no
Darwin unsent threshold; the stalled-reader test retained 64,800 socket bytes
after local ACK settlement. Enabling Darwin `TCP_NOTSENT_LOWAT=4096` alone
made the option test pass but left the same 64,800-byte backlog. This is a
readiness threshold, not a hard queue cap; Tokio can keep using its cached
writable flag without asking the kernel about the smaller threshold.

A generic write gate (SDK `673a76fd`) now rechecks OS writability with nonblocking poll, clears
only obsolete readiness, and limits one new input write to 4096 bytes. Plain
TCP, obfs4, rustls/BoringSSL TLS, WS/WSS and boxed HTTPS paths use it. Public
TLS stream aliases/handshake return types remain unchanged. A separate duplicated
socket descriptor owns the writable registration so TLS's read-side protocol
flushes cannot steal the writer's wakeup. It is a descriptor for the existing
connection, not another authenticated endpoint or connection-budget slot. Both
descriptors close with the stream. Registration failure falls back to existing
I/O; already admitted framing still flushes and graceful shutdown does not wait
for a new admission. Other platforms delegate their existing I/O unchanged.
No payload class, wire priority, media role, new packet ACK or relay privilege
is introduced. The implementation is shared by all TCP traffic in these paths.

The same stalled-reader control now settles at 4,800 socket bytes. It includes
in-flight data: this is not an exact unsent counter or a universal remote-link
bound. After reading resumes, every accepted byte arrives in order. A separate
128-KiB scalar/128-KiB vectored control verifies partial writes and exact data,
including EOF after dropping the duplicated readiness registration.

All 150 transport unit tests passed. Clippy with warnings denied passed after
moving an existing export before its test module and removing an existing
identity conversion in a fixture. Both production SDK build and optional
`tls-boring` check passed. The non-Apple pass-through compiled in an offline
ARM64 Linux container; its first setup attempt lacked the workspace's configured
clang, so the successful check explicitly used the image's GCC/cc. The owned
container exited and was removed. No server was updated.

Private logs are under `~/.cache/codex/xveil-physical-20261014/`:
`darwin-backpressure-red.log`, `darwin-lowat-only.log`,
`darwin-fresh-write-gate.log`, `darwin-gated-transport-final.log`,
`darwin-gate-clippy.log`, `darwin-gate-boring-check.log`, and
`darwin-gate-linux-check.log`. The complete quality comparison uses
`pcm-darwin-gated-stress-360`, stock adaptive Opus 20–60 ms, actual Dart policy,
a neutral aggregate 1,024-kbit/s obfs4 FIFO and two 512-KiB files. Capture,
source-clock, PCM, decoded-image, exact-file and cleanup gates remain unchanged.

That 360-second capture is complete and still fails the unchanged quality gate.
The source clock now passes at 25.440 ms, with no dropped observations, callback
errors, quiet PCM frames, missing transitions or reported audio interruptions.
All 704 expected tone edges are exactly attributed. Mixed-phase PCM maxima are
213.452/201.736 ms (p95 190.557/190.820 ms); native delay peaks at 181/171 ms.
The largest edge at second 141.407 has 32.678 ms capture-to-encode, 16.112 ms
SDK-to-ingress and 164.598 ms from WebRTC submission to the rendered transition.
The latter includes lookahead/playout/rendering, not a NetEq-only measurement.
Both 512-KiB files arrive exactly (190.2/201.4 seconds), and decoded images move
through the end. However one direction has twelve protective-pause samples
and a 13-second sampled video gap; the other has about two-second gaps. This
transport correction is not a complete audio/video quality fix.

Independent blind-shaper timing reports up to 99.494/263.403 ms waiting for a
reader turn, followed by up to 45.318/55.231 ms reservation delay. These opaque
chunk maxima are not matched audio packets. They cannot be added to the tone
edge spans or used to claim a media-specific relay scheduling defect. All
three nodes stopped successfully, every fixture worker exited, and no fixture
sockets remain. No GUI or phone app was opened in this cycle. The connected
replacement remains Blackview BV6600Pro, not the earlier Poco.

The next isolated comparison combines this SDK with the existing fixed-20-ms
candidate library (`media-opus-duration20/libveil_media.dylib`) in
`pcm-darwin-gated-duration20-stress-360`. No packet-duration source change is
accepted on the strength of the previous, ungated test. Current production
media remains adaptive 20–60 ms. SOCKS proxy return paths have not yet been
wrapped by this gate; group target propagation and physical application
qualification likewise remain open.

The fixed-20-ms comparison has now finished and is rejected again. Source
coverage is complete, the source clock passes at 39.390 ms, and all 704 expected
tone edges are attributed with no missing transitions, quiet PCM or reported
audio interruptions. However mixed-phase PCM peaks at 311.437/320.861 ms
(p95 201.844/219.084 ms), native buffer delay at 281/288 ms, and sampled video
gaps reach 21 seconds in both directions. Protective pauses occupy 39/32
one-second samples. Both files are exact (210.4/228.4 seconds), endpoint control
arrives completely, every fixture worker exits, all three node stops return
zero, and no fixture sockets remain. Production media source was never changed
for this comparison; it used the already isolated candidate dylib.

At the largest edge (second 233.311), capture-to-encode is 11.545 ms,
SDK-to-ingress 11.332 ms and the post-WebRTC residual 297.937 ms. Across the
whole mixed phase, packet SDK-to-ingress maxima are nevertheless
236.114/231.681 ms. This is consistent with a receiver retaining delay after an
earlier delivery burst, not proof that packet transport is always prompt. The
same-process Python blind shaper records up to 109.621/109.408 ms between a
reservation becoming ready and its actual write. The capture has no GC timing
trace, so the cause of those scheduling stalls is unknown. Future work must
separate fixture-process stalls from product transport accumulation; it cannot
attribute them to relays or call the receiver residual NetEq alone. Keep the
unchanged full quality gates. Neither duration experiment qualifies the goal.

## 2026-10-15: requested-buffer telemetry and endpoint admission

The previous goal turn made authoritative progress in `b0786510`: complete
capture qualification and two packet-duration counterexamples. Both duration
experiments were rejected; the SDK remains `20d9d301` with adaptive 20–60-ms
Opus and no change to native playout or relay scheduling.

The next endpoint candidate transmits the receiver's requested jitter-buffer
target as optional encrypted JSON `ap.td`, distinct from actual/peak delay
`d`/`cd`. Unknown fields remain compatible with older peers. The target is
validated, expires with the actual sample, is cleared on unknown snapshots and
repairs, and cannot be refreshed by replay. A native target requires accepted
audio, a responsive worker and a receive age no greater than three seconds.
It cannot qualify absent/stale audio as healthy or turn a target into measured
mouth-to-ear delay.

The user requires video cuts only for measured buffer growth or its ceiling.
An initial candidate using the requested target as another cut trigger was
withdrawn before evaluation. Its partial `pcm-target-buffer-stress-360` fixture
was interrupted and cleaned up: all three node stops returned zero, workers
joined, no fixture sockets remained. It is not a quality result.

The revised candidate uses the target only to withhold VIDEO GROWTH and limit
competing own reliable DATA. Existing video reduction and sparse-floor pause/
recovery continue using actual receiver-buffer measurements. A target at
200 ms can expedite one existing encrypted report per second; targets below
the 160-ms recovery rail permit gradual producer growth again. The requested
target and current delay have separate fields and neither overwrites the other.
No priority, media role, mailbox operation or service privilege reaches relays.
The one-to-one controller and the codec stand consume the same measurements.
Fixed-size native group APP feedback does not yet carry the optional target;
group target propagation remains a separate completion item, not a claimed fix.

The focused suite passed 134 tests, including separate current/target values,
expiry, replay, missing/stalled receivers, legacy reports, urgent feedback,
reliable-source admission and the invariant that a target alone cannot cut
video. Static analysis of all eight affected runtime/stand files found no
issues. The native media library was rebuilt unchanged into
`media-buffer-target/` before measurements. Evidence beneath
`~/.cache/codex/xveil-physical-20261014/pcm-target-admission-stress-360` uses real
Opus/VP8, the actual Dart policy, authenticated feedback, separate obfs4 media/
control/file connections, a neutral aggregate 1,024-kbit/s FIFO and simultaneous
512-KiB files. Full capture, PCM <200 ms, source clock <40 ms, moving decoded
images, exact files and shutdown gates are retained.

A read-only transport follow-up found that `veil-transport/src/tcp.rs` applies
its 4096-byte unsent readiness threshold only on Linux/Android, though the local
Darwin SDK declares `TCP_NOTSENT_LOWAT` (0x201). Apple's
[tcp option handling](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_usrreq.c)
and [readiness check](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_subr.c)
confirm an unsent-data readiness mechanism. This is not a hard byte cap and is
not proof of the measured backlog's cause. No socket configuration was changed
in this candidate. A platform-specific blocked-writer experiment is needed
before attempting a Darwin port or attributing quality gains to it.

The 360-second admission candidate does not meet quality acceptance. Coverage
is complete in both directions and all 704 expected tone edges are exactly
attributed, with no missing transitions or quiet PCM samples. Both files pass
byte-for-byte (281.6/307.6 seconds), decoded images move through the end with
approximately two-second maximum sampled gaps, and no protective video pause
occurs. Nonetheless mixed-phase PCM peaks at 348.235/327.663 ms (p95
210.459/201.029 ms), and native delay reaches 208 ms.

The independent source clock also fails at 155.510 ms near second 239.589 and
113.600 ms near second 241.054. Its measured maximum wake lateness is
148.948 ms while the native callback peaks at only 2.271 ms. The independent
Python shaper records approximately 147-ms late releases too. This locates
these outliers in scheduling of threads in the same process, not a demonstrated
155-ms codec callback. It does not identify the scheduling cause or prove a
host-wide pause. Even BEFORE second 230, exactly joined mixed-phase PCM peaks
at 211.783/242.321 ms, so excluding the clock event cannot qualify the run.
The largest unaffected edge retains a substantial post-WebRTC span. No timing
or PCM gate was weakened, and no complete-quality claim follows from this run.

`target-telemetry-audio-22` separately verifies both peers actually receiving
optional targets 40/60 ms over the authenticated encrypted path; the explicit
`requested_buffer_telemetry_verified` diagnostic is true. This short wire test
is not a full quality pass: its 1010-ms source has insufficient post-second-20
capture-position coverage for all observed packet durations, so the overall
fixture correctly fails that separate gate. It is not a replacement for the
long stress case. Both this fixture and the long run joined their workers,
stopped all three nodes with result zero and left no sockets.

The retained endpoint feature makes requested targets available independently
of measured delay and prevents increasing competing producers into a requested
buffer ceiling. Its focused behavioral/compatibility tests pass, but the full
goal remains open: complete constrained-network quality, source scheduling
qualification, generic transport backpressure/pacing, group target propagation,
and physical application checks are not established by these captures.
No phone/GUI app, running relay, release or remote branch was changed.

## 2026-10-15: adaptive packet-duration follow-up

The previous cycle made authoritative progress (`20d9d301` SDK, `5c00cc69`
superproject): reordered-cell handling, config persistence and real unshaped
anonymous codecs/files were verified. This follow-up retains the full audio
priority goal, including the unresolved constrained-network PCM tail.

The older `pcm-floor-probe-stress-360/pipeline.json` attributes all 704 expected
tone edges, with no unattributed edges. Its largest edge, 214.488 ms, consists of
24.522 ms capture-to-encode, 17.409 ms SDK-to-ingress and 172.449 ms from WebRTC
submission to the rendered tone transition (plus negligible other stages).
That residual can include following-packet/FEC lookahead and rendering as well
as jitter buffering; it is not a direct NetEq-only measurement. The largest
edge occurred on a 40-ms packet while the stream also used 60-ms packets.
The nearest receiver snapshots show a 60→40→20→40-ms transition around
seconds 131–139 and a 120–140-ms jitter-buffer target. Mixed-phase edge maxima
by containing packet were 206.500 ms (20 ms), 214.488 ms (40 ms), and 213.599 ms
(60 ms). These are observations of one adaptive stream, not isolated experiments
at each fixed duration; they cannot establish causation or prove a smaller cap
sufficient without rerunning the full workload.

A candidate limits negotiated adaptive Opus sends to 20–40 ms rather than
20–60 ms. The wrapper continues to honor the encoder's supported range and
retain a 16–32-kbit/s payload target. Fixed-packetization anonymous audio and
relay scheduling are unchanged. The real Opus/ANA smoke passed the existing
20-, 40- and 60-ms negotiated-range cases. The engine and current production
SDK were rebuilt before starting PCM measurements.

The codec harness now records its requested shaping rate and media-library
SHA-256, complementing its SDK hash. Earlier artifacts omitted those fields.
The older shaper's first unqueued reservation independently establishes the
same 1,024,000-bit/s aggregate rate (383 bytes / 2.9921875 ms). The candidate
uses real codecs, the Dart adapter, encrypted endpoint feedback, independent
obfs4 connections and simultaneous 512-KiB file transfers in both directions.
The blind FIFO treats connections equally; it does not inspect media roles.

The first `pcm-duration40-stress-360` capture cannot qualify the candidate:
the native helper was built before setup but first loaded only after the
workload origin. Host library validation delayed capture and polling by
42.601 seconds. There were no observations in the audio-only phase, despite
the old row-count gate passing. Both files completed and all nodes stopped,
but startup quiet frames, missing transitions and later PCM peaks failed the
quality gate. Exact post-second-50 attribution still contains a 273.627-ms
edge (40-ms packet, 40.878-ms SDK-to-ingress, 232.606-ms post-WebRTC residual),
so this is not evidence that forty milliseconds solved the tail either.

The helper is now explicitly loaded before the workload origin. A pure coverage
gate requires both directions to begin within 100 ms and reach the final 100 ms;
both audio-only and competing phases must contain matched tone transitions.
Four timing unit tests passed, including the delayed-load counterexample, and
the new gate rejects the actual incomplete capture. Setup also waits for the
initial authenticated bootstrap feedback before starting the timed workload.
The corrected long capture is `pcm-duration40-preloaded-stress-360`.

That corrected 40-ms capture covers 0.0003–359.989 seconds in both directions;
all 704 expected edges are exactly attributed. It still fails: mixed-phase
peak PCM delay is 250.159/211.081 ms (p95 172.043/161.337 ms). The largest edge
at second 140.392 has only 28.878 ms SDK-to-ingress but 220.923 ms after WebRTC
submission. The independent source clock also fails its separate gate at
44.900 ms around second 52.946, far from this largest delay. No quiet PCM
frames, reported interruptions or protective video pauses occurred, decoded
images kept changing, and both files completed exactly (195.5/185.8 seconds).
Thus a 40-ms cap is insufficient, despite improved p95; it is not accepted as
an audio-quality fix. All nodes stopped with no remaining fixture sockets.
The next isolated candidate keeps packet length at 20 ms while retaining
bitrate adaptation; it changes no playout or video-protection threshold.
The 20-ms candidate library is `media-opus-duration20/libveil_media.dylib`,
with evidence in `pcm-duration20-preloaded-stress-360`. Its command uses the
current debug SDK plus `--transport obfs4-tcp --rate-kbps 1024 --duration 360
--adaptive-audio --compact-media --compact-call-health --local-source-feedback
--compete-file --native-timing-trace --native-trace-capacity 24000
--tone-period-ms 1010 --shaper-trace`, always with `TMPDIR=/private/tmp/`.

The fixed-20-ms candidate also fails, despite complete capture and a passing
source-clock maximum of 32.870 ms. Audio-only PCM peaks at 63.327/63.412 ms;
under competing video/files the peaks become 271.423/858.842 ms (p95
231.916/258.703 ms). All 704 expected edges are exactly attributed. The largest
edge at second 76.765 contains 9.335 ms capture-to-encode, 658.529 ms
SDK-to-ingress and 190.928 ms from WebRTC submission to rendered output.
Both files complete exactly (271.8/287.5 seconds), and video still changes near
the end, but sampled video gaps reach 20/42 seconds and protective pauses occur.
No quality gates were relaxed. Both packet-duration candidates were rejected
and the production engine was restored byte-for-byte to `20d9d301`.

The next frontier is transport accumulation under contention, not merely Opus
packet collection. In seconds 70–78, blind shaper direction 1 records up to
494.345 ms from byte arrival in its reader to read, plus up to 65.061 ms
reservation delay; reader-arrival-to-write reaches 528.916 ms. Those opaque
chunks cannot be attributed to a particular media packet without correlation.
The RTP join independently proves the audio's 658.529-ms pre-ingress delay.
See `pipeline.json`, `shaper-timing.json` and `shaper-peak-window.json` in the
20-ms artifact directory. Source-side padding counters stay at 7/8 packets,
so an ongoing native audio padding flood is not supported by these counters.

There is also an early signal to investigate: side 1's native requested jitter
buffer target jumps to 220 ms at second 70 and 300 ms at second 71, while its
reported current delay remains 25/90 ms. The current-delay trigger reduces
video later. Distinguish the requested target from measured current/PCM delay;
do not silently relabel one as the other or permit relay media priorities.
Investigate endpoint pacing/backpressure and whether authenticated target-buffer
telemetry can warn senders before the receive queue fills.

All three optional codec captures stopped their three nodes with result zero,
joined their workers, and left no fixture sockets. No phone or GUI application
was launched. The only retained edits in this cycle are the measurement/setup
fixes, their coverage tests, and this handoff. No release, push or relay update
was performed.

## 2026-10-15: sustained pressure, reordered cells and relay allowance

SDK commit: `20d9d301` (local, unsigned, not pushed).

Three further causes were reproduced without phones or speech:

1. Under a continuous endpoint pressure report, eight private send/receive
   circuits queued a padded probe every two seconds, exceeding the existing
   maintenance allowance. Probe admission is now coalesced: skip checks while
   an echo is under two seconds old and allow six seconds between admitted
   checks. A rejected admission can retry on the normal worker tick. The
   twelve-second stale threshold and byte allowances are unchanged.
2. Coalescing alone was insufficient. A 36-second isolated control passed, but
   the combined suite and a 72-second control still replaced healthy circuits.
   Debug logs identified `anonymity.circuit.replay_fwd_dropped` for delayed
   reliable checks: independent fresh datagrams overtook them by more than the
   shared 64-cell replay window. The old window treated unseen packets as too
   old. A regression admitting sequence 2 after 128 newer cells failed before
   the fix. The shared window now holds 8192 cells in a circular bitmap, clearing
   only expired slots rather than shifting the whole bitmap for each packet.
   Duplicates, zero, and out-of-window cells remain rejected; reference-set
   tests cover word boundaries, multiple wraps, large jumps and `u32::MAX`.
   State is bounded at a 1-KiB bitmap per direction. This is uniform replay
   handling: no relay media recognition, scheduling priority, wire format,
   nonce or per-user service privilege changed. Relays must also receive the
   updated library to tolerate the larger reordering distance; old relays still
   enforce 64 cells. No running relay was updated in this cycle.
3. `DhtConfig::is_default` omitted `service_budget_bytes_per_hour`. If that
   allowance was the only changed DHT field, whole-config serialization omitted
   `[dht]`, including an explicit zero. New saves and existing-file patches were
   affected. The fixture's intended large allowance was lost: all four nodes
   actually used the Leaf default of 8 MiB/hour. Media exhausted its burst; new
   file circuit builds were declined at the middle relay while existing media
   correctly continued. The prior zero-byte captures were not proof of broken
   file routing or successful isolation under competing file traffic.

The DHT predicate now preserves an explicit allowance. A regression checks zero,
1 MiB/hour and the largest TOML integer through serialization, new-file saves
and existing-file updates. All 234 `veil-cfg` tests passed with
`test-low-difficulty`; the production-difficulty full run was stopped while two
unrelated PoW searches were running. The direct serialization regression also
passed without that feature. All 334 anonymity tests passed (one ignored), as did all 33 dispatcher
anonymity tests. Production `cargo check` and formatting checks passed.

The stand now uses an explicit, TOML-representable 1-TiB/hour allowance on every
node and verifies its actual runtime value immediately after startup. Both
512-KiB files passed byte-for-byte in the real-obfs4 active-primary fixture;
the same workload previously timed out with zero bytes. The native codec stand
also requires nonzero file progress during media before claiming competing
file load. It still has no network shaper or application Dart adapter.

Private logs share `~/.cache/codex/xveil-physical-20261014/`:
`service-allowance-config-red.log`, `service-allowance-config-fixed.log`,
`service-allowance-cfg-suite-low-difficulty.log`,
`pressured-private-routes-red.log`, `pressured-private-routes-coalesced-72.log`,
`pressured-private-routes-replay-debug.log`, `circuit-reordering-suite.log`, and
`primary-bidirectional-files-fixed.log` preserve the controls and counterexamples.
The replacement Android device is Blackview BV6600Pro (Android 11), available
through ADB; read-only checks did not launch its application.

With the larger replay window, the 72-second sustained-pressure control passed:
3600/3600 primary packets per direction used private circuits, all four route
identities stayed unchanged, no primary/camera/screen fallback attempts occurred,
and the debug log contained no replay-window drops. The five control fallback
attempts per endpoint are bootstrap traffic predating route readiness. See
`pressured-private-routes-reordered-72.log`. This is endpoint pressure policy
with fresh packets, not a physical packet-loss or cellular-network simulation.

The corrected 60-second real-codec fixture also passed. Evidence is in
`anonymous-native-live-files-60/` and the adjacent `.log`. Both 512-KiB files
completed byte-for-byte while native media was still active; this verifies
actual contention rather than merely queued file requests. Audio, camera and
screen each progressed on their separate private paths, decoded images changed
in both video phases, and no media fallback occurred. Control retained the five
bootstrap attempts. All four nodes and native engines stopped normally.

Exact synthetic tone matching found all 55 expected transitions per direction
after warmup, with no missing transitions, quiet PCM observations or reported
interruptions. Peak source-to-rendered PCM delay was 52.096/52.129 ms (p95
51.430/51.508 ms). The independent 10-ms source clock peaked at 12.754 ms, with
12004 observations, none dropped, and no native callback errors. Reported native
audio delay peaked at 42 ms. See `pcm-tone-analysis.json` for phase detail.
This validates fixed-packetization codecs on unshaped loopback obfs4. It does not
validate the Dart adapter, adaptive non-onion packetization or phone acoustics;
the earlier long stress case exceeding 200-ms PCM latency remains open.

## 2026-10-15: private route expiry under periodic feedback

The user deferred the speech test; continue with owned synthetic fixtures. No
phone, installed application, real microphone, speaker or camera was opened.

### Proven defect and fix

An optional native-codec fixture now runs two synthetic Opus/VP8 engines through
four real node runtimes: A/C → middle → rendezvous, using authenticated loopback
obfs4 sessions. All four private receive addresses and both relay hops are checked.
It does not use the application's Dart adapter or a network shaper. Anonymous
audio retains its production fixed packetization; the non-onion adaptive codec
helper's overhead and RTP-size overrides are not applied.

Before the fix, primary private circuit admission stopped after about 12 seconds;
audio continued over the fallback pool. Camera and screen subsequently did the
same. Separate endpoint counters distinguish private admission, fallback attempts
and received private media cells before AEAD; a quiet private counter alone is
not proof that sound stopped.

The cause was `PriorityQueue::pop_local_datagram_lane_if`: periodic signaling
datagrams skipped reliable controls in the same local queue, then spent the next
shared signaling allowance before those controls could send. Route probes starved.
Route probes now use the existing endpoint network-maintenance queue/budget,
independently of application signaling. An initial candidate preserving reliable
signaling FIFO prevented expiry but regressed two existing RTCP delivery tests;
it was rejected and the queue implementation was restored. Forwarded traffic
remains neutral. No relay role, wire priority, service privilege or byte allowance
changed.

The real 18-second primary + 10-Hz feedback regression failed with the original
signaling queue selection. Idle routes and primary traffic without feedback
passed the diagnostic controls. The final maintenance queue selection passed all
nine network scenarios (eight together, then the existing splice/repair test
after updating its expected local probe selector), including legacy interop and
RTCP delivery. Production `cargo check`, the native-library loader test and both
Python native PCM/ABI tests passed.

### Native rerun and remaining failure

Private evidence is beneath
`~/.cache/codex/xveil-physical-20261014/anonymous-native-maintenance-60/`.
The earlier `anonymous-native-fifo-fixed-60/` directory is evidence for the
**rejected FIFO candidate**, not the final queue selection.
The 60-second capture includes audio alone, camera from second 20, and screen
traffic from second 40. Audio/camera/screen fallback counters remained zero;
control retained only its five bootstrap fallback attempts per endpoint.
Decoded video content changed in both phases and native audio RTCP was present.
The source clock's maximum interval was 15.008 ms, with no lost observations or
native callback errors. Exact source-tone edge matching found 55/55 changes in
each direction after warmup: maximum PCM delay 53.552/53.591 ms, no quiet PCM
frames and no reported interruptions. This is local synthetic evidence, not
speech quality or a shaped multi-hop latency result. Fixed anonymous encoders do
not emit the adaptive encoder-input trace; full stage attribution is unavailable.

At that commit the complete optional fixture failed: both simultaneous 512-KiB
files received zero bytes and timed out, including after native engines stopped.
The allowance-serialization cause was established in the follow-up above. That
capture did not verify competing file traffic. The previous assertion that the
two opposite-direction files could not finish during the mixed phase also
incorrectly combined separate endpoints' allowances; it was removed. The final
fixture records actual progress during media and permits completion afterward
when needed, without assuming either outcome.

The native fixture requires `test-low-difficulty` as well as `node-embedded`;
without it a filtered invocation can silently run zero tests. Build the media
library with `VEIL_MEDIA_TEST_HOOKS=1`; set `VEIL_MEDIA_TEST_VIDEO=1`,
`VEIL_MEDIA_CODEC_TEST_DYLIB`, `VEIL_MEDIA_PCM_DRIVER_DYLIB`,
`VEIL_MEDIA_CODEC_OUTPUT` (an existing owner-only empty directory), and
`VEIL_MEDIA_DIAG_PATH`. Run the ignored exact test
`media_ffi::media_route_network_tests::codecs::real_anonymous_codecs_share_obfs4_with_files_on_four_private_planes`.
The loader resolves SDK symbols from that Rust executable, avoiding a second SDK
channel table. Both native PCM ABI layouts are verified before writable buffers
are passed across FFI. All four nodes and native engines stop before gate failures
are reported. Use `TMPDIR=/private/tmp/` throughout.

The earlier long non-onion stress result still exceeds the 200-ms PCM target;
this unshaped anonymous capture does not close that remaining goal.
The simultaneous file-open and sustained-pressure follow-ups are recorded at
the top of this document; both now have positive controls after their fixes.

## Historical handoff

Date: 2026-07-09.

This note preserves the last known working context after the local scratchpad was
removed from git and cleaned from disk.

## Current state

- Calls over veil Phase 4 video is implemented and was device/user verified:
  bidirectional audio and video over the 2-hop onion media datagram channel.
- Recent committed line includes macOS camera discovery, route-change crash
  hardening, heartbeat/media-aware liveness, in-call mic/camera toggles, non-
  blocking macOS media start, stale-route media self-heal, off-isolate node id
  FFI, and low-latency media queue tuning.
- Latest superproject commits around this line:
  - `2d036eb` - bump veil for low-latency media queue.
  - `e4b5e19` - retire stale durable call signals.
  - `fa2a1c7` - mac media start no longer freezes UI on accept.
  - `f0bd6aa` - self-heal desktop->phone media when channel opened early.
- Local uncommitted follow-up:
  - `third_party/veil/flutter/veil_flutter/lib/src/client.dart`: ordinary
    `AppHandle.send()` now runs `veil_send` on a worker isolate. This removes
    the call signaling path (offer/answer/heartbeat over `MessagingService`) from
    Flutter's UI isolate; previously it used `Future(() { ... })`, which still
    ran the synchronous Rust `block_on` FFI on the same isolate.
  - `third_party/veil/crates/veilclient-ffi/src/lib.rs`: media datagram outbound
    queue is split into high-priority audio/RTCP/unknown packets (32) and VP8
    video RTP packets (96). This preserves normal VP8 keyframe bursts without
    putting audio behind a long video FIFO.
  - `third_party/veil/flutter/veil_media/src/veil_transport_shim.{h,cc}`:
    inbound datagrams copied into WebRTC's network queue are now bounded to 256
    pending packets or 4 MiB. Overload drops are logged, and `Stop()` waits
    briefly for already posted inbound tasks to drain before destruction.

## 2026-07-09 follow-up verification

- Rebuilt macOS native media and veil FFI libraries:
  - `third_party/veil/flutter/veil_media/macos/Frameworks/libveil_media.dylib`
  - `third_party/veil/target/release/libveilclient_ffi.dylib`
  - `third_party/hidden-volume/target/release/libhidden_volume_ffi.dylib`
- Re-signed the debug macOS app and reset Camera/Microphone TCC for
  `network.veil.xveil`.
- Android `libveil_media.so` was not rebuilt in this pass because the local
  Docker/Colima `webrtc` profile socket was unavailable. The connected phone
  still participated in the real call with its existing app build.
- Real macOS <-> Android video call, mac initiated and phone accepted:
  - active for roughly 4.5 minutes;
  - both sides stayed active and debug hooks remained responsive;
  - media counters continued growing (`mac_recv` reached about 18k,
    `phone_recv` about 23.6k);
  - macOS RSS rose from about 572 MiB to the 753-769 MiB band, then oscillated
    there instead of running away toward the previous 45 GB failure;
  - `/tmp/veil_media_diag.log` showed normal send/capture logs and no inbound
    overload drops or `Stop()` timeout;
  - hangup completed cleanly and both sides returned `call:null`.
- Local checks passed:
  - `flutter analyze lib/state/veil_call_media.dart lib/state/call_service.dart third_party/veil/flutter/veil_flutter/lib/src/client.dart`
  - `flutter test test/call_service_test.dart test/durable_redrive_test.dart`
  - `cargo check -p veilclient-ffi --features node-embedded,production-seeds`
  - `cargo test -p veilclient-ffi --features node-embedded,production-seeds media_priority_tests --lib`
  - `WEBRTC_SRC=~/Projects/veilnetwork/webrtc-checkout/src WEBRTC_OUT=out/mac-arm64 ./build_veil_media_dylib.sh`
  - `cargo build -p veilclient-ffi --features node-embedded,production-seeds --release`
  - `flutter build macos --debug`

## Open bugs

### 1. Real bidirectional video call memory leak

Status after the 2026-07-09 follow-up: not reproduced in a roughly 4.5 minute
real macOS <-> Android video call after bounding the native inbound shim queue.
The macOS process stabilized around 753-769 MiB RSS and hung up cleanly. Keep
this section until Android `libveil_media.so` is rebuilt and a longer soak has
confirmed the same behavior.

Original symptom: during a real macOS <-> Android video call, the macOS `xveil`
process grew to roughly 45 GB RAM and became unresponsive under swap pressure.

Ruled out so far:

- media stale-route self-heal drain loop: flat RSS while blasting dropping
  datagrams to an unreachable peer.
- Dart remote video renderer: coalesces decode work and disposes `ui.Image`.
- C++ receive sink keeps only the latest RGBA frame in a reusable vector.
- Dart `getVideoFrame` reuses its frame buffer and frees width/height pointers.
- audio-only calls and synthetic video send do not show runaway growth.

Prime suspect before the follow-up: native `libveil_media` under real phone
camera receive/decode, especially an unbounded inbound datagram handoff into
WebRTC's network queue when decode/network processing lagged live media.

Next step if it returns: reproduce with a real video call and
`MallocStackLogging=1`, capture `heap <pid>` and
`malloc_history <pid> -allBySize` at about 2.5-3 GB RSS, then kill the process
before macOS reaches global memory pressure.

### 2. Low-RSS Flutter UI isolate freeze in synchronous FFI

Symptom: separate freeze at about 0.49 GB RSS, low CPU, app/debug hook
unresponsive. `sample` showed the main thread in Dart JIT frames, a synchronous
veil FFI call, `tokio::runtime::Runtime::block_on`, and `parking_lot` condvar
wait. The nearest symbol was `veil_get_node_id`, but the offset may point to a
nearby function.

Most likely pattern: a call/media-start path still invokes a blocking Rust FFI
operation from the Flutter UI isolate.

Primary places to inspect:

- `lib/state/veil_call_media.dart`, especially `VeilCallMediaController.start()`.
- `third_party/veil/flutter/veil_flutter/lib/src/client.dart` for wrappers that
  should use `Isolate.run` instead of direct synchronous FFI.
- `third_party/veil/crates/veilclient-ffi/src/lib.rs` and `anon_stream.rs` for
  FFI functions that call `Runtime::block_on`.

Useful already-committed fix in veil: `554b053` runs node id FFI off the Flutter
UI isolate. Continue looking for other synchronous media/open-channel calls.

Local follow-up after that commit: `AppHandle.send()` was also moved off-isolate,
because call offer/answer/health signaling uses the ordinary messaging send path
and `veil_send` also `block_on`s. In the 2026-07-09 real video call, the debug
hooks remained responsive throughout the run, so the low-RSS freeze did not
reproduce in that pass. If it returns, confirm with `sample` that the main
thread no longer parks inside `libveilclient_ffi`.

The stale-route self-heal commit `45061b5` is a possible A/B test candidate if
deadlocks persist, because its drain task can re-enter media channel opening and
async mutexes.

## Repro and safety notes

- Use debug builds with release native libs, launched from Terminal with
  `MallocStackLogging=1`.
- Keep a safety monitor that captures allocator state and kills the process at
  2.5-4.5 GB RSS. Do not let the real leak run to 45 GB again.
- Debug hook ports:
  - macOS: `http://127.0.0.1:38765`
  - Android via adb forward: `http://127.0.0.1:38766`
- Unlock both with POST body `111111`, then use `/wait_ready`, `/identity`,
  `/call_place?peer=<hex>&media=video`, `/call_accept`, `/call_hangup`,
  `/call_state`, `/media_open`, `/media_send`, and `/media_recv_count`.
- On macOS, ad-hoc re-signing resets Camera/Microphone TCC for the bundle id;
  reset/grant permissions before a real video repro.
