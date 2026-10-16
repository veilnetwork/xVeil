# Three-party group audio preflight

## 2026-10-17: native pacing experiment rejected

A real-pacer component test reduces a 5060-byte immediate burst to 2024 bytes
with a 4x/100-ms video profile, finishing by 97 ms with every packet in order.
Small/high-rate frames remain immediate. The full candidate is measurement-
valid but NEGATIVE: 2112 ordinal matches / zero missing, loaded peak
210.046 ms, six moving tails 14/6/13/6/13/14, and three full correct 512-KiB
files by 352.182/312.512/352.364 s within the original 360-s deadline.

The origin SDK's relay frame assembler collects those paced RTP packets until
the marker and sends the complete frame as one local work batch. The upstream
pacer therefore does not establish spaced cell release at the relay path and
can add sender delay. The native treatment and its helper/test are REVERTED;
current video remains 4x/25 ms. Private source patches, binaries and negative
proof remain available. Next pace cells after whole-frame source admission,
preserving ownership, deadlines and neutral relay behavior. See
CALLS-MEDIA-HANDOFF.md for the exact call path, evidence and retained standalone
VAP1 test-reader fix. The immutable contention fixture/gates are unchanged.

## 2026-10-16: earlier DATA pressure and faster decoded catch-up; full test NEGATIVE

The candidate now restrains own ordered DATA on sustained relative RTT growth
from fresh authenticated primary ACK observations. Its expiring lease is
separate from video/signaling/recovery/transit. New decoded audio catch-up takes
two Opus-budget rungs while isolated loss takes one. Rust tests: 83 pass, one
pre-existing ignored experiment; Dart: 17 pass; timing: 3 pass; analyzer clear.
Details and binary provenance are in CALLS-MEDIA-HANDOFF.md.

`group-files-data-delay-1024-60` remains NEGATIVE overall: all 330 transitions
match, loaded peak 140.213 ms, but audio-only startup reaches 260.079 ms. The
full `group-data-delay-combined-1024-360` has all 2112 transitions and three
complete verified files at 338.016/343.339/280.075 s. It still FAILS: loaded
peak 480.049 ms, every video tail has zero changes, and decoded catch-up remains
frequent. Audio-only reaches 160.087 ms. Native discarded-audio counters report
about 30 seconds across each participant's two receivers; tone matching does
not prove continuous speech quality. Keep both negative captures.

Clocks/coverage/routes/topology and independent process/socket cleanup verify.
Next inspect initial physical/video bursts and NetEq's repeated 120-ms catch-up
with 40-ms packets and video resume/hold. Existing resume requests a keyframe;
do not assume it is missing. Retain six paths, every phase, immutable deadlines,
file hashes, moving-video and speech requirements. Relays stay neutral. Audio
goal ACTIVE; private `group-data-delay-{file,combined}-proof.json` keeps evidence.


## 2026-10-16: split route/key reply race fixed; file-only run still NEGATIVE

SDK `c18d12d7` waits for both route and key before releasing concurrent local
senders, within the original fixed deadline. Three new regressions and all 68
send-handler tests pass. Details and private binary provenance are in
CALLS-MEDIA-HANDOFF.md under the matching date heading.

`group-files-split-reply-1024-60` reduces key proofs from 6 to 3 (12 to 6
admitted hop copies, 16548 to 8274 plaintext bytes). It remains NEGATIVE:
330 matching PCM transitions, zero ordinal misses, loaded peak 350.047 ms,
audio-only peak 160.086 ms. Clock/row/route/topology gates verify, all workers,
policy processes and four nodes exit, and independent PID/socket checks pass.
This short file-only isolation completes none of the three files and does not
qualify combined contention or continuous speech.

The peak source transition occurs at 28.28 seconds. Receive-direction wire
observations reach 1187.7 kbit/s during second 27 against the unchanged
1024-kbit/s FIFO, with queue maxima near 200 ms. Source pressure responds later;
next inspect steady DATA ramp, physical byte cost and feedback latency. Keep
original PCM/deadline/full-file/video gates and neutral relays. Do not use RTT
alone to cut video or tune a fixed ceiling just to pass this stand. Private
proofs: `group-split-reply-{proof,attribution}.json`. Audio goal remains ACTIVE.

This is a baseline for the continuing audio-priority investigation. It is not
the full group/video/file contention qualification or a speech-listening test.

## Why separate processes

The FFI media receive registry currently has one callback per remote node in
a process. The original four-node fixture also placed all three local media
participants in that process, so each last registration replaced an earlier
participant's registration to the same remote node. Exactly three of six voice
paths survived. That result does not establish a failure between real apps.

