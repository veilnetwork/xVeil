# Calls media handoff

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
