# Calls media handoff

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