The process preflight keeps the owned relay and three embedded nodes in its
parent, and connects one media participant per spawned worker over its own
node's IPC socket. Every worker has a single real group engine, two peer
channels and its own native synthetic audio device clock. It never forks an
already-running node. All workers use the same service/module names as before;
there is no routing exception, custom peer identity or relaxed authentication.

## Timing evidence

Each worker captures a distinct alternating tone pair and identifies the other
two pairs independently in actual mixed decoded PCM. Native callbacks run
without Python callbacks or the GIL. Only timing/frequency metadata is kept.
One local capture row and two receiver observations are retained per tick.

The parent matches each remote source's actual capture transitions against the
receiver's decoded transitions by ordinal. The receiver does not guess remote
capture times. Unit tests reject whole-period stale audio that periodic phase
matching could accidentally call low latency. Native clock policy, full sample
coverage, row loss and callback failures remain explicit gates.

The first process preflight is preserved as NEGATIVE: all six voice paths
worked, but Python started capture 239 ms after the shared origin. The source
coverage gate rejected this run. Coordinated startup now occurs on the native
device thread before the shared deadline, with bounded waits allowing stop;
the unchanged 100-ms source-start coverage gate passes afterwards.

## Usage

The stand currently requires macOS for native Mach deadline policy validation.
Use a Veil Rust FFI and a matching test-hook media library built with
`VEIL_MEDIA_TEST_HOOKS=1`. No microphone, speakers or app profile are used.

```sh
TMPDIR=/private/tmp/ python3 scripts/group-process-preflight.py \
  --sdk /absolute/path/libveilclient_ffi.dylib \
  --media /absolute/path/libveil_media.dylib \
  --directory /private/tmp/group-audio-preflight \
  --duration 60 --rate-kbps 1024
```

The directory must not already exist. Zero rate means unrestricted. The
optional shaper is the existing blind UDP FIFO: it never interprets payloads
or assigns media priority. It retains bounded wire metadata without contents
or addresses. Source snapshots and hashes identify the executed fixture.

## Results and next work

Private `group-proc-preflight-41` passes the unrestricted 40-second baseline:
six directions, all 210 measured transitions, peak mixed decoded age 50.157 ms,
zero native clock errors or lost rows. All workers and four nodes stop; socket
and process cleanup are independently verified.

Private `group-proc-audio-1024` FAILS even with no video/files. Native clocks
remain complete, but decoded transitions are missing and delays reach 730 ms.
The follow-up `group-proc-audio-wire` is also NEGATIVE. Its full bounded wire
trace records 35,096 datagrams. One direction offers about 1076 kbit/s against
the 1024-kbit/s FIFO limit, reaching approximately 211 ms queue age and packet
loss. That aggregate includes control traffic and startup/tail time; it is not
a claim about codec payload bitrate alone.

Group audio still uses the built-in encoder at default packet duration and
does not join the audio Call's congestion allocator as the 1:1 path does.
These source differences and the measured overload justify investigating
group framing/adaptation next. Do not raise link capacity, relax PCM timing
bounds, remove losses from evidence or add relay media priority to obtain a
pass. First repair the audio-only case, then run the full six-path workload
with video and three complete encrypted files under the same link limit.

## Controlled packet-duration experiment (still test-only)

A follow-up 40-ms experiment originally allowed PEX/DHT to add direct
participant sessions. Its route verification FAILS and the capture is retained
as `group-ptime40-1024`; it is not accepted as a treatment comparison.

The fixture now disables PEX, uses hidden listeners with cryptographic node
allowlists for only the three relay links, and requires exact initial/final
session counts 3/1/1/1. Every sampled admission must still go through the owned
relay. This establishes the intended test topology; the FIFO's bandwidth,
queue bound, opacity and lack of media priority remain unchanged.

A single instrumented test library then compares 20/40/60-ms Opus packets.
Its duration switch and sender-counter hook are compiled only with
`VEIL_MEDIA_TEST_HOOKS=1`. An ordinary build retains 99 exports and has no test
exports; the private test build has 129. The experiment retains actual sender
packet/payload counters and source snapshots, not merely its requested setting.
Rust FFI remains the preserved 006cf831... runtime (equivalent to release 2d7d
apart from version metadata), so this is not qualification of a fresh public
APK or a new production adaptation policy.

- `group-closed20-1024`: NEGATIVE. All routes/topology and clocks verify;
  native sender rates are about 50 packets/s at 29–32 kbit/s payload. Six
  measured tone transitions are missing; decoded age peaks at 630.049 ms.
