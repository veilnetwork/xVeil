# Calls media handoff

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