- `group-closed40-1024`: PASSES the audio-only timing gate. All 330 transitions
  match below the unchanged 200-ms bound (peak 190.040 ms). Sender rates are
  about 25 packets/s with approximately 32-kbit payload preserved. Route,
  topology, full capture/row coverage and native deadline policy verify.
  There are still FIFO drops and many decoder recovery events. This does not
  establish perceptual speech quality or headroom for video and complete files.
- `group-closed60-1024`: NEGATIVE. Topology and clocks verify, but 55 transitions
  fail ordinal matching and a matched observation exceeds 200 ms. Keep this
  result; longer packets are not assumed to improve every condition.

All three workers and four nodes exit in every capture, with zero remaining
sockets and independent PID checks. The next implementation must use measured
feedback to adapt group audio, including mixed-version behavior and correct
fanout accounting; a fixed global 40-ms switch is not the completed solution.
The 1:1 path already has bounded framing ANA; group start does not join its
allocator and its shims do not parse transport feedback by default. Then run
the original full video/three-encrypted-file workload at the same link budget.

## Live group audio control (local, after the release)

The optional SDK `veil_media_group_engine_set_audio_budget` controls 20/40/60-ms
Opus framing and 16–32-kbit/s payload before or during audio. It reconfigures
the existing sender on its audio worker, preserving RTP, capture and receivers.
A busy worker rejects the bounded request without applying abandoned work
later; held video queues do not block it. Callback errors remain sticky and
failed reconfiguration restores the previous known configuration or marks it
invalid. Requested budget, actual encoded duration and sender counters are
separate diagnostics. No fabricated BWE or relay media/priority hint is added.

Production `GroupCallAudioAdapter` starts at 40 ms/32 kbit/s and uses fresh
loss, local drop/recovery deltas, authenticated peer decoded-recovery events,
or fresh growing/full peer buffers. Its budgets are 20/32, 40/32, 40/24
(milliseconds/kbit/s). The payload floor is now 24 kbit/s: a real-codec
component regression demonstrates long signal attenuation at the earlier
16-kbit floor without routing, loss, NetEq or DTX being necessary. This is a
signal-preservation check, not a continuous-speech quality verdict. An engine
explicitly advertising `audio_max_packet_ms:60` can use a final 60/24 budget,
only after an applied 40/24 budget has actually emitted packets and fresh
pressure remains. Unknown
or stalled native snapshots, a missing packet counter and an unapplied floor
cannot enable that step. The original startup budget is unchanged; this is
not the earlier fixed-60-ms experiment. An explicit legacy maximum cancels a
pending unsupported retune. Recovery needs eight fresh, complete room-wide
healthy observations after a quiet period, without fresh peer decoded loss.
Cached reports, muted capture, counter resets and failed retunes cannot
manufacture recovery or repeated cuts. The controller runs it even without
video. Old engines keep their existing codec through the optional API/ABI
fallback and do not enter the 60-ms policy step.

`TMPDIR=/private/tmp/ python3 third_party/veil/flutter/veil_media/test/run_group_opus_signal_smoke.py`
reproduces the codec comparison using the pinned real encoder and decoder.
The simulated capture runs for 360 seconds, retains the initial 40-ms/32-kbit
profile and compares 16/24/32-kbit payloads with DTX on/off. A bitrate-only
retune retains the encoder; a later ptime change recreates it. No PCM/payload
is retained. Lower-profile attenuation is reported as evidence; preservation
of the protected profiles is asserted. This component check does not replace
the original six-path contention fixture, its stimulus or any of its gates.

`group-budget-live-60` passes the native API regression: six paths, all 330
transitions, peak 80.227 ms. Five live changes per sender exercise 20/40-ms
framing and 16/24/32-kbit payloads. RTP origin, modular sequence and timestamps
stay continuous. Busy audio rejects in 20.3 ms; held video allows retunes in
under 0.2 ms. Real video runs only in that queue regression, not in the timed
audio workload.

`group-adaptive-audio-1024-60` uses the actual Dart policy, privately compiled
per participant. Native feedback drives it; decoded tones are measurement-only.
The same 1024-kbit blind FIFO/closed relay star passes all 330 transitions at
a 170.057-ms peak. Senders reach 40-ms/16-kbit by about six seconds. There are
still 61 FIFO drops and decoder recoveries. This does not prove continuous
speech quality, recovery under changing capacity or full video/file contention.

All owned workers, policy processes and four nodes exit; independent PID and
zero-socket checks pass. Focused Flutter tests pass 63 cases; targeted analyzer,
complete native call-plane suite and group decoded-backlog regression pass
(168.047-ms fresh marker, zero fallback). The new production build exports
100 functions with zero test hooks; private instrumentation has 131. Both
old/new production libraries pass the ABI gate. Published tags and the older
99-export engine cache are unchanged. Private evidence:
`group-audio-control-verified.json` and both source-frozen capture directories.

Next qualify the six paths with production video/source policy and three
complete encrypted files, retaining the frozen completion deadline, changing
tail video and the unchanged 200-ms PCM timing bound.

## Full process-isolated load: still NEGATIVE

`scripts/group-codec-control.py` now forwards to the isolated implementation
with `--adaptive --full-load` (360 seconds/1024 kbit/s by default). The previous
single-process implementation is retained in Git and the historical evidence;
it must not be used to claim six working directions. The full fixture adds real
synthetic VP8 and one authenticated AES-GCM 512-KiB file per sender in a ring.
File receipt callbacks reject fragments after the immutable deadline. Complete
hashes, no duplicate/authentication/async errors, changing tail video, complete
source/native clock coverage and all six PCM directions remain required.
`--load-kind files|video` isolates a competitor and can never qualify the full
workload. Those modes do not relax the both-mode gate.

Private `group-full-process-baseline-60` is NEGATIVE: unrestricted, all 330
audio transitions below 130.063 ms and all six video tails changing, but only
165888/174080/172032 bytes of the three files arrive by 60 seconds. This is not
relabeled a pass merely because the longer deadline below permits completion.

`group-full-process-1024-360` is NEGATIVE under the unchanged blind 1024-kbit
FIFO: all 2112 transitions match, but peak mixed decoded age reaches 490.095 ms
after video/file start (audio-only peaks at most 170.112 ms). All three files
complete with exact hashes at 353.270/353.202/353.344 seconds from origin; zero
authentication errors, duplicates or async failures. All six tail images change.
Native clocks have zero lost rows, deadline misses or callback failures. All
routes and exact 3/1/1/1 topology verify. The wire trace is bounded: this long
capture retains the last 100000 events, not its entire startup.

This exposes a policy defect: fresh decoded catch-up cut the video ladder but
was excluded from audio failure at its actual one-fps floor and from the video
resume guard. Post-trim buffer values could therefore look healthy during
continued real speech discard. The adapter now treats each fresh catch-up
event as audio loss: isolated events still cannot immediately pause the floor;
repeated events after actual floor frames can, and continuing discards cannot
earn resume. Existing counter freshness/real-frame trial gates remain intact.
154 focused Flutter tests and targeted analyzer pass. The former draining-buffer
test now supplies only buffer samples, rather than also asserting seven real
discard events; separate tests cover isolated and repeated discards.

`group-full-discard-protection-1024-60` is still NEGATIVE. All three native
senders actually pause by the 25-second sample, and two later attempt a sparse
probe. Initial audio delay still reaches 480.041 ms; one path also fails ordinal
matching (61 decoded vs 60 source transitions), which is retained, not realigned.
Its incomplete files and missing video tails are not waived.

Isolation confirms another problem. `group-files-only-1024-60` has all 330
transitions but a 340.051-ms peak; `group-video-only-1024-60` has all 330 but
a 440.033-ms peak. In both, initial audio-only peaks stay below 200 ms.
Full, payload-blind wire traces cover these short captures and retain the exact
monotonic origin. Before added load, offered traffic is about 625–630 kbit/s
per direction. File startup reaches 959.7 kbit/s with a 163.6-ms queue peak;
video startup reaches about 1180/1174 kbit/s and fills both 200-ms FIFO queues.
Thus average bitrate/headroom does not prevent source bursts. These observations
locate a remaining source pacing/startup problem; they do not yet prove which
handshake, encoded frame or reliable write produces each burst.

Next inspect whole-frame admission vs actual wire emission. Relevant SDK paths:
`veil-session/src/runner.rs` reliable admission around `reliable_source.admit`,
`local_source_activity.rs`, `reliable_frames.rs::write_frames`, and
`veil-transport/src/reliable_records.rs`. Admission currently charges a whole
frame's future time, while the reliable writer submits a whole encrypted record.
Verify a packet-level treatment without double-charging, dropping committed
bytes, changing FIFO/nonces, starving files or adding transit priority. Also
measure native video startup/keyframe emission; nominal one-fps/8-kbit targets
do not prove that their first wire burst is small. Preserve all negative evidence
and rerun the original six-minute combined gate after correcting emission.

All owned workers, policy processes, file threads and four nodes exit in every
capture, with zero remaining sockets and independent PID checks. Four fixture
unit tests verify complete payload hashes, late-fragment rejection, duplicate
accounting and foreign/corrupt fragment rejection. No physical app, microphone
or speakers were opened. No new SDK engine cache/release was published.

## Cold video and local startup telemetry: still NEGATIVE

Capture origins now include UNIX milliseconds as well as the monotonic clock;
each statistics sample records its observation time before the native read.
Local startup diagnostics include the peer and physical pool slot, handshake
and binding elapsed time, UDP byte counts, PTO and losses. Slots may be assigned
to source or transit resources; never infer media roles from their numbers.
Group RTP counters count attempted peer copies, including padding and rejected
copies. `video_tx_rtp_queued` means local queue acceptance, not delivery.

`group-video-startup-trace-1024-60` is NEGATIVE: a 390.071-ms known peak and
one ordinal mismatch remain. Initial source connects complete QUIC in 57–73 ms
with 6126 outbound/2448 inbound bytes before application data; binding takes
174–214 ms and reaches 7909/4235 bytes. Four further physical connections begin
about 20.37–20.40 seconds after origin. Their binding takes 530–2464 ms. In
contrast, the first per-sender video sample has one frame, 1490 RTP payload
bytes and 2040 padding bytes across its copies, with zero local RTP rejections.
This identifies significant startup overhead, not an exact packet attribution.

A generic 2400-byte initial congestion-window experiment is rejected:
`group-video-small-cwnd-1024-60` matches all 330 transitions but peaks at
490.024 ms. The production transport parameters and treatment-only test were
restored. Private `group-small-cwnd-rejected-sdk` retains its patch and binary;
this failed treatment is not current source or a claimed quality fix.

The fractional native video budget can now prepare the next sender before its
first encoded frame; the controller mounts paused and retries after start if an
older engine rejects preparation. The legacy integer setter keeps its previous
stopped-state error and restart defaults. Native regression checks actual first
encoder output under 8 kbit/s and consumption of the one-shot preparation.
The fixture uses the same preparation and retains its older-library fallback.

`group-video-cold-budget-1024-60` is NEGATIVE: all 330 transitions match, peak
380.069 ms; all three engines acknowledge preparation. First sampled encoder
targets are 7840 bps, with 510 padding bytes per sender, rather than the earlier
2040. Reducing initial video padding does not remove the startup congestion.
All six tails change and all worker/node exits, clocks, routes and zero remaining
sockets verify. 156 focused Flutter tests, targeted analysis and the complete
native call-plane suite pass, including legacy stopped-state rejection and
cold-budget encoding/restart. Production has 100 exports, zero test hooks,
and passes the Dart symbol gate; private instrumentation has 131 exports.
Private verification: `group-cold-video-verification.json`.

The earlier reliable-writer hypothesis is not established for the file fixture:
its file fragments use canonical Delivery forwarding, with packet-sized local
admission, rather than the new reliable child writer. RPC outbox requests already
use the local network-control lane. Inspect certificate-resolution requests and
their remote response amplification alongside physical connection startups;
do not patch an unused writer or prewarm only the fixture to move the burst out
of the measured interval. Gates, deadlines and relay neutrality stay unchanged.

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
a nickname claim reports no sovereign identity. Follow-up `4fba0ef5` records
an independently reproduced deferred-boot nickname fix and durable outgoing
request recovery; the original Windows/Android acceptance failure is still not
independently attributed. See CALLS-MEDIA-HANDOFF.md for exact test evidence.
Do not silently replace identity keys or route ordinary traffic via mailbox.
The audio goal remains active; remaining source/control and video handshake
bursts still fail the original quality gate. No new release/push or physical
app/microphone/speaker use in this cycle.

## Release handoff

The pre-existing runtime fixes have Veil v0.11.41 published and xVeil
v0.13.86 tagged, with immutable product sources 2d7d3ed6 and 19640228.
Final verification confirms Veil source CI 6/6, mobile 11 passed/1 skipped,
recovery publication/hygiene successful, xVeil source CI 4/4 and release 9/9.
Veil has 43 published assets and xVeil 12; their tag sources are unchanged.
hidden-volume remains unchanged at v2.6.1. These later process-fixture and
packet-duration experiments are local research commits, outside those tags.
No production adaptive group-packet policy has been shipped by this experiment.

Veil publication originally failed because its changelog extractor expects
`## vVERSION —`, whereas the preparation mistakenly used xVeil's bracket
heading format. Recovery workflow source 9a9243f2 on branch
`release/recover-0.11.41` verifies the original seven successful build jobs,
checks out the original product tag, verifies all checksum files, then signs
and publishes the same 43 artifacts with a compatible notes extractor. The
tag is unchanged. That branch contains a recovery-only workflow and must NOT
be merged as the default release workflow. The later local documentation fix
restores the expected canonical heading for future releases.
