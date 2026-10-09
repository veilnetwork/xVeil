# xVeil architecture

xVeil is a cross-platform (Android · iOS · Windows · Linux · macOS) Flutter client
for the [veil](https://github.com/veilnetwork/veil) overlay network. It is
**messenger-first**: a Telegram-grade chat experience whose primary differentiator
is decentralization and deniability. Proxy/VPN routing and node management are
secondary surfaces. Cloud file storage is shipped, not planned — its own screens,
folder sync, a trash with undo, and per-folder ACLs.

It is built for people in censored / authoritarian environments. The two design
rules that follow from that — minimal user actions, and no central source of data —
shape every decision below.

## Ports & adapters

Every external dependency sits behind a **port** (a Dart `abstract interface`) with
**both a real adapter and an in-memory fake**. The fakes let the whole app build/run/test
without the native Rust stack; selecting real vs fake is a provider choice in
`lib/state/providers.dart` (+ `main()` bootstrap). All three real adapters are
implemented and verified end-to-end.

| Port | File | Real adapter | Fake (dev/tests) |
|------|------|--------------|------------------|
| `Storage` | `lib/data/storage/` | `HiddenVolumeStorage` over `hidden_volume` (deniable container; `HvKvLogStore`) | `HiddenVolumeStorage` over `FakeKvLogStore` |
| `NodeController` | `lib/data/node/` | `EmbeddedNodeController` (node in-process via FFI) **or** `SubprocessNodeController` (`veil-cli node run`) | `FakeNodeController` |
| `VeilTransport` | `lib/data/transport/` | `VeilFlutterTransport` (`veil_flutter` `VeilClient`/`AppHandle`, `xveil/inbox` endpoint) | `LoopbackTransport` (echoes) |

`RealVeilStack` (`lib/data/veil_stack.dart`) composes the real node + transport + this
device's bootstrap invite; `main()` activates it when `XVEIL_VEIL_CLI`/`XVEIL_VEIL_CONFIG`
are set (`XVEIL_NODE_MODE=embedded` picks the in-process node), else the app stays on fakes.

```
UI (features/*)  ──►  Riverpod state (state/*)  ──►  Ports (data/*)  ──►  fake | native
                         AppController                Storage
                         MessagingService             NodeController
                                                      VeilTransport
```

## Key decisions

1. **Node runtime — embedded or subprocess (both done).** The veil client FFI only
   *connects* to a running node. xVeil starts one two ways behind `NodeController`:
   `SubprocessNodeController` spawns `veil-cli node run` (desktop/Android); the
   **embedded** path runs the node IN-PROCESS via a new `veil_node_start/stop` FFI
   (`node-embedded` feature in `veilclient-ffi`) — required for iOS and sandboxed
   desktop (no subprocess), and verified end-to-end. The embedded build drops RocksDB
   (in-memory DHT) so mobile stays slim.
2. **Storage — hidden-volume.** Default is a deniable hidden space; plain storage is an
   explicit, warned opt-in. A **master vault** (`MasterVault`) that unlocks several
   child spaces with one password is an app-layer construct (the library does 1
   password → 1 space). `loadConversations` derives from a contacts index + the message
   log (hidden-volume has no KV key enumeration).
3. **Consent gate.** Strangers can't message unsolicited: a typed `WireEnvelope`
   carries request/accept/message; a relationship is `pending → accepted` before free
   messaging (`MessagingService`; `ContactStatus`). Messages from non-accepted/blocked
   peers are dropped.
4. **Fakes-first.** The fakes keep the whole app build/run/test-able without the native
   stack; the real stack is verified by env-gated tests under `test/native/`.

## State & navigation

- **Riverpod** for DI and state. `AppController` exposes an `AppPhase`
  (`bootstrapping → onboarding | locked → ready`).
- **go_router** gates navigation on `AppPhase` via a redirect bridged from Riverpod.
- **MessagingService** is the single seam where `VeilTransport` meets `Storage`:
  inbound payloads are persisted then surfaced; `sendText` persists then transmits.

## Status

**Done & verified:** native storage (deniable container on desktop); node lifecycle
(subprocess **and** embedded in-process FFI); pure-Dart BLAKE3 → `app_id`/`node_id`;
real transport (`send`/`messages`); **two-node real chat**; bootstrap-invite contact
exchange (QR + paste); `RealVeilStack` composition; consent gate (request/accept);
`MasterVault`; recovery-phrase input; app icons; lock-screen "start over" recovery.
Test harness: ~5,700 tests in 566 files. Live cases in `test/native/` and
`test/e2e/` skip under a plain `flutter test` when their native libraries are
missing; the multi-device harness also needs a `veil-cli` from the same build.
`.github/workflows/nightly.yml` builds these artifacts and schedules the
locally runnable live cases, while the push CI covers the regular Dart suite.

**Shipped since this section was written** — each was roadmap here, each is wired into
the app rather than merely present as a file:

- Veil FFI follow-ups: `veil_config_init` and `apply_config` (deferred mode) are bound
  and called from `RealVeilStack`; iOS dylib bundling is `scripts/build-mobile.sh ios`, TCP-loopback IPC is in `embedded_node.dart`.
- Identity restore/import, via `veil_config_init_from_phrase`.
- Username claiming — rarity-proportional PoW through `veil_flutter`
  (`claimNickname`/`resolveNickname`), UI in `features/settings/nickname_screen.dart`.
- Multi-device pairing (`device_link_invite`), mailbox offline delivery
  (`mailbox_service` + `mailbox_orchestrator`).
- File / image / video transfer (`messaging_file_transfer`).
- Audio / video calls (`call_service`, `group_call_service`). New video starts at 45 kbit/s at 1.2 fps on direct calls (8 kbit/s at 0.3 fps on anonymous/group calls) with the low-rate native API; older libraries retain 45/30 kbit/s at 1 fps, then grows one rung per 12 healthy audio samples with known RTT. Missing, expired or stalled audio feedback cannot increase video. Rebuilding the same unicast call/profile retains its video budget and hysteresis; the new native encoder starts at that budget. Desired microphone state belongs to the call, survives media-engine recreation and asynchronous opening, and is cleared on final hangup. Reusing an older call snapshot cannot undo a mute chosen during the call; cancelled or replaced opening remains muted.
- Built-in S3-style object storage across identities (`cloud_*`).
- Proxy/VPN (oproxy/ogate), SSH node provisioning.

Loaded-call check (Android debug 2150, 2026-10-04): both cellular/Wi-Fi phone
video calls remained active for at least 85 seconds. One concurrent 8 MiB file
completed in 28.1 seconds with matching SHA-256; the second download API returned
504 after its 45-second observation deadline, without a verified exported file.
During the verified transfer the receiver's median native audio playout estimate
rose from 272 to 472 ms (peak 631 ms), and stayed elevated afterwards. RTP counts
continued increasing; this does not establish acoustic quality. Two observed
Poco QUIC sessions advertised no opaque flows, independent transport or circuit
datagrams. These sessions cannot provide the new connection split; their exact
mapping to the call route is not yet established. Loaded-link audio quality and
actual end-to-end transport separation remain open, beyond local queue tests.

Ordered compatibility transport now bounds this endpoint's bulk write-ahead
while its own primary producer was active within three seconds: normally one
4 KiB padded batch may wait behind the writer, with a whole-frame exception for
an oversized individual frame. The writer wakes the runner when the required
slots become available; progress does not depend on another inbound frame or
keepalive. This cannot recall bytes already committed to the transport/kernel.
Transit retains its normal WRR/FIFO, batching and capacity; no transport label
or relay service preference is added. The encrypted, uniformly paced stream
regression fails without admission (133,808 bytes ahead of the next primary),
passes with less than 16 KiB, and verifies all 64 reliable payloads in order.
Gates: 96 runner integration tests passed (one ignored), 23 queue tests and
four admission tests passed.

Phone check (Android debug 2151, 2026-10-05): both video directions stayed active
for 85 seconds, with ring/active times 5.7/8.9 and 3.1/5.0 seconds. The two
60-second file observations timed out with zero exported bytes. A control file
without a call completed with matching SHA-256 in 74 seconds. A longer video
call remained active for 150 seconds; its 8 MiB file completed and verified in
104 seconds, with the first positive export sample 80 seconds after requesting
the download. The sender logged 23 stream authorization denials naming a
device different from the accepted contact identity, and no successful stream
serve for that CID; the device-owner authorization path needs investigation.
During observed verified-file progress, median native playout estimates were
137/218 ms (Blackview/Poco), peaks 362/460 ms; other phases exceeded 500 ms.
These estimates and continuing RTP do not establish acoustic quality or a
controlled improvement. This last ring took 19 seconds. Local first-send
diagnostics finally observed relay forwards in source slots 0 and 2 on shared
QUIC DATAGRAM sessions, all with `independent=false`; separate source transport
is not established on those hops. Signaling latency and audio quality remain
open. The authenticated debug hook provides CID-scoped download cancellation
and pending IDs so stands can cancel their own retry jobs before cleanup.
The cleanup exposed a cancellation race: a suspended resume could re-record
durable intent after cancellation. Recording now checks the cancellation latch
both before scheduling and inside the persistence chain. A gated-storage test
fails before the fix and verifies cancellation across restart plus a fresh user
retry afterwards; all six auto-resume tests pass.
Debug 2153 was installed and its APK verified on both phones. Scoped cleanup
cancelled the six identified stand content IDs on Blackview (one still pending),
left zero of those pending and preserved unrelated intents. Both contacts were
accepted. Own plaintext fixtures, debug forwards, logcat readers and launched
app processes were verified absent after the tests.


Fallback file chunks now use the endpoint's local background lane (3), through
both sealed ordinary delivery and authenticated onion delivery. Chat/control
sends retain their prior lane, ratchet reservations and persistence ordering.
Veil exposes `send_on_local_lane` / `veil_send_on_local_lane` / `sendOnLocalLane`;
an IPC-only explicit-hint bit distinguishes a chosen lane 0 from legacy zero
headers. The hint is stripped before network encoding. Direct and relayed
ratchet payloads still decrypt, anonymous sends remain on the onion path, and
neither the source lane nor a traffic-role label reaches relays. The real SDK /
IPC socket test verifies ordinary lane 1 and explicit lanes 0/2/3 with identical
inter-node bytes. Gates: 35 send-handler tests, writer and SDK/IPC tests, FFI
argument and generated ABI checks, strict production Clippy, 16 content service
tests and scoped Flutter analysis passed. Removing background routing makes the
new content lane tests fail.

Phone check (standard Android debug 2154, 2026-10-05): Poco used cellular;
Poco -> Blackview video rang after 7.7 seconds, became active after 10.9 seconds
and stayed active for 150 seconds. Native playout estimate medians/peaks were
374.5/590 ms on Blackview and 354/504 ms on Poco. Two observed first-hop QUIC
sessions still lacked independent source flows. The 8 MiB download timed out at
120 seconds, with only one verified 256 KiB export sample; the sender logged
22 authorization denials. No background chunk sends were observed in the
retained log. This run does not validate completed concurrent bulk delivery or
an improvement in acoustic quality.


A diagnostic receiver-only build (2155, `XVEIL_PLAIN_FILE_STREAM=false`) exercised
the new fallback on the same phones: all 64 background chunk sends were observed,
and a 256 KiB file completed in 0.69 seconds with matching SHA-256 during a
95-second video call. Ring/active times were 3.2/7.1 seconds; native playout
estimate medians/peaks were 236/605 ms on Blackview and 234.5/460 ms on Poco.
The brief transfer cannot establish sustained loaded-link acoustic quality.
Own download intents, plaintext fixtures, forwards, logcat readers and app
processes were cleared and verified after both successful runs. Blackview was
restored to its hash-verified standard 2154 APK; Poco retained standard 2154.
A subsequent 8 MiB fallback attempt stopped before creating fixtures or placing
a call: Poco disappeared from ADB while starting its debug connection. Blackview
was again restored and closed. Poco's process state after that last launch
attempt must be checked when it reconnects; the sustained fallback test remains
pending. Separate source transports on the observed relay hops, stream-owner
authorization, signaling latency and acoustic quality remain open.


Audio receive repair is now independent of aggregate media ingress. The native
`audio_rx_pkts` receive-stream counter advances audio activity only for a valid
worker snapshot; video/RTCP ingress and timed-out worker defaults cannot refresh
it. When the peer has announced mic-on, ten seconds without accepted audio asks
it to repair even if video continues. Mic-off, unknown peer posture and legacy
engines without the counter retain their prior behavior. Unmuting and a new
receive session each receive a full grace interval; peer repair requests are
suppressed during a local session rebuild. An unchanged newer posture heartbeat
also advances its ordering watermark without emitting a redundant UI update,
so a delayed older mute cannot overwrite it.

A continuously stalled local audio worker triggers a local session rebuild,
sharing the existing two-attempt per-call cap. Local starvation rebuilds also
recreate the engine on onion calls; refreshing only the outbound circuit would
leave their receive worker stuck. The actual selected route, microphone intent
and video adaptation budget are retained. Gates: 98 audio-activity/call-service
tests and scoped Flutter analysis passed; the audio-outage test fails with the
old aggregate-only receive policy. This control change still needs a two-phone
call check after Poco reconnects; it does not prove acoustic quality or remove
the observed shared-hop limitation.

Android debug 2156 contained that receive-repair change. Its native libraries,
production feature set, generated FFI contract, ARM64 packaging and full
installed APK hash were verified. Blackview reached a ready real-stack startup
with no active call, then its launched process and owned forward were verified
closed. The signed Poco update was prepared but not installed: subsequent ADB
checks still listed only Blackview.

Unicast call protocol v5 adds sequenced audio playout estimates to encrypted,
ephemeral health signals. The sender's video ladder now also considers the
receiver's native audio buffer estimate: >=300 ms reduces bitrate and cadence;
recovery needs <200 ms plus healthy RTCP for the existing 12-sample interval.
These are conservative buffer budgets, not measured acoustic latency targets.
A v5 peer with no fresh measurement gives video bandwidth back instead of
growing it. Unknown playout alone does not produce a failing-link prompt.
Older peers and deliberately muted senders retain the existing RTCP policy;
unmuting or rebuilding requires new feedback before growing video.

Feedback is emitted only from valid audio-worker samples with accepted audio
RTP within three seconds. Receive sample sequence numbers remain monotonic
across engine repairs. The peer uses local receipt-time expiry (12 seconds),
rejects old/replayed sequences and keeps the ordering watermark when it clears
a measurement. Only health from the matching active call/peer reaches this
policy. Signal stamping and copying preserve the additive feedback; the real
messaging path uses realtime delivery without creating durable outbox rows,
including anonymous delivery. The relay scheduling policy and on-wire transport
role metadata are unchanged. Gates: 166 scoped call, audio, wire and realtime
tests passed; scoped Flutter analysis found no issues. Disabling the playout
condition makes the clean-RTCP/slow-audio regression fail. Group-call receiver
playout feedback and live two-phone/acoustic verification remain outstanding;
this change does not establish independent flows on the observed old relays.

Android standard debug 2157 (source e17bdd6c, Veil 9bf5c8e8) was built with this
playout policy. Production Rust features, ARM64-only packaging, staged/packed
native library hashes, the generated FFI contract and absence of native test
exports were verified. Blackview was updated in place, and the full installed
APK hash matched the build artifact. Startup reached ready/real-stack with no
active call; force-stop and absence of both the app process and owned ADB
forward were verified. Poco's signed 2157 APK is ready but remains uninstalled
while only Blackview is enumerated by ADB. The existing 14 media-seal tests and
the transport-feedback v4/v5 compatibility test also passed after the version
bump. No live two-phone call was possible in this cycle.

Group video now requires fresh AUDIO RTCP reports from every connected peer
before its shared encoder budget can grow. Native group stats count one fresh
report per peer shim; stopped/deferred-teardown shims return no feedback, so a
departed receiver cannot substitute for a silent active receiver. The media
controller supplies its successfully opened peer count. Partial/absent reports,
a stalled audio worker, empty stats or a failed stats query release video
bandwidth toward the floor; retuning is still attempted when querying fails.
Fresh bad reports still substantiate congestion even if other reports are
missing. Unknown quality alone raises no failing-link prompt. Adding a peer
requires its feedback; removing one permits recovery after the usual healthy
interval. Deliberately muted senders retain the prior RTCP policy.

The group controller also retains microphone intent during permission/channel
setup and applies it before audio capture starts. A mute chosen after setup
begins can no longer be overwritten by the initial call snapshot. Teardown
clears this state for the next call. Gates: 72 scoped group-media, group FSM,
teardown, bitrate and unicast playout tests passed; scoped analysis found no
issues. Reverting the per-receiver completeness input makes the real group
controller's clean-RTCP/missing-receiver regression fail. Group receive-side
playout estimates are still not exported/reported; this gate protects RTCP
coverage and cannot establish acoustic latency or independent network flows.

Standard Android debug 2158 (source 829b5913) packages the group coverage and
capture-intent fixes. Native libraries/features/ABI were verified as for 2157;
the full installed Blackview APK hash matched the build. Real-stack startup was
ready with no active call, then the app process and owned ADB forward were
verified absent. Poco's signed 2158 update is prepared, remains uninstalled,
and its last stand process still needs verification when ADB reconnects. Only
Blackview was enumerated at the end of this cycle; no live call was placed.

Group media now exports `audio_receivers`, keyed by peer id, with packets
accepted by each real WebRTC audio receive stream and its native playout
estimate. The explicit `audio_rx_supported` capability remains set when the
audio worker stalls; an empty receiver map then means unknown audio, not a
healthy default. Audio and video sampling retain separate 20 ms scheduling
waits. The controller polls this even in audio-only rooms and keeps audio
activity separate from total ingress, resetting it on peer rejoin/removal and
engine teardown. This telemetry is local; no new relay-visible role or priority
is introduced.

The group audio watchdog now uses accepted audio independently of video and
RTCP, so continued video cannot hide a silent audio leg. Older native libraries
retain their total-ingress fallback. Capability is latched for the current
engine: a failed stats query cannot restore that fallback. Repair JOINs keep
their cooldown, and remote unmute/rejoin starts a fresh ten-second grace window
using local receipt time. Repair decisions use the current call after the
awaited heartbeat, and a new call no longer inherits the prior repair cooldown.
Gates: 70 scoped controller/FSM/teardown/audio/bitrate tests passed; scoped
analysis found no issues. Disabling the audio-only watchdog makes the real FSM
video-only ingress regression fail. The native Call/queue stand passed: accepted
audio remains four packets despite video, RTCP and wrong-source RTP ingress;
peers keep separate counts, stalled samples are unknown and bounded, and rejoin
resets counts. ARM64 Android native media rebuilt with 90 production exports.
Group receiver playout estimates are now exported locally; reporting them to
the sender, live two-phone quality and independent flows through older relays
remain unverified or incomplete.

Standard Android debug 2159 (source a28fd61f, Veil 13b4906b) contains this
per-peer audio telemetry and repair policy. Production Rust features, ARM64
packaging, raw/staged/packed native hashes, FFI header contract and absence of
native test exports were verified. Blackview was updated without clearing
data; its full installed APK hash matched. Startup reached ready/real-stack
with no active call, then force-stop, absent app processes and removal of the
owned ADB forward were verified. No test files or transfer jobs were created.
Poco's signed 2159 APK is prepared; only Blackview was enumerated by ADB, so
the Poco update, its old process verification and live two-phone test remain
pending. Stand binaries and Flutter test processes have exited.

Group receiver playout is now also reported to the sender through optional
`VAP1` RTCP APP blocks appended to existing report packets. The APP block,
including its target audio SSRC, 64-bit sample sequence and delay/unknown
sentinel, passes through the same native end-to-end media sealing as RTP/RTCP.
No relay-visible role, relay priority or additional standalone report timer is
introduced. Unknown APP names are compatible with the RTCP extension mechanism
([RFC 3550 §6.7](https://www.rfc-editor.org/rfc/rfc3550.html#section-6.7)).
BYE and padded reports are left intact. Unicast continues using negotiated
call-health feedback; only group receive samples enable the APP producer.

The producer requires a valid receive-worker sample and accepted audio within
three seconds; a stalled worker advertises unknown rather than the previous
measurement. Sample sequences remain monotonic across peer rejoin within one
group engine. Each recipient binds reports to its own audio SSRC, validates the
entire compound packet, rejects duplicate/older sequences, and expires measured
feedback after twelve seconds using local ingress time. Known support survives
an unknown/expired estimate, so lack of new measurements cannot masquerade as
a legacy endpoint. Removed/stopped peer shims contribute no reports.

The shared group video budget now reacts to the worst fresh receiver estimate.
At 300 ms or above it reduces video even with clean RTCP loss/jitter/RTT;
recovery requires estimates below 200 ms from every capable receiver, together
with the existing complete RTCP coverage. Partial/expired/unknown playout gives
bandwidth back; a known bad estimate remains evidence of congestion even with
partial coverage. Deliberately muted senders retain their previous policy.
Gates: 95 scoped media/controller/FSM/teardown/audio/bitrate/seal tests passed;
scoped analysis found no issues. Disabling receiver playout makes the real
controller's clean-RTCP/delayed-audio regression fail. Native Call/queue tests
passed with a real accepted Opus sample sent from one group engine to another,
unknown-worker feedback, per-peer maxima, wrong-target/malformed/unsupported
APP rejection, 64-bit ordering, replay resistance, expiry and peer removal.
ARM64 Android media rebuilt with 90 production exports. These are native buffer
estimates; acoustic two-phone quality and independent flows through the observed
old first-hop relays remain unverified.

Standard Android debug 2160 (source 76a753e2, Veil f2a49fb8) packages this group
playout feedback. Production Rust features, ARM64-only ABI, raw/staged/packed
native hashes, the FFI header contract and absence of native test exports were
verified. Blackview's in-place install matched the full APK hash. Startup was
ready/real-stack with no active call; force-stop, absent app processes and
removal/absence of the owned ADB forward were verified. Native stands and
Flutter tests exited; no phone test files or transfers were created. Poco's
signed 2160 APK is prepared but not installed: only Blackview remains visible
in ADB. Live two-phone/group playout verification and Poco's old stand cleanup
are still pending.

Large group snapshot and shared-document slices now use endpoint-local source
lane 3 on both initial durable sends and outbox re-drive. The re-drive derives
the classification from persisted wire kind, so a restart does not restore
normal-lane scheduling for queued bulk. Legacy small-file body chunks, including
their NACK re-sends, also use lane 3. Small group/document updates and file
metadata keep their previous path. Anonymity, frame bytes/ids, ratchet durability,
ACKs, receiver authorization, mailbox eligibility and relay policy are unchanged;
transports without optional source-lane support retain the normal fallback.

Gates: 21 scoped bulk-lane, snapshot reassembly and anonymous-routing tests
passed; scoped analysis found no issues. A fresh messaging service re-drives
persisted slices with the same payloads, ids, anonymity and source lane.
Disabling replication classification makes the source-lane regression fail.
The broader durable re-drive suite has five failures in old generic long-silence
expectations; all five also fail with both changed source files restored to
their pre-change versions (baseline log:
`/private/tmp/xveil-background-replication-baseline-redrive.log`). This cycle
does not establish a green full suite or live loaded-phone audio quality.

Standard Android debug 2161 (source 0cf17323, Veil f2a49fb8) packages these
replication lanes. Production Rust features, ARM64-only ABI, native library
hashes, the FFI header contract and absence of native test exports were
verified. Blackview's in-place install matched the full APK hash and startup
reached ready/real-stack with no active call. App processes and the owned ADB
forward were verified absent after the check. No phone fixtures or transfer
jobs were created. Poco's signed 2161 APK was prepared; Poco was absent in ADB.

Remote reliable IPC byte streams now use background source lane 3, including
open/data/close in the same FIFO class. Their wire headers keep the ordinary
neutral priority; the local selection adds no relay role metadata. The Rust
SDK sends at most 2048 application bytes per stream frame, so a whole body fits
under the active-primary 4 KiB ordered-writer budget. Large writes use the
existing bounded writer backpressure. Receive compatibility with larger older
frames is retained. Explicit SDK shutdown suppresses a duplicate close on Drop.

Gates: 112 IPC tests passed (five existing ignored), 36 SDK unit tests and 27
SDK/IPC integration tests passed. The new real remote-stream integration
checks all 128 KiB + 19 bytes, frame size, source lane, neutral wire header,
close order and bridge cleanup. Restoring either the old normal source lane
or the old 256 KiB producer makes that integration fail. The encrypted
SessionRunner compatibility stand also passed: a new primary passed before
16 KiB of committed bulk, then all 64 bulk frames completed in order without
duplicates. These gates cover endpoint queues and stream compatibility;
live loaded-phone audio and older first-hop independent-flow support remain
unverified.

Standard Android debug 2162 (source 76300e70, Veil 661f3c49) packages this
reliable-stream policy. Production-feature Rust clippy passed with warnings
denied. The ARM64 Rust library was rebuilt; raw/staged/merged/packed library
hashes, production features, FFI header contract and 90 production media
exports without test hooks were verified. Blackview's in-place install
matched the full APK hash, startup reached ready/real-stack and no call was
active. Force-stop, absent app processes and absence of the owned ADB forward
were verified. No phone test files or transfers were created. SDK/IPC/runner
test processes exited. Poco remained absent in ADB; its signed 2162 APK is
prepared, and its update, prior stand process verification and two-phone
loaded-call test remain pending.

The anonymous stream datagram fallback now also uses source lane 3 for valid
DATA cells and their retransmissions. Pacing, cell bytes, destination and
authenticated anonymous routing are retained. Controls and undecodable cells
keep the ordinary path. The source choice adds no wire role or relay policy;
the pinned-circuit DATA backend already selected this lane.

Gates: 20 anonymous-stream/media-route tests and four mux fault tests passed.
The new fallback test drives the production CellSender through the real SDK
and Unix IPC to the authenticated anonymous-send boundary; it checks exact
bytes/address and source lane for DATA, repeat DATA, all stream controls and
malformed cells. Restoring ordinary-lane DATA makes it fail. A StreamMux/driver
test forces FIN ahead of withheld DATA, then verifies complete bytes and EOF.
The provider in the IPC test records calls; it is not a live encryption or
relay stand. Loaded two-phone audio quality remains unverified.

Standard Android debug 2163 (source 29fa645f, Veil 1d2c0082) contains the
fallback source policy. Production-feature clippy passed with warnings denied;
the ARM64 Rust library was rebuilt. Production features, native library hashes
through APK packaging, FFI header contract and 90 production media exports
without test hooks were verified. Blackview's in-place install matched the
full APK hash and reached ready/real-stack with no active call. App processes
and the owned ADB forward were verified absent after force-stop. No phone
fixtures or transfers were created; all scoped test processes exited. Poco
remained absent in ADB. Its signed 2163 APK is prepared; updating it and the
live loaded-call/acoustic check remain pending.

**Not built:**
- Remote push. Notifications are local-only (`flutter_local_notifications`): the
  notification layer displays what the caller hands it and holds no policy, and there
  is no FCM/APNs registration anywhere in `lib/`. A sleeping device stays asleep until
  it wakes and drains its mailbox on its own.
- The Lua extension VM. The ARB strings are kept (`networkExtTitle`) and the row was
  taken out of the network screen, because a chevron leading to a "coming later"
  snackbar reads as a feature that exists and is merely switched off.

See `doc/SECURITY-NOTES.md` for the threat-model constraints these features inherit.

### Effective low-rate video budgets

Video adaptation now keeps fractional encoder-handoff cadence rather than
rounding each rung to an integer. Native integer setters previously clamped
budgets to 30 kbit/s and 1 fps, so the anonymous/group floor could not release
additional bandwidth for audio. The additive optional `set_video_budget` ABI
accepts positive budgets down to 1 kbit/s and 0.02 fps. The VP8 layer minimum,
allocation target and Call bitrate bounds follow the reduced budget. The
WebRTC video-registration minimum is explicitly 1 kbit/s; otherwise it raises
even these explicit layers back to 30 kbit/s. Encoder
max_framerate is rounded up only for WebRTC's integer configuration, while the
source gate enforces the fractional cadence. Camera, screen, synthetic and
app/JNI frame inputs share that gate; self-preview precedes the gate.

The sender exposes both its requested budget and WebRTC's actual
`video_encoder_target_bps`. Old integer ABI defaults/clamps, including the
explicit debug bitrate pin, stay compatible. Optional Dart lookup exposes the
capability; old engines receive their effective integer targets instead of
fractional values or zero, which an old native setter would interpret as a
15-fps default. New group capture is retuned before the camera/screen opens;
a busy video worker leaves the latest budget pending for the next stats poll.
No signaling, route, relay scheduling or visible media-role field is added.
These are encoder allocation/capture budgets, not an exact bound on padded
wire traffic, keyframes, retransmissions or RTCP overhead.

Verification: 60 focused Flutter adaptation/playout/group-controller tests
and scoped analysis passed. Real WebRTC Call/queues behind a mocked plaintext
Veil boundary verified 12-fps encoding, no additional encoded frames during a
2.2-second window at 0.02 fps after drain, changing self-preview, four accepted
Opus packets, recovery, 1-kbit/s actual encoder allocation, legacy integer
zero/defaults, and bounded abandonment of a busy low-rate retune. Actual
8-kbit/s targets were 7,840 bps unicast and 8,000 bps group. The native gate
first failed at 29,520 bps before the WebRTC registration floor was lowered;
checking only requested stats would have missed that failure. Stand processes
exited and their temporary build directory was removed. Production Android
ARM64 media compiled with 92 public exports and no stand hooks. Two-phone
loaded-call and acoustic quality remain unverified while Poco is absent; older
live relay hops still lack negotiated independent opaque flows.

Android standard debug 2164 (source e4667e1d, Veil 0ec24fc1) packages the
low-rate video API and policy. Production Rust features, unchanged generated
Rust FFI contract, ARM64-only APK, raw/staged/merged/stripped/packed libraries,
92 production media exports without stand hooks, and the full installed APK
hash were verified. Blackview reached ready real-stack startup with no active
call; its process and owned debug API forward were independently verified
absent after closing. Poco remains absent in ADB; its signed 2164 APK is
prepared, and installation plus loaded-call/acoustic verification are pending.

### Separate admission budgets for local loss-tolerant traffic

The session scheduler no longer puts all loss-tolerant sources into one
64-frame admission pool. Local queue classes have independent 64-frame limits;
a primary audio burst cannot evict another source's frames or lose its older
packets merely because a newer video/background burst occupied that shared
pool. Each class discards its own oldest lossy packet at capacity, leaving its
reliable FIFO intact. Ordinary neutral transit retains one INTERACTIVE budget
and equal treatment of forwarded users. Wire formats, relay priorities and
transport-role signaling are unchanged. The 500-ms age bound and aggregate
4096-frame cap stay in place; admitted lossy capacity across all four local
classes is now at most 256 frames rather than 64 total.

Gates: 363 session unit tests (3 existing ignored), 2 real encrypted-stream
SessionRunner checks and 18 real-QUIC opaque/parallel/rekey checks passed.
The mixed-burst regression checks all 256 received frames, exact bytes and
order within each source. Reinstating shared admission drops primary packets
0..31 and retains only 64 of the 256 queued frames; restoring separation passes.
Counter checks include restore, expiration and aggregate-pressure shedding.
Production session Clippy with warnings denied and Android ARM64 Rust build
passed. These stand results do not measure physical playout/acoustic delay or
establish independent opaque connections through the previously observed old
first-hop relays.

Android standard debug 2165 (source c4a794cd, Veil 011f94f1) packages separate
lossy admission budgets and retains the low-rate media library from 2164.
Production Rust features, unchanged generated Rust FFI contract, ARM64-only
APK, raw/staged/merged/stripped/packed libraries, 92 production media exports
without stand hooks, and the full installed APK hash were verified. Blackview
reached ready real-stack startup with no active call. Its process and owned
API forward were independently verified absent after closing; the owned
logcat reader exited. No datagram capability-offer event was captured during
that startup, so it provides no new evidence about current independent-flow
support. Poco remains absent in ADB; its signed 2165 APK is prepared. Physical
loaded-call, playout and acoustic checks remain pending.

### Preserve lossy frame age across session ingress and fallback

Loss-tolerant freshness now starts at the FrameSender ingress attempt, before
waiting for outbox capacity, and follows the frame through the runner's queues.
Previously, moving a frame out of the producer outbox restarted its 500-ms
clock; a stopped runner could replay already obsolete audio/video on recovery.
Datagram encode/send fallback also renewed that clock and discarded the return
carrier. The runner now restores the original local envelope, including its
admission time and weak carrier; an expired frame is dropped before it can
evict a fresh frame from a full source class. Reliable data is not expired.
Byte-only legacy FIFO adapters cannot recover upstream timestamps; their local
age starts when they create an envelope. Production FrameSender preserves it.
No timestamp, source role, deadline or service priority is added to the wire.
Relays keep the same neutral FIFO and admission policy for all forwarded users.
This bounds time before socket commitment at this session; it does not bound
end-to-end playout time or recall bytes already committed to a stream.

The encrypted SessionRunner recovery test uses the real producer outbox,
holds three local source classes plus neutral circuit traffic past the age
limit, then queues fresh frames. Before the fix it received obsolete sequence
numbers 0..3; after the fix it receives only 100..103, retaining the old reliable
message and legacy circuit wire priority. Queue checks cover original age
through both scheduler rounds, expiry during fallback, full-class admission,
weak-carrier restoration and time spent awaiting ingress capacity.

Gates passed: 366 session unit tests (3 existing ignored), 3 encrypted-stream
runner checks, 18 real-QUIC opaque/parallel/rekey checks, production session
Clippy with warnings denied, and Android ARM64 Rust compilation with
production-seeds/node-embedded/packet-tunnel. This verifies local freshness and
transport regressions, not physical acoustic delay or current live relay
support for independent flows; two-phone load tests remain pending.

Android standard debug 2166 (source e8bd1d97, Veil 928757e9) packages the ingress
and fallback age fix, retaining the low-rate media library from 2164. Production
Rust features, unchanged generated Rust FFI contract, ARM64-only APK,
raw/staged/merged/stripped/packed libraries, 92 production media exports without
stand hooks, and the full installed APK hash were verified. Blackview reached
ready real-stack startup with no active call; after closing, its processes and
owned API forward were independently verified absent. Poco is still absent
from ADB; its signed 2166 APK is prepared. Physical loaded calls, recovery under
mobile-network stalls and playout/acoustic measurements remain pending.

### Retain native media freshness in the SDK IPC writer

Direct and sealed-relay native pumps now pass their original 200-ms producer
deadline into the SDK. Previously, after acquiring the shared sender handle,
the datagram entered the SDK's 1024-frame FIFO as bytes without an age limit;
IPC backpressure could replay obsolete audio/video even though the native
pump's own queue had already enforced freshness. Only timed media admission
can expire while awaiting capacity. The background writer checks each whole
timed frame immediately before writing, including frames already drained into
its local batch. A started partial write finishes under the existing socket
timeout, preserving IPC framing. Reliable frames carry no producer deadline
and keep FIFO/backpressure semantics. The deadline is process-local metadata;
IPC payloads, network formats, crypto and neutral relay scheduling are unchanged.
This bounds uncommitted SDK work, not bytes already accepted by a socket or
end-to-end acoustic delay. Anonymous media continues using its existing native
deadline checks and circuit path rather than these SDK IPC methods.

Gates: 38 SDK unit tests, 27 real Unix IPC integration tests and 27 native
media-pump tests passed, along with production SDK/FFI Clippy with warnings
denied and Android ARM64 Rust compilation. A real writer task over a bounded
byte stream verifies completion of a partial header/body, expiry of later
primary and secondary cells, reliable/fresh delivery, FIFO and clean EOF.
Disabling its pre-write expiry check delivers six frames instead of the
expected four, replaying both stale cells. The real IPC daemon verifies direct
wire bytes and sealed-relay fields/source queues against the legacy APIs;
only per-send random content ID and creation time are normalized for relay
comparison. Expired admission is followed by a reliable ordering barrier.
Two-phone loaded calls and physical playout/acoustic quality remain pending.

Android standard debug 2167 (source 51798828, Veil 1c812f86) packages SDK IPC
media expiry and retains the production low-rate media library from 2164.
Production Rust features, unchanged generated Rust FFI contract, ARM64-only
APK, raw/staged/merged/stripped/packed libraries, 92 production media exports
without stand hooks, and the full installed APK hash were verified. Blackview
reached ready real-stack startup with no active call; its processes and owned
API forward were independently verified absent after closing. Poco remains
absent in ADB; its signed 2167 APK is prepared. Mobile-network load/recovery
calls and physical playout/acoustic measurements remain pending.

### Keep P2P file opens independent of the chat sender

P2P file opens now use a dedicated SDK client, writer and FFI app sender.
The previous call used the ordinary chat app handle: `veil_stream_open` holds
its AppSender mutex while waiting for the remote receipt, which also blocked
`veil_send` on that handle. Node-side stream opens already run off the IPC
request loop; the reproduced bottleneck was this caller-side mutex. The new
sender binds the same `xveil/inbox` app identity at local endpoint 16. Opens
still address the peer's chat endpoint 0, and incoming streams stay on the
existing identity/device inboxes. Connection failure and transport disposal
close the added binding and client. Anonymous streams retain their existing
hub/circuit ownership. Audio/video already have separate IPC sender clients.
No service role, deadline or sender endpoint is added to stream wire bytes;
relay policy remains neutral.

A real C-FFI/SDK/Unix-IPC test holds the remote AppOpen receipt outstanding:
the shared-sender negative control blocks chat, while the dedicated sender
delivers it before the receipt is released. Source app IDs and complete
AppOpen network frames match across both variants; chat uses its original
source class and payload. Streams, clients, the server and bridge registrations
are closed after each variant. That test, FFI test-target Clippy with warnings
denied, 33 focused Flutter tests and transport analysis passed. This verifies
local sender isolation, not physical call delay or file authorization from a
previously unknown device. ADB currently exposes only Blackview; physical
two-phone loaded calls and playout/acoustic measurements remain pending.

Android standard debug 2168 (source 96532867, Veil 6bf4dfbd) packages the
dedicated P2P file sender. Veil changes this cycle are test-only, so it retains
2167's production Rust binary and 2164's production media binary. Production
Rust features, FFI header contract, ARM64-only APK, raw/staged/merged/stripped/
packed library hashes, 92 media exports without stand hooks, and the complete
installed APK hash were verified. Blackview reached ready real-stack startup
with no active call. Its processes and owned API forward were independently
verified absent after closing. Poco remains absent in ADB; the signed 2168 APK
is prepared. No new physical call or acoustic result is established.

### Continuous mixed-load verification and remaining live checks

A ten-second encrypted QUIC check now combines 50 primary cells/s, compact
secondary cells at 2/s and a continuously pending 4 MiB reliable writer over a
neutral 1 Mbit/s FIFO with 20-ms one-way propagation. It uses the current
endpoint reliable admission budget and verifies that secondary payloads and
file bytes actually arrive, rather than merely being submitted. Its final
run received all 500 primary cells without duplicates, all 20 secondary cells,
and 91,136 file bytes with checked contents; primary p95 was 124 ms. The file
remains incomplete in this interval: background throughput gives way to the
primary source. The fixture checks transport delivery, not native Opus playout,
full SessionRunner integration, adaptive video actuation or acoustic quality.

Disabling only reliable admission in that same ten-second fixture admitted the
whole 4 MiB writer, received 460/500 primary cells and raised p95 to 333 ms;
the quality assertion failed. The exact source was restored afterwards. The
older ignored characterization still fails with unbounded reliable admission
and 100 secondary cells/s (72/100 primary received, p95 467 ms). It remains a
negative characterization, not a claimed passing load gate. The backlog test
group passes six checks, with those three manual characterizations ignored.
Session library/test-target Clippy also passed with warnings denied. This
cycle changes only test fixtures and documentation; installed 2168 production
binaries remain applicable, and no phone app or log reader was launched.

Completion still needs current-build physical calls on Blackview and cellular
Poco: sustained simultaneous file/video traffic, native remote-audio feedback
and playout measurements, reconnection, group receiver coverage, and actual
first-hop independent-flow negotiation. The last physical observation used
older binaries and reported `independent=false`; local opaque-QUIC tests do
not establish deployment support. The previous device-owner file stream
authorization denials also remain unresolved and must not be bypassed to
make a load test pass. ADB still exposes only Blackview. No physical acoustic
claim or complete-goal claim follows from this transport fixture.


### Two-phone 2168 checks and incomplete IPC diagnostics

Both Blackview and Poco returned in ADB. The signed standard 2168 APK was
installed on Poco without clearing data, and its entire installed APK hash was
verified. Poco's default network remained cellular. One cold Poco-to-Blackview
audio offer arrived 93.9 seconds after its timestamp and was discarded after
the caller's 75-second ringing timeout; cancellation arrived first. Subsequent
calls rang in 2.6–5.8 seconds and became active in 4.0–7.3 seconds. Those are
separate observations, not evidence that cold signaling is fixed.

A 150-second Poco-to-Blackview video call used relay fallback after NAT
signaling timed out. During an attempted 8 MiB file download, all Blackview-to-
Poco media receive counters stopped for approximately 38 seconds while the
reverse direction and both local transmit counters progressed. Blackview's
engine counters reset twice, but neither reset immediately restored reception.
The file attempt failed with HTTP 409 after 71.6 seconds: Poco recorded 108
stream authorization denials for an unmapped requesting device. No complete
file was exported or hash verified. This is an attempted-load reproduction,
not a successful sustained simultaneous file/video delivery test. Authorization
must not be weakened to make the fixture pass.

Two further 120-second Blackview-to-Poco calls without a file did not reproduce
the 38-second outage or reset either engine. The audio-only median native delay
was 391/200 ms (Blackview/Poco), and video-call median was 446/215 ms. Receive
ages still reached roughly 7–8 seconds for audio-only and 4–6 seconds for video.
These are native counters, not acoustic measurements. Both calls remained on
relay fallback; no actual independent first-hop negotiation event was captured.

Existing IPC diagnostics hid expired admission (Ok(false)), expired mutex
waits and frames admitted to the SDK but discarded before their socket write.
Relay diagnostics now record failed admission, all sender waits and those later
writer expirations. The last counter is a process-local Arc shared with the SDK
queue item; it adds no IPC fields, C ABI fields, network labels, scheduling or
relay privileges. The original Rust send API remains available without tracking.
A real 13-byte buffered IPC writer check verifies one tracked admitted-but-
expired cell is counted, fresh data and reliable FIFO are preserved, and failed
admission is not counted twice. Its two tests and the 30 focused FFI media pump/
network tests passed. These counters do not establish end-to-end delivery or
cover every later transport/receiver discard.

All owned calls, applications, API forwards, log readers and plaintext fixtures
from these stands were closed/removed. Both phone process lists and the absence
of owned forwards/readers/fixtures were independently checked. Physical sound
quality, the cold offer delay, the one-way media outage, successful bulk-file
authorization/delivery and the remaining group/reconnect scenarios are unresolved.


### Android 2169 physical receipt and successful file direction

Standard debug 2169 (xVeil 0907e39c, Veil 3d8ecee7) packages the corrected relay
IPC diagnostics. Production Rust features and warnings-denied library Clippy
passed; generated Rust FFI contract, ARM64-only APK, raw/staged/merged/stripped/
packed libraries, 92 production media exports without stand hooks, and both
complete installed APK hashes were verified. Native media remains 2164's
unchanged production binary. Both phones reached ready real-stack startup;
Poco's default transport was verified cellular.

Poco-to-Blackview audio rang at 5.94 seconds and both endpoints became active
at 8.37 seconds. In its 45-second active interval, native audio delay medians
were 141/203 ms (Blackview/Poco), but receive ages reached 15.55/15.98 seconds.
Both receive counters paused while native audio transmit packet counters
continued advancing (roughly 50 packets/s); this was not merely an idle
DTX interval. No engine reset or repair event occurred. Updated SDK admission/pre-write expiry counters stayed
zero, sender mutex waits were 0 ms, and observed IPC admission maxima were
0/1 ms. This narrows the measured caller-side wait hypothesis; it does not
exclude node/session/relay/receiver loss or establish acoustic quality.

The next Poco-to-Blackview video call rang at 6.13 seconds, became active at
7.95 seconds and remained active for 165 seconds. A reversed file direction
(Blackview to Poco) successfully exported all 8 MiB during that call in
63.4 seconds, with the full-file SHA-256 verified. Its plain-file fallback
succeeded; P2P stream opens still failed, so this does not establish successful
P2P stream authorization or resolve the previous Poco-to-Blackview denials.
No native counter reset occurred. Video targets were 45 kbps at 1.2 fps, with
202 transmitted frames per phone and 141/188 decoded remote frames. Native
audio delay medians were 350/362 ms, receive ages peaked at 4.55/3.29 seconds,
and IPC admission maxima were 2 ms with zero tracked expirations/failures.
The earlier 38-second outage did not recur in this run; this is not proof it
is fixed. The native playout counters are not acoustic measurements.

Captured production QUIC events include actual relay forwards on local slots
0 and 2 with independent=false. Negotiated sessions reported opaque_flows=false
and independent_available=false; separate opaque connections were therefore
not demonstrated on these observed links. NAT signaling again timed out and
both calls used relay fallback. Endpoint exchange knew two peer endpoints on
each phone; no addresses or identity IDs were persisted in the status receipt.
This does not identify which remote deployment needs updating or make all
observed relay sessions equivalent. Relay queue policy remains neutral.

All owned downloads were cancelled only by their fixture content ID after the
call, and absence from both pending queues was checked. Both applications,
forwards, readers and the two plaintext fixtures were closed/removed, followed
by independent process/forward/reader/fixture checks. Both phones retain 2169
and their identities/data. Physical network gaps, cold-call signaling, P2P
establishment, reverse-direction file authorization, group/reconnect tests and
acoustic quality remain open.


### Paused publish experiment and origin path diversity

A five-minute standard-2169 audio call with existing RT trace enabled compared
90 seconds of normal publication, 120 seconds of temporarily paused DHT/ad
publication, and 90 seconds after restoring it. Blackview/Poco maximum receive
ages were 3.38/9.72 seconds before pause, 1.01/1.01 seconds while paused and
1.37/4.55 seconds after restoration. This suggests a background/path interaction,
but does not prove publication is the sole cause; no production publication
policy is changed. Both diagnostic switches were reset before applications
were closed and their process/forward/reader absence independently verified.

Matching authenticated sealed-cell epoch/sequence samples across the phones
showed median sender-to-receiver intervals of 133 ms Blackview-to-Poco and
95 ms Poco-to-Blackview, with maxima 16.74 seconds and 1.35 seconds respectively.
ADB clock midpoint offsets were -147/-154 ms relative to the host, with 73/52 ms
request intervals; clock error cannot explain the long observed tail. This
probe uses sparse matching cells, not acoustic timing or a claim that every
packet exits its sender at the instant of the FFI admission log.

The relay sender previously stopped after the first local queue admission even
when that hop never delivered promptly. Small (at most 512-byte ciphertext)
locally primary presealed lossy sends now try up to two distinct first hops.
Both copies retain exactly the same encrypted payload and content ID, so the
existing recipient replay/dedup gates accept the earliest arrival once. Secondary,
background and oversized cells keep one copy; call lifecycle controls retain
their existing three-hop bound and ACK sends retain their original single-hop
semantics. No labels, priorities, capability bits, service roles or fields are
added to network packets. Relay queue policy remains unchanged and neutral.
This origin redundancy can approximately double bandwidth for the covered
small cells; it is not an independent-flow negotiation or P2P fix.

The relay send tests cover successful admission at the preferred hop while a
second copy reaches another hop, a bounded copy count, exclusion of the final
peer as a relay, matching ciphertext/content ID and unchanged network header
flags. Twelve relay checks and warnings-denied production FFI Clippy passed.
Current-build physical quality verification follows separately; no improvement
is inferred merely from these caller-side tests.


### Current-device regression and nonblocking call offers

Standard debug 2170 (Veil 9f120ffc) exercised two 120-second audio calls
and a 165-second video call with Poco on cellular and Blackview on its
existing network. No receive-counter reset or local media rebuild occurred.
Maximum audio receive ages were 3.58/9.71 seconds in the Poco-originated call
and 5.88/6.46 seconds in the reverse call (Blackview/Poco respectively);
origin path diversity has not eliminated the physical gaps. Median native
audio-delay counters were 224/319 and 370/316 ms. These are not acoustic
measurements. The reverse-direction 8 MiB fixture download timed out after
120 seconds without an authenticated full-file result; neither phone logged
a stream authorization denial for this fixture. This failure remains open.
Both fixture content IDs were cancelled and absent from pending queues before
apps, forwards, readers and plaintext fixtures were removed. Independent
process/forward/reader checks confirmed cleanup. Identities/data were retained.

Outgoing direct calls now send their permitted transport proposal before
waiting for P2P endpoint preparation. Endpoint preparation runs while ringing;
its late result cannot change a newer or already accepted call. The proposal
expresses consent, while callee policy/reachability checks and native admitted
session checks still gate actual P2P. Anonymous calls do not prepare P2P.
A missing direct session continues to fall back to relay. This removes the
previous up-to-five-second wait before the initial signal, not all network
latency. 110 call, wire, slot and policy/fail-closed checks and focused analyzer
passed; current physical validation follows separately.


### Origin transport choice under ordered-write stalls

RT trace in the 2170 regression recorded Poco socket writes lasting up to
6.52 seconds and local realtime queue writer blockage up to 3.11 seconds.
Sparse matching authenticated cells had maximum sender-admission/receiver
intervals of 2.81 seconds Blackview-to-Poco and 4.66 seconds in reverse.
The shorter matched maxima do not bound unsampled receive gaps.

Origin presealed lossy routing now prefers candidate first hops whose
current runner has a usable generic QUIC datagram sender. It preserves
existing route order within each transport group, fallback candidates and
copy bounds. This avoids selecting an ordered writer before an available
datagram link. A generation-scoped lease expires when the sender is disabled,
on stream replacement and runner exit; generic availability is separate from
independent-child availability. It does not claim independent support for
legacy links, change relay queue policy or label application roles on wire.
Three readiness lifetime checks, 16 relay checks, 368 session checks
(three ignored), and warnings-denied production FFI Clippy passed.
Real-network validation of this choice follows separately.


### Sovereign identity NAT responder address

The NAT dispatcher previously classified a token-bearing request addressed
to its own sovereign identity as a foreign forwarding target when the
transport device ID differed. It now also accepts the identity from the
runtime's current local-recipient lookup. The request still passes existing
quota, token and asynchronous socket-worker gates; reply/device keys,
cryptographic admission, forwarded-byte preservation and wire formats are
unchanged. Identity claims in remote messages do not grant this alias.
The lookup is evaluated per request, so a retired identity is immediately
foreign again. Twelve NAT tests, including current identity/device acceptance,
foreign forwarding and retired-identity rejection, plus warnings-denied
production FFI Clippy passed. This does not establish P2P convergence through
older remote coordinators or permissive carrier NAT.


### Answer signaling before the NAT ladder

Standard 2171 produced incoming rings at 1.09/1.41 seconds; active media
was observed at 8.08/4.31 seconds (Poco/Blackview origin). Standard 2172's
audio-only maximum receive ages were 1.58/1.97 seconds and 3.40/3.68 seconds,
but video plus the original-direction file fixture reproduced 15.20/20.75
second gaps with one Blackview media rebuild. The full-file fallback failed
and the source logged 42 unmapped-requesting-device denials. Those defects
remain open; transport preference alone is insufficient.

Accepting a permitted P2P proposal no longer waits for the full reachability
ladder before sending the answer. Both proposals express mutual policy
consent; the existing native admitted-session check is the authoritative
gate for opening P2P. Its failure selects the permitted relay route and
announces that actual transport to the peer. Anonymous and policy-denied
calls retain their existing route restrictions. A never-resolving probe
regression verifies immediate answer, actual relay fallback announcement
and no change from a late false result. 107 call/native-route/wire/fail-closed
checks and focused analysis passed. This is a setup fix, not evidence that
loaded acoustic quality or carrier NAT convergence is solved.


### Own background budgets across the node's links

The local primary write-ahead guard was formerly scoped to the same session
that carried its primary producer. Own background writes on the other links
kept the ordinary multi-blob allowance, despite sharing the endpoint's radio.
Session outboxes belonging to one registry now share a three-second local
producer activity window. The same existing 4 KiB/empty-writer admission guard
therefore applies to this node's own bulk/background ordered writes on its
other links too. Whole-frame progress, transit INTERACTIVE FIFO/admission and
the previous allowance after producer expiry remain intact; another node's
registry is unaffected. Activity comes only from a local primary lossy/circuit
source, not remotely asserted priority or relay traffic. There is no new
wire field, remote role, relay priority request or audio classification.
369 session checks (three ignored) and warnings-denied production FFI Clippy
passed, including cross-link sharing, transit isolation, distinct-node
isolation and expiry. Physical validation of competing loads remains pending.


### Peer fallback arriving during initial media setup

Physical standard 2174 exposed a real setup race: Poco's native P2P open
failed fast to the permitted relay and announced transportInfo while
Blackview's controller was still awaiting its device-status lookup.
Switching at that point found no active call/session, returned false and
ended the call. The reverse call reached active relay media in 2.55 seconds.
Endpoint exchange settled on both phones, but neither canonical identity nor
physical device had an admitted P2P session at the final check. Thus the NAT
identity responder fix has not established physical P2P convergence.

The call FSM now remembers a peer relay fallback during connecting and applies
it after the bounded initial controller start returns. It follows a completed
P2P attempt, or retains an already opened relay without rebuilding. A setup
timeout still ends the call: an unresolved underlying future is not a session
that may safely be switched. Tests cover deferred switching, failed initial
attempt recovery and a never-returning start with pending fallback plus a late
success. 108 focused call/native-route/wire/fail-closed tests and analysis
passed. Both 2174 app processes and forwards were independently absent after
the stand; new setup/load verification follows separately.


### Physical 2176 regression and residual delayed audio

Both phones retained their identities on standard 2176 (xVeil b011b053,
Veil 5d6671eb). Two 60-second audio calls and two 165-second video calls
completed without engine rebuild or call termination. Incoming rings were
0.22/4.45 seconds for audio and 1.01/0.40 seconds for video; observed active
setup was 2.86/5.55 and 2.85/2.51 seconds, respectively (Poco/Blackview origin).
Receive ages stayed below 3.42 seconds, but this is NOT an acoustic-quality
pass: matched sealed-cell samples in the last Blackview-to-Poco leg still
arrived up to 9.54 seconds late while receive counters progressed. Native RTT
reached roughly 8.6/10.8 seconds there. A growing receive count does not prove
fresh sound. Cross-call idle ingress-spacing windows are not call outages.

Both 8 MiB downloads failed with HTTP 409 (77.93/115.40 seconds) and source
stream authorization denials; neither exported file was hash verified. This
is attempted competing traffic, not a successful full file/video load gate.
Neither phone had an admitted identity/device P2P session at the final check.
Captured Poco first-hop QUIC links still reported opaque_flows=false and
independent_available=false; no Blackview independent-hop event was captured.
Owned apps, API forwards, trace readers and cache fixtures were independently
absent afterwards. Poco stayed on cellular.

### Video reserve after confirmed multi-second audio congestion

The ordinary video floor could still spend 45 kbit/s with multi-second RTT.
After two confirmed severe samples at that floor, a native engine supporting
fractional cadence now receives a 1 kbit/s, 0.02 fps video budget. This retains
capture/preview and incoming video while reserving local sending capacity for
audio. Unknown or expired feedback cannot activate this mode by itself or
clear it. Twelve consecutive healthy samples restore only the ordinary sparse
floor; later recovery continues through the existing ladder. Older native
engines keep their representable integer budget. This changes endpoint video
production only, with no relay instruction, wire field or remote priority.
37 adapter checks and focused analysis passed, including delayed/expired
feedback, confirmed remote playout, bounded recovery and old-engine behavior.
Physical validation of this new budget remains pending; source authorization,
P2P convergence and actual independent-hop deployment remain unresolved.


### Physical 2177 reserve and remaining congestion

Two 165-second video calls completed on both standard 2177 phones without
engine reset. The new native video reserve actually applied (1 kbit/s rather
than 45 kbit/s) during the Poco-origin call, but audio receive ages still
reached 3.85/9.58 seconds (Blackview/Poco). Matched ciphertext samples reached
6.27 seconds Blackview-to-Poco and 2.91 seconds in reverse. The opposite call
had ages below 1.61/1.40 seconds and did not need reserve. This variable real
network result does not establish a causal acoustic-quality improvement.
Neither 8 MiB file completed within 120 seconds; source authorization remains
unresolved on those installed binaries. P2P was still unadmitted, and captured
QUIC peers still negotiated no opaque independent flow. Owned processes,
forwards, readers and fixtures were independently absent after cleanup.

### Certified device evidence across relayed ratchet delivery

A contact is stored under its identity, while an anonymous file request names
its physical device. Ratchet delivery formerly surfaced a device only when the
outer envelope happened to differ from the opened identity; that outer hint
was explicitly not an authorization proof. A verified ML-KEM certificate now
retains its document signing subkey's certified transport device address.
The bounded ratchet key cache keeps this address beside the exact instance,
X25519 key and validity window. After AEAD acceptance, the device is selected
from that exact key while the ratchet entry is still locked, not from an
independently reread entry or the envelope. Missing, mismatched or expired
current evidence yields no device. The existing IPC origin-device slot carries
this verified address to the app, including when the outer sender already
names the canonical identity. Local reconstructed certificates have no such
proof. C ABI, ratchet persistence and network encodings do not change.

NAT probes can likewise address that verified physical device from the recent
certificate cache, while TLS/OVL1 admission still pins the original registered
identity. Missing, expired, stale, foreign or zero-device certificate evidence
retains the previous identity target. No endpoint/DHT address claim becomes a
membership proof. Anonymous refusal, quotas, token gates and relay neutrality
remain unchanged. 260 dispatcher, 121 E2E, 454 identity, 34 resolver and one
certificate-target tests passed, plus warnings-denied production FFI Clippy.
Tests include a relay rewriting the envelope's device, exact opened-key proof,
expired/mismatched evidence, and current/stale NAT targets. Phone verification
of file authorization, NAT connectivity and competing traffic follows.


### Physical Android call follow-up: build 2178 (2026-10-05)

Both real paired phones retained their identities; Poco used cellular data.
Two video calls ran for 165 seconds after activation. Poco-originated ringing
was 1.050 s, activation 4.615 s; Blackview-originated ringing was 0.491 s,
activation 3.167 s. The first call stayed on relay (one engine epoch); the second
used admitted direct P2P on both phones (one engine epoch). Native direct
sessions negotiated opaque independent channels and sent on local slots 0 and
2. A session becoming available after initial fallback did not upgrade the
already active first call.

Audio still had receive gaps: maximum accepted-audio ages were 1.533/2.637 s
on Blackview/Poco for relay and 3.681/4.916 s for direct. Maximum direct RTT was
969/810 ms; reported local playout estimates reached 834/1754 ms. These are
endpoint telemetry, not an acoustic end-to-end measurement. Direct admission
alone does not establish that the pauses are fixed.

Both simultaneous 8 MiB file attempts timed out after 120 s. The stand's source
was Poco in BOTH cases, regardless of the call direction: do not interpret
these as two-direction file coverage. Exported partials reached 2.5 MiB and
2.25 MiB. There were no recorded stream-server requests or authorization
denials; background chunk delivery progressed. Successful authorized reliable
stream transfer is therefore still unverified. Apps, forwards, log readers and
owned fixtures were closed/removed; independent ADB process checks found both
app processes absent.

### Late direct-call upgrade and direct-send timing (2026-10-05)

Call protocol v6 adds endpoint readiness using the existing encrypted
transportInfo signal. Original offer AND answer must consent to P2P; both
postures must be direct, both versions at least v6, local policy is checked
again, and local direct admission must succeed. Neither direct posture nor a
readiness frame alone grants consent. Each endpoint announces readiness,
repeated on heartbeat for loss recovery, and only rebuilds relay to P2P after
receiving the other endpoint's readiness. Native channel admission and media
sealing remain mandatory. Old peers retain the prior route behavior.

Only one upgrade attempt is allowed per call. Failed admission returns to the
permitted relay and announces fallback; peer fallback during a rebuild waits
for completion and suppresses further upgrades. Call/generation checks prevent
an old probe or switch resurrecting a hung-up/disposed call. Receive repair is
held while the switch owns the media controller. 128 focused call FSM, wire,
and sealed-channel checks passed; focused analyzer was clean. Physical upgrade
coverage is pending the next Android stand.

Native trace-enabled direct primary sends now emit the same sealed epoch/
sequence sample as relay sends. This local diagnostic allows send/receive
latency correlation on P2P; it changes neither the wire format nor relay
scheduling, and does not expose media keys. It is inactive without rt_trace.


### Route-control delivery and reliable-stream identity routing (2026-10-05)

The build-2179 phone stand exposed a missing integration detail in the v6
upgrade: all transportInfo signals previously shared one durable frame id.
The earlier relay fallback primed dedup, so later P2P readiness was silently
discarded even though both sessions became admitted. TransportInfo ids now
include sender timestamp and proposed kind; different transitions remain
separate even within one millisecond. The FSM ignores older timestamped route
information after a newer proposal. A regression passes fallback and readiness
through the actual MessagingService dedup pipeline (including a replay).
154 focused realtime/FSM/wire/sealing checks passed; analyzer clean. Physical
upgrade verification requires the next build; build 2179 does not contain this
follow-up.

Reliable stream opens independently returned code 6 (NO_SESSION) against
identity addresses despite admitted direct device sessions. IPC now resolves
an identity to ONE device from the verified live-session index before any
receipt/data registration. Only currently registered device peers are chosen;
an explicit device address, legacy identity session or unresolved address keeps
its existing destination. The selected physical peer keys the receipt waiter,
data bridge and subsequent stream frames; the original destination application
id remains unchanged. Streams never use identity fan-out. No DHT advertisement
or claimed outer sender establishes this mapping, and application content
access checks remain in force. A full open/receipt/data/close regression also
rejects another sibling's receipt and excludes a stale indexed device.
115 IPC tests passed (5 ignored); production-feature FFI Clippy with warnings
as errors passed. Physical file completion remains pending the next build.


### Repaired direct-call fallback must remain a successful repair (2026-10-05)

The Blackview-originated video call on build 2179 stalled and reproduced a
second independent teardown defect. Native direct admission disappeared during
receive repair; controller start restored the non-onion relay and logged
success, but _rebuildLocalSession returned false solely because the restored
route differed from the old P2P route. The FSM then sent end instead of its
already implemented transportInfo(relay) transition. Rebuild now reports a
successfully opened channel; the FSM retains responsibility for validating the
actual route against both postures and announcing the permitted fallback.
SwitchRoute still requires its requested route, so failed late upgrades retain
the separate failure handling. 151 focused FSM/sealed-channel/realtime checks
passed, including the existing peer-notified P2P-to-relay repair regression;
analyzer clean. Physical call survival is pending build 2180.


### Physical Android build 2180 and authenticated datagram liveness (2026-10-05)

Four real-phone calls ran with Poco on cellular: audio Poco/BV ringing
1.058/0.324 s, activation 5.019/1.393 s; video Poco/BV ringing 0.142/0.579 s,
activation 2.172/2.703 s. The audio upgrade was ATTEMPTED but native admission
failed at mount, so the first call stayed relay (epochs 1/3). A counter reset
alone is not proof of direct upgrade. The second audio and first video used
P2P; the second video stayed relay. Neither video call ended during its 165 s
observation, but the last relay call needed repair and Poco's accepted-audio
age reached 24.350 s. Full elimination of pauses remains unverified.

Both 8 MiB file directions now opened authorized direct streams and produced
server manifests, confirming the identity routing/authorization fixes on the
phones. Both still timed out at 120 s: partials reached 768 KiB and 3 MiB.
Source logs queued far more bytes than arrived. Acceptor remote STREAM_DATA
currently discards send_app_data's false result; source admission/backpressure
needs a separate follow-up. App processes, forwards, readers and owned
fixtures were independently closed/removed.

Poco's direct session to Blackview was reaped with the parent reporting
5.894 s of stale genuine data despite independently received data channels.
The realtime receiver did not update parent SessionTimers at all. A shared
per-session atomic monotonic receive timestamp now records only fully
AEAD-authenticated, replay-checked, eligible complete datagram frames. Parent
idle/probe checks consume the ACTUAL receive instant, never observation time.
Relay/circuit data proves ordinary liveness without enabling direct-session
acceleration. Monotonic timer updates cannot regress a newer ordered receive.
This changes no wire class, channel role, payload or relay priority.

372 session tests passed (3 ignored), 19 actual QUIC runner tests passed, and
production FFI Clippy with warnings as errors passed. A real bidirectional
independent-channel test keeps a parent alive for multiple idle deadlines while
its main writer is stopped, then verifies silence still reaps it and its child
connections. Disabling the production datagram-liveness handoff makes this
regression fail; the source was restored and the full QUIC subset rerun green.
Phone verification of this liveness fix is pending the next build.


### Late direct admission belongs to the answering device (2026-10-05)

Identity-level P2P readiness can name another live device and must not authorize
opening this call's direct channel. Late route upgrade now checks the native
admission of peerDevice (or the original peer for legacy calls) before every
readiness announcement and switch. Missing, failed or timed-out status leaves
the working relay channel intact; stale readiness is withdrawn locally.
Policy and mutual signaling consent remain required. The regression starts
with identity reachability but no answering-device admission, observes no
announcement or switch, then admits that exact device and observes the upgrade.
153 focused call/realtime/sealed-channel tests passed; analyzer clean.
Physical verification is pending Android build 2181, which also includes the
authenticated datagram parent-liveness fix.


### Reliable source backpressure across native scheduling (2026-10-05)

Remote stream DATA now awaits source admission on both opener and acceptor
sides. Each session has 64 endpoint-only reliable credits retained across
ingress and scheduler buffering; draining ingress cannot renew capacity or
shed already admitted stream bytes. Those entries share the existing local
BACKGROUND FIFO/WRR but are protected by their separately bounded credits.
Ordinary/transit capacity and wire INTERACTIVE headers remain unchanged;
relay frames cannot acquire these credits. Registry locks are released before
awaiting. A 30 s admission timeout reports failure instead of hanging forever.
Graceful OPEN/DATA/CLOSE use the same admission and lane. Disconnect/error
cleanup remains best effort and does not delay process teardown.

Acceptor remote DATA previously ignored false admission. Merely closing the
IPC local-pair table is also insufficient for a REMOTE inbound stream, which
has no entry there. Failure now releases ownership, attempts peer close and
explicitly notifies the originating SDK with STREAM_CLOSE. Native Unix IPC
regression covers that notification and rejects subsequent writes on the
released route. Capacity tests retain all 64 admitted frames through scheduler
overflow, block frame 65 even after ingress drained, keep primary ingress
independent, preserve FIFO and release stalled waiters on close.

374 session tests passed (3 ignored), 116 IPC tests passed (5 ignored),
19 actual QUIC runner tests passed; production FFI Clippy clean. Physical
file SHA verification under call load is pending Android build 2182.


### Physical 2181 and punched-runner registration lifetime (2026-10-05)

Build 2181 included authenticated datagram liveness and the exact answering
device readiness guard. All four calls stayed relay: the guard correctly
refused upgrades with no current direct admission. Cold Poco ringing still
took 34.151 s (activation 36.572 s). Reverse audio ringing/activation was
1.096/6.954 s. First video lasted 165 s but Poco's accepted-audio age reached
9.614 s; second video ended early after Poco audio silence reached 38.133 s.
Files did not complete, so this is not a successful load/continuity result.
Own failed downloads were canceled per case and final cleanup independently
verified both app processes absent and no forwards/readers/fixtures retained.
Tracing and publish-pause are SEPARATE flags; rt_trace does not pause DHT
publishing. The next driver explicitly clears publish_pause to avoid a stale
experiment setting.

Native logs repeatedly showed nat.udp_punch.session_registered immediately
followed by session.close of that same outbound link, BEFORE the runner's
datagram-enabled event. Rust precise async capture moved only referenced
AttachedDebugSession fields into spawn_punched_outbound's future; the
unreferenced _guard dropped at the function boundary. Its destructor removed
the session registration and sender, ending the direct connection before media
opened. The guard is now explicitly moved into, and retained by, the runner
future. This changes neither handshake proof nor admission/security policy.

The real spawn-boundary regression verifies registration before first poll,
during the runner, after transport close, and after cancellation BEFORE first
poll. Removing only the production guard ownership makes it fail at the
pre-poll admission assertion; the source was restored and rerun green.
Five hole-punch gate/single-flight tests passed; production FFI Clippy clean.
Physical verification of guard lifetime and source backpressure is pending
Android build 2182.


### Neutral forwarding and legacy relay compatibility (2026-10-05)

The source still emitted a REALTIME Forward trailer and a default zero wire
priority. Current relays ignored the requested queue priority, but older
relays could honor it. Forward source headers are now INTERACTIVE regardless
of local endpoint scheduling. Forwarders normalize legacy REALTIME trailers
to the neutral INTERACTIVE transport hint, omit other queue hints, and emit
neutral headers on direct, cached-route and gateway paths. Retry/trace/hop
fields remain intact. This carries no audio/video role and requests no faster
relay queue. Existing short-lived, unacknowledged, bounded datagram checks
still apply.

A new capability extension explicitly negotiates decoding of neutral forwarded
datagrams. Peers without it receive those frames through the existing ordered
transport. A real QUIC regression verifies endpoint payload delivery with the
ordered writer stopped only when negotiated, and actual ordered delivery for
legacy peers when the writer runs.

Build 2182 physical verification was interrupted by Blackview USB loss before
ringing; no media result is established. Poco was closed immediately. After
Blackview returned its remaining test process was force-stopped and independently
verified absent. Readers/forwards were removed; no file fixtures were created.
Phone verification continues with build 2183.

Verification: 825 protocol, 116 IPC (5 ignored), 374 session (3 ignored),
260 dispatcher, and 20 real QUIC runner tests passed; production FFI
Clippy with warnings as errors passed. Physical build 2183 remains pending.


### Physical 2183 and blocking direct-stream Dart writes (2026-10-05)

Both whole installed APK hashes were verified. Poco remained cellular.
Punched P2P registration now survives and the cold call successfully upgraded
from relay onto independent direct media connections. Cold ringing/activation
still took 14.434/17.100 s; reverse audio took 1.402/2.426 s. Both audio calls
remained active for a minute, but accepted-audio ages reached 1.810 s and
3.752 s; this is not a clean continuity result. First video stayed active for
165 s and its Poco-to-Blackview 8 MiB file passed the full exported SHA-256
check in 84.12 s. Audio still had a 6.334 s receive-age sample and a 1.969 s
playout-delay sample. Reverse video started in 0.337/1.465 s but Blackview's
call-state API stopped responding after download started; that case is
incomplete and cannot count as a successful reverse transfer or call soak.
Native sealed media continued while the Dart API stalled, distinguishing this
from USB loss or immediate native P2P connection death.

VeilStream.write wrapped a potentially blocking Rust block_on/write_all in
Future(), which still runs on the caller isolate. Reliable native source
backpressure exposed that assumption. Direct stream writes now run on worker
isolates, with 16 bounded workers and a FIFO gate per stream to preserve byte
invocation order. Reads remain independent. A queued write rechecks close
before entering native code; native generational handles/Arc lookup preserve
in-flight safety. No transport admission or authority policy changes.

The actual Dart FFI regression uses a small ABI-matched test-only C fixture
whose native write waits for a Dart timer to release it. It verifies a live
event loop, FIFO bytes and rejection after close. Replacing only Isolate.run
with Future makes the regression fail at the native bounded wait; the fixed
source was restored and rerun green (2 tests passed, 1 existing live-daemon
skeleton skipped). Analyzer clean. Both phone app processes, own readers and
forwards exited after 2183; four own fixture paths were removed. Blackview's
API cancellation timed out before force-stop, so do not claim API cleanup on
that phone was confirmed. Physical verification continues in build 2184.

For remaining direct media losses, opt-in rt_trace now counts per local slot
accepted datagrams, complete-frame buffer admission drops and outbound cap
drops, logging at most once per second per slot. It adds no wire role or queue
priority, and never logs media plaintext or keys. It distinguishes source
admission loss from transport/receive loss; disabled tracing does no counting.
20 real QUIC runner tests and production FFI Clippy passed. Android build 2185
is prepared for these measurements after the ongoing 2184 stand ends.

### Physical 2184 follow-up (2026-10-05)

Both minute-long audio calls and both 165 s video calls remained active.
All calls used direct media; native independent primary and secondary sends
were observed. Cold audio ringing/activation was 1.235/4.133 s, reverse audio
0.633/1.837 s; video Blackview-to-Poco 0.951/2.390 s and reverse 1.024/2.182 s.
Blackview's API remained responsive during source backpressure, validating the
Dart worker fix. Accepted-audio ages still reached 4.484 s on audio-only and
3.996 s on video; pauses are not fixed. Both 8 MiB downloads timed out at
120 s with no verified hash. Sources queued ~2.3/2.8 MiB into SDK/native queues
then hit the 30 s payload-write deadline. Actual exported progress was much
lower, so queued bytes are not delivered bytes. The current 1 KiB canonical
reliable admission during local primary activity is a candidate for this
remaining file slowdown, pending controlled measurement; do not call it proven.
Both own pending downloads were canceled, both app processes independently
verified absent, own readers/forwards exited and four fixture paths removed.

### Physical 2185 admission evidence and signaling isolation (2026-10-05)

Two 30 s audio probes and one 165 s Blackview-to-Poco video call stayed active;
accepted-audio ages stayed at or below 1.022 s in this shorter campaign.
This does not supersede the longer earlier pauses. The file again timed out
at 120 s without a verified hash. Opt-in counters recorded 13,807 source-slot-0
admissions and 1,705 complete-frame buffer admission drops on Poco, versus
13,569/339 on Blackview; neither endpoint recorded outbound-cap drops. Counts
are admission observations, not proof of packets delivered on the network.
Both pending downloads were cleared, both app processes independently verified
absent, own forwards/readers exited and two fixture paths removed.

The FFI signaling API already stamps the XVSG application discriminator, but
used the same local source slot as native audio. It now selects local BACKGROUND
for its loss-tolerant datagrams, obtaining the separate generic source channel.
Native media keeps its explicit primary/secondary source choices. The wire
AppRtData classifier and payload are unchanged; the source choice is stripped
at the IPC encoder and no relay receives an audio or signaling queue role.
A test using the actual C entry point, SDK and Unix IPC server captures local
BACKGROUND, legacy wire priority zero with no IPC lane bits, and unchanged
application bytes/address/endpoint. It passed; production FFI Clippy and the
Dart blocking-write/FIFO regression passed. The C ABI signature is unchanged;
regenerated header documentation updated the matched Rust/Dart contract hash.
Phone verification of this isolation proceeds in build 2186.


### Physical 2186 and independent reliable admission (2026-10-05)

The full campaign completed: two 60 s audio and two 165 s video calls.
The cold Poco offer rang after 34.054 s and became active after 36.157 s;
warm calls rang in 1.362–4.450 s. Maximum accepted-audio ages were
5.415/5.523 s during the first audio call, so pauses remain unresolved.
Blackview-to-Poco 8 MiB transfer passed the complete SHA-256 check in
65.86 s during video. The reverse transfer timed out at 120.21 s, with only
786,432 bytes in the actual receiver export. Both own downloads were cleared;
both app processes were independently absent and own forwards/readers/fixtures
removed. Signaling isolation does not establish either file or audio quality.

New reliable-write admission now checks the selected, prepared independent
primary connection. When present, the canonical reliable send window remains
bounded to 16 KiB instead of retaining the shared-connection 1 KiB limit.
If preparation fails, the shared bound is immediately selected for new writes;
already accepted bytes cannot be retracted. Transit frames cannot select this
endpoint policy. This introduces no relay queue role or wire discriminator.
An actual QUIC admission test checks file progress, bounded acceptance and
return to the shared limit; it deliberately does not assert media quality,
because that fixture supplies readiness and shares its connection. All 375
session tests (three ignored), 20 real QUIC tests and production FFI Clippy
passed. Physical quality verification proceeds in build 2187.


### Outbox record capacity and interrupted 2187 campaign (2026-10-05)

During 2186, endpoint announcements reached ~4 KiB and their base64-enveloped
outbox records threw `HvException.PayloadTooLarge`. Log batching splits batches,
not an individual incompressible record. Large serialized outbox rows now use
1800-byte parts plus a bounded descriptor (length, range and SHA-256), with all
parts, index and allocator counter in one native commit. Existing small rows
remain readable. Restart cleanup preserves live parts; recipient-bound ACK
removes them together. Missing or replaced parts never become a modified wire
frame. Envelopes remain unchanged on the network and inside the encrypted store.
The serialized row is bounded to 512 KiB and remains below native batch limits.

132 storage/outbox regressions and analyzer passed. A real hidden-volume test
with the current macOS bundled library confirms an incompressible single row
below the nominal 8 KiB limit is refused, then checks fragmented 16 KiB wire
persistence across a true close/reopen and recipient-bound ACK cleanup.

2187 did not establish either cold call and did not receive the file offer;
there is no physical quality result for the independent reliable-window change.
Native logs show route discovery misses and Poco rejecting six packets for a
missing ratchet conversation; this is evidence to investigate, not proof that
ratchet persistence is their cause. Both apps independently absent, own forwards,
readers and fixture removed; own pending downloads cleared. Further campaigns
must retain startup ratchet diagnostics along with call/content logs.


### Partial ordered frames stall independent sources (2026-10-05)

2186 shows both endpoints continuing native media submission while the parent
runner waits 6.4–6.5 s for an ordinary body, alongside a 7.074 s ordered write.
The runner selected only the first header byte, then awaited the remaining
header, inbound-memory reservation and body outside its scheduling select.
Thus independent QUIC sender connections still depended on a blocked parent
loop to dequeue new source frames.

Ordered reads now retain partial header/body cursors inside the select.
Cancellation preserves exact bytes, the node-wide body permit and absolute
body/budget deadlines; outbox and source-channel scheduling continue meanwhile.
Real body progress updates liveness without classifying transit traffic as
local media. A replacement stream during a partial frame closes the session
rather than discarding encrypted bytes under an unchanged implicit nonce.

Two tests with actual runners and independent QUIC connections deliberately
leave both parents with incomplete headers or bodies. Both fail on the old
runner (zero independent progress) and pass with the reader fix. Three reader
tests verify repeated cancellation, exact consecutive frames, the unchanged
body deadline and size rejection before reservation/allocation. The final
378 session tests (three ignored), 102 runner tests (one ignored), and
production FFI Clippy passed. Physical verification proceeds in build 2189.

2188 restored four ratchet conversations on Poco and one on Blackview, all
accepted; the missing-conversation replies in 2187 do not by themselves prove
that persistence lost state. No PayloadTooLarge was observed after the outbox
fix. Both 60 s audio and 165 s video calls stayed active through relay, with
no direct admission during this campaign. Cold rings took 19.198/16.027 s;
maximum accepted-audio age reached 7.711 s. Both files timed out at 120 s,
with actual partial exports of 2.5/4.5 MiB, so no full-hash success is claimed.
Both own app processes absent, own downloads cleared and forwards/readers/four
fixture paths removed. Earlier P2P results are separate route evidence.

### Physical 2189, resumed relay context and native audio timing (2026-10-05)

Both phones remained available; Poco used cellular. Both 60 s audio calls
and 165 s video calls stayed active. Cold Poco → Blackview rang in 18.425 s;
the reverse warm call rang in 0.505 s. Video rings took 0.272/1.133 s.
Poco → Blackview's 8 MiB file passed the complete export SHA-256 in 74.78 s.
Blackview → Poco reached 7,602,176 actual export bytes before the diagnostic
120 s deadline; it did not pass a full-hash check. The timeout alone does not
show stalled transfer: the partial export continued growing. P2P became
available in the first audio call and carried subsequent calls.

The old audio-age field samples packet counts on a one-second Dart timer.
It reached 2.6–2.9 s under load, sometimes while a newer diagnostic snapshot
already showed more accepted audio packets. These maxima are not exact native
arrival gaps. Native audio delay reached 2.3 s in one sample; physical audio
quality is not yet established as free of interruptions. The media library
now exports the receive stream's last accepted RTP age using its native clock,
concealed samples/events and interruption count/duration. Dart liveness uses
the native timestamp when present; unknown/worker-timeout samples remain
unknown, and older libraries retain the counter fallback. Actual WebRTC tests
verify age growth with RTCP-only ingress; 128 Flutter checks and analysis pass.

The cold trace shows a missing-conversation reply at startup, followed by
authentication failures and a second signed reset. Imported conversations
use identity addresses, while relayed envelopes name physical devices.
Until ephemeral verified certificate/session caches warm up, a valid bare
frame could be looked up under the physical address and spuriously return
NoSession. A unique held conversation matching both local/remote instances
now supplies only the decryption context for bare frames. AEAD verification,
certificate expiry, origin-device verification and route authority remain
required. Ambiguous contexts fail closed. A dispatcher restore/relay test
fails on the old resolver and passes with the fix; an expired-authorization
test still reports unproven packet authorship. The 122 E2E, 261
dispatcher and four integration tests pass. Phone verification of this
context fix and exact audio timing proceeds in build 2190.

Both 2189 app processes independently absent after cleanup; own forwards,
readers and four fixture paths removed, own pending downloads cleared.

2190 completed with both phones on their original networks. Cold Poco →
Blackview rang in 1.077 s and became active in 2.946 s; reverse warm audio
took 0.485/1.748 s. Both 8 MiB exports passed full SHA-256 (84.10/83.74 s).
All calls remained active. Exact native timing confirms remaining audio
interruptions: the second audio call has 13/16 NetEq interruptions, 11.284/
11.432 s total, and maximum sampled native packet ages 1.102/1.195 s. These
are receive-stream concealment measurements, not an acoustic latency test.
The first audio call has one startup interruption on each end (261/286 ms).
The first video/load call reaches ~2.9 s native arrival gaps, so quality is
not declared fixed. The opt-in admission trace now additionally samples
actual generic QUIC RTT, congestion window, sent/received UDP, received ACKs,
losses and congestion events at the existing one-second cadence. This
separates admitted packets from transport progress, without wire changes or
relay source classification. Five actual QUIC transport tests and production
FFI Clippy pass. The next phone campaign uses build 2191.


Phone campaign 2191 and durable live-lane restoration (2026-10-05)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both phones remained on their original networks (Poco cellular). Cold
Poco -> Blackview rang in 0.194 s but caller activation took 20.747 s.
Blackview sent its answer promptly; the first four rapid retries already
raced ordinary/direct/relay realtime. Subsequent durable flushes, however,
used only the ordinary sender, including after restart. Re-drive now
restores call, group-call and endpoint-bootstrap live paths from the saved
wire kind after the existing relationship and TTL gates. Contact call
answers retain identity addressing. Frame-id prefixes cannot promote
ordinary content into realtime; mailbox eligibility remains unchanged.

A restart regression drops ordinary sends, restores an answer, delivers
it on realtime, deduplicates a repeated copy, and retires only after the
recipient ACK. The old implementation fails this regression. Blocked-peer
and actual-wire-kind tests cover the lane selection boundary.

2191 does not pass the phone quality gate: second audio native arrival
gaps reach 3.112/3.132 s; video/file load reaches 22.979/26.466 s. Poco's
independent primary QUIC path shows RTT around 2 s, few received ACKs,
congestion losses and a full ~4 KiB datagram queue. Blackview closes the
canonical stream on its body deadline and Poco reconnects later. These
are observed transport failures, not proof of a particular radio or
congestion-control cause. The file export did not complete before call
termination; the stand's bounded future wait expired. Reverse video/load
was therefore not run. Both started app processes, owned readers, forwards,
pending fixture downloads and two fixture paths were closed/removed;
process exit and fixture absence were checked independently.

Verification: 143 call-service/realtime tests pass and scoped Flutter
analysis is clean. The broader durable suite reports 5 offline-silence
assertion failures both with this change and with the unchanged HEAD
outbox (34 passing baseline tests). Its reconnect fixtures expect the
older silent-peer probe policy, whereas the current policy applies the
probe gate only to contact mailbox-eligible frames. These baseline
failures are recorded, not represented as a fully green suite.


Silent direct-path recovery and relay switch serialization
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Audio-only phone campaign 2192 completed both 120 s calls. Cold ring/active
times were 3.595/6.216 s and reverse 0.480/2.831 s; the 19 s ordinary answer
stall was not repeated in this run. Audio outages remain (up to 21.053 s
first call and 17.033 s second). Independent ICMP samples to a public
endpoint show Blackview 46.6--49.0 ms, all 63 replies, versus Poco
42.8--2612 ms with 6 incomplete three-packet probes (48 replies). Both
thermal statuses are normal. This proves the mobile network path itself
has large latency excursions/loss independently of camera/file load; it
does not prove that it accounts for the entire application outage.

The receive watchdog previously only asked the remote sender for repair.
If direct media and call control stalled together, recovery depended on
that missing remote request. After the existing 10 s receive grace, an
active P2P call with direct posture on both endpoints now recovers over
the already permitted relay and announces its actual route. Healthy media
does not trigger fallback merely because health signals are absent;
onion posture is not changed by this path. Simultaneous relay fallback
requests for one call now join one route-switch future. Previously the
second native switch could fail because the first was rebuilding, and
the FSM ended the call as an error.

Three regressions cover missing-peer-heartbeat recovery, healthy ingress,
and concurrent announcements against a controller rejecting overlapping
switches. Both defect regressions fail against the unchanged call service;
all 116 call-service tests and scoped analysis pass with the fixes. Phone
confirmation follows in build 2193. Campaign 2192's apps/readers/forwards
were closed, with process exit independently verified.


Campaign 2193 and replay-safe ratchet recovery
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both 120 s audio calls completed without ending. Cold Poco -> Blackview
ring/active times were 32.454/34.697 s; reverse was 0.637/3.640 s. The
answer arrived on realtime about 259 ms after sending; initial offer
bootstrap delay remains unresolved. Active media used relay on both
calls, so the new silent-P2P watchdog is covered by the state-machine
regression, not by a live fallback in this campaign. Native arrival gaps
reach 1.595/3.161 s in the first call and 2.043/1.314 s in the reverse.
Quality is still not declared fixed. Both native workers remain responsive.
Poco also records several ratchet AuthFailed/unopenable replies from
Blackview during the first call; the new generic error log adds payload
kind to distinguish bare mismatches from refused prologues in the next run.

A concrete replay defect was reproduced independently: ordinary consumed
bare frames counted toward the wedge threshold and earned unopenable
replies, which reset the sender's healthy chain. Prologues refused against
a held conversation, including stale authenticated prologues after
restore, could also count toward a wedge or ask the sender to reset.
Consumed-key errors now neither count nor request resets. Retained-session
prologue refusals carry the original cryptographic error in a separate
internal variant and do not trigger reset replies; downgrade/forged packets
still fail and do not deliver plaintext. New valid prologues still require
verified authorship and a newer peer send time before replacing state.

An actual dispatcher regression repeats both prologue and bare payloads
with distinct carrier IDs over direct and relayed paths, including restored
stores with warm/cold certificate caches. It checks no duplicate delivery,
no reset, byte-identical held state, and delivery of the next fresh frame.
A separate bare-frame regression exercises the wedge threshold, and the
old-prologue test now repeats enough times to cross it. The old open/reset
policy fails both new regression controls. 123 E2E, 262 dispatcher and 4
integration tests pass, as does production FFI Clippy; no wire or persisted
state format changed. 146 Flutter call-service/realtime tests also pass.

2193 cleanup was independently verified before Poco disconnected from ADB.
The follow-up idle ICMP observation on Poco has no replies because ADB was
unavailable and must not be interpreted as network packet loss. Blackview's
idle probe completed 30 replies (47.8--76.8 ms). Both phone apps remain
closed and own forwards/readers/fixtures are absent. Build 2194 will carry
the replay fix; paired phone validation awaits Poco's return to ADB.

Build 2194 packaging complete: production-feature ARM64 Rust rebuilt,
unchanged 92-export media engine included; staged/merged/stripped/APK
libraries and C ABI header hash verified. Installed Blackview's complete
pulled APK matches the build hash and its app process is stopped. Poco
remains disconnected: its matching-certificate APK is prepared at
/private/tmp/xveil-audio-2194-poco.apk, but installed version remains 2193.
Do not claim paired validation or install/launch a mixed-version stand.
Source roots are committed unsigned and unpushed.


Neutral UDP loss and primary queue age characterization
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Blackview returned to ADB with verified build 2194 and no app process.
Poco remains absent; paired 2194 replay/quality validation is still pending.
No phone app was launched during this work cycle and no forward was added.

The real encrypted QUIC FIFO stand now has a test-only neutral blackout
switch. Both UDP directions drop all packets (including ACKs and packets in
propagation), without examining payloads or assigning traffic priorities.
A manual characterization sends 50 frames/s on a fresh connection, warms it
for 6 s, drops UDP for 2 s, and continues for 10 s. It compares a 128-byte
AppRtData payload with a fragmented 2048-byte circuit cell. Handshake and
application packets use the same FIFO; there is no video, file, call-control,
ratchet reset or application route repair. Sequence/timestamp fields are
inside the encrypted session datagrams, not exposed to the neutral link.

Measured with the existing endpoint primary backlog admission:

  one-way link delay   frame                  first fresh after reopen   maximum age
  20 ms                short AppRtData         972 ms                     1884 ms
  20 ms                padded circuit cell     814 ms                     2689 ms
  1000 ms              short AppRtData         6637 ms                    8923 ms
  1000 ms              padded circuit cell     6396 ms                    9336 ms

All four cases resume on the same connection and have no logical duplicates.
Maximum admitted queues remain 2990--3913 bytes; the 4 KiB backlog cap alone
therefore does not establish an age bound. Under high RTT it can preserve
old packets while refusing new ones. Reported age includes intentional loss,
propagation and queueing; this stand does not separately attribute time to
Quinn versus the neutral FIFO. A long interruption can be reproduced
without competing application traffic, but these results do not prove the
cause of every physical phone pause or resolve it.

The characterization is ignored by default and asserts delivery/recovery,
not a passing voice-quality threshold. Its four-case run passes. All seven
existing automatic QUIC backlog tests pass (four manual tests ignored).
Artifacts: /private/tmp/xveil-quic-blackout-rtt-matrix.log and
/private/tmp/xveil-quic-blackout-existing-gates.log. Production source and
installed APK contents are unchanged; no new build is required for these
test-only changes. Endpoint queue freshness and paired phone quality remain
open. Blackview process absence and empty ADB forwards were rechecked.


Endpoint primary DATAGRAM expiry
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil 6b4f5ad2 adds a 200 ms monotonic deadline only for the endpoint's own
REALTIME source on a prepared independent sibling. All fragments of one
frame share the deadline. Capacity queries remove expired packets before
new admission; packet creation removes expired packets before encryption.
Ordinary sends, shared fallback, neutral transit, reliable streams and
congestion-controller settings keep their existing policy. Dropped payloads
do not reset flow keys, nonces, replay counters or authenticated bindings.

The locked Quinn 0.11.9 / quinn-proto 0.11.15 sources are vendored with
licenses and registry archive SHA-256 provenance. Only four upstream source
files differ: the wrapper API, protocol queue, pre-packet expiry hook and
two regression tests. Their default APIs have no deadline. The extension
adds no wire field, advertised transport parameter, media role or relay
priority. An optional local diagnostic reports expired outgoing datagrams
separately from wire losses. Maintenance and standalone upstream test
commands are in third_party/veil/third_party/quinn/VEIL_PATCHES.md.

The eight-case actual QUIC blackout matrix compares unchanged and expiring
queues, with no competing application producers:

  one-way delay   frame        maximum age before / after   fresh after reopen before / after
  20 ms           short        1890 / 229 ms                 957 / 972 ms
  20 ms           circuit      2840 / 163 ms                 946 / 946 ms
  1000 ms         short        8971 / 1204 ms                6706 / 4262 ms
  1000 ms         circuit      9292 / 1219 ms                6324 / 6337 ms

All cases resume and have no duplicates. Propagation/neutral-router queueing
remain outside the local deadline. In particular the several-second loss
recovery is still visible and is not represented as fixed. The final short
packet regression sees 1889 versus 228 ms age and 83 local expirations.
Disabling only the production expiry selector makes that regression fail on
stale delivery. The policy guard checks that shared fallback and every
non-primary local class, including neutral transit, do not opt in.

Verification: 379 session + 114 transport tests and 7 doctests pass, with
4 manual session and 1 transport doctest ignored; the subsequently added
policy guard and final expiry/diagnostic regressions pass separately.
267 upstream protocol tests and 17 upstream Quinn tests pass (3 ignored).
Production FFI Clippy passes with warnings denied. No C ABI changed.
Logs: /private/tmp/xveil-quic-expiry-{blackout-matrix,app-gates,proto-all,
quinn-all,loss-final,negative-control,production-final-clippy}.log.
This is source validation, not proof of physical phone quality or every
route's isolation. Build 2195 will carry the change. Poco is still absent;
paired validation, replay confirmation, video/file load, fallback, group
media and sustained playout quality remain pending. Apps were not started
in this source-only cycle.


Build 2195 packaging and partial installation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Production-feature ARM64 native build with Veil 6b4f5ad2 completed. The APK
contains the new expiry diagnostic marker and unchanged 92-export media
engine. Raw/staged/merged/stripped/APK library hashes, architecture, production
features and C ABI header hash passed the packaging verifier. Root build
commit is 27d0a87d; this subsequent documentation-only commit needs no rebuild.
Blackview's full pulled installed APK matches the verified build hash and
reports versionCode 2195. It was force-stopped after installation and all
package-prefixed processes are absent. Own ADB forwards are absent.
Poco remains disconnected: /private/tmp/xveil-audio-2195-poco.apk is prepared
and signature/library hashes verified, but its last verified installed build
is 2193. Skip the superseded 2194 APK on return; install/verify both phones
at 2195 before launching a paired stand. No phone call/media quality gate was
completed in this cycle. Source edits are committed unsigned and unpushed.


Build 2195 paired physical validation and endpoint load feedback
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both phones now have verified build 2195. Two 120-second audio calls completed
with Poco on cellular. Poco -> Blackview rang after 0.247 s, active after 4.002 s;
reverse rang after 0.343 s, active after 1.446 s. The first call transitioned
from relay to P2P; the second stayed P2P. Primary expiry ran physically (maximum
local counters: Blackview 542, Poco 304). Workers stayed responsive. Audio still
paused: maximum sampled native receive age 4132/4279 ms in the first call and
633/665 ms in reverse. Maximum reported NetEq interruption counts were 15/22 and 8/5, respectively.
All owned apps, log readers and ADB forwards were closed; package-prefixed
process absence was independently checked. Artifacts are the private
/private/tmp/xveil-audio-2195-{summary,native,logs,network}.json and
/private/tmp/xveil-audio-load-2195.json.

Do not infer ratchet success from the absence of literal Rust enum names:
physical logs contain kind=1 authentication failures, missing/dropped
conversations, signed unopenable replies, and a refused kind=0 PQ downgrade.
The earlier replay correction therefore does not close the physical ratchet
problem. These failures remain under investigation; no authentication or PQ
check is bypassed.

A separate concrete control defect was found: a fresh P2P readiness signal
provoked another readiness signal even after both peers had upgraded, allowing
a mutual reply loop. Only the first readiness transition now triggers an
immediate check; heartbeat repetition remains at five seconds. All 116
call-service tests pass, including repeated fresh readiness with no replies
and one heartbeat retry. Disabling only this guard fails the real count
assertion (23 announcements instead of 3).

Veil 1fc2cfcc adds endpoint-local pressure feedback from the prepared primary
connection's actual RTT (>150 ms) or increasing expired-packet counter, with a
two-second hold. Under pressure, new reliable admission uses the existing
1 KiB window instead of the independent 16 KiB budget; only local BULK lossy
production is limited to one complete probe per 200 ms. Neutral INTERACTIVE
traffic never selects or resets this gate; ChildCarrier forwarding bypasses
it. Wire fields, relay priority, authentication and replay policy are unchanged.

The new harness binds two genuinely distinct child QUIC connections to the
canonical session using exporter-bound HELLO/ACK and fresh child keys, behind
one neutral FIFO link (1 Mbps, 20 ms one-way). It sends 50 primary frames/s,
overloads the secondary source at 100 padded cells/s and streams a reliable
file. No role or QoS is visible to the link. The denominator is all 500 source
attempts, including admission drops. Under padded-primary load, baseline
received 160/500 with p95 age 454 ms; feedback received 467/500 with p95 287 ms.
Short-primary load changes 489/500, p95 311 ms -> 487/500, p95 249 ms. File and
secondary data both progress; file content is checked, but this short source
harness does not prove complete large-file export/hash or perceptual quality.

The automatic padded-load gate requires >=450/500 received, p95 <350 ms,
maximum receive gap <300 ms, no duplicates and competing-producer progress.
Interleaved neutral classes must remain admitted. Disabling only pressure
observation fails this actual gate at 168/500, p95 448 ms. Source verification:
381 session tests (5 manual ignored), 114 transport tests and 7 doctests pass;
production-feature FFI Clippy passes with warnings denied. Logs:
/private/tmp/xveil-bound-independent-{load,pressure,pressure-regression,pressure-negative}.log,
/private/tmp/xveil-independent-pressure-{source-gates,clippy}.log and
/private/tmp/xveil-call-readiness-storm-{test,negative}.log.

Build 2196 will include the source feedback and readiness fix. Its packaging,
installation, paired quality/load tests and ratchet investigation are pending.
This is a measured improvement, not completion of every media isolation route,
group call, sustained fallback or audio quality requirement.


Build 2196 physical audio and video/file results
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Build 2196 packages root 50139485 / Veil 1fc2cfcc. Both installed APKs were
pulled in full and their hashes verified, including Poco's matching signature.
Both contain verified ARM64 production-feature Rust and unchanged 92-export
media engine libraries. Private build manifest:
/private/tmp/xveil-audio-build-2196.json.

Two further 120-second audio calls completed with Poco on cellular. Poco ->
Blackview rang in 0.183 s and became active in 3.089 s; reverse 0.541/1.769 s.
The first upgraded relay -> P2P; reverse stayed P2P. Native receive ages peaked
at 480/481 ms first and 2082/2087 ms reverse (Blackview/Poco). Maximum reported
NetEq interruption counts were 6/5 and 24/29; route rebuilds reset engine
counters, so these are not summed whole-call interruption totals. All media
workers remained responsive. Neither phone logged delivery.decrypt_failed or
unopenable replies in this campaign. Readiness sends were bounded to at most
one per second (27/24 over both calls including startup/fallback), rather than
an immediate mutual reply loop. This limited run does not establish that every
ratchet-restart case is resolved.

Blackview's external ICMP remained <=52.7 ms with no incomplete probes;
Poco reached 921 ms, with repeated 571-855 ms samples during the second call.
Both thermal statuses were 0. Those independent network excursions are real,
but do not by themselves account for every audio interruption. Primary QUIC
loss/expiry counters also rose. Artifacts:
/private/tmp/xveil-audio-2196-{summary,native,logs,network}.json and
/private/tmp/xveil-audio-load-2196.json.

A separate physical video call added an 8 MiB random file Poco -> Blackview
24.656 s after placing the call. The full file was exported in 105.45 s and its
SHA-256 matched the source. The API's progress snapshot reported 8388607 bytes
while the verified export actually contains all 8388608 bytes. This proves
file completion, not media isolation: native receive age reached 17280 ms on
Blackview and 20647 ms on Poco. Decoded remote_frames reached 17/11 (Blackview/Poco);
video_rx_frames is absent from this API and must not be reported as zero;
the adaptive sender had fallen to 1 kbps / 0.02 fps. Workers stayed responsive.
The call recovered through relay and completed, but this quality/isolation
gate FAILS. The new source admission regression is therefore insufficient to
close the physical video/file competition defect.

At the blackout, logs show keepalive timeout reaping the direct peer session
(unacked ~5 s, genuine data stale ~6 s), several relay-session closures and
slow ordered body reads. The realtime receiver already records authenticated,
replay-checked child progress in its shared activity tracker. Next investigation
must distinguish actual transport silence, IPC/source backlog and ordered
stream scheduling; a keepalive close alone does not prove missing child
liveness accounting. Actual SDK byte-stream traffic also needs a session-runner
integration test: the new synthetic load harness exercised a raw canonical
QUIC file writer, not the full SDK/IPC/file-serving route.

Artifacts: /private/tmp/xveil-av-file-load-2196.json,
/private/tmp/xveil-av-file-2196-{native,logs,network,live-failure}.json and
/private/tmp/xveil-av-file-2196-run.log. Both owned file fixtures were removed,
only the campaign's download was cancelled/checked, both app processes and
owned ADB forwards were closed, and reader subprocess exits were verified.
An independent ps -A check found no package-prefixed process on either phone;
ADB forwards are empty. Source edits are committed unsigned and unpushed.
Physical quality, SDK file isolation, usable video, group-media and sustained
fallback requirements remain open.


Shared IPC file-write isolation (follow-up to build 2196)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The physical chronology is now clearer: the first relay audio receive freeze
started 20.653 s after placing the call, BEFORE the download request at 24.656 s.
Independent Poco ICMP probes were already incomplete or above one second before
the download. Late P2P upgrade occurred at 42.021 s, and the file source first
served data around 44 s after retrying open. The later P2P receive freeze and
keepalive reap overlap file transfer, but the first blackout cannot be attributed
to that transfer. Actual cellular brownouts and endpoint queueing must be
separated; this change does not establish that all physical pauses are fixed.

A separately reproduced defect existed in the actual app↔node IPC loop:
remote STREAM_DATA and graceful STREAM_CLOSE awaited reliable source admission
inline, up to 30 s, delaying subsequent media/control commands on the shared
connection. A real Unix IPC regression blocks exactly that broadcaster await;
the old path fails its 250 ms control-response deadline, the new path passes.

The SDK/node negotiate an IPC-only source write credit in APP_HELLO/HELLO_OK.
Each stream has 8 KiB including 128 bytes charged per frame to bound tiny-write
allocations. Legacy clients/nodes retain the original behavior. Remote reliable
writes are queued and their cancellation-safe admission future is polled beside
IPC requests/delivery. Node admission refunds credit directly through the SDK
reader; neither a slow file consumer nor exhausted source credit holds the
shared IPC writer. Local pairs immediately refund successful source admission;
the separate acceptor read window is unchanged. Data/close retain FIFO order
and stream ownership/wire leases stay reserved through graceful close. A credit
violation closes only that stream; foreign clients cannot spend/cancel its
credit. Disconnect cancels the pending reliable await. Source-window close wakes
blocked SDK writers with BrokenPipe. No inter-node wire, relay priority,
authentication, device proof, PQ or replay policy is changed.

Gates: IPC 118 passing / 5 existing ignored; SDK 38 passing at the initial gate,
28 SDK integration tests passing; 1 SDK doctest passing / 2 existing doctests
ignored overall. The added SDK close-wakeup test passes separately. Real SDK +
IPC transfers 512 KiB + 19 bytes across many credit windows, checks every byte
and ordered close, and admits a direct media cell and control response while
reliable admission is blocked. The existing opener/bridge SDK file test also
passes. This fixture ends at FrameBroadcaster; it does not cover an actual
SessionRunner/crypto/neutral link or establish physical media quality.
Production-feature FFI Clippy passes with warnings denied before the final small
SDK close-wakeup addition. Private logs:
/private/tmp/xveil-ipc-file-{negative,regression}.log,
/private/tmp/xveil-ipc-credit-gates.log,
/private/tmp/xveil-sdk-credit-close.log and /private/tmp/xveil-ipc-credit-clippy.log.

An older SDK wire-neutrality assertion expected flags=0 on relay forwarding,
but the existing production encoder writes constant neutral INTERACTIVE=1.
It fails identically with legacy negotiation (private
/private/tmp/xveil-relay-wire-legacy-baseline.log). The assertion now checks that
existing constant, still compares complete decoded forwarding fields across
local source classes/deadline APIs, and permits no source-credit/deadline bit.
The production forwarding encoder was not changed.

Build 2197 packaging, installation and paired physical validation are pending.


Build 2197 physical follow-up
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Verified/installed build 2197 packages root 09dc3271 / Veil aa1d865b on both
phones. Full pulled APK hashes match the prepared builds; ARM64 production Rust
and unchanged 92-export media libraries are verified. Poco remained cellular.
Build manifest: /private/tmp/xveil-audio-build-2197.json.

A 165-second active video call Poco -> Blackview rang in 1.113 s / active 4.975 s.
The complete random 8 MiB file hash matched after 68.28 s (request relative
25.141 s, completion 93.897 s). Native receive age still reached 3944/3970 ms
(Blackview/Poco), p95 663/679 ms; during download request→completion p95 was
990/1010 ms, afterwards 286/287 ms. Decoded remote_frames reached 185/179;
video_tx_frames 218/442. Media workers remained responsive; no shared IPC HELD
warning or delivery.decrypt_failed/unopenable was logged. Maximum reported
NetEq interruption counters 24/24, duration 17646/16647 ms; these are not summed
whole-call totals if engines reset. This is a working file/video result and
an IPC isolation correction, NOT a physical audio-quality pass.

The 4-second blackout froze primary child QUIC ACK/receive counts on both
phones around epoch 1791220393–96; RTT stayed stale near 77–82 ms, local outgoing
deadline expiry rose, then loss/RTT rose on recovery. Poco's independent ICMP
probe at 1791220394.556 was incomplete with 1237 ms first response; Blackview
probes were complete <=56.2 ms. The file source's first request/manifest only
completed at phone wall time 20:13:17, after that freeze. A later direct open
failed code 7 and both anonymous/direct serve accepts appear in logs; the file
cannot be assumed to have used just one direct SDK source route. Anonymous
fallback isolation remains pending. Artifacts:
/private/tmp/xveil-av-file-load-2197.json,
/private/tmp/xveil-av-file-2197-{summary,native,logs,network}.json,
/private/tmp/xveil-av-file-2197-run.log.

Correction to the previous video assessment: video_rx_frames was not a numeric
field in 2196 either. The actual decoded remote_frames was 17/11, not zero.
2197 decodes substantially more frames, but a single different physical
network trace does not isolate the cause or prove usable quality under every
route.

Two more 120-second audio-only calls expose a separate large recovery defect.
Poco -> Blackview ring/active 1.747/3.317 s; relay -> P2P -> relay. Native ages
reached 14818/10007 ms, p95 8423/3696 ms. Both direct sessions were reaped around
epoch 1791220727.6 after 5 s unacked probes / ~5.7 s stale genuine receive.
CallService waits its existing 10 s silent-media grace; Poco switched to relay
at relative ~62.7 s, Blackview followed/recovered near ~67.6 s. That delayed
fallback compounds the initial transport outage and requires work. Reverse
Blackview -> Poco stayed P2P; ring/active .755/2.663 s, ages 3322/3350 ms and p95
659/654 ms. Workers stayed responsive. Poco external ICMP peaked at 1151 ms,
with one incomplete probe; Blackview <=74.6 ms, complete. Source artifacts:
/private/tmp/xveil-audio-load-2197.json,
/private/tmp/xveil-audio-2197-{summary,native,logs,network}.json and
/private/tmp/xveil-audio-2197-run.log. Neither loaded nor audio-only quality
meets the objective yet.

Another concrete lead: one relay keepalive timeout log reports swap_attempts
1011 despite a nominal per-episode ceiling of 2. Runner Stage B re-evaluation
runs on every timer wake while the probe stays fired, although its comment
promises only keepalive ticks. Fresh genuine receive protects a live session
from teardown, but does not gate repeated hot-standby trigger calls. Check and
regression-test that retry rate before blaming all pauses on physical cellular
service. No reaper/PQ/authentication bypass is justified by these results.

All campaign downloads/fixtures were cleaned, both owned app processes and ADB
forwards closed, readers exited, and independent ps -A confirmed no package
process remains. Final production FFI Clippy passes with warnings denied.


Bounded keepalive recovery and early closed-direct detection
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The real SessionRunner regression keeps genuine Ping/Pong traffic live while
withholding keepalive ACKs, then stops genuine traffic without closing its
socket. The old runner calls keepalive failover 75 times in one ~0.5 s episode.
The fix retries only on a new keepalive tick and at most twice per episode;
it checks stale teardown on ordinary loop progress, preserving immediate
no-failover closure without adding a full base keepalive interval. A cached
last probe-spawn result retains the pending first attempt until the next tick.
Genuine traffic still protects the healthy session; stopping it still reaps.
The regression checks the actual trigger log sequence has a keepalive emission
between retries, not just the controller's separately flap-damped dial count.
This fixes excessive trigger calls; the prior controller already bounded dials,
so the 1011 log must not be described as 1011 actual network reconnections.
Nine keepalive runner integration tests pass; production FFI Clippy passes.
Private /private/tmp/xveil-keepalive-rate-{negative,existing-tests,clippy}.log.

CallService now checks current local direct-session admission once per second
only after three seconds of media silence, for an active P2P call with both
postures direct. It queries the answering device; it never dials or treats an
identity hint as admission. A confirmed closed session triggers the existing
permitted relay recovery immediately, rather than waiting the complete 10 s
silence grace. Healthy, unknown, failed or timed-out admission queries retain
the original grace. Query flights are bounded to one, and results are rechecked
against the same call/device and current receive activity. Recovered media,
hangup/disposal, an in-progress repair or a different call/device cancels that
decision. The new timer stops with heartbeat teardown. Controller queries
return null on error/unsupported rather than claiming a closed session.
No mailbox, onion-posture downgrade, relay QoS or authentication change.

All 120 call-service tests pass; focused Dart analyze has no issues. Tests cover
closed-device early recovery, healthy/unknown verdicts, recovered media during
a query, one query in flight and hangup/disposal boundaries. Disabling only the
early-check timer body fails the actual pre-grace assertion. Private logs:
/private/tmp/xveil-call-closed-direct-{tests,negative,analyze}.log.
Build 2198 with these changes requires packaging and fresh paired validation;
build 2197 on the phones still has the observed 15 s recovery outage.


Build 2198 physical validation and pending-prologue restart regression
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Build 2198 contains root 156eef4d / Veil e29411cf with the unchanged 92-export
media library. Both installed APKs were pulled and verified against their
manifests. Final session gate: 381 passed, five existing ignored.

Two 120 s audio calls completed with Poco on cellular. Poco -> Blackview
ring/active times: 0.997/3.238 s; reverse: 0.486/1.565 s. The first call
falls back to relay; the reverse stays P2P. The early closed-session recovery
actually fires on Poco. First-call direct sessions reap at epochs
1791222817.775 / 1791222818.089 with swap_attempts=1, rather than the earlier
trigger storm. This demonstrates execution, not adequate recovery quality:
maximum native receive ages are 10969/15953 ms (Blackview/Poco) in that call,
and 2938/2860 ms in reverse. Both workers stay responsive. Reported NetEq
interruption maxima are 14/27 and 36/34; counters reset across media rebuilds,
so these are not summed whole-call totals. Both relay IPC failure counters
stay zero. Source relay_send samples continue during the later asymmetric
Poco receive blackout; receiver ingress samples disappear until after the
sender rebuild. Independent Poco ICMP recovers during that later blackout.
This does not identify the dropping hop; a successful IPC enqueue is not
end-to-end receipt. Quality is still failing.
Private /private/tmp/xveil-audio-load-2198.json and
/private/tmp/xveil-audio-2198-{summary,native,logs,network}.json.

The fresh video/file campaign did not start a call: its file offer remained
unavailable for the 30 s wait. Restored conversations were reported usable,
but physical logs contain kind=1 and kind=0 authentication failures and signed
unopenable replies, including repeated resets. This is not a loaded quality
result. /private/tmp/xveil-av-file-2198-{run.log,native.json,logs.json}.
All owned apps, ADB forwards, readers and the file fixture were closed/removed;
independent ps -A checks confirmed no package-prefixed processes on both phones.

A real dispatcher regression reproduces a separate cold-cache mistake:
a sender awaiting its first answer attaches its original prologue to each
new frame. The receiver restores the held conversation before certificate
caches warm, but peer_identity_for_payload accepts only bare frames for that
held context. It instead tries the physical envelope address as the AEAD
identity and asks the sender to reset. The unchanged code fails the regression.
The bounded context lookup now also accepts a retained prologue, with matching
local/sending instances and a unique held identity. Unsupported versions/kinds,
wrong recipients and ambiguous contexts fail closed. The ordinary ratchet open
still verifies AEAD, refuses replays and requires verified device authorship
and freshness for replacement prologues. The context neither authorizes a
physical device nor refreshes a certificate nor teaches a route. The regression
checks valid delivery after restore, forgery/replay rejection, identical held
state on refusal, no reset reply, and rejection of a new unverified prologue.
This fixes a reproduced reset cause; it does not establish that every physical
restart/ratchet failure above has the same cause.

Final gates: 263 dispatcher and 123 E2E tests pass, including the strengthened
pending-prologue regression. IPC suite: 118 passed, five existing ignored.
Production-feature FFI Clippy passes. Private
/private/tmp/xveil-pending-prologue-{negative,regression,full-gates,clippy}.log.

The existing local stand trace switch also enables bounded, sparse origin
relay-admission observations: source/destination/first hop, local slot,
accepted/refused counts and generic datagram-transport availability. Off by
default, one observation per key/second with at most 256 retained keys. It
parses no media, changes no relay policy or wire field, and explicitly measures
only queue admission. New physical campaigns must correlate it with receiver
ingress before assigning the asymmetric blackout to any hop or path.


Build 2199 paired load and publication-pause experiment
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Verified build 2199 contains root 3877306d / Veil 1ec4e7cf. The cold file offer
arrived; video call ring/active times were 1.233/5.223 s. The complete random
8 MiB file downloaded in 179.09 s and matched SHA-256. The API progress field
again reports N-1, but the exported full N bytes are verified. The call lasted
about 200 s, with initial relay then P2P. Maximum sampled native audio receive
ages: Blackview 2624 ms / Poco 2673 ms; p95 448/461 ms. NetEq interruption
maxima: 22/25, durations 13985/16303 ms, not whole-call sums across rebuilds.
Workers stayed responsive; decoded remote_frames reached 203/80. Severe
adaptation reduced Blackview's video target to 1 kb/s, so usable sustained
video is not claimed. Source progress remained gradual; no shared IPC HELD
warning was captured. The local origin relay-admission trace emitted 10/13
rows. Physical ratchet errors remain: 54/52 delivery.decrypt_failed log rows,
so a successful offer does not close the restart problem.
Private /private/tmp/xveil-av-file-load-2199.json and
/private/tmp/xveil-av-file-2199-{summary,native,logs,network,live-diagnostics}.json.

Two subsequent 120 s Poco -> Blackview audio calls stayed P2P. Baseline maximum
receive ages: 2408/2415 ms. In the second call only periodic native publication
was paused from relative 24.073 to 84.158 s, then restored. Within that interval
ages still reached 1096/1110 ms (p95 884/911); after publication resumed they
reached 3338/3357 ms. Pausing publication therefore does not eliminate pauses;
these different physical traces are insufficient to assign all residual loss
or to deploy a permanent pause. Publication switches were restored in cleanup.
Private /private/tmp/xveil-publish-audio-{load-2199,2199-summary,2199-native,
2199-logs,2199-network}.json. Both apps and owned readers/forwards were closed;
independent ps -A checks confirmed package process absence on both phones.

Confirmed unresolved crossed-init defect
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A standalone regression seals A's and B's first messages BEFORE either side
opens a message, then delivers both prologues in either order. Both stores
replace their own pending root with the peer's root. B's next bare frame fails
AEAD at A; the roots disagree. The reproduction fails on the current source:
/private/tmp/xveil-crossed-init-negative.log. It is retained as the explicitly
ignored simultaneous_initiations_converge_before_the_next_bare_frame test,
not counted as a passing gate. Run with --ignored to reproduce.

A prototype retained the lexicographically smaller identity/instance's pending
root after verifying a competing prologue. That made the crossed-init test
pass, but broke the existing a_peer_re_opening_a_conversation_we_never_heard_
back_on_is_followed recovery contract by refusing the first genuine message.
The prototype was removed. No deferred-init production change is installed
or committed. The resolver must preserve first-message delivery, existing
unanswered-peer recovery, authenticated device/instance binding, replay safety
across restore, and bounded key retention. An immediate authenticated convergence
control or a bounded temporary second receive chain needs those gates before
adoption; discarding a first message merely to choose a root is insufficient.
This is a reproduced protocol race, not proof that every physical ratchet
error above comes from it. Audio quality, relay blackholes and this race remain
open, with the goal active.

Opt-in connection receive-stage trace
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The existing RT trace gate now samples each authenticated generic datagram
receiver once per second, including intervals with no receive progress. A
process-local ordinal separates connections without exposing a pointer or
exporter. Counters separate incomplete assemblies, decode refusals, ineligible
complete frames, dispatcher calls, rate-limit/violation results and the maximum
synchronous dispatch duration. Actual QUIC UDP/ACK/loss/RTT counters accompany
each window. Decode refusals include replay and malformed packets as well as
authentication failures; they are not attributed to one cause. No application
classification, network field, scheduling or relay policy changes. The interval
branch is disabled when tracing is off. Session checks: 382 passed / five
existing ignored; production FFI Clippy passed with warnings denied. This is
instrumentation for the unresolved physical gaps, not a quality fix.

Build 2200 physical receive-stage observations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both phones verified full installed APK 2200 (root 7ee07e8a / Veil dabdef5c),
with Poco still on cellular. Two 120 s audio calls: Poco -> Blackview ring/active
1.089/4.565 s, Blackview -> Poco 0.423/1.454 s. Maximum native receive ages were
4400/4465 ms in the first call (initial relay then P2P), 4556/4576 ms in the
second (P2P). Quality fails. Across the captured connection windows, Blackview
received 12172 datagrams and Poco 11320: zero decode refusals, ineligible frames,
dispatcher rate limits, violations or unexpected results. Maximum dispatch
durations 1415/2241 us. In a synchronized stalled interval, both incoming child
connections' UDP counters stopped, while source queues continued accepting
frames. Source ACK progress stalled and loss recovery followed. This locates
those gaps before local authenticated frame dispatch; it does not distinguish
radio/path loss, socket progress and QUIC recovery or exonerate all background
load. Regular ratchet errors still occurred (96/103 logged decrypt failures).
Private xveil-audio-{load-2200,2200-summary,2200-native,2200-receive-summary}.json
under /private/tmp. Both apps/readers/forwards closed; independent ps checks
confirmed package and child-process absence, adb forwards empty.

The existing debug P2P policy hook now reads the effective value when no value
argument is supplied, allowing a stand to save and restore the original policy
instead of guessing it before a temporary relay comparison. Invalid explicit
values retain their error path. No production call policy is changed.

Confirmed warm relay media attribution defect (build 2201)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
With both original P2P policies saved and temporarily set to denied, two 120 s
relay-only calls reproduced a separate complete audio blackhole. The first
Poco -> Blackview call received 5617/5728 audio packets, with receive ages up to
3123/2473 ms (quality still fails). The second Blackview -> Poco call received
zero audio AND zero media packets on both phones for the full observation,
despite local capture, IPC acceptance and repeated media rebuilds. Receive age
was unknown (-1), not a zero-delay success. Native source-app mismatch counters
rose to at least 4500/5000. Cold binding used the device; warm binding used the
identity because an unrelated admitted P-Net session existed.

The nonanonymous presealed relay envelope names the physical sender device.
Native media validation derives its expected source app from that authenticated
envelope sender. Dart incorrectly used admission alone to choose the identity
app even for relay sends. Relay now always chooses the device app; direct media
retains the existing authenticated-session choice. Missing device bindings fail
channel creation rather than silently using an incorrectly attributed app.
Receiver validation, wire format, cipher and relay scheduling are unchanged.
The focused regression checks actual app-id derivation for both cold and warm
relay cases; restoring the old admission-only rule makes it fail. Focused
Flutter gates: 123 passed; analysis clean. Physical confirmation of the fix is
pending. This does not resolve the remaining network gaps or crossed-init race.
Private artifacts: xveil-relay-audio-{load-2201,2201-native,2201-logs,
2201-policy-backup,2201-policy-restoration}.json under /private/tmp. Both original
policies restored; apps/readers/forwards closed. Independent ps checks confirmed
package and child-process absence; adb forwards empty.

Build 2202 cold and explicitly warmed relay comparisons
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The sender-app fix alone removed source-app mismatch drops but did not resolve
all silent relay calls. Cold relay-only calls received 5692/6009 and 5943/5836
audio packets; maximum native ages 2044/2101 and 1908/1964 ms (quality fails).
Neither physical peer had P-Net admission in that run, so it is not counted as
proof of the original warm condition. A fresh stand explicitly established
P-Net admission on both phones BEFORE selecting relay. Both 120 s calls then
received zero audio/media packets. Source-app mismatch was zero, while native
media ingress reported no-channel drops: incoming physical device IDs differed
from the controller's registered identity peer. Generic datagram receive and
dispatch continued; this second rejection occurs before the media cipher.

The controller had also chosen the identity receive address from admission
alone, ignoring the negotiated relay route. Relay now always selects the
physical device from the authenticated call signal. Direct media retains the
identity for an admitted session. If direct channel creation falls back to
relay, the opener returns the actual physical peer so channel reuse, liveness
counters and repairs stay bound to the channel that was really opened. No
receive alias search, weakened source-app gate, cipher or relay policy change.
Focused sealing/sender/service gates: 139 passed; analysis clean. Restoring the
old receive choice or fallback address separately makes the new regression
fail. Physical verification of the combined correction is pending.
Private xveil-{relay,warm-relay}-audio-2202-* artifacts under /private/tmp;
both stands restored original P2P policies and closed apps/readers/forwards.
Independent ps checks confirmed no package/child processes, adb forwards empty.

Build 2203 explicitly warmed relay media confirmation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Full installed APKs verified on both phones (root 48b39d28 / Veil dabdef5c).
Before EACH call both physical peers had admitted P-Net sessions, then media
remained in relay mode by the temporary denied policy. Two 120 s calls received
5576/5395 and 5687/5937 audio packets. No source-app mismatches; each native
media epoch stayed stable through its call. The complete silent warm-relay
failure passes with the combined sender and receive-address correction.
Ring/active times 1.192/3.159 and 0.730/1.782 s. Quality still fails: maximum
native receive ages 4381/6657 and 2806/880 ms; interruptions 26/29 and 14/20.
No native worker stalls or relay IPC failures. Do not equate this attribution
success with solving the remaining pauses. One no-channel log per phone remains
in the lifecycle capture; it did not prevent either call's audio flow.
Private xveil-warm-relay-audio-2203-{attribution-summary,native,logs,
policy-restoration}.json and xveil-warm-relay-audio-load-2203.json. Warm admission
prerequisites are recorded per call. Policies restored, apps/readers/forwards
closed; independent ps/forward checks confirmed cleanup.

A separate native replay regression reproduces a receive-history reset when
the same call's keys move from an identity address to its physical device:
a captured valid cell opens twice on current Veil. The existing route-rebuild
regression used the SAME peer address and did not cover this switch. Fix and
verification are in progress; no alias authority is being added to reception.

Media replay scope correction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The address-rebind regression fails on the old native implementation at the
assertion that a captured cell must not open twice. Replay history now uses a
domain-separated digest of the exact directional receive key, shared across
identity/device route addresses. This accepts no address aliases and searches
no unrelated keys. AEAD, the atomic post-authentication replay commit, the
four-epoch window and eight-entry LRU bounds are retained; digests are RAM-only,
never logged or persisted, with no raw call-key retention beyond the channel.
Production-feature native FFI gates: 232 passed / two existing ignored, Clippy
including tests passed with warnings denied. Private negative/positive logs:
xveil-media-route-replay-{negative,gates,clippy}.log. New phone build pending.

Build 2204 ordinary-call confirmation and kernel UDP observations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both full installed APKs verified (root 804a9836 / Veil 8b24f257), identities
preserved and Poco still cellular. Two 120 s calls with the original contact
P2P policy: Poco -> Blackview starts relay then switches to P2P; Blackview ->
Poco stays P2P. Ring/active times 1.218/3.435 and 1.315/2.357 s. Audio received
on both: 5429/5046 packets across the first call's two media epochs, 5771/5565
in the second. No source-app mismatch or native worker stalls. The installed
replay-scope change carries real audio through the identity/device route switch.
Quality still fails: maximum native receive ages 3722/3704 and 4071/732 ms.
Interruptions sum to 22/24 across the first call's epochs (17970/18950 ms),
16/12 in the second (11823/4693 ms). Epoch maxima must be summed, not mistaken
for full-call totals. Native regular ratchet open-failed events remain 115/202;
the media replay correction does not fix the separate crossed-init race.

During the paired observation, system UDP InErrors/RcvbufErrors/SndbufErrors
increased by zero on both phones, and all sampled app-owned sockets reported
zero drops. A separate 0.5 s sampler collected 231 samples per phone over 130 s:
maximum receive queue 82688/4160 bytes, longest consecutive nonempty readings
one/two. These are all app UDP sockets, not proven individual media connections;
sampling can miss shorter stalls. They give no evidence for receive-buffer
overflow as the cause. Public ICMP maxima 49.2/1468 ms are corroborating path
observations, not a measurement of the audio path itself. Generic native
receive windows: 1220/1705, zero decode refusals, ineligible frames, rate limits,
violations or unexpected dispatch results. Remaining transport gaps are open.

Private xveil-audio-2204-{summary,audio-rx-summary,native,logs,network,
udp-queues}.json and xveil-audio-load-2204.json. Both apps and owned readers/
forwards closed, all reader sessions reaped; independent ps and adb-forward
checks confirmed package/child process absence and empty forwards. No push or
release was performed in this cycle.

Source audio cadence and generic QUIC recovery diagnostics
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil a36cf45b adds endpoint-only Opus RTP attempt/successful local admission
counts, ages, maximum output gap and admission duration. The exact local audio
SSRC and Opus payload type exclude video/RTCP. Unknown ages are -1; DTX silence
can also create output gaps. Admission is not delivery. Statistics remain
readable independently of the bounded WebRTC worker query. No role, timestamp,
SSRC or payload is exposed to relays or added to wire messages.
Generic QUIC snapshots add bytes in flight and consecutive PTO count to the
existing gated datagram trace; scheduling/congestion/recovery are unchanged.
The controlled dropped-PING test observes occupied flight/PTO then ACK reset.
Its isolated vendored test copy passed with offline dev-dependency resolution;
production session gates passed 382 / five existing ignored and FFI Clippy
passed with warnings denied. Native cadence smoke, Android production media
build (92 exports, no test hooks), and actual WebRTC call-plane smoke passed.
These observations prepare build 2205 phone attribution; they do not solve or
prove the cause of the remaining physical audio pauses.

Build 2205 physical source/transport attribution
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both installed full APKs verified (root 675b61b1 / Veil a36cf45b), identities
preserved, Poco cellular. Two 120 s calls: ring/active 1.057/2.898 and
1.243/2.319 s. First relay -> P2P, second P2P; audio received 4781/5262
(epoch sums), then 5173/5594. Quality fails: receive ages 2832/2853 and
964/873 ms. Source RTP maximum gaps 401/403 and 406/403 ms, local admission
maximum 1/2 and 3/2 ms, no media worker stalls. In the first steady interval,
11/15 late Blackview receive samples and all 13 late Poco samples coincide
with peer source/admission ages <=200 ms. Individually atomic count snapshots
occasionally differ by one while admission is in progress; no accumulating
attempt/queue deficit was observed. Do not call such a snapshot a failed send.

At 57.690 s, Poco receive age is 2853 ms while Blackview source/admission
ages are 4 ms. Blackview independent primary admission continues (51 frames
in its window), but ACK/UDP receive counts remain fixed, in-flight 17384 bytes
exceeds cwnd 11575, PTO count four. The reciprocal primary connection shows
PTO three with occupied cwnd. Generic trace: 596 admission rows, maximum PTO
four. All eleven generic receive timer groups continue at ~1 s cadence
(maximum consecutive timestamp gap 1.016 s), arguing against a whole-runtime
multi-second stop; this does not rule out an individual driver or OS fault.
Regular ratchet open-failed events 41/30 remain separate and unresolved.

A fresh additional 120 s call (artifact suffix 2205gap) runs independent
system ping processes to a public address on both phones, 0.5 s cadence, no
DSCP/priority changes. Ring/active 1.130/4.792 s; direct open initially fails
on Poco and the call uses relay after Blackview's startup switch. Receive
ages 4689/6325 ms, packets 5008/4987, interruptions 29/33. No source-app
mismatch; one startup no-channel event per phone, before stable media.
Blackview independent ICMP: 343 replies, max RTT 127 ms, max receive gap
0.580 s. Poco: 319 replies, max RTT 2851 ms, max receive gap 5.866 s.
The longest Poco probe gap spans call seconds 32.745--38.611 (eight skipped
sequence numbers); contemporaneous audio ages reach 4689/5549 ms. Another
3.303 s probe gap at 39.370--42.673 overlaps Poco audio age 6325 ms.
Thus prolonged reception gaps occur outside xVeil too, on Poco's network/OS
path. Public ICMP follows a different route and cannot identify the modem,
carrier, specific relay or OS component, nor explain every media interruption.
This establishes external-path contribution, not a complete audio quality fix.

Private xveil-audio-2205{,gap}-{source-summary,epoch-summary,native,logs,
network}.json, xveil-audio-load-2205{,gap}.json, and 2205gap-*-icmp.log.
All apps, child processes, readers and own forwards closed; scoped remote ping
PIDs exited, host readers joined and adb probe processes reaped. Independent
ps/forward checks confirmed cleanup. Quality remains an open gate; relay
neutrality, authentication and replay rules are unchanged. No push/release.

Build 2205 audio/video/file source isolation and earlier ACK-pressure gate
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A 177 s active phone video call transfers an actual 8 MiB fixture Poco ->
Blackview in 156.30 s; the exported file SHA-256 matches. Ring/active
2.315/7.149 s. Both remote renderers receive video (73/205 texture frames);
source/transport trace has independently admitted slots for audio and video.
The native video_rx_frames field is zero and must not substitute for renderer
coverage. Native source gaps max 401/407 ms, admission max 2/8 ms, no sampled
video worker stalls. Audio still has receive ages 2237/2147 ms; quality fails.
Private xveil-av-file-2205-* artifacts include network/independent ICMP, file
export progress and final SHA verification. Apps/children, own fixtures,
readers, forwards and remote system probe PIDs closed and independently checked.

A concrete source-admission omission is fixed: while ACKs stop, the stored
successful RTT can remain low and no unsent datagram may have expired yet.
LocalReliableAdmission previously allowed competing video bursts in that
interval. It now observes the authenticated local primary connection's PTO
count and occupied congestion window, alongside existing RTT/expiry feedback.
The existing sparse secondary probe, two-second pressure grace and reliable
window bounds are retained; transit paths neither activate nor consume this
source policy, and no relay wire role/priority is introduced.
A real QUIC connection behind the neutral blackout fixture reproduces the
omission with RTT below 150 ms and zero expired datagrams. The old policy
fails at the secondary-burst assertion; the fix suppresses the burst, keeps
one sparse probe and other local classes, and resumes after ACK progress/grace.
Session gates 383 passed / five existing ignored; production-feature FFI
Clippy passed with warnings denied. Private xveil-primary-ack-pressure-*
logs. Build 2206 physical installation and load confirmation are pending.

Build 2206 falsification and reliable-control correction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Full installed APKs verified (root 333c2a90 / Veil 0f17ece4). The AV/file
phone load does NOT pass: ring/active 1.260/12.897 s, relay -> P2P, receive
ages up to 10278/3699 ms, no worker stalls; source output gaps 401/407 ms and
admission maxima 0/9 ms. File export stops at 2097152 bytes and the 8 MiB
request times out after 240.2 s, then owned download/fixtures are canceled
and removed. Ordinary ratchet open-failed events: 476/366 versus 0/1 in the
previous 2205 loaded capture. These events are independent evidence of an
unresolved crypto/session problem; do not assign the physical file stall
solely to a scheduling change. Independent network probes on Poco also stall.
All apps/children/readers/own forwards and scoped probe PIDs closed/reaped;
independent process/forward checks verified cleanup.

The earlier ACK-pressure rule also had a separately reproducible admission
regression: a real QUIC test with low stored RTT, zero expiry and primary PTO
shrinks the reliable parent window from 16 KiB to 1 KiB and blocks a 12 KiB
control write while the independent primary has no ACK progress. The new
control-write assertion fails on 0f17ece4. Veil 551239fe keeps early ACK/window
pressure in a separate two-second secondary-only guard. The reliable parent's
RTT/expiry window policy is preserved, while video bursts still stop early,
sparse probes remain possible, and production resumes after recovery/grace.
The bounded control write now fits. Session gates 383 / five existing ignored,
production-feature FFI Clippy passed with warnings denied. Physical build 2207
confirmation is pending; the remaining ratchet and network problems are open.

Build 2207 physical control correction confirmation
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Full installed APK hashes verified (root fd9068f9 / Veil 551239fe), phone
identities preserved and Poco cellular. A P2P video call transfers the actual
8 MiB file Poco -> Blackview in 191.91 s; exported SHA-256 matches. Ring/active
1.382/7.269 s. The progress API reports 8388607/8388608 bytes despite the full
verified export; this reporting discrepancy is separate from file integrity.
Both remote renderers receive video (205/224 texture frames). Audio packets
9381/9967, interruptions 35/43 totaling 36640/40182 ms; receive ages reach
3397/5019 ms, so audio quality still fails. Source maximum gaps 401/403 ms,
local admission maxima 1/4 ms, no sampled audio/video worker stalls. No ordinary
ratchet open-failed events appear in this capture; this does not resolve the
separate failures seen in 2206. Reliable control correction has actual loaded
phone coverage, not a claim that every media or session defect is fixed.

Independent default-priority system ICMP: Blackview 558 replies, maximum RTT
74.6 ms and receive gap 0.528 s; Poco 525 replies, maximum RTT 2656 ms and gap
4.077 s. This again establishes interruption on Poco's network/OS path outside
xVeil, without isolating its cause or attributing every audio pause to it.
Private xveil-av-file-2207-{native,logs,network,source-summary}.json,
xveil-av-file-load-2207.json and scoped probe artifacts retain the evidence.
Apps and their child processes, owned forwards/readers/cache fixtures and
remote probe PIDs closed/reaped; independent ps/forward checks verify cleanup.
Build 2207 is installed on both phones. No relay role/priority, security bypass,
push or release. Sustained audio quality and ratchet recovery remain open.

Build 2207 quiet calls and four-second recovery attribution
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both phones returned and verified accessible, build 2207 retained. Two
120 s audio-only calls (no camera or file fixture): ring/active 1.113/17.713
and 0.344/1.342 s. First relay -> P2P, second P2P. Audio received 5262/5859
(epoch sums), then 5164/5845. Maximum receive ages 924/298, then 1063/1070 ms;
source gaps 280/405, then 301/403 ms, admission maxima 2/4 then 1/5 ms. No
sampled media worker stalls or regular ratchet open-failed events. Quality
still fails; these are separate conditions from the simultaneous AV/file test.

The first cold answer remains a distinct defect: Blackview's answer is logged
sent at 00:41:00.062 and received on Poco at 00:41:14.688 (reported age 14629
ms); repeated live sends occur in between. Independent ICMP during that cold
window has reply gaps <=0.503/0.775 s and RTT <=49.4/322 ms. It does not support
assigning the fourteen-second signalling delay to the general network blackout;
it also cannot rule out a different-route interruption. No ratchet failure was
captured. The reliable media relay fallback was active before eventual direct
admission; source relay traces then report datagram_transport=false. The exact
cold control route/queue delay remains unresolved, not fixed by the ACK guard.
Whole quiet stand ICMP gaps <=0.543/3.542 s and RTT <=114/1580 ms. Kernel UDP
RcvbufErrors/SndbufErrors/InErrors have zero delta; observed own socket drops
zero; sampled thermal status zero on both. Interface counters are captured,
but they are device-wide and cannot alone attribute a burst to xVeil.

Veil 5f385e21 adds a manual encrypted-QUIC diagnostic for the independently
observed four-second outage. A neutral UDP FIFO drops both directions without
reading any role. Production source expiry remains 200 ms. After the FIFO
returns, first fresh audio-sized/circuit-sized frames take another 1268/1743 ms;
maximum delivered frame age 225/159 ms, no duplicates, same connections recover.
This isolates additional transport recovery latency after loss; it does not
prove every phone pause has that cause. The unchanged two-second expiry
regression also passes. Both targeted tests ran and were reaped. No speculative
PTO/cwnd bypass or connection replacement is deployed by this diagnostic commit.

Private xveil-audio-2207quiet-* and xveil-four-second-{quic-recovery,
expiry-regression}.log retain evidence. Both started apps/children closed,
readers and scoped probe processes reaped, own forwards removed; independent
ps/forward verification confirms cleanup. This cycle adds diagnostic coverage
and the physical report; phone production binaries remain 2207 / Veil 551239fe.
The next concrete investigation is cold answer control delivery and bounded
authenticated path recovery, while relay service stays neutral. No push/release.

Cold control attachment fallback
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The compatibility control origin returned after any first-hop queue admitted
the per-device copy; an admitted stale device attachment could therefore hide
an available identity attachment. The handler now retains one bounded alternate
addressing copy: identity plus the same verified instance, using the same
ciphertext sealed once. No network certificate lookup or alias authorization
is added. Each addressing path has its own outer content id so transit dedup
cannot discard the alternate before recipient resolution; terminal ratchet
replay and app frame-id rules remain authoritative. At most three first hops
per path; relay headers remain INTERACTIVE with no role/traffic-class hint.

A failing old-code test reproduces suppressed identity delivery despite
successful device queue admission. New handler tests verify both recipient
paths, identical ciphertext, authenticated opening, benign duplicate rejection
without losing the authenticated chain, and separate decryptability for two
devices. IPC gates 119 passed / five existing ignored. The actual dispatcher
identity/instance/reload recipient gate passes; production-feature FFI Clippy
passes with warnings denied. This repairs a reproducible attachment fallback
omission; its contribution to the physical fourteen-second delay is not yet
established. Build 2208 installation and cold phone coverage are pending.

Build 2208 control attachment physical coverage
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Full installed APK SHA-256 verified on both phones (root cbfe5d70 / Veil
ddae2171), original identities preserved, Poco default network cellular.
Two 120 s audio calls: ring/active 0.177/2.713 and 1.176/2.189 s. Before the
first call neither phone had admitted the peer identity/device session; its
transport changes relay -> P2P. The second call uses P2P. Received answer ages
reported by the device clocks are 8/207 ms, not independent network RTT proof.
The fourteen-second answer delay did not recur in this capture; this does not
prove all cold attachments or the sole cause of the previous delay.

Audio packets 5652/5668 (epoch sums), then 5192/5738. Receive ages 1805/1795,
then 2467/2482 ms, so quality still fails. Source RTP gaps max 402/402 then
400/402 ms, admission max 1/3 then 2/3 ms, no sampled audio/video worker stalls.
Independent system ICMP: Blackview 598 replies, max RTT 74.7 ms and gap 0.528 s;
Poco 585 replies, max RTT 1528 ms and gap 3.647 s. Neither route correlation
alone nor those aggregate values establish a cause for every media pause.

Ordinary app.ratchet.open_failed events recur: 140/97. Captured failures include
authentication, dropped conversations, no-session and retained-prologue PQ
downgrade refusals (missing ML-KEM leg), rather than benign unavailable-message
keys. This is an unresolved crypto/session failure, not passed replay coverage.
It was also present in earlier 2206 runs, absent in 2207 quiet/load captures;
these varying traces cannot establish whether the new addressing copy affects
the race. The isolated same-ciphertext duplicate gate passes, but does not
cover all bidirectional ratchet/root transitions. No crypto checks were relaxed.
Do not attribute these ordinary AppData failures directly to inner-key media
AppRtData reception, which uses the separate per-call cipher.

Private xveil-audio-2208quiet-{native,logs,network,transport}.json and
xveil-audio-load-2208quiet.json retain actual phone evidence; build/installed
APK manifests retain hashes. Apps including package child processes exited,
owned forwards/readers and scoped remote ICMP PIDs removed/reaped, independently
verified with ps/forward checks. Both phones retain 2208. Audio transport
recovery and bidirectional ratchet transitions remain open. No push/release.


Local reliable control admission under independent primary pressure
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil 27a8af98 separates bounded parent control writes from bulk admission.
Actual exporter-bound independent QUIC child loss/expiry previously shrank
all parent writes to 1 KiB. Always retaining 16 KiB was falsified by the
existing neutral 1 Mbps file/video/audio gate: 274/500 primary opportunities
received, p95 381 ms. That experimental policy was discarded.

Parent bulk admission retains the existing pressure policy. Only while the
writer actually writes a locally authored control blob does a bounded lease
raise admission to at least 16 KiB. The lease spans all partial writes and
concurrent primary observations, then restores the bulk limit on completion,
error or cancellation. Ciphertext order and nonce ownership do not change.
Coalescing cannot mix a control blob with bulk or neutral transit. A source
REALTIME non-datagram frame or authored session/control response selects the
lease; remote priority and raw public writer buffers cannot select it. No
role metadata, wire change, relay priority or cryptographic bypass is added.

The new actual neutral-UDP/QUIC test binds a child with a different exporter,
induces real primary PTO/expiry, pauses the production writer after its first
partial write, and applies concurrent source pressure. Its 12 KiB control
blob remains admitted; subsequent 2 KiB neutral transit stays blocked at the
bulk window, then arrives after recovery. Temporarily disabling the lease
reproduces the specific control-admission failure. Source hint/remote header
separation and the raw writer path are also checked. Full Session gates:
385 passed / six existing manual ignored; final focused gate and production
FFI Clippy with warnings denied pass. Phone build 2209 and actual video/file
coverage are pending. Transport recovery and bidirectional ratchet remain open.


Build 2209 control-admission physical regression coverage
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Full installed APK SHA-256 verified on both phones, root 5b06e606 / Veil
27a8af98, production Rust features, ARM64 only, unchanged production media
library (92 exports, no test hooks). Identities preserved; Poco cellular.

Poco -> Blackview video plus actual 8 MiB file: ring/active 0.217/4.534 s.
Download took 234.96 s; exported bytes match SHA-256 (API progress still ends
at 8388607/8388608, so the progress counter alone is not completion proof).
Both cameras active; 280/287 decoded video frames. Audio receive packet epoch
sums 11745/11960. Max receive ages after startup 3080/3107 ms, so audio quality
still fails. Source max gaps 261/404 ms, queue-admission max 2/4 ms; no sampled
audio/video worker stall. Occasional attempt/queued difference is at most one
and can be a nontransactional in-progress admission. No ordinary ratchet open
failure observed in this capture; the known bidirectional-root defect remains
unfixed. Independent system ICMP: BV max RTT 75.3 ms / gap 0.528 s, Poco
1570 ms / 5.051 s; different destination, not proof of the cause of every pause.

Two subsequent 120 s audio-only calls, Poco -> BV then BV -> Poco:
ring/active 1.479/5.617 and 0.441/2.758 s. Audio packet epoch sums 5759/5530,
then 5362/5829. After-startup receive ages 2408/2422, then 811/363 ms.
Source queue admission max 2/3, then 1/4 ms; no sampled worker stall.
Both directions still miss the full receive-gap quality gate. No ordinary
ratchet open failure observed; no security rule or key check was relaxed.

The audio-only network probes show no increase in kernel UDP receive/send
buffer errors and zero observed app UDP socket drops. During the actual call
intervals BV ICMP max RTT/gap 49.7 ms/0.507 s, Poco 2287 ms/2.995 s. The much
larger whole-capture Poco ICMP gap (14.944 s, max RTT 9360 ms) occurs before
the first call during startup, and must not be presented as an active-call
audio outage. Sampling cannot rule out every local scheduling delay.

Refined private transport attribution matches producer first_send events
(local REALTIME AppRtData) to each authenticated parent, then selects that
parent/slot's independent admission observations. AV traces have 255/252
matched primary observations, PTO up to four, sampled ACK plateaus 2.040/
2.223 s and increasing outgoing expiry. Quiet traces have 241 observations
per phone, PTO up to three/two, plateaus 1.010/2.026 s. These are stronger
associations than arbitrary nearby QUIC rows, but not a packet-level proof:
child replacement can split generations, no TLS exporter is logged, and
system ICMP follows a different destination. Source admission remains short
while transport delivery/ACK progress stalls. The controlled neutral-outage
fixture from the earlier cycle independently demonstrates excess QUIC
recovery delay; bounded authenticated recovery remains to be implemented.

Private xveil-av-file-2209-* and xveil-audio-2209quiet-* retain paired samples,
source/primary correlations, network and cleanup evidence; build manifest
retains installed hashes. Apps including package child processes exited;
own forwards/readers, two file fixtures, pending own downloads and scoped
remote ICMP PIDs removed/reaped. Independent ps/forward checks confirm cleanup.
Both phones retain 2209. No push/tag/release. Goal remains active: delivery
recovery and bidirectional ratchet transitions are not declared repaired.


Bounded authenticated source-primary recovery
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil 43ee52b8 may now warm one replacement for its locally selected primary
when ACK progress stalls for 500 ms, PTO is nonzero, flight is occupied and
new outgoing datagrams expire. Idle ACK silence, neutral transit and secondary
producers cannot request this repair. Attempts are spaced by at least 2 s;
the existing 3 s binding deadline and shared eight-connection quota remain.
The old sender continues until the replacement verifies the live parent's
exporter-bound proof. Failure retains it; restored ACK progress cancels the
redundant candidate. Rekey/drop retire credentials and cancel pending tasks.
Fresh children have independent TLS and datagram keys/counters. No congestion
state is reset and no relay role, wire priority or authorization bypass is added.

The generic exclusive accept path held its endpoint mutex through TLS and the
first lazy stream, serializing unrelated children. It now locks only dequeue;
two bounded generic accept jobs progress independently, with failure backoff
inside each job. Empty waits reserve no child slot. Their old timeout also
expired while merely awaiting an incoming connection, synchronizing receiver
backoff just when the neutral outage ended. The deadline now bounds only an
incoming TLS/first-stream attempt; idle waits remain parent-cancellable.
Capacity exhaustion still rejects immediately. Shared-listener dispatch is
unchanged. Every outgoing generic sibling seeds its local initial RTT from
the same current parent path, clamped to 50 ms–1 s; wire parameters are unchanged.

Actual production ParallelSession sender/receiver paths behind a neutral
1 Mbps / 20 ms UDP FIFO reproduce a 4 s bidirectional blackout. Baseline first
fresh frame after restoration: 1.331/1.507 s for small AppRtData / 2 KiB opaque
circuit cells. Repair: 385/476 ms, post-return frame ages at most 27/56 ms,
zero duplicates, 184/180 post-return frames, two attempts and one verified
switch. The pending failed attempt retains the old exporter. Opaque circuit
headers remain INTERACTIVE. The unmodified <600 ms recovery, <400 ms age and
minimum 140-frame gates pass. This covers this outage fixture, not all network
failures or phone audio quality. The isolated first-stream and idle-deadline
regressions each fail with their old behavior restored and pass with the fixes.

Final library gates: Session 387 passed / six existing manual ignored;
Transport 116 passed. Temporary bind-stage instrumentation was removed.
Production-feature FFI Clippy passes with warnings denied. Build 2210 phone
coverage is pending.
The ordinary bidirectional ratchet-root defect remains unresolved.


Build 2210 physical recovery and loaded coverage
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Full installed APK SHA-256 verified on both phones (root 7061759f / Veil
43ee52b8), production Rust features, ARM64 and unchanged 92-export production
media library. Identities preserved; Poco's actual default network cellular.

Two 120 s audio calls: ring/active 0.261/3.241 and 0.435/1.426 s. After-startup
max native receive ages 5816/5836, then 1876/1928 ms: quality still fails.
Source max RTP gaps 400/404, then 400/405 ms; queue admission 1/2, then 1/1 ms;
no sampled worker stalls. No ordinary ratchet open failure in these calls.
Source-primary replacement attempts 7/5, with no logged verified switch.
Short outages can restore the old ACK path before the proof completes; the
capture does not distinguish every cancellation/failure and does not validate
a successful physical replacement. The controlled authenticated fixture does.

The first call's large pause overlaps an independent Poco ICMP receive gap
of 6.935 s (ten missing sequence numbers; next reply RTT 1346 ms), while BV
replies continue at about 0.5 s. Source-primary ACK plateaus 5.027/4.477 s,
PTO up to five and rising outgoing expiry overlap it. Genuine authenticated
data stops; the existing five-second unacknowledged keepalive policy closes
the direct parents, and call recovery follows. Multiple Poco sessions close
in this interval. This establishes a simultaneous broader network symptom,
not a diagnosis of the carrier, modem or OS, nor every media pause's cause.
System ICMP follows a different destination and cannot prove media packet paths.

Poco -> BV video plus actual 8 MiB file: ring/active 1.187/4.766 s; download
202.21 s, exported bytes SHA-256 verified. API progress still reports
8388607/8388608, so completion is established by bytes/hash. Decoded video
frames 149/257, audio receive epoch sums 9821/10300. Max native receive ages
3456/3466 ms, so loaded quality also fails. Source gaps 401/403 ms, admission
1/25 ms; no sampled audio/video worker stalls. Source-primary candidates 7/3,
no verified switch logged. Ordinary app.ratchet.open_failed recurs 193/142,
including authentication failures. The bidirectional-root defect is not fixed;
these outer AppData failures are not proof of the cause of inner-key AppRtData
media gaps. No key, PQ, replay or identity validation was relaxed.

Loaded independent ICMP max RTT/gap: BV 74 ms/0.527 s, Poco 1587 ms/4.118 s.
Kernel UDP receive-buffer errors increase by two on BV, zero on Poco; sampled
own socket drops max two/zero. This is not a zero-drop capture. Sampled phone
power states remain ACTIVE, charging and screen on, thermal status zero;
sampling does not rule out every scheduling or radio transition.

Private xveil-audio-2210quiet-* / xveil-av-file-2210-* preserve paired samples,
primary/recovery attribution, independent probes, sanitized power/radio/kernel
snapshots and cleanup evidence. Apps and package child processes exited;
owned API forwards/readers, two file fixtures and scoped remote ICMP PIDs
removed/reaped, only owned downloads cancelled. Independent ps/forward checks
confirm cleanup. Both phones retain 2210. Source code and root pointer committed
unsigned; no push/tag/release. Goal remains active: actual phone quality,
successful physical replacement coverage and bidirectional ratchet remain open.


Primary replacement outcome attribution
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil 2fccc27b records the bounded replacement's local phase and terminal
outcome, including an aborted task before its first poll. Outcomes distinguish
verified proof, failed connection/binding, deadline and cancellation; the
source separately records cancellation because the old ACK path recovered.
Local connection-budget snapshots include pending and accepted children and
do not reserve capacity or change admission. Error reasons are authored labels;
untrusted error strings, keys, exporters and proofs are never logged. There is
no new wire field, relay scheduling rule or authorization change.

The actual authenticated 4 s neutral-outage fixture still passes: small/large
first fresh frames 384/435 ms, no duplicates and max post-return age 26/57 ms.
Production-feature FFI Clippy passes with warnings denied. Build 2211 physical
outcome capture and sustained forced-relay coverage are pending. The added
diagnostics alone are not an audio-quality fix.


Build 2211 physical outcome capture and cold direct-open race
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both full installed APK hashes verified (root 5a9adad9 / Veil 2fccc27b),
production ARM64 libraries and unchanged 92-export media library. Identities
preserved; Poco remains on its actual cellular default network.

Two 120 s P2P audio calls: ring/active 1.033/3.244 and 0.644/1.949 s.
After-startup max native receive ages 2643/2665 and 2278/2292 ms. Source queue
admission maxima 2/2 and 1/7 ms; no sampled audio worker stalls. Pauses remain.
All seven BV and three Poco primary replacements were cancelled because the
old ACK path resumed, before verification: eight during connect, two waiting
for binding ACK. No timeout, quota refusal or verified switch was recorded;
free-slot snapshots at cancellation were at least two/three. This resolves
these attempts' outcomes, not every outage's cause or physical switch coverage.
Ordinary ratchet open failures recur 25/49; they do not establish causation for
per-call AppRtData media gaps. During the first call, Poco's independent ICMP
reply gaps reach 3.486 s while BV replies continue at about 0.5 s. A 15.579 s
Poco gap was during startup before that call, not a 15 s audio outage. ICMP
uses a different destination and does not identify the failing network layer.

A warm P-Net prerequisite followed by temporary denied P2P media policy
verified an actual relay video call for more than 165 s, with a concurrent
Poco -> BV 8 MiB file: ring/active 0.710/3.571 s; bytes/hash verified in
16.93 s; decoded video frames 284/195. After-startup max native receive ages
1079/941 ms, source admission 0/3 ms and no sampled media worker stalls.
Both policies restored to their original stored contacts value. No ordinary
ratchet open failures in this capture. Kernel receive errors and sampled own
socket drops remain zero; Poco's global UDP SndbufErrors grows by seven, which
cannot be attributed to an individual app socket from this sampling. This is
relay-media coverage, not proof that every file packet traversed a relay or
that every compatibility hop had an independent connection.

A repeat with the normal contacts policy initially negotiated P2P, then both
ends used relay. It is not a P2P loaded pass. Ring/active 1.234/6.202 s; actual
8 MiB export hash verified in 74.19 s; native receive ages up to 2691/2740 ms.
No ordinary ratchet failure occurred, so such failures are not required to
reproduce a media pause. Source/native worker samples remained live.

The repeat identified a separate setup race: Poco's direct open returned not
active at 03:39:26.584, but its authenticated direct session registered at
03:39:26.765. The caller had retained the device receive address selected
before admission; it immediately surrendered P2P and the peer rebuilt its
already opened direct media on relay. A negotiated direct open now retries a not-active/probe failure once after
300 ms. Before retrying it rechecks the exact answering device (query bound
300 ms), choosing its identity address only after that device is admitted.
Another device of the identity cannot substitute for it. Native
admission still gates each attempt, the directional keys are unchanged and
an unsuccessful retry still uses the permitted physical-device relay route.
No retry delay follows the final attempt. Onion and relay opens are unchanged.

The cold-admission regression fails with the old fail-fast behavior (relay
instead of P2P) and passes with the fix. A separate wrong-device negative gate
fails if the identity is selected without checking the answering device. All
139 media sealing/call-service tests pass with TMPDIR=/private/tmp/. Physical
build 2212 race coverage is pending.
All 2211 app/package children, owned forwards/readers, scoped ICMP processes
and both file stands' fixtures were verified closed/reaped; only owned
pending downloads cancelled. Private xveil-audio-2211quiet-*,
xveil-relay-av-file-2211-* and xveil-av-file-2211-* retain sanitized evidence.
Pauses, successful physical primary replacement, ordinary ratchet convergence
and complete compatibility/group/screen coverage remain open. No push/release.


Build 2212 actual P2P load and app-off network baseline
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both full installed APK hashes verified against root 95224690 / Veil
2fccc27b; production native libraries unchanged. This fixes the cold-open
policy without changing native admission, keys, wire flags or relay service.

Poco -> BV video with concurrent actual 8 MiB file remained P2P on both ends
throughout all active samples. Ring/active 1.542/4.732 s; exported bytes/hash
verified in 186.69 s. Decoded video frames 233/244, source gaps 399/405 ms,
queue-admission maxima 1/6 ms; no sampled audio/video worker stalls. Both
source-primary and secondary first_send events report independent=true.
The direct sessions were ready before the first open in this capture: it
validates real P2P/media/file operation with the fix, not a naturally occurring
retry of the exact 181 ms cold-admission race. Its deterministic regression
and wrong-device negative gate cover that policy change.

After-startup native receive ages still reach 2080/2094 ms, so audio quality
is not fixed. All ten BV / three Poco primary replacement attempts were
cancelled after old ACK progress returned, twelve during connect and one
waiting for binding ACK; no verified switch or failed proof/quota/timeout.
No ordinary ratchet open failure in this capture. BV's kernel receive-buffer
errors grow by four and a sampled own UDP socket records four drops; Poco
records neither. This is not a zero-drop run; the socket's transport role and
its contribution to individual gaps require attribution.

Independent ICMP max RTT/reply gap during the stand: BV 120 ms/0.564 s,
Poco 1748 ms/2.781 s. A further 90 s baseline with both xVeil packages
force-stopped (no app or package child processes, no API forwards) reproduces
Poco reply gaps up to 3.167 s, three missing sequence numbers across the largest
gap and max RTT 1399 ms. BV has all 180 replies, max RTT 77 ms/gap 0.528 s;
Poco has 174 replies. The broader symptom also exists outside the running
xVeil process under these app-off conditions. It does not identify OS,
modem, radio or carrier, or prove the cause of every media interruption.

All stand apps and package children were independently verified exited;
both packages remain stopped with 2212 installed, identities preserved,
Poco cellular. Owned forwards/readers, scoped remote probes and both file
fixtures were removed/reaped; only owned download jobs cancelled. Private
xveil-av-file-2212-* / xveil-idle-network-2212-* preserve sanitized samples
and cleanup evidence. Goal remains active: quality gaps, exact physical cold
race/replacement coverage, socket-loss attribution, ordinary ratchet
convergence and remaining compatibility/group/screen cases are still open.
No push, tag or release.


Endpoint video pause for severe audio pressure (2026-10-06)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The previous severe-audio reservation still allowed 1 kbit/s at 0.02 fps.
The optional native video-send-pause ABI now stops all encoder handoffs
(camera, screen, synthetic and pushed sources) and blocks already encoded
VP8 RTP at the unicast shim / group fanout before Veil admission. Audio,
RTCP, local preview/capture and remote-video reception remain live. This is
endpoint-local only: no relay role, priority or wire metadata is added.
Packets already admitted into Veil cannot be recalled.

The existing confirmed severe-audio policy controls the pause. Missing or
expired feedback cannot earn recovery. Resume requests a keyframe on the
existing stream, with a 20 ms scheduling wait; an abandoned resume remains
paused and is retried next poll. Pause itself does not wait on a blocked
video worker. Separate application caches track successful budget and pause
changes. Older libraries lacking the additive export retain the sparse
low-rate fallback without claiming a complete pause.

Native real-Call/queue tests cover immediate pause with video queues held,
failed/resubmitted resume, actual encoded frames stopping and restarting,
blocked already-encoded video RTP, continuing audio/RTCP, fresh preview and
inbound audio during pause, for both unicast and room engines. Flutter
policy/controller gates cover severe pressure, unknown feedback, recovery,
a busy setter and old low-rate ABI fallback. Engine type-check and Android
ARM64 production build pass (94 media exports, no test hooks). Camera and
screen use the tested common handoff gate; this is not a physical screen
capture or an acoustic-quality measurement. Physical build 2213 results follow. Existing receive pauses and socket-drop
attribution remain open.


Build 2213 physical video-send pause and file load
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both installed full APK hashes verified against root 0c687e6a / Veil
7b395a0b, with the rebuilt ARM64 production media library (94 exports).
Poco remains cellular; profiles preserved. Poco -> BV video call, simultaneous
8 MiB file: ring/active 1.897/5.756 s; exported file SHA-256 verified in
186.85 s. All active post-startup samples remain P2P on both phones.

BV's actual native video_send_paused=1 appears in 139 samples, from 99.366
through 213.576 s. Its outbound video frame count stays exactly 112 while
local preview progresses 2744 -> 6118 and accepted inbound audio increases
by 4697 packets. Poco never enters the pause in this capture. Thus this
is physical coverage of severe-pressure pause and continuing capture/audio,
not a physical recovery/keyframe test; the latter passes on the native stand.

Receive ages after startup still reach 2000/1997 ms: these are time since
last accepted RTP, not end-to-end or acoustic latency. Source gaps max
360/405 ms, admission max 1/5 ms; no sampled native worker stalls. Ordinary
ratchet open failures zero. Both phones start three primary replacement
attempts, all cancelled by restored old ACK progress; no verified switch.
Sampled own IPv4/IPv6 UDP socket drops stay zero, and IPv4 kernel
RcvbufErrors/SndbufErrors do not increase. This run retains the receive gap
without reproducing the earlier BV receive-buffer drops, so those drops do
not explain all pauses. Independent ICMP max RTT/reply gap: BV
142 ms/0.594 s, Poco 1860 ms/2.388 s; the destinations differ from media.

The follow-up also fixed the portable (non-Android) Android420 conversion
branch to respect the same handoff gate. Its native regression checks
frames_encoded rather than only transmitted frames, so dropping at the
transport cannot mask continued encoding. Native Call/queue smoke passes
again, Flutter policy/controller gates pass 57 tests, analysis is clean.
This host-only branch change is not included in installed 2213; the Android
branch in that installed build already uses the gate.

Both package/process trees were independently verified exited and packages
stopped, installed 2213. Owned API forwards, log readers, remote ICMP processes,
file fixtures and own pending downloads were removed/reaped. Private
xveil-av-file-2213-* preserve sanitized samples and cleanup evidence.
Goal stays active: receive pauses, acoustic-quality measurement, actual
primary replacement, complete group/screen coverage and prior socket-loss
attribution remain open. No push, tag or release.


Bounded reliable byte-stream packetization (2026-10-06)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The ordered compatibility writer retains whole frames: its 4096-byte local
source budget cannot preempt one oversized frame already being written.
IPC remote byte-stream writes are now packetized at their producer into
at most 3900 data bytes per AppData. Fields/header/AEAD total 3988 bytes,
leaving room for padding into the 4096-byte bucket. The wire receive limit
and format are unchanged; stream segments concatenate to the original bytes.
Local background admission, byte credits and open/data/close order remain;
wire headers retain INTERACTIVE. A single 30-second deadline bounds the whole
write. Failure after a segment reports false and stops further admission;
the existing caller closes the failed stream rather than replaying its prefix.

The actual producer regression sends one large write, checks every encoded
frame's wire bound and neutral header, and reconstructs all original bytes in
order. The real IPC backpressure test commits one segment of a 6000-byte
write, blocks the next, handles control, resumes and verifies no duplicated
prefix; the original 8-KiB IPC credit remains enforced. Partial-failure and
empty-write regressions pass. Restoring the old 64-KiB segment cap makes the
producer regression fail at the oversized source frame assertion; source
restored and gates rerun.

The real encrypted SessionRunner test now uses maximal valid AppData
segments: a newly queued primary arrives before 16 KiB of committed stream
bytes, all 64 reliable segments decrypt in original order and draining resumes
without new inbound/input events. Full IPC suite: 120 pass, five previously
ignored; doctest remains previously ignored. IPC/proto Clippy all-targets
passes with warnings denied; a pre-existing complex test capture tuple was
named, with no runtime change. Android ARM64 production FFI built and both
installed build 2214 APK hashes verified. This limits IPC-owned byte-stream frames,
not arbitrary large control/Delivery frames or the proxy's separate producer.
No relay classification, scheduling or application metadata is added.


Build 2214 relay video/file capture: unresolved ingress outage
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Root 18996c92 / Veil 4fd398ff, profiles preserved and Poco cellular. PNet was
warm before temporarily denying P2P; both media endpoints report relay in
every active post-startup sample. Ring/active 1.119/3.349 s. The real 8 MiB
Poco -> BV file is exported with the exact SHA-256 in 38.97 s. This does not
establish the carrier used by every file packet or intermediate hop.

At about call second 108, native inbound packet/byte and audio counters stop
on both phones. Receive ages reach 22781/22828 ms while outbound audio keeps
advancing, source admission max remains 0/6 ms, sampled media worker stalls
remain zero and video_send_paused=1. The file had already completed around
second 65. Call state disappears around second 131.8; an end reason was not
captured, so a specific timeout cause is not established. Ordinary ratchet
open failures and sampled own IPv4/IPv6 UDP socket drops are zero.

Independent Poco ICMP receives its last reply at second 107.326 and then no
replies for the remaining 26.944 s of the probe; the tail includes 13 sendmsg
ENOBUFS errors. BV keeps replying. A consecutive-successful-replies metric
alone misses this trailing outage. Both phones are awake/charging with idle
state ACTIVE; Poco retains a cellular default. Some direct session health
ACK counters still advance early in the outage, so complete network loss is
not established. Multiple parent sessions are subsequently reaped after
unacknowledged keepalives. Attribution to a particular carrier, socket,
parent/child liveness interaction or network interface remains open. Later
app-stopped ICMP succeeds, which alone does not prove causation by the app.

Original P2P policies restored and verified on both phones. Owned exports,
fixtures, API forwards, log readers and remote ICMP processes cleaned up;
both package/process trees independently verified exited and packages stopped.
Private xveil-relay-av-file-2214-* retain sanitized evidence. Goal remains
active: this capture fails the physical receive-continuity check. No push,
tag or release.


Build 2214 audio-only relay repeat and frame-specific readiness
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Same installed build, warm PNet, temporary P2P denial and cellular Poco; no
video or file transfer. Ring/active 4.142/6.243 s, 180 s active capture.
Both media endpoints report relay throughout. Initial native receive ages
reach 4395/4445 ms and then recover; after the first 15 active seconds they
stay at most 388/370 ms. Native workers show no sampled stalls, source gaps
max 404/404 ms, admission max 2/3 ms. This is not an acoustic quality pass:
the native interruption counters reach 6/9, including the startup outage.
The previous 23-second outage is not reproduced and a fixed call-second-108
timer cause is not established. Kernel IPv4 send/receive-buffer errors and
sampled own UDP socket drops remain zero. Independent Poco ICMP max RTT is
1548 ms, completed reply gap 5.091 s, ENOBUFS zero; BV 152 ms/0.605 s.

The complete route trace, unlike the earlier selected generic-peer event
slice, identifies actual first-hop admission for locally primary cells.
During startup Poco's matching ordered writers stall 610/895 ms and its
primary queue waits 131/678 ms. In the previous video's outage window its
first-hop trace includes both admissions and 271 refusals. These observations
do not establish a single cause of that outage or make a generic peer's ACK
progress proof of the actual media route's health.

Found a separate route-selection bug: has_datagram_transport could be true
for a legacy relay that negotiated no neutral-Forward support. The runner's
eligibility gate correctly keeps that frame on the ordered writer, but origin
sorting wrongly preferred this link as if the frame could use datagrams.
Frame-specific readiness now requires both the live runner generation and
the peer's existing neutral-Forward capability. Origin sorting and sparse
relay-admission diagnostics use that readiness; generic availability remains
separate. Unknown adapters conservatively retain route order. Replacing or
retiring the runner expires its claim. Relay policy, wire bytes, crypto,
fallback hops and origin copy bounds are unchanged.

Full IPC suite passes 120 tests (five previously ignored, one ignored
doctest). The enhanced routing gate includes a generic-QUIC-only candidate;
temporarily restoring the old selection fails its route assertion, and the
restored implementation passes. Four readiness tests cover capability,
replacement and expiry. Real QUIC/SessionRunner regression checks published
readiness against negotiation, delivers the neutral Forward with the ordered
writer stopped only when negotiated, preserves old ordered fallback, and
checks readiness expiry after exit. Session/IPC/runtime library Clippy passes
with warnings denied; Android ARM64 production FFI builds with only
production-seeds,node-embedded,packet-tunnel. This capture used installed
2214, before the readiness fix; installation and build 2215 results follow.

Both apps/process trees independently verified exited, package stopped,
owned forwards/readers/remote ICMP probes gone, original policies restored.
Private xveil-relay-audio-2214-* retain sanitized samples and cleanup evidence.
Goal remains active; complete path separation and physical audio quality are
not established. No push, tag or release.


Build 2215 installed readiness fix: remaining network receive gap
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both installed full APK hashes verified against root 215cd608 / Veil
989b3241. ARM64 production FFI and unchanged 94-export media library verified
in staged/merged/stripped/APK artifacts; profiles retained. Poco stays cellular.
The same warm-PNet, temporary-P2P-denial audio-only capture runs for 180 active
seconds. Ring/active 1.137/3.202 s; all active media samples report relay.

Actual source relay-admission samples now report datagram_transport=false
for every selected neutral-Forward first hop, including generic QUIC peers
that negotiated opaque_flows=false/independent_available=false. There is no
observed neutral-Forward datagram first-send event. This verifies honest
frame-specific readiness; it does not upgrade legacy relays or establish an
independent source connection through them. No logged slow ordered writes,
sampled worker stalls, kernel IPv4 buffer errors or own UDP socket drops.
Ordinary app.ratchet.open_failed zero; separate Delivery decrypt/replay
diagnostics are present (45/42 lines) and are not proof of media AEAD failure.

Quality still fails: native receive ages reach 3927/3950 ms at call second
43.180. Both native packet/byte and audio counters freeze from about second
39.2 until 44.0 while source RTP continues, then ingress catches up in bursts.
Independent Poco ICMP has no successful replies from 38.626 to 43.371 s
(completed gap 4.745 s), overlapping the media outage; BV ICMP stays regular
(max gap 0.529 s). Poco ICMP max RTT 1736 ms, ENOBUFS zero. This narrows the
investigation to the shared network interval but does not identify its failing
component or prove every network flow stopped. Source gap max 400/403 ms,
admission max 3/3 ms. Opus DTX is enabled, so individual source gaps and native
concealment/interruption counters alone do not measure audible speech loss;
the multi-second ingress-counter plateau here is separately observed.

Both original P2P policies restored and verified; installed 2215 packages
stopped and their complete process trees independently verified exited.
Owned API forwards, log readers and remote ICMP probes exited/reaped; no file
fixtures or downloads created in this repeat. Private xveil-relay-audio-2215-*
retain sanitized samples and artifact/cleanup checks. Goal remains active:
the installed route-selection fix is verified, receive continuity and
acoustic quality are not repaired. No push, tag or release.


Proxy source admission and bounded stream frames
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The separate proxy producer previously sent each read (up to 64 KiB) into
local INTERACTIVE admission, and ignored failure of its initial destination
header. Both client and exit bridges now await endpoint-owned reliable
BACKGROUND credits and packetize writes into at most 2500-byte AppData
segments. APP_OPEN/header/data/APP_CLOSE retain their order in that local
source lane; wire priorities remain neutral INTERACTIVE. A failed initial
header prevents user bytes, and a failed partial write closes without replaying
its already accepted prefix. Existing open route discovery has one overall
12 s deadline including source waiting; each write/close has a bounded 30 s
admission deadline. Inbound bridge tasks are aborted and awaited on exit.

RoutedFrameBroadcaster now implements the async reliable admission API instead
of inheriting its synchronous default. It waits for direct/first-hop local
capacity without holding registry locks, invalidating a live route, or
sending an alternate copy merely because that source queue is full. Missing
or closed sessions retain encrypted routed fallback and verified peer-key
resolution. The outer Forward header is neutral INTERACTIVE. No relay transit
scheduler, role metadata, authentication or E2E cryptography was relaxed.

2500 accounts for the routed ML-KEM-768 envelope, hop AEAD and padding space:
an actual encrypted maximal first-hop frame fits one 4 KiB bucket. This is a
producer recommendation, not a smaller receive/wire compatibility limit.
The cost is more per-frame ML-KEM encapsulations and padding than a 64 KiB
write; each short routed segment still uses the existing full E2E envelope.
This does not create a new connection to legacy relays or upgrade their
transport capabilities.

Verification: all 50 veil-proxy tests (including actual connect/receipt/exit
readiness/header/user-data/close lifecycle), 4 routed runtime tests, and all
4 source stream integration tests pass. The real proxy bridge sends 256 KiB
through an encrypted stream-only SessionRunner under held/slow reads; bytes
are complete and ordered, close occurs once, and a fresh primary packet
passes before 16 KiB is committed. Direct and routed capacity-one gates prove
background backpressure leaves reserved primary admission and registry writes
available, with no alternate direct copy. Actual ML-KEM encrypt/decrypt and
neutral-wire-header checks pass. Negative gates restoring old synchronous
routed admission or a 64 KiB proxy segment fail their intended assertions;
sources restored and positive gates repeated. Proxy/runtime all-target
Clippy passes with warnings denied. The wider integration-test Clippy run
hits an existing untouched too_many_arguments helper in opaque_datagram_tests;
no broad lint suppression or unrelated source edit was added.

Physical follow-up on the two phones remains pending at this code checkpoint.
This closes one producer scheduling gap, not the audio-only receive outage
observed in build 2215. Goal remains active; no push, tag or release.


Build 2216 installed proxy fix and denser network attribution
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The ARM64 production FFI builds with only production-seeds,node-embedded,
packet-tunnel. Both installed full APK hashes and staged/merged/stripped/APK
native libraries are verified against root bc55462b / Veil 498efe09; unchanged
media library has 94 production exports. Profiles retained; Poco remains
cellular (default net 143), BV Wi-Fi (net 136). No observed VPN transport;
NOT_VPN capability text is not counted as an active VPN.

Warm-PNet then temporary-P2P-denial audio-only relay repeat has 180 active
seconds: ring/active 0.251/3.071 s, last sample 183.747 s. All active media
samples remain relay. Actual media source-hop admission samples have neutral
Forward datagram readiness=false and zero recorded refusals. These legacy
hops still use compatibility transport; warming the phones' direct capable
P-Net link is not proof that relay media uses independent datagrams. No video
or proxy transfer was active in this capture: it verifies installation and
remaining call behavior, not physical proxy-transfer scheduling.

Receive continuity still fails: BV/Poco native ages max 2487/1878 ms, after
startup too. All inbound packet/byte/audio counters plateau together on both
phones at samples 94.094..95.664 s, resume at 96.460; another plateau starts
109.202 s, ends 111.616 on BV / 110.778 on Poco, then resumes. Source RTP keeps
advancing; max source admission 3/3 ms, source gap 406/405 ms, sampled native
worker stalls zero. Native delay estimates max 566/591 ms. Opus DTX remains
enabled: receive age and aggregate concealment/interruption counters are not
an acoustic speech-loss or end-to-end latency measurement.

Independent Poco ICMP reply gaps 92.917..95.559 s and 108.524..111.176 s
(2.642/2.652 s) overlap these plateaus; max RTT 2182 ms. BV ICMP remains regular
during active media (max RTT 103 ms); its largest 1.025 s gap precedes call
start. Kernel IPv4 buffer error deltas and own UDP socket drops are zero on
both. Ordinary app.ratchet.open_failed zero; separate Delivery decrypt/replay
lines 45/42 are not identified as audio E2E failures.

Fast own-UID socket sampling every ~0.5 s yields 286/280 samples, no reader
errors. Around native-age peaks TCP receive queues are zero and largest
transmit queue 2077/5720 bytes. A separate parsed TCP_INFO supplement covers
call seconds about 77..185 (387 total samples); the first collector's TCP_INFO
parser missed same-line fields, so earlier timer coverage is not claimed.
Peak-window TCP RTO strings are 0.20..0.32 s on BV / 0.20..1.69 s on Poco, but
observed cumulative retransmission counters do not increase in the supplement.
Existing nonzero counters are not proof of retransmission in this call.
Socket/timer observations are own-UID aggregates, not mapped to the chosen
media first hop. Correlation narrows the shared outage interval, without
identifying a carrier, relay or application fault as the proven cause.

Both original hydrated/stored P2P policies restored and verified. Both
packages stopped and complete package/process prefixes independently verified
exited. API forwards, log readers, both scoped remote ICMP probes and both
additional socket sampler threads exited/reaped; no fixtures or downloads
created. Private xveil-relay-audio-2216-* retain sanitized samples, artifact
checks, path attribution and cleanup evidence. Goal remains active: bounded
proxy source scheduling is fixed and installed, physical proxy-load coverage,
complete transport separation, receive continuity and acoustic quality remain
open. No push, tag or release.


Reliable routed message packetization and ACK source admission
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A second producer gap existed beyond IPC byte streams and proxy bridges:
ordinary large sealed message envelopes used 64 KiB Forward chunks and
synchronous, lossy queue admission. Reliable locally originated relay messages
now use the existing ChunkedEnvelopePayload format at 3600 data bytes per
piece, including messages below the old 64 KiB chunking threshold. Actual
Forward/metadata/hop-AEAD/padding length fits one 4096-byte bucket. The payload
is sealed once before splitting, so this adds small carrier headers without
repeating ML-KEM/ratchet sealing per chunk. Aggregate padding/bandwidth under
load has not been measured for this new producer.

Every piece awaits endpoint-owned reliable BACKGROUND source credits. A full
queue waits without invalidating a healthy route or spraying the batch through
alternatives; a missing/closed session retains indexed whole-batch rerouting.
One admission deadline covers all candidate hops, at most 30 seconds and no
later than the original envelope's remaining TTL. Partial failure reports
NO_ROUTE rather than replaying a prefix in place. Metadata, transfer/original
content ids, ciphertext, final ACK key and address remain unchanged. Received
chunk/body/count/reassembly limits remain unchanged, and the origin checks
chunk count before sending. Explicit lossy relay cells retain their prior
size threshold, chunk size and local lane; they are not converted to reliable
reassembled messages by the smaller reliable recommendation.

ACK retransmission previously injected the same batch synchronously at
INTERACTIVE priority. It now runs at most eight scoped async source-admission
futures, leaves the ordinary single-frame ACK path and health/timer loop live,
and drops these futures with the parent task on shutdown. The tracker excludes
in-flight batch attempts and defers other batches when all slots are occupied,
without spending attempts or expiring a currently admitted batch. Completion
rearms the ACK wait after admission and updates an accepted alternate hop only
for the same current attempt. A cleared authenticated ACK or replaced attempt
cancels a blocked sender within the 100 ms polling interval; no registry or
tracker lock spans a source wait. Whole retry admission is bounded by 30 s and
the stored original TTL; expired batches do not consume source credits. Fresh
outer chunk content ids bypass relay replay suppression on retry while inner
transfer/index/original ids preserve terminal dedup and one logical ACK.
No relay priority, media role hint, key validation or cryptographic rule changed.

Verification: full IPC library suite 123 passed / five previously ignored,
all ten pending-ACK tests, and three actual runtime chunk retry tests pass.
Real handle_ipc_send tests split 12 KiB and 100 KiB, verify every neutral wire
header and 4 KiB bound, reconstruct the sealed bytes, authenticate/decrypt the
original payload and check one tracked batch with a nonzero ACK key. A held
capacity-one source proves the real handler waits and retains its route.
Real SessionTxRegistry retry tests preserve reserved primary admission while
background is full, cover a closed original hop plus live alternate, feed a
retained partial transfer and duplicate indices into the actual reassembler,
then decrypt exactly once. Cancellation releases pending credits, and expiry
neither sends nor forges an ACK. Tracker tests cover the bounded worker slots,
current-attempt completion, no premature failure, single-frame timer progress
and ACK-winning removal. These are component/handler gates, not a physical
stand of the complete timer/controller under network loss.

Negative gates restoring 64 KiB origin pieces, synchronous retry admission,
or expiry of a busy final attempt fail their intended assertions. Sources
restored and positive gates repeated. IPC/pending-ACK/runtime all-target
Clippy passes with warnings denied; production ARM64 FFI builds with exactly
production-seeds,node-embedded,packet-tunnel. Native artifact is prepared;
phones still retain installed 2216, independently checked stopped with no
package-prefix processes or forwards. No new phone/macOS app stand this cycle.

Remaining scope includes large direct AppSend/fanout frames, arbitrary large
control frames, complete group/screen/compatibility behavior and actual path
separation through legacy relays. This change fixes the ordinary routed
producer and its retries; it does not establish a repair of the receive pauses
observed in 2216 or prove acoustic quality. Goal remains active. No push/tag.


Build 2217 installed envelope fix and renewed phone continuity checks
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both physical devices returned on ADB (Blackview on Wi-Fi, Poco deliberately
on cellular). Debug ARM64 APK 2217 packages root bbfb5467 / Veil af8801c4,
with exactly production-seeds,node-embedded,packet-tunnel and the unchanged
94-export production media library. Header ABI, native raw/staged/merged/
stripped libraries, version code and complete installed APK hashes verified.
BV retains its debug signature; Poco retains its production signature. Both
installs use replacement with existing profiles preserved. No release/tag/push.

Warm-PNet then temporary P2P denial audio-only repeat: incoming ring 0.182 s,
both endpoints active 2.682 s, 180 active seconds captured without an observed
ended state. All active media transports remain relay. After startup, largest
native receive ages 1024/1077 ms (BV/Poco); source RTP maximum gaps 220/402 ms
(DTX enabled), source admission maxima 2/3 ms and no sampled media worker stall.
Late receive-age peaks recur around seconds 135, 139, 143, 147, 151, 155 and
159: all native inbound packet and audio counters plateau, then resume. Poco's
independent ICMP reply gaps around the same period recur roughly every four
seconds at 1.20..1.35 s; BV ICMP remains regular. This is correlation at a
different destination, not proof of a carrier/modem/OS/relay cause. Own-UID
TCP information is parsed in this capture but not mapped to the selected
media hop; no assertion of media-specific TCP retransmission is made.

An attempted 12/100 KiB text load (six attempts per device) never reaches the
transport: the existing encrypted storage record limit raises
HvException.PayloadTooLarge. None of these attempts becomes a stored message
on either endpoint. A 100-byte control is sent and received, then deleted on
both devices; the repeated 12 KiB diagnostic returns that explicit storage
error. Thus this capture is audio-only, not a large-message load verification,
and does not physically exercise the new routed packetization/retry path.
The Veil component gates for those larger payloads remain the separate
evidence. The API storage refusal is not counted as a network delivery loss.

Separate warm relay video + 8 MiB file capture: incoming ring 1.144 s, both
active 4.314 s, last sample at 170.041 s. Download starts at 24.781 s, finishes
at 101.907 s; export takes 76.94 s and the complete file SHA-256 matches.
The progress snapshot says 8388607/8388608 bytes; the full exported file hash
establishes completion rather than that one-byte-behind progress counter.
Video decodes on both endpoints; source bitrate reaches the severe-audio
floor. This verifies simultaneous file/video/audio operation and file integrity,
not acceptable acoustic quality or complete path independence.

After the file completes, native receive ages still reach 10053/11493 ms;
source RTP maximum gaps remain 400/404 ms and source admission 0/4 ms, with
no sampled media worker stall. Poco records 114 slow socket writes, including
a 2098-byte write taking 18524 ms at second 78.185 and a 407-byte write taking
11250 ms at second 157.682. BV records none. An independent Poco ICMP gap
of 11.290 s overlaps the late outage; BV's largest reply gap is 0.527 s.
All traced media first hops report neutral independent datagram readiness
false, with no recorded source-admission refusals. This identifies real
ordered socket stalls on Poco in addition to delayed native ingress; it does
not establish their underlying cause or prove the message fix repairs them.
The stream writer and reader were already split before this capture.

BV locally rebuilds its relay media session around second 160, preserving
the active call while changing the media epoch/channel. Its packet counters
reset at 160.527 s. Counters across that rebuild are not treated as monotonic;
the recovery is not counted as an observed call end or as seamless audio.
No primary parallel-session replacement is evidenced in these captures.

Original hydrated/stored P2P policies restored and verified. Both complete
package/process prefixes independently verified exited, packages stopped with
version 2217. Own API forwards, both log readers, all scoped remote ICMP probes
and their reader processes reaped; own pending downloads canceled/absent,
cache input/export fixtures removed, own visible file offers removed. Private
xveil-audio-build-2217.json and xveil-relay-{audio,av-file}-2217-* retain artifact,
sample, attribution and cleanup records. Phones now contain the envelope fix;
goal remains active: large direct frames, complete transport separation,
physical routed-message/proxy-load coverage and receive/acoustic quality remain
open. Source changes remain unsigned and unpushed.


Direct reliable sealed source scheduling and device independence
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil 7a31b8a3 extends the 3600-byte source envelope packetizer to large
ratchet-sealed direct sends and identity fanout. Existing Forward/chunk
framing reaches the actual device session, uses endpoint background source
credits, and keeps the wire priority neutral/INTERACTIVE with no application
role hint or lossy datagram eligibility. Frame generation is lazy. Successful
direct sends retain their old source-admission reply semantics; no new E2E
ACK/retry protocol is silently introduced. A live full queue waits within a
30-second request deadline. Timeout never falls back to the original large
frame or sprays another copy. A missing/closed route can use the existing
relay fallback with the same ciphertext rather than consuming another seal.

Identity copies use at most eight scoped admission futures under one deadline.
A blocked sibling does not hold up the other live sibling in the tested pair.
Known session ownership is checked before and after certificate resolution;
matching an instance alone cannot authorize a copy to another identity. Existing
verified sender-device provenance is retained by the dispatcher: without a
verified certificate association, origin_device is omitted rather than invented.

129 IPC library tests pass (five pre-existing ignored), including six new real
handler/dispatcher/session gates: 12/100 KiB authenticated direct delivery and
metadata, duplicate and completed replay, capacity-one background wait with
reserved primary progress, two-device queue independence and key isolation,
virtual admission expiry without relay fallback or leaked credit, a closed
partial direct route followed by exactly-once relay completion, and foreign
identity refusal before sealing or plaintext fallback. Three negative gates
restoring whole direct frames, synchronous admission, or serial fanout fail
the intended assertions; sources restored and positive gates repeated.
All-target IPC Clippy passes with warnings denied. Production ARM64 FFI
builds with exactly production-seeds,node-embedded,packet-tunnel.

This component change is not a phone audio repair claim. Unsealed arbitrary
large direct/control bytes still need a distinct typed negotiated framing;
more than eight simultaneously blocked siblings are not proven independent.
Physical direct provenance/interoperability and audio/video/file separation
remain to be checked on an installed build. Phones still retain 2217 at this
source-cycle boundary. Goal remains active; commits unsigned and unpushed.


Installed 2218 direct call load and stopped-app network baseline
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Both physical phones returned on ADB and now contain ARM64 build 2218,
root a0588e85 / Veil 7a31b8a3. Production native features, header ABI,
raw/staged/merged/stripped library hashes, the unchanged 94-export media
library, full installed APK hashes and version codes verified. Both existing
profiles/signatures retained. Blackview stays on Wi-Fi; Poco deliberately
stays on cellular. Original contact/global P2P policies used without denial.

Poco-to-Blackview video call rings in 0.317 s, both endpoints active in
4.494 s. All sampled active media paths are P2P. The direct session negotiates
independent QUIC channels, and first-send traces establish authenticated
independent local slots 0, 2 and 3 after initial warmup fallback. The 8 MiB
file exports in 81.41 s with its complete SHA-256 matching. Its progress
snapshot remains one byte behind. Last call sample at 170.184 s, no sampled
call end. Video decodes on both endpoints and reduces to the severe-audio
floor; this is continuity and integrity evidence, not acceptable audio/video
quality. This stand does not prove the new direct ratchet chunk/provenance
path: P-Net admission itself reports hasCert=false.

Native receive ages still reach 3850/3040 ms (BV/Poco), with both entire
inbound packet counters plateauing near call seconds 64.6..67.9 before
resuming. Source RTP maximum gaps stay 399/403 ms (DTX enabled), admission
maxima 1/3 ms and no sampled media worker stall. Receiver dispatch maxima
1432/2509 us, with no recorded decode/ineligible/rate-limit/violation errors.
Independent Poco ICMP reply gap 3.966 s overlaps that outage; BV ICMP remains
regular (largest gap 0.564 s). Ordered write maxima 1144/3151 ms are aggregate
session evidence, not identification of the independently carried audio path.
Primary recovery attempts cancel when ACKs resume (13 BV, 6 Poco); no
successful replacement or media-session repair is established by this capture.

A separate 75-second baseline runs after both applications and every process
under their UIDs have exited. Poco still shows two ICMP reply gaps above one
second, maximum 2.482 s and RTT 1490 ms; BV maximum gap 0.528 s and RTT
76.3 ms. Thus some cellular-path variability exists without xVeil running.
This excludes the app process as the sole cause of all observed network
delays, but does not distinguish carrier/modem/OS/other traffic or establish
that every call pause has the same cause. Independent ICMP uses a different
destination; receive age is not measured end-to-end audio or acoustic quality.

Original policies verified restored. Own downloads absent/canceled, visible
offers and input/export fixtures removed; apps/package prefixes and complete
UID process sets independently verified exited and stopped at version 2218.
Own forwards, trace/network readers and call/baseline remote probes reaped.
Private xveil-audio-build-2218.json, xveil-p2p-av-file-2218-* and
xveil-idle-network-2218-* retain samples/artifact/attribution/cleanup evidence.
Goal remains active: physical direct ratchet/proxy coverage, unsealed/control
framing, complete group/screen/compatibility behavior and acoustic/receive
quality remain open. No release, tag, signed commit or push this cycle.


Negotiated bounded direct AppSend bytes and reconnect ownership
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Veil 1e9273a7 adds AppSendChunk (App message 9) for large reliable direct
application bytes without daemon ratchet sealing. The existing marked
capability extension has an explicit SUPPORTS_DIRECT_APP_CHUNKS bit, advertised
by current handshakes and authenticated resumes. Legacy prefixes/random
padding never enable it. Application bytes, including every possible first
byte, remain opaque application data; they never enter envelope-marker or
ratchet parsing merely because their content resembles a protocol prefix.

Pieces carry the existing AppSend address metadata plus bounded chunk records,
with 3600-byte data segments, lazy frame generation and neutral INTERACTIVE
wire priority. The local producer waits for reliable background credit under
the existing 30-second request deadline. Scoped identity copies retain the
eight-future limit; a full sibling does not block the tested second sibling.
No relay publication or new E2E delivery ACK protocol is introduced by this
direct format. Old decoders retain the old whole-frame contract, so this does
not bound legacy peers or unrelated arbitrary control frames.

Decoder support is stamped on the exact session-owned outbox under the
registration lock. Admission captures that sender and its capability together
before waiting for credit: neither a late old handshake nor cached discovery
can enable a replacement legacy outbox. Live session lookup drives initial
format selection; actual queue admission independently enforces the ownership
binding. The production OwnDeviceAwareLookup and SessionTxBroadcaster wiring
is retained and supplies both checks.

Direct plaintext and encrypted envelope transfers have separate reassembly
keys, with direct keys also scoped to the authenticated device. They share
the existing global byte/slot/per-sender/per-peer budgets. Every continuation
checks recipient, sender, source/destination app, endpoint and ACK metadata.
Completed direct application bytes route with the existing SessionPeer floor
and actual origin device; they cannot acquire Signed provenance or complete
an encrypted envelope transfer.

Final gates: 134 IPC library tests pass (five pre-existing ignored), including
five new real handler/dispatcher tests for all 256 initial byte values, exact
metadata and replay suppression, legacy format, capacity-one primary progress,
deadline/credit release and two-device independence. Seventeen reassembly,
six directory/admission and 24 actual fresh/resumed/legacy handshake tests pass;
the explicit capability codec test passes. Three negative gates restore whole
plain frames, borrow an old capability for a replacement sender, or collapse
reassembly domains; each fails its intended assertion, sources are restored,
and positive gates repeat. IPC/session/dispatcher/runtime all-target Clippy
passes with warnings denied. Three existing test lints fixed without changing
the control-stream mechanism; ratchet reset now asserts the dropped count.
Production ARM64 FFI builds with exactly production-seeds,node-embedded,
packet-tunnel; ELF machine and embedded header contract verified and artifact
frozen privately for the next installation.

No new app stand or APK installation this source cycle. Phones retain 2218;
no app instances were opened. This is a component framing/admission fix, not
evidence that the cellular receive pauses are repaired. Physical direct large
payload/provenance coverage, generic control/legacy behavior, group/screen/
compatibility coverage and measured audio quality remain open. Goal active;
commits unsigned and unpushed.

Paired ARM64 APKs 2219 are now prepared from root 03626f8b / Veil 1e9273a7.
Production feature set, ELF/header ABI, raw/staged/merged/stripped library
hashes, media exports, version and both packaged library sets verified. Debug
BV and production-signed Poco artifacts are frozen privately; the installer
checks each complete artifact hash before replacing an installed package.
Neither APK is installed yet: Poco disappeared from ADB and is requested for
the physical check. BV remains available/stopped; no new app stand started.

Paired 2219 installation, large direct sends and crypto refusals
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Poco returned on ADB. Both prepared APKs 2219 (root 03626f8b / Veil
1e9273a7) installed with existing signatures/profiles retained; pulled installed
APKs match the complete frozen artifact hashes. Poco's default network is
verified cellular. Both existing contact/global P2P policies and anonymous
routing preferences remain unchanged (anonymous routing was already false).

Poco-to-BV video call: ring 0.988 s, both active 4.286 s, last sample 169.265 s,
no sampled call end. Actual independent QUIC local slots 0/2/3 are established
after warmup. Concurrent live_send probes bypass storage/outbox/mailbox: ten
12 KiB and ten 100 KiB payloads per direction. Each recipient records all ten
12 KiB arrivals, but BV records six 100 KiB arrivals and Poco two. The API's
sent count only means the SDK/FFI accepted the request: its ordinary send
returns before the asynchronous daemon admission/delivery result. It must not
be reported as ten successful source admissions or deliveries. Daemon logs
show identity_fanout waits up to 16.836 s and two ratchet reset events per
device. The first capture omitted chunk-completion events; it alone cannot
attribute all missing large payloads to a specific processing stage.

Repeat without video, with chunk events captured: ring 0.174 s, both active
3.143 s, last sample 98.756 s, no sampled call end. Each recipient reassembles
all ten 104799-byte encrypted envelopes for the ten 102400-byte application
payloads, but only two application arrivals occur at each end. No chunk quota
rejection appears. After load, BV has four authentication failures, two wedged
conversation drops and two NoSession refusals; Poco has two authentication
failures, one wedged drop and five NoSession refusals. These eight refusals
per endpoint accompany the eight missing application arrivals. Each sender
receives one verified unopenable reset. This establishes a crypto-stage
failure in this run, rather than a missing-chunk explanation. It does not
establish exact physical ciphertext provenance, decrypted byte equality or
the cause of every crypto state divergence.

The existing ignored E2E test
simultaneous_initiations_converge_before_the_next_bare_frame is run explicitly
with --ignored and fails its next-bare-frame assertion with Ratchet(AuthFailed),
not a build error. Crossed initiation is therefore an independently reproduced
open component defect and a candidate for the physical divergence; matching
physical transcript/state evidence is still needed. A fix must preserve
pending-peer recovery and replay protection, not just choose a winning
initiator and discard accepted traffic. The test is not newly disabled.

Audio quality is still not acceptable. In video/direct load, maximum last-RTP
ages are 1985/1995 ms (BV/Poco); in the audio-only repeat both reach 2877 ms.
Source admission maxima are 1/6 ms with video and 1/1 ms without video; no
sampled audio worker stall. Audio-only Poco independent ICMP reply gaps reach
3.820 s during the call, versus 0.543 s on BV; some gaps precede the large
load. Primary recovery attempts cancel on ACK progress (6 BV / 4 Poco), with
no successful replacement established. Independent ICMP has another
destination, and last-RTP age is not measured acoustic/end-to-end latency.
Neither crypto refusals nor this cellular evidence prove the cause of all
audible pauses. Source separation is not an audio-quality success claim.

Veil 620cc06d separately fixes diagnostics exposed by these captures:
note_decrypt_failure reset its count to zero after logging, then exempted
every next count-of-one from throttling. Repeats now accumulate until the
60-second boundary; metrics still count every refusal. Both failure-log and
unopenable-reply sender tables enforce their actual 1024-entry bounds under
varying claimed labels, retain known sender aggregates and admit new labels
after expiry. Two new tests verify real log-file output/aggregation/boundary
and sender-flood bounds/expiry/complete metrics. All 269 dispatcher tests pass;
dispatcher/runtime all-target Clippy passes with warnings denied. Three
negative gates individually restore repeat-log flooding, unbounded log labels
or unbounded reset labels; each fails its intended assertion, original bytes
are restored, then the full positive suite repeats. This diagnostic change
does not fix crossed initiation or media delays and is not in installed 2219.

Both stands restore/check original preferences, create no file fixtures or
offers, reap their own forwards, trace/network readers and remote probes, and
independently verify complete app UIDs exited and packages stopped on both
phones. Private xveil-audio-build-2219.json, xveil-p2p-av-file-2219* and
xveil-direct-2219* retain artifact, capture, attribution, gate and cleanup
evidence. Goal active; physical crypto divergence, crossed-init repair and
audio receive quality remain open. Commits unsigned/unpushed; no release/tag.

Durable send reservations across chain changes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Following the independently reproduced crossed-init failure, source inspection
found a prerequisite for safely retaining an older ratchet context: a new
sending chain overwrote the single reservation even while disk still held the
old chain's state. A crash after that replacement could restore the old counter
without burning its previously published indices. A host regression reproduces
this ordinary epoch-change case without introducing inactive contexts.

Veil a13d0987 adds bounded live and exact-stored-snapshot sending-position
helpers. Stored metadata is decoded in native code without importing it or
exposing secret state to Dart. The C/Dart ABI contract and header are regenerated;
buffer records have explicit big-endian counters and record counts. Host
reservations now retain the union of live and durable chains, retiring a mark
only when both snapshots have stopped holding that chain. The ledger is bounded
to four positions, accepts the previous single-chain format, rejects malformed
marks, shares cache retirement across binders over one container and clears
caches on a fresh binder/restore. Same-chain sends retain their amortized write
window. Volatile epoch churn does not accumulate historical marks.

Checks: 51 host persistence/publication tests pass, including crash after a
chain change, 200 volatile epochs, durable retirement, legacy migration,
malformed state/marks and competing binders. E2E: 124 pass, the existing
crossed-init gate remains ignored and unresolved. Two FFI snapshot boundary
checks and two ABI-contract checks pass; targeted Flutter analysis and E2E/FFI
all-target Clippy pass. Two controlled negative gates discard the disk chain
or restore separate binder caches; each fails its intended assertion, exact
source bytes are restored, then the positive host suite is repeated.

This repairs reservation retirement, not the full asynchronous send/publish
contract or crossed-init convergence. A host position read followed by an
asynchronous SDK send is not an atomic epoch fence; native state may change
between them. Nor can the new format reconstruct a mark already overwritten
by an older build. Installed phones are still 2219: neither this change nor
620cc06d is installed. No audio-quality success is claimed from source tests.

Paired 2219 quiet audio and independent network observations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Poco was visible in macOS USB while missing in ADB. After reconnection and a
local ADB server restart, both phones are available. Starting the server with
the host default TMPDIR failed because /Volumes/cfb/tmp was absent; using
TMPDIR=/private/tmp/ succeeded. No app data or network settings were reset.

The new stand retains installed 2219, existing contact/global policies and
anonymous=false preferences. Poco's active default network is verified
cellular. Warm P-Net is established before the call: this is not a cold-route
signal test. Audio only, no video/file/live_send load. Incoming ring 0.191 s,
both endpoints active 3.834 s, last sample 154.588 s, no sampled call end.
After the first 15 active seconds, 173 samples per endpoint: last accepted RTP
ages peak at 2187 ms BV / 2177 ms Poco, with twelve samples over one second at
each end. Native media-cell inter-arrival windows separately report maxima
2961.0 / 2885.3 ms; these are different measurements, not acoustic latency.
Source audio cadence maxima are 220 / 358 ms, source admission at most 2 ms
each, and no sampled audio worker stall. No ordinary ratchet open failures
occur in this quiet capture, so its pauses do not require the large-send crypto
failure seen in the preceding capture.

Around call seconds 83–86, source admission stays approximately 50 datagrams/s
while both audio connections stop advancing received-UDP/ACK counters. In-flight
bytes grow past their roughly 25–27 KB congestion windows; queued datagrams
then expire. Incoming datagram counters also stop during the gap and resume
without decode rejection, rate limiting or slow dispatch. Recovery attempts
cancel on ACK progress (seven BV, five Poco); no replacement is established.
Poco's independent active-call ICMP reply gaps reach 3.048 s, maximum RTT
1551 ms; its gaps at approximately 75–78, 83–86 and 91–94 s overlap the media
pauses. BV also loses independent ICMP replies (maximum gap 3.053 s), but its
active-call maximum RTT is 91.5 ms. ICMP targets another destination and may
be rate limited: it does not identify the responsible hop or explain every
media gap. The observed ACK/UDP stalls precede congestion-window exhaustion;
source window fullness alone is not evidence of an application scheduling bug.

Poco radio polling takes 178 active-call samples: the connected SIM remains
registered on LTE, channel/bandwidth and reported signal fields do not change.
This does not prove absence of modem events or a handover, since the queried
fields do not expose a complete radio trace. Both phones remain charging,
screen-on and ACTIVE in sampled device-idle state. No blanket carrier/modem
root-cause claim is made. Audio quality and exact pause cause remain open.

Original preferences are read back; both complete app UIDs are independently
verified exited, packages stopped, own forwards absent, probes/readers reaped,
zero owned media/file fixtures/offers. Private xveil-p2p-av-file-2219quiet2*,
xveil-direct-2219quiet2-network-attribution.json and
xveil-phone-cleanup-2219quiet2.json retain evidence. No new APK is installed.

Poco and macOS: congestion and reordered call endings
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The next cycle uses Poco on cellular and the existing standc macOS profile;
Blackview is absent. Debug production-network builds preserve application data.
The first Android build omitted the Dart production-network define: its
unavailable routes were a stand configuration mistake, corrected before the
following measurements. APK signer, installed full-file hash and packaged
native ABI are checked. The macOS stand uses TMPDIR=/private/tmp/.

In the 150-second Cubic audio-only P2P call, ring arrives in 0.366 s and both
endpoints become active in 1.148 s. After discarding the first 15 active seconds,
135.016 seconds of observations record 70 decoder interruptions / 21346 ms on
Mac and 9 / 3220 ms on Poco. These are native decoder counters, not measured
acoustic latency. The source audio lane on Poco expires 1356 queued datagrams;
its congestion window reaches 2618 bytes. Mac expires 36. Source admission
stays at most 1 ms and sampled media-worker stall/drop counters remain zero.
No ordinary ratchet-open failure is captured. Independent ICMP observes gaps,
but targets another destination and cannot identify the responsible hop.

A subsequent call's cancel reaches Poco before its offer, which arrives nearly
60 seconds after being sent and starts ringing after cancellation. CallService
now remembers authenticated cancel/end even before the offer exists, scoped by
caller and call id. The same pair scopes ending fan-out and finished-call
suppression: a different peer with the same id cannot suppress a call or consume
its sibling fan-out. The bounded in-memory cache does not survive restart or
repair delayed native routing; outgoing offers still retry after local hangup.
All 129 call-service tests and targeted analysis pass. Removing early-ending
retention makes all four direct/verified-sibling reorder regressions fail;
exact source is restored and the positive suite passes again. If cancel arrives
while the sibling list is resolving, the completed resolver no longer sends
that offer. Removing this guard independently reproduces the delayed fan-out.
Both inbound lanes require authenticated provenance for an ending before a
matching active call exists, before ACK and frame dedup. A claimed copy cannot
suppress its authenticated successor with the same frame id. Active-call bearer
capabilities and sibling membership checks retain their previous semantics.
All 211 call/control, inbound-provenance and outbox tests pass; targeted analysis
passes. Disabling this proof check independently fails all four early-ending
checks (cancel/end, ordinary/realtime); exact bytes are restored and the positive
suite is repeated. In-memory ending retention still does not cover restarts.

An initial BBR-on-Poco-only warm retry rings in 0.389 s and becomes active in
3.300 s, but immediately falls back to relay (399 Mac / 398 Poco samples).
Its lower Mac interruption count does not establish a BBR improvement over
the P2P baseline: the actual routes differ. Reverse receive quality remains
poor. Both ended stands' owned macOS processes and complete Android UID are
verified exited; log readers and network probes are stopped. Private evidence
is retained under /private/tmp/xveil-call-2220/. All these results concern
sampled packet/decoder behavior; full audio-quality success remains open.

The next build (2222) tests BBR at both endpoints with Poco calling Mac. Incoming
ring takes 26.974 s after cold startup; both are active at 27.345 s. The full
150-second active call stays on P2P. After the 15-second exclusion, 135.081 s /
360 samples per endpoint record 13 interruptions / 9021 ms on Mac and 13 /
9751 ms on Poco. Receive ages reach 1955 / 2013 ms, reported loss 18% / 10%.
Source admission remains 0 / 1 ms and sampled worker/drop counters stay zero.
Both independent audio connections expire zero outgoing datagrams, but their
source QUIC lost-packet deltas are 424 / 752 over 8530 / 7990 sent packets.
Their congestion windows peak around 2.9 / 2.6 MB. Independent Poco ICMP reaches
1561 ms RTT and a 2.862 s receive gap; this is another destination, with device
and host clocks also differing. Sequential physical runs cannot establish a
controlled congestion-controller comparison. Stable improvement in both audio
directions is not demonstrated.

Native ratchet-open failures in this capture first occur after hangup, during
cleanup/locking (three Mac, four Poco), not within the measured active call.
They do not explain its active-media gaps. Post-quantum downgrade checks remain
enforced; teardown attribution and the previously reproduced crossed-init
defect are not repaired by this experiment.

Consequently production keeps Cubic. Veil adds a context-wide opt-in BBR choice
for controlled tests, inherited by clients, servers and independent sibling
connections; no media role, relay priority or wire label is added. The real
TLS/QUIC outage fixture retains all original explicit-Cubic recovery assertions
and separately checks opt-in BBR with small/large opaque frames, with and without
replacement. The observed Cubic baseline waits 1.375 / 1.852 s after the outage;
authenticated replacement takes 365 / 442 ms. BBR takes 39–49 ms in this fixture,
without duplicate delivery or stale replay. Independent fresh-key/queue/parent
lifetime checks and warnings-denied transport Clippy pass. These local results
do not supersede the physical limitations above. Owned processes, Android UID,
probes/readers and forwards for the 2222 stand are verified gone.

Build 2223 restores Cubic on both endpoints and includes the ending-provenance
guard. Poco is updated in place, with unchanged signer and full installed APK
SHA-256 verified; existing identity/history are preserved. Its Veil source is
d8c25ddd. The macOS stand is rebuilt against the same default controller.

An 80-second cancellation check requests hangup 2.278 s after placing a cold
Mac-to-Poco call. Unproven early copies are refused before ACK/dedup. Poco later
dispatches the offer and cancel 138 ms apart, with logged ages approximately
9.0 s / 6.9 s. The 350-ms state poll observes no late ringing samples, but cannot
exclude a brief incoming-state/UI transition between those callbacks. This is
not evidence that every delayed-cancellation case is repaired: early *claimed*
endings still lack the proof needed to suppress an offer before it arrives.
Authenticated early endings and the sibling resolver race are regression-tested;
cold routing delay, this claimed-ending case and physical audio pauses remain
open. No relay trust or authentication check is weakened to hide them.

The 2223 stand's complete Android UID, owned macOS process/log reader and ADB
forward are independently verified gone. No release/tag/push is performed.


#### Independent screen producer and capture intent (2026-10-07)

The endpoint now has three media producers: primary (audio and RTCP), camera,
and screen. Screen capture selects its producer at native ingress, before
queued packets drain. It has its own bounded queue/frame assembler, task,
IPC writer and cipher salt/sequence/lock. Direct and non-onion relay sends use
existing local source slots 0/2/3. Source congestion admission also limits
slot 3 when the primary stalls; neutral transit scheduling is unchanged.
There is no media role or priority instruction for relays on the wire.

Anonymous Screen gets its own lazy producer pool, outgoing circuit, private
return cookie, repair generation and route cache. VMR1 still advertises two
receive addresses for existing peer compatibility; Screen uses the secondary
receive address. This is independent source plumbing, not a claim that all
anonymous receive paths are separate. VME1 framing is unchanged. The bounded
receive cipher history retains six authenticated salts so three producers
survive two overlapping route generations, with replay/reflection checks.

The FFI/plugin installs and validates a same-app screen sender before exposing
a channel. xVeil uses a separate Screen IPC writer on endpoint 17 (endpoint 16
is already used for file streams). One-to-one and group controllers select
Screen before capture and clear it on stop/failure. Newly joined group peers
inherit the selected producer. Pending screen consent cannot be switched back
to the camera producer by a concurrent camera enable.

Hardware exposed an additional camera privacy defect: route replacement used
an old call snapshot and reopened capture after the UI camera was switched
off. Desired camera state now belongs to the call and survives replacement;
late Android camera starts also check the current engine, capture owner and
choice. A camera choice made while sharing updates this intent without
switching the screen source.

Verification completed before the final hardware confirmation:

- 45 Rust media FFI/route checks and 27 cipher checks pass. Tests include a
  blocked Screen writer while audio/camera progress, independent frame
  assemblers, three-task close, and actual encrypted anonymous circuits with
  a distinct Screen return cookie and unchanged receive advertisement.
- The actual IPC Flutter fixture passes with a private embedded node: same-app
  Screen writer accepted, another app rejected, close/repair lifetime checked,
  and node shutdown not abandoned.
- Real QUIC under neutral FIFO loss receives 467/474 admitted primary cells
  from 500 attempts, zero duplicates, p95 278 ms and maximum gap 162 ms;
  camera and Screen also decrypt, and the competing reliable file makes
  progress. The separate ACK-blackout check passes without relaxing gates.
- Targeted Flutter call/group/capture tests and static analysis pass. Native
  Clippy with warnings denied passes; generated ABI/header and Rust formatting
  are checked. A crypto fixture uses fresh directional key material to avoid
  pollution from the process-wide replay cache of unrelated fixtures.

The first 2224 screen test did not finish the Android app selector and is not
screen delivery evidence. The second 2224 test completed projection, but
produced no new decoded Screen frames. Build 2225 instrumentation identified
the cause: selecting xVeil launched another MainActivity/Flutter engine;
it attempted a second debug API bind and replaced the global frame channel.
ScreenCaptureBridge now binds only when a particular engine requests capture.
The initial singleTask experiment (2226) prevented the duplicate but cancelled
the selector result by clearing activities above the main window. That failed
experiment is superseded; the final launch mode must preserve both ownership
and the OS consent result and is verified separately below.

Audio remains unresolved. With cameras actually off after repair on 2225,
a 13.376-second relay interval has no new encoded/decoded video frames, yet
Mac and Poco each record three interruptions (2857/2890 ms), with receive ages
up to 1702/1402 ms. The earlier 2224 P2P run also loses most Poco uplink audio
and logs thousands of expired source datagrams. A 2226 cold offer rings only
at 33.072 s and both endpoints become active at 35.174 s. These are not claims
that queue separation cured physical audio or cold signalling. Video RTCP
still shares the primary producer; its contribution is not established.

Stands 2224/2225/2226 are closed: complete Android UID, owned macOS process,
log readers and owned ADB forward are verified absent. Poco remains on cellular.

Build 2227 reproduced a native Camera2 race: disabling capture while `onOpened`
created its session could close the device underneath `createCaptureSession`
and terminate the Poco process. Capture generations now fence device/session
callbacks, image acquisition and the processing queue; publication/create/close
and the native engine push have one ownership monitor. Stale callbacks may
close only their own resource and cannot stop a successor capture. Build 2228
survives the immediate post-answer disable and twelve concurrent on/off pairs
in the same process, with the call still active and final camera intent off.

The 2228 P2P voice interval (30.351 s, after startup) receives 1462 packets at
Mac / 1515 at Poco, with no recorded interruptions and no new video. The next
14.329 s with camera also records no interruptions. This short healthy sample
is not resolution evidence: the following failed-consent interval has eight
Mac and thirteen Poco interruptions (7047 / 7364 ms), with receive ages above
one second. Whole-epoch counters must not be mixed across route replacements.

The singleInstance experiment also fails to preserve projection consent on
this HyperOS device (2228). The final approach uses a non-exported plain
ScreenCapturePermissionActivity in its own task, with a process-local request
capability and callback, while singleTask reuses the existing Flutter UI.
An initial 2229 experiment explicitly removed that permission task after a
successful consent. Android then stopped the package's stopWithTask services,
including the live microphone and the not-yet-foreground Screen service, and
raised ForegroundServiceDidNotStartInTimeException. The permission activity
now finishes normally; the main application's stopWithTask policy is retained.
The final physical delivery/cancellation results are recorded below.

Stands 2227/2228/2229 are closed and their complete Android UID, owned Mac
process, log reader and ADB forward are independently verified absent.

Build 2230 completes app-only OS consent, receives the first RGBA image,
converts it, delivers it to the original Dart controller and acknowledges a
successful engine push. No second Flutter engine is started. OS cancellation
and hangup while consent is pending both resolve without leaving the permission
activity or starting an orphan projection. However, the physical receiver still
gets no new Screen frames after native camera capture: source delivery alone
is not successful encoding/delivery evidence.

Inspection found that native Camera2 passed the sensor timestamp unchanged,
whereas screen and the Flutter fallback ask the engine for webrtc::TimeMicros.
The local WebRTC implementation uses CLOCK_MONOTONIC on Android. The Android
[CameraMetadata reference](https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME)
explicitly requires clock compensation when manually passing REALTIME sensor
buffers to an encoder (that sensor clock includes device suspend). Build 2231
therefore asks the media engine for its canonical timestamp in both sources;
physical camera-to-Screen encoding is gated separately below.

The 2230 voice pauses are still real: an independent Poco-to-1.1.1.1 probe
reaches 1547 ms while the Mac probe reaches 53.255 ms. This shows cellular-path
jitter beyond the app; it does not establish that all call pauses originate
there or rule out local encoder/transport defects. Ten existing screen privacy
and permission UI regression tests pass. The complete 2230 Android UID, owned
Mac/log/probe processes, remote ping and ADB forward are verified gone.

Build 2231 is the final tested Android source of this cycle. The installed APK
has the original signer and full pulled-APK SHA-256
`aaf3e4dbc3fed66033c527cc4ab3f9fdd279b503197f1cd5110130b854b29955`.
Its Veil source is 1c1ebe98; packaged Android and Mac Veil share ABI
`877231b66c54844b05eb0bf421d0d96f79378e2c6ece74ed53ac27bca9e38440`.
The Android media/hidden-volume native payloads are unchanged by this app fix.
The paired Mac stand uses the already rebuilt 2227 host with the same Veil
library and Dart media source; the new capture/permission changes are Android-only.

The physical camera-to-Screen gate now passes: the call rings in 0.386 s and
both endpoints are active in 1.207 s. App-only consent completes, there is one
debug API/Flutter engine start and no native crash. In a 28.365-second Screen
interval within media epoch 1, Poco adds 75 transmitted video marker events
(including possible retransmissions) and Mac receives 19 new decoded frames.
This contrasts with the 2230 negative control, where the encoder/receiver
counts stopped when switching from native camera timestamps to Screen.
OS cancellation and hangup during a subsequent pending request pass again;
the permission task is gone, and no orphan capture is started.

Audio is still open: the same Screen interval records five Mac interruptions
(3769 ms) and four Poco interruptions (1731 ms), with native receive ages up to
2205 / 1265 ms. Independent probes in this stand reach 1492 ms on Poco versus
113.931 ms on Mac. The healthy short 2228 sample cannot supersede this result.
RTCP producer attribution and the distinction between encoded audio and BWE
padding remain diagnostic questions; no relay scheduling change is justified
by the current evidence. The 2231 stand's whole Android UID, owned Mac/log/probe
processes, remote ping and ADB forward are verified gone. No release/tag/push
is performed in this cycle.


Call identity/device control continuity (physical Mac + cellular Poco)
----------------------------------------------------------------------

The 2232 cold relay-to-P2P transition exposes a concrete receive/liveness bug.
The forked answer binds the Mac dialog to physical device 487b486f, but later
Poco transportInfo/health and direct media ingress use its original contact
identity 418654b3. CallService rejects those identity-attributed controls as a
different peer. Poco upgrades to P2P while Mac remains on relay with a native
receiver registered only for the physical address. Mac logs `no-channel` for
identity ingress; its audio receive counter freezes at 181 and native receive
age grows beyond 22 seconds before the 24-second liveness timeout. Poco keeps
receiving Mac's relay egress. The harness ends only after the endpoint is lost;
it did not cause this timeout. Camera-load phases after that loss are invalid.

CallService now normalizes only the saved original identity of the exact live
call to its already accepted device dialog. Native admission still checks the
answering physical device; policy and media-key verification are unchanged.
The regression covers an unrelated readiness/health sender, identity readiness,
physical-device admission, identity health for 60 seconds, and eventual timeout
when authorized health stops. Removing just the normalization makes this test
fail (expected P2P switch, actual none); restoring it passes. The call service,
media seals, audio routes and identity/device policy gates total 160 passing
tests.

Endpoint-only native diagnostics now distinguish actual Opus RTP payload,
header/padding-only probes, retransmitted audio and accepted RTCP sends. Bounds
checks cover CSRC, RTP extensions and invalid padding; padding cannot renew the
actual payload clock. Existing counters and packet sending remain unchanged.
The C++ smoke test and rebuilt Mac native engine pass; the Android native media
payload is unchanged, so these new diagnostic fields are Mac-only in stand
2233. Nothing about media roles or priority is added to relay framing.


Build 2233 installs the Dart control-continuity fix on both endpoints. Poco's
APK retains the original signer and full pulled-APK SHA-256
`52a9e64880d02d7edd58d427dc891c29237024f88ae10442412f00accb04ee71`.
A 115-second Mac-to-Poco call rings in 1.127 s and becomes active in 2.460 s;
both endpoints upgrade relay to P2P and continue receiving until deliberate
hangup. This answer arrived under the identity, so physical coverage of the
forked-device normalization itself remains the original failing capture plus
the controlled regression, not an observed same-case hardware positive.

Audio remains defective. In one stable P2P epoch, the 28.778-second voice-only
window has 9 Mac / 11 Poco interruptions (9779 / 11793 ms), with receive ages
up to 2943 / 2794 ms. Mac produces 1440 actual audio payload packets and 303
padding packets, no retransmitted audio, and 197 RTCP packets. Its actual
payload maximum gap is 101 ms, queue admission is below 1 ms, and pacer delay
is zero: these counters distinguish a receiver gap from a stopped Mac encoder.
The following 29.570-second phone-camera window has no new interruptions and
33 new decoded Mac frames; this healthy interval does not resolve the earlier
voice failures. Independent Poco ICMP reaches 1524 ms in this stand, while
Mac ICMP reaches 61.371 ms.

After restarting both apps without forcing endpoint exchange, a Mac call fails
the harness's 45-second setup budget. Its offer arrives at Poco about 62 seconds
after placing it, after the harness's cancellation. Native trace shows missing
ratchet session/unavailable message keys, while unauthenticated realtime offers
are correctly refused. This is unresolved cold delivery, not repaired by the
control alias change; sender authentication is retained.

A subsequent Poco-to-Mac call rings in 0.396 s and becomes active in 0.776 s,
remaining active for 140 seconds. Voice-only P2P intervals repeat normal / paused
publish-and-mailbox / normal / paused / normal operation. Pauses persist in both
paused windows (6/8 and 5/6 new Mac/Poco interruptions). Pausing these two tasks
is therefore not sufficient to remove the fault; already in-flight traffic and
other traffic are not excluded. The process-local diagnostic switches are
restored before teardown. Both 2233 stands are closed; complete Android UID,
owned Mac/log/probe processes, remote ping and ADB forward are verified absent.
The next investigation is the unexpectedly large audio probe traffic, not a
relay priority change. No acoustic-quality success or complete repair is claimed.


Audio estimator/probe budget (2234)
-----------------------------------

The separate audio Call inherited WebRTC BitrateConstraints' 300-kbit/s
startup prior and unlimited maximum, even though the camera uses its own Call.
In the 140-second reverse stand the first 17.596-second stable voice interval
contains 1598 Mac padding packets versus 880 audio payload packets; by 91.457 s
padding accounts for 437515 bytes versus 269861 actual encoded-audio bytes.
The ordinary source FIFO cannot treat such empty packets as useful speech.

Both unicast and group audio CallConfig now start at 48 kbit/s with a 96-kbit/s
estimator/probe ceiling. Opus/FEC/DTX settings, audio allocation behavior,
video estimates and Veil/relay policies are unchanged. The real native gate
uses a counting ADM, actual AudioState/Opus streams and synthetic video,
verifying outgoing audio and independent video estimates. Before the fix it
fails with audio=300000 and video=900000; afterward unicast audio=48000,
video=900000 and group audio=48000, video=300000 pass. The complete native
call-plane suite passes, including held video queues, source pause, low-rate
encoding, feedback, muted capture/rebuild and teardown. Production Mac native
media is rebuilt; the change has not been built into Android's native media.
The local Android WebRTC output lacks its archive/compile database, and the
Linux builder is not available in this workspace.

Physical 2234 pairs the capped Mac with Poco app 2233 (uncapped Android native
media). Mac-to-Poco rings in 0.369 s, both endpoints are active in 1.145 s and
remain active for 115 seconds until deliberate hangup, in one P2P media epoch.
Mac sends 5754 payload packets / 447376 payload bytes and 581 padding packets /
29166 padding bytes, with no retransmitted or unclassified audio. Its maximum
actual payload gap is 110 ms and admission below 1 ms. This demonstrates bounded
probe load and continuing encoding, not an acoustic-quality success or a causal
A/B estimate across different cellular conditions.

The 28.669-second initial stable voice window still has 1/2 new Mac/Poco
interruptions (304/768 ms). The 29.312-second camera interval has no new
interruptions and 34 new Mac decoded frames. After camera stops, the final
29.335-second voice window has 6/8 new interruptions (7700/7670 ms), with receive
ages up to 4160/3980 ms despite regular Mac encoded audio and little padding.
Independent ICMP reaches 2216 ms at Poco versus 53.203 ms at Mac. Poco's primary
QUIC admission trace reaches 355 expired outgoing datagrams, despite nonblocking
app admission. The remaining network/QUIC delivery gaps therefore are not solved
by this one-ended cap, and Android deployment of the cap remains unverified.
Cold authenticated signaling/ratchet recovery and same-case physical forked
answer coverage are also open. The complete stand and native test processes,
Android UID, local/remote probes and owned ADB forward are verified exited.


Video RTCP source ownership (2235)
----------------------------------

The separate native audio/video Calls still shared one Transport::SendRtcp
entry. Rust classified their RTCP as audio, putting video feedback/reports
into the primary source queue, connection and cipher epoch. Both unicast
video streams and both group video streams now use a video transport adapter.
It preserves the producing Call's ownership through a new nonblocking
veil_media_send_video_control_datagram boundary. Camera control uses the
camera source; local screen sharing selects the screen source. Full/busy
video admission never falls back into audio. Video RTCP also no longer reads
the audio playout mutex or appends its VAP1 audio feedback extension.

The direct camera pump explicitly retains Secondary sealing even for RTCP,
whose packet type alone would classify it as Primary. Relay control enters
as a complete work item, preserving any partially assembled VP8 frame. The
existing relay video queue/frame counters therefore count these control work
items as well as complete video frames. Source selection is endpoint-local;
relay framing and transit scheduling are unchanged. Incoming RTCP is still
dispatched to both native Calls for SSRC demultiplexing: this change isolates
outbound source ownership, not the complete receive control path.

All 33 Rust media-priority tests pass, including compound framing rejection,
camera/screen backpressure with available audio, teardown and preservation of
a partial relay frame around control. The complete real WebRTC Call suite
passes twice. Its actual TWCC gate checks that audio/video feedback leaves
through the respective source API, and its group gate holds video RTP and
video RTCP sends while audio continues. Restoring only the four old video
transport bindings fails on video feedback observed in the primary source;
the fixed bindings are restored before production builds. Rust formatting and
diff checks pass. Windows thunk/export filtering is updated but not compiled
on this Mac. No full CI or acoustic-quality success is claimed.

Mac SDK and production native media are rebuilt; Android SDK and APK 2235
are rebuilt and installed with the original signer, preserving the phone's
data. A complete pull matches APK SHA-256
678b82d32c52a0d551bac3313de946d76e5322ff8ef40ed93a9ab1128c3b20fd.
The new shared SDK ABI is
9addb7381e09bc3545d0484a90399ba5855e7805e1b68ea03c0c6d64ab7f3136.
Android's native WebRTC media artifact remains the previous binary: neither
the audio estimator cap nor this C++ RTCP adapter is deployed on Poco yet.

With Poco on cellular, Mac-to-Poco rings in 0.377 s, both are active in
1.229 s, and the 115-second call ends by the harness's deliberate hangup.
The answer actually rebinds root identity 418654b3 to physical device
487b486f. Later readiness/health/control arrives from the original identity;
the fixed caller upgrades to P2P and receives through the end. This provides
the previously missing physical positive for the forked-answer normalization.
No no-channel media drops appear in the captured app devlog. The measured
windows all remain in media epoch 3.

The 28.726-second initial voice window has no new interruptions on either
endpoint. In the 29.531-second phone-camera window, Mac sends 278 video RTCP
packets / 12468 bytes through the new source, and decodes 18 new video frames.
Audio still has 5/7 new Mac/Poco interruptions (4927/6849 ms), with receive
ages reaching 3287/2923 ms. The final 29.609-second voice window has another
2/2 interruptions (1163/889 ms). Across the call Mac continuously produces
5509 actual audio payload packets, with 353 padding packets, maximum actual
payload gap 110 ms and admission below 1 ms. Independent ICMP reaches
1541 ms at Poco versus 53.561 ms at Mac. Primary QUIC traces reach 208 Mac /
96 Poco expired outgoing datagrams; separate camera traces show no expiry.
These observations retain network/QUIC delivery gaps as an unresolved fault;
they do not identify all causes or establish that the RTCP change solves it.
Cold authenticated signaling/ratchet recovery and Android native deployment
also remain open. Apps, complete Android UID, native tests, owned local/remote
probes and ADB forward are verified gone after teardown.


Residual QUIC congestion-window capacity (2236)
-----------------------------------------------

A local protocol reproduction identifies an additional admission defect:
ordinary small packets were required to have room for an entire MTU in the
congestion window. Two outstanding 1000-byte datagrams in a valid 3000-byte
window therefore prevented a queued 64-byte datagram from being transmitted,
even though the complete encrypted packet fit. The reproduction fails on
the previous packetizer before waiting for an ACK; its source deadline is
75 ms. This identifies a protocol defect, not the sole cause of cellular
playout pauses.

Established ordinary 1-RTT packets can now use the residual window, preserving
the existing strict in-flight budget and pacing checks. A short final GSO
segment retains the alignment of earlier segments. Whole oversized datagrams
remain queued until ACK progress; reliable streams can use a shorter packet.
Initial/coalescing requirements, requested MTU padding, PATH_RESPONSE padding
and loss-probe exceptions are retained. The optimization is generic for all
connections/frames, without inspecting application roles or changing relay
priorities. The endpoint trace exports a generic residual_window_transmits
counter to verify actual use on physical connections.

All 270 standalone quinn-proto tests and 3 doctests pass. New gates verify
small expiring datagram delivery, preservation of a larger queued datagram,
reliable stream completion and requested MTU padding. The original GSO I/O
count gate remains unchanged and passes. Veil's limited neutral FIFO UDP
suite passes 13 tests covering primary freshness, concurrent video/files,
file progress and recovery; 6 ignored manual/characterization experiments
are not executed. Formatting and diff checks pass. No full CI result is
claimed.

Mac SDK/app and Android SDK/APK 2236 are rebuilt. Poco receives an install-r
with the original signer; the completely pulled APK matches SHA-256
bc3bffd760b97331d38a08c48902f493b4f4ee1a5c9e0954c439473b93453cba.
The shared ABI remains 9addb7381e09bc3545d0484a90399ba5855e7805e1b68ea03c0c6d64ab7f3136.
Mac uses the current native audio cap and video RTCP adapter; Android native
media remains the previous artifact, so those C++ fixes are still not deployed
on Poco in this measurement.

With Poco explicitly on cellular, Mac-to-Poco rings in 0.389 s, both endpoints
are active in 1.177 s, and the call stays active for 115 seconds until the
harness hangs up. Stable measured windows retain P2P media epoch 3. Primary
connection traces reach 104 Mac / 39 Poco residual-window transmits, confirming
that the new packetizer is exercised physically. Primary outgoing expiry
still reaches 317 / 123; separate camera traces show no expiry.

The 28.827-second initial voice window has 10/13 new Mac/Poco interruptions
(10686/10157 ms), with receive ages up to 2580/2829 ms. During the 29.819-second
camera window there are no new audio interruptions; Mac decodes 33 new frames
and sends 240 video RTCP packets / 10136 bytes on the video source. Final voice
has 4/5 new interruptions (3297/2349 ms) over 29.538 seconds. Mac produces
5254 actual audio payload packets and 875 padding packets, maximum payload
gap 106 ms and admission below 1 ms. Independent ICMP reaches 1566 ms at Poco
versus 77.315 ms at Mac. This measurement does not establish a causal quality
improvement over previous calls with different cellular conditions. Delivery
pauses, Android native deployment and cold authenticated signaling/ratchet
recovery remain unresolved. Both apps, the complete Android UID, owned
local/remote probes and ADB forward are independently verified exited.


Android native builder recovery
-------------------------------

An isolated Colima profile `xveil-media` now runs an aarch64 VZ VM with Rosetta,
8 CPUs, 12 GiB RAM and an 80 GiB data disk. An actual Linux amd64 container
reports x86_64 and runs the compiler/dependency tools. Its Ubuntu image is
pinned to sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401.
The media source is mounted read-only; output uses a private stand directory,
and the checkout/cache uses the named volume `xveil-webrtc-android-4ef980bc`.
The Docker host is the profile's explicit Unix socket. The container is
`xveil-media-build-2236`; it preserves installed build tools between retries.

The actual WebRTC checkout is verified at
4ef980bc2c70834276c791e71e7834b8809f24ad, matching the Mac archive.
The literal gclient configuration selects target_os=['android'] and
custom_vars.checkout_instrumented_libraries=False for this non-MSan release
build. A stalled unused Linux instrumented archive is excluded. Dependency
sync requests --no-history; compiler parallelism is bounded to six jobs.
Patchelf is installed for the required libveilclient_ffi.so ELF dependency.
Synchronization is still in progress: this environment setup does not yet
establish a successful Android archive, media link, packaging or deployment.
The next physical call must verify the new native artifact on Poco before
claiming that the two native endpoint fixes are deployed there.


The existing Mac checkout provides the exact pinned third_party commit
773cf3db24ccb5c7da8cbb93bd1a95465ed07dbe. A private shallow object cache copies
the original commit and its complete current tree, without synthetic commits.
Git connectivity verification passes, and the tree matches
e348f7a5566b444f2d50a9c369116f03ae439f86. The cache is 757940911 bytes;
Linux imports it with a depth-one local fetch and reaches that exact HEAD.
This replaces a remote dependency fetch requesting 3190283 history objects.
The original upstream origin and source revision remain authoritative.

Dependency synchronization, CIPD and resource/system-library hooks complete.
GN generates compile_commands.json and 7317 targets; the Android arm64 webrtc
archive starts a 4340-step build with ninja -j 6. Compilation is verified live,
but archive completion, media linking and phone deployment are still pending.
Private follow-up stand helpers prepare a 128 KiB checksum-verified file transfer
alongside phone screen sharing and audio; that combined physical case has not
yet run. No new acoustic or Android native-deployment success is claimed.


Android native deployment and screen shutdown race (2237–2241)
-------------------------------------------------------------

The pinned Android build completes all 4340 steps and links an AArch64 ELF.
Its SHA-256 before AGP processing is
a0fa09ebc0f7719a5f634d26d5f2229aa55f14bd92d4acb7ebd51672e93b8b42.
The Dart export check passes: 94 exports and 94 lookups. DT_NEEDED includes
libveilclient_ffi.so; all three media imports resolve against the packaged SDK,
including veil_media_send_video_control_datagram. Independent llvm-strip
--strip-unneeded reproduces AGP's packaged artifact exactly, SHA-256
442b95dfbd591f95e9c5b17cc832126e1813e6a721a914a295efb5e9376b2deb.
Thus the audio startup cap and video RTCP source separation are now deployed
on Poco. SDK ABI remains 9addb7381e09bc3545d0484a90399ba5855e7805e1b68ea03c0c6d64ab7f3136.
The isolated builder VM is stopped before physical measurements.

Poco receives install-r updates with the original signer. Full installed APK
pulls match the signed artifacts: 2237 SHA-256
255b2b337fc54e74316484a26fcf3eb8a21a468d4f9302349c5f0d4d6a390b15;
2241 SHA-256 fc2be2e9ab8adf6cfa7a08fe935b404e9f5eb9f54c73f0935122b1e3c784ec70.
Identity/history are retained; Mac uses the existing 2236 stand build.
Relay scheduling and wire metadata receive no media roles or user priority.

Physical native-android2237 lasts 115 seconds after both endpoints become
active. Measurements are aligned to that event, rather than call placement;
the ringing delay is 16.987 seconds and both-active delay 18.800 seconds.
Media epoch 3 remains stable in each measurement window:

| Window after active | New interruptions Mac/Poco | Added interruption duration Mac/Poco | Maximum native RX age Mac/Poco |
| --- | --- | --- | --- |
| Voice 16–45 s | 4 / 5 | 5130 / 6552 ms | 3470 / 3301 ms |
| Camera 50–80 s | 0 / 0 | 0 / 0 ms | 664 / 387 ms |
| Voice 85–115 s | 2 / 6 | 1440 / 5172 ms | 2112 / 1803 ms |

The camera window receives 22 decoded frames at Mac. Video RTCP advances on
both native endpoints: 319 packets at Mac and 59 at Poco in that window.
Audio RTP admission maxima are 0 ms / 2 ms. Independent ICMP maxima are
55.473 ms / 1527 ms. Primary QUIC expiry counters reach 316 / 106 and residual
window transmission counters 46 / 26. These are transport/counter observations,
not a controlled before/after comparison or an acoustic quality guarantee.
Voice pauses remain unresolved.

The first file case (2238) starts an audio-only call, so screen enabling is a
no-op by the existing video-call guard. Its screen result is excluded. The
128 KiB random file is nonetheless downloaded in 2.4 seconds with matching
SHA-256, and the call lasts 170 seconds. In 2239 the video call's direct media
path falls silent during projection consent; relay recovery cancels the pending
capture as the old media channel closes. This is not counted as a successful
screen-load case.

A repeat without restarting applications (2240) rings in 0.376 seconds and is
active in 1.809 seconds. Single-app projection of xVeil starts; the concurrent
128 KiB download takes about 3 seconds and its SHA-256 matches. Mac receives
66 decoded screen frames in the measured 42–100-second interval. In that
interval Mac adds no audio interruptions; Poco adds two, and native RX ages
reach 898 / 873 ms. At screen-off around 100 seconds, the Android process
crashes with IllegalStateException: Image is already closed, from
ScreenCaptureService.rgbaToI420 → onImageAvailable. The call consequently loses
its Poco endpoint. This run proves screen/file delivery, not successful shutdown.

The shutdown defect is a concrete ImageReader lifetime race: service teardown
can close an acquired Image while the worker reads its planes. Conversion,
Image.close and reader shutdown now share a service-local monitor. Late image
callbacks check both shutdown and reader identity before acquiring anything;
the shutdown flag is visible across threads. No audio or network lock is involved.
APK 2241 compiles this fix. The repeat rings in 0.393 seconds, is active in
1.726 seconds, and continues for 140 seconds until deliberate hangup. Screen
capture starts at about 29 seconds; the 128 KiB file download takes 14.3 seconds
with matching SHA-256. Screen-off at 100.065 seconds returns screenOn=false.
Both endpoints remain active afterwards, through hangup. The phone log has no
screen-capture fatal exception or closed-Image error. The same previously
crashing lifecycle thus passes with the fix on the physical phone.

This run still fails the audio-quality objective. In the 40–100-second window,
Mac/Poco add 10 / 6 interruptions with 8431 / 10229 ms summed duration; native
RX ages reach 4725 / 4456 ms. Mac decodes 62 screen frames, with a maximum
inter-frame gap of 10283 ms. Audio admission maxima remain 0 / 4 ms and media
epoch 3 is stable. ICMP maxima are 54.083 / 1568 ms; primary QUIC expiry counters
reach 423 / 329, with PTO counts reaching 3. Screen shutdown is fixed, but
cellular media pauses and cold signaling/recovery remain open. The shorter
file transfer and cleaner camera window in other runs are not causal evidence
of a general audio-quality improvement.

Every physical stand is closed after collection. Final cleanup verifies the
whole Android app UID, owned Mac/log/probe processes, remote ping and ADB
forward are gone. The private builder VM remains stopped. Root owns the screen
lifetime fix and report; Veil and hidden-volume have no new source changes in
this cycle. No push, signing of commits, tag or release is performed.


Incoming audio outage also reserves local video bandwidth (2242)
---------------------------------------------------------------

2241's largest measured audio hole shows the priority gap: Poco still has
video_send_paused=0 at audio RX age 4456 ms, RTT 1844 ms and no fresh remote
playout delay. The old severe guard needs RTT >= 2000 ms or confirmed remote
playout >= 1000 ms; these last-known estimates do not reveal a receive outage.
Primary QUIC counters freeze incoming UDP/ACK progress through that hole and
reach three PTOs. The concurrent ICMP stream also has cellular delay bursts;
this does not establish whether all additional QUIC delay is network-side.

The single-call controller now supplies expected incoming audio posture to
CallBitrateAdapter. An actual native RTP gap >= 1000 ms immediately reserves
video bandwidth at any ladder level, rather than waiting for fresh RTCP or
descending each rung. This pauses local encoded video/screen sending through
the existing native pause API, retaining capture and reception. Recovery still
needs 12 healthy samples and now also requires native audio age < 500 ms.
The received-packet counter and valid native telemetry are prerequisites;
ordinary Opus DTX intervals, unknown/legacy telemetry and the peer's intentional
microphone-off posture do not claim a receive outage. CallService propagates
only capture changes passing its existing call/peer and timestamp checks.
The policy and measurements remain local; no relay rule or wire role changes.
Group calls keep their existing aggregate-feedback policy; this new receive
age guard is currently for the single-call native stream.

170 adapter/service tests pass, including the captured 4456-ms sample, stale
good RTT during missing audio, recovery, DTX, mute and timestamp ordering.
Disabling the new outage-to-reserve branch makes the captured-sample regression
fail with expected true / actual false. Analysis of the three changed runtime
files passes. Both Mac and Poco use Dart build 2242; native SDK/media libraries
are unchanged from the verified 2241 set. Mac's bundle seal/kernel version and
Poco's original signer/full installed APK match are verified. APK SHA-256:
d3a855a19c661ef306dbae94ccfb27e418c06501b3f462f48d43fcbda6a5833b.

The physical call rings at 12.515 seconds, is active at 14.283 seconds, and
lasts 140 seconds until deliberate hangup. At placement-relative 25.668 seconds,
Mac native RX age is 1085 ms with video still unpaused; the next sample at
26.034 seconds shows paused video, RTT 1076 ms and remote playout 55 ms.
Poco's sample at 39.783 seconds has RX age 1292 ms, RTT 454 ms and remote
playout 511 ms; at 40.175 seconds video is paused. These RTT/playout values do
not meet the old severe guard. A newly arriving audio packet does not immediately
resume competing video: both endpoints retain the pause through this unstable
run. Healthy-path physical recovery is not demonstrated by this run.

Single-app screen capture starts around 28.6 seconds after the active event,
but encoded screen frames remain paused for audio, so this run is not a
successful screen-delivery load test. The 128 KiB file is received in 19.9
seconds with matching SHA-256. Screen-off at 100 seconds and final hangup
succeed without the earlier ImageReader crash. During the 40–100-second window,
Mac/Poco still add 5 / 5 audio interruptions, with 4962 / 5060 ms summed
duration and RX ages up to 3775 / 3578 ms. Admission maxima are 0 / 4 ms;
independent ICMP maxima are 52.764 / 3012 ms. Primary datagram expiry counters
reach 496 / 200. The local priority gap is fixed; audio quality and cold
signaling remain unresolved, and no causal quality improvement is claimed.
All stand applications, probes and the owned ADB forward are closed afterwards.


Local QUIC scheduling is measured separately from path delay (2243)
-----------------------------------------------------------------

Quinn now records endpoint-to-connection protocol-event queue delay and timer
lateness against each scheduled monotonic deadline. Last/maximum delays and
counts of observations >= 100 ms are cumulative per connection. The existing
local rt_trace admission snapshot exposes these six generic counters through
veil-transport. Nothing new is transmitted; source roles, relay forwarding,
congestion control and admission rules are unchanged.

A real UDP/QUIC test blocks its current-thread runtime for 250 ms, checks that
an expired timer reports the local stall, and verifies application datagram
delivery afterwards. It passes against the vendored quinn-proto 0.11.15; the
standalone Quinn lock names upstream 0.11.13, so this gate needs an explicit
local patch and cargo update in its temporary test setup. The tracked standalone
lock is restored after testing. The existing bounded-primary-recovery gate also
passes. The Mac and Android production SDKs build successfully; ABI remains
9addb738. Android's packaged SDK equals an independently stripped new artifact,
all 94 native media exports resolve, and the installed APK equals the signed
artifact (original signer retained). APK SHA-256:
cd6c72214410a8efb35b6ec9bdca44889b772746e0c84466df1184fc422a1fa8.
Mac's bundle seal and Dart version 0.13.84+2243 are verified. Early host build
scripts waited in dyld_start during macOS provenance evaluation; the evaluation
completed without changing system security policy.

The physical Mac/Poco call rings at 0.400 s and is active at 1.609 s. Both use
P2P and native media epoch 1 stays stable throughout 180 s until deliberate
hangup. Poco's default network is CELLULAR. Cameras are disabled initially,
enabled around active +60 s, and disabled around +110 s. During active 70–105 s,
both endpoints receive 18 additional decoded video frames; Mac/Poco add 1/0
NetEQ interruptions (150/0 ms), with native receive ages <= 447/374 ms.
Video delivery is sparse (maximum gaps 6496/7529 ms), so this is not a claim
of healthy video quality.

During the final audio-only active 125–180 s window, Mac/Poco add 1/4 audio
interruptions (876/2241 ms), with native RX ages up to 1095/1005 ms. The largest
Poco RX age over the whole post-startup call is 1044 ms near camera activation.
Audio submission maxima remain 0/2 ms. Primary protocol-event queue maxima are
417/2597 us and timer-lateness maxima 3491/2972 us, with zero >=100-ms local
stalls. Thus local QUIC driver scheduling does not explain this run's audio
holes; this is not evidence excluding every other local processing layer or
establishing the carrier as the sole cause of earlier 3–5-second gaps.
Independent ICMP maxima are 52.960/1118 ms.

Mac's primary expiry counter reaches 67 and one admission snapshot reports 41
buffer-policy drops; Poco's expiry counter reaches 2. Checking the admission
path confirms it already purges expired datagrams before reading capacity.
The endpoint's 4-KiB backlog rule can still reject complete new frames while
unexpired data occupies its bounded queue. The once-per-second trace aggregates
drops but reports current capacity, so a snapshot with queued_wire_bytes=0 does
not establish that an empty queue rejected that frame. The remaining work is
to correlate loss/ACK/PTO and these admission decisions with audio delivery,
then verify the appropriate endpoint fix. No quality improvement is attributed
to the new diagnostic counters, and audio-quality work remains open.

After collection, both applications, their whole Android UID, owned Mac/log/
probe processes, remote ping and the owned ADB forward are independently
verified absent. The private Android native builder VM remains stopped.
Veil commit 45a89c37 contains the diagnostic change; hidden-volume is unchanged.
No push, signed commit, tag or release is performed in this debugging cycle.


Group receive priority and linked-device media identity (2245)
-------------------------------------------------------------

The group native engine now reports each receiver's accepted audio RTP age,
using WebRTC's packet timestamp rather than the host's last stats poll. Unknown
receivers report -1; an explicit capability remains present on worker timeout.
Group video uses the same >=1000-ms immediate receive-outage pause as direct
calls. Recovery requires every expected, unmuted remote participant to have
fresh accepted audio; unknown or stalled receivers cannot earn recovery.
Muting the local microphone does not waive incoming-audio protection. The debug
API exposes the controller's cached sample, so API polling cannot refresh it.

Physical testing also found that the group adapter used the SDK device id for
its local media identity. On linked Poco this opened a channel to its own
identity roster entry and hashed the wrong participant pair. It now awaits
peerFacingNodeId, matching direct calls and the authenticated room roster.
A test drives the actual production adapter over a linked SDK double, verifies
that only the remote channel opens, and compares its keys with the remote's
directional derivation. Group control now races the ordinary contact identity
lane with existing realtime paths, including restored local outbox frames.
Anonymous posture is retained; no call control enters relay mailbox storage.
Membership, epoch encryption, sender signature and dedup/ACK gates are unchanged.
This is delivery redundancy, not a fix to the underlying ratchet failure.

248 selected Flutter tests pass (adapter, group media/service, direct-call
service and realtime delivery); analysis of five changed runtime files passes.
Reverting either the identity choice or the group contact leg makes its new
regression fail. The earlier receive-priority negative gate also fails with
the guard disconnected. The real native WebRTC suite passes with video RTP/
RTCP queues held, age advancing without host polling, rejoin age reset and
worker-timeout capability reporting. Veil commit 65a2f25c contains the native
age and smoke-test changes; SDK and hidden-volume code are unchanged.

Mac and Poco run 0.13.84+2245. The Mac bundle seal, Dart image and new group
media capability are checked. Android retains the original signer; the full
installed APK equals the signed artifact, SHA-256:
ec0c05bf5d764e68f8745afba69b63e2a82f1f57c8b74220519028c586acf736.
The packaged media equals an independently stripped new native artifact;
all 94 Dart exports and three SDK imports resolve. Its SHA-256 is
1661835e86745a68347a667544f22a1ff89d99ef79e9e91b54accfe5a5b9bf2f;
the unchanged SDK is 2a84700a5b12dbadbadd8c0f1212b8b3fd551195e073c17e7fffea39173d5d1b,
ABI 9addb738. Only the cached WebRTC archives are reused for native compilation;
the private builder VM is stopped afterwards.

The valid two-device group run rings at 1.027 s and both sides hold the SAME
call id with two participants at 18.841 s. Each endpoint opens exactly one
remote channel. It runs for 175.228 s after that event, ending by explicit
local leave on both sides. Earlier 2244 trials did not establish a shared room
and are not media-quality evidence; the driver now checks call id and roster,
and uses leave rather than an owner-only end action for cleanup.

At placement +25.404 s Mac pauses video with accepted audio age 2207 ms, RTT
0 ms and peer playout 20 ms: the old severe RTT/playout thresholds would not
explain that decision. Poco also pauses. The phone microphone is off at
active +30.004 s and on at +45.181 s. Cellular data is intentionally off from
active +85.135 to +89.337 s and then restored; CELLULAR is independently
confirmed as the default network. Both audio streams recover. During active
110-175 s they receive another 518/3144 packets (Mac/Poco), with receive ages
<=864/359 ms. Final accepted totals are 1246/8294, ages 195/13 ms.

Video remains paused (seven encoded frames on each endpoint), so healthy-path
physical video recovery is still unproven. Audio delay estimates reach
499/563 ms and group establishment still takes 18.8 s; no satisfactory audio
quality or resolved cold signaling is claimed. Ratchet message-key failures
were observed in the earlier invitation run. The test's ordinary owner group
remains on Poco (its owner cannot leave); Mac has left it. No existing group
membership or history is changed by cleanup.

Both applications, whole Android UID, owned Mac/log/probe processes, remote
ping and owned ADB forward are independently verified absent. The private
builder VM remains stopped. No push, signed commit, tag or release is performed.


Original source-age budget for local primary datagrams (2246)
------------------------------------------------------------

Veil 5cfc0468 fixes a local scheduling lifetime extension: primary audio could
wait up to the generic 500-ms queue limit and then acquire another 200 ms at
QUIC submission. Trusted endpoint-local REALTIME lossy frames now expire at
200 ms in every queue path; all fragments retain the original envelope's
queued_at deadline on both independent and shared QUIC senders. Expiry is
checked before encoding/carrier charges. Reliable data does not expire under
this rule. Transit packets retain the neutral INTERACTIVE classification and
500-ms lossy budget, regardless of the wire's claimed priority. Relays receive
no media-role/deadline field and apply no user traffic priority.

29 queue, one blocked ingress and 14 realtime routing tests pass. Reverting
the primary queue budget or renewing the transport deadline makes the new
regressions fail; exact source bytes are restored afterwards. The existing
real QUIC outage gate also passes (200-ms deadline plus a 20-ms link gives
220-ms maximum delivered age). Its baseline comparison validates the expiry
primitive, not the incremental phone-quality effect of this source-age fix.

Mac and Poco run 0.13.84+2246 with freshly compiled SDKs. The Mac bundle's
__TEXT,__text matches the fresh SDK. Android's packaged SDK equals an
independently stripped fresh build, SHA-256:
731f47dbd5006399b857cf377973f7bdb374a2f49433b3d14e37592a2086ac4a.
ABI remains 9addb738; native media and hidden-volume are unchanged. The full
installed APK matches the signed artifact, SHA-256:
0fc3d65d2b5a9f97fe5459448513f5b5f250e76eec5692a6c4f903367846ed4f.

The physical 180-s call rings at 0.383 s and both endpoints become active at
1.623 s with the same call id. P2P initially delivers audio, then both primary
ACK counts freeze around placement +7 s. Native accepted audio age reaches
10.5/11.3 s, although local admission is <=2 ms and sampled primary scheduler
lateness is below 3 ms. Both endpoints fall back to relay around +18/19 s;
these observed relay hops use the legacy non-datagram carrier. Later relay
windows still show multiple multi-second audio interruptions. Requested
camera phases decode zero video frames, so healthy video recovery is unproven.

The independent Android ping probe also stalls: the response at placement
+6.843 s is followed by a burst at +22.162 s with RTT up to 9989 ms. Android's
own receive timestamps and reported RTT establish that this is not merely
host ADB output buffering. The few quick replies inside the earlier stall
window cannot establish a healthy phone Internet path: delayed replies arrive
after that window. Mac's maximum ping RTT is 53.876 ms. This points to a wider
phone/network interruption; carrier fault, device power policy and the exact
cause are not established. The source-age defect is fixed, but satisfactory
audio quality and timely path recovery remain open.

Both apps, the whole Android UID, owned Mac/log/probe processes, remote ping
and the owned ADB forward are independently verified absent. No push, signed
commit, tag or release is performed in this debugging cycle.


Linked-device call control retains the identity conversation (2247)
-----------------------------------------------------------------

A subsequent 2246 audio-only run establishes the same call on both ends at
1.139 s (ring 0.388 s). It initially uses relay, then Mac upgrades to P2P at
placement +4.828 s while Poco stays on relay; Mac returns to relay at +15.852 s.
The phone keeps announcing direct readiness, but does not receive Mac's later
readiness/health control addressed to its physical device id. Its native trace
rejects those sealed kind-1 frames: no ratchet session for that conversation,
with sealed-for naming the physical device. An initial control delivery and a
successful local live send are not proof of subsequent peer acceptance.

CallService now sends exact-dialog controls through the saved contact identity
after a forked answer. Media, native admission checks and the accepted peer
remain pinned to the answering device. Offers and sibling fan-out retain their
original addresses; onBehalfOf fan-out is not remapped. Identity routing also
retains MessagingService's accepted-contact gate and certificate/ratchet lane.
No mailbox, relay role field, priority rule or authentication bypass is added.
This avoids using a device conversation for identity control; the separate
crossed-init ratchet defect is not claimed fixed.

169 selected call-service and realtime-delivery tests pass; analysis passes.
The forked-answer regression checks identity destinations for direct readiness,
capture health and the eventual end, while admission stays device-specific.
Reverting the destination to the physical peer makes the regression fail.

During the preceding run the screen is requested off at active +40.55 s and
on at +100.68 s. Android's device-idle states remain ACTIVE throughout and the
veil:daemon CPU wake lock is present in 33/34 power snapshots (the first is
before call startup). Multi-second receive gaps also occur while Awake before
the sleep phase, so this run does not implicate Doze or establish a causal
screen effect. Poco ping reaches 2537 ms, Mac 53.488 ms; the cellular default
network remains unchanged. Both apps and their full owned process sets,
remote ping and ADB forward are independently verified gone after collection.


Both platforms then run 0.13.84+2247 with the new control helper's actual
source bytes present in their Dart kernels. Android's full installed APK
matches the signed artifact (original signer), SHA-256:
591fce0a7d6b56f4eca13cc2bed8d3419f52f327ee7dfbc921e5fbf563ff9dc7.
Native SDK/media/ABI are the verified 2246 artifacts. Mac's bundle seal passes;
its old stand debug log is archived before rebuilding. A preparatory endpoint
exchange API times out, but both APIs remain responsive; that preparation is
not counted as successful. The subsequent call rings at 0.419 s, both endpoints
become active at 4.375 s with the same call id, and remain on P2P epoch 1 for
180.360 s. Fresh reciprocal control heartbeats now reach both endpoints.
This run verifies control delivery after rebinding; it does not reproduce the
preceding cold relay-to-P2P transition and is not proof of that race's removal.

Voice-only windows at active 15-55 and 125-175 s add zero reported audio
interruptions on either endpoint. Cameras are requested on at +62.936 s and
off around +110 s. During 70-105 s Mac adds one 200-ms interruption and Poco
adds nine totalling 6085 ms. Mac sends 16 additional video frames and Poco
decodes seven; Poco sends none. Local audio admission stays <=4 ms, but total
estimated audio delay reaches 529/671 ms. Phone ping peaks at 1524 ms, Mac at
52.759 ms. Thus stable signaling is improved; satisfactory mixed-media audio
quality and healthy bidirectional video are still open.

The actual pinned WebRTC source confirms delay_estimate_ms includes FILTERED
NetEq buffer level plus future sync-buffer samples and ADM playout delay;
jitter_buffer_ms is the instantaneous buffer size. Their discrepancy alone
cannot establish a hardware playback backlog. A useful next check is the
initial video-enable/capture gate: new video must not burst before existing
poor or unknown audio is evaluated. Controlled audio playout measurements are
also needed before changing NetEq based on silence/DTX telemetry alone.

Both apps, whole Android UID including package processes, owned helpers,
remote ping and the ADB forward are independently verified absent after this
run. No push, signed commit, tag or release is performed.


Audio admission before video mount and after engine replacement (2248)
--------------------------------------------------------------------

Video now evaluates expected incoming audio and capable peer playout BEFORE
creating its send stream or starting capture. A capable receiver with no
accepted RTP, stale/unknown receive age, or required poor/unknown remote
playout starts with native outbound video paused. Receive and preview remain
available. Twelve consecutive healthy audio samples earn resume; explicit
mute/removal can release an initial hold when no relevant audio remains.
Healthy DTX, video without expected audio and legacy low-rate capability
retain their appropriate paths. Known receive-age support remains sticky
through missing fields/worker timeouts so a partial sample cannot earn resume.

At the sparse video floor, two measured remote playout samples >=300 ms now
pause the send stream, rather than allowing sparse frames up to 1000 ms.
Unknown feedback does not substantiate a bad-link advisory. Recovery still
uses the existing <200-ms playout budget and twelve good samples. This changes
an endpoint policy; no wire role, mailbox delivery or relay QoS is added.

Engine replacement also invalidates BOTH applied native caches: the previous
engine having been paused cannot establish that its replacement is paused.
The existing budget/pause policy survives and is reapplied before video mount.
Group startup uses the same admission policy and checks all expected peers.

246 selected Flutter tests and five-file analysis pass. Four negative controls
fail at their intended assertions: removed startup hold, stale predecessor
pause cache, the old 1000-ms floor threshold and omitted group pre-mount pause.
Exact source bytes are restored and the positive suite rerun. The real native
WebRTC suite passes; additional direct/group checks set pause BEFORE mounting
video and verify mounting retains it. Its existing real encoding/preview and
held-video/audio queue gates also pass. Veil a01c33ab contains only those
additional native tests; deployed SDK/media/ABI remain the verified 2246
artifacts, and hidden-volume is unchanged.

Both actual Dart kernels contain the new admission helper. Mac's bundle seal
passes. Poco retains its original signer and its full installed APK equals the
signed 0.13.84+2248 artifact, SHA-256:
f2ff38311311a2dd5f7aedd7a5fffc3a7d1282214aedd5f22b089f0a7ecfe0e7.

The attempted physical comparison becomes unobservable after Poco disappears
from ADB before the camera-on phase. Mac still reports fresh received audio;
the driver's endpoint_lost label is caused by API transport URLError, not
proof of a dropped call. Its first request's timestamp is not a precise ring
latency measurement. The driver now distinguishes missing observations from
an actual successful response with no call, and timestamps observations after
both API reads. This aborted run does NOT validate mixed-media improvement,
healthy physical video resume or satisfactory audio latency.

Mac hangup/lock succeeds and all owned host app/helper/probe PIDs and the ADB
forward are verified absent. Phone force-stop/UID and remote ping verification
remain explicitly pending until ADB reconnects; cleanup is not claimed complete
for that device. No push, signed commit, tag or release is performed.


Live audio measurement loss and group fanout admission (2249)
-----------------------------------------------------------

The startup admission guard alone did not protect a video budget already
earned during a call: a missing expected incoming audio sample or expired
capable peer playout could leave video sending. These unknown measurements
now pause outbound video immediately, retaining capture/preview and incoming
media. Twelve consecutive healthy samples earn resume. Known receive-age
support survives missing fields; legacy telemetry and intentionally muted
audio retain their existing behavior. Unknown quality alone does not justify
the bad-link advisory.

In a capable group engine, a newly expected audio participant (including an
existing participant unmuting) puts video on hold before opening/adding its
fanout. Healthy old participants cannot establish the new participant's audio
quality. A rejected native pause remains pending for the existing poll retry.
Explicit removal/mute can release a hold when no relevant audio remains.
All scheduling remains endpoint local; no relay role or QoS is introduced.

Three new regressions fail at their intended assertions against 2248: lost
live audio measurement, expired required playout and pause before peer add.
After the fix, 249 selected Flutter tests and four-file analysis pass. The
group regression also verifies real controller ordering, retained camera
intent, worker-sample failure, and twelve-sample resume. Native production
code is unchanged; no new acoustic or network-quality claim is made.

Debug stand builds 0.13.84+2249 are prepared for Mac and Android. Both actual
Dart kernels contain the updated policy and fanout admission source bytes;
Mac's bundle seal passes. The APK preserves the original phone signer and
the verified 2246 native SDK/media/ABI. APK SHA-256:
b25bb229fcfe000e7f46e9b72d2710c2e4c97c842d9d9c06a3aee4b48958a5ea.

ADB still lists no devices. The new APK is not installed and mixed-media
physical validation remains pending. No new stand apps are launched; the
previous phone's force-stop/whole UID/remote ping cleanup remains pending
reconnection. The host apps/helpers and owned ADB forward remain absent.


Required group playout capability survives failed samples (2250)
--------------------------------------------------------------

A failed or missing native snapshot previously reset the observed capable
playout peer count to zero. With incoming microphones intentionally muted,
this incorrectly released the video hold despite unknown OUTGOING audio
quality. Group admission/polling now share a retained count; explicit current
zero clears the requirement and teardown resets it for the next call. A
regression fails on 2249 at the erroneous resume, then passes for thrown and
empty samples, twelve healthy recovery samples, and explicit zero. Unicast
polling also requires call.media.audio, matching its pre-mount guard.

250 selected Flutter tests and three-file analysis pass. Prepared Mac/Android
stand builds are 0.13.84+2250, with updated source bytes in both Dart kernels
and a verified Mac bundle seal. APK SHA-256:
9564fa7c52db4eafda0bd7b5133e1c100956ae0b80e53119f2698c4c230e805a.
The original phone signer, packaged native artifacts and native production
source hashes match 2248; native production code is unchanged.

Poco remains absent from ADB. No new apps are launched; installation, physical
mixed-media/audio-latency comparison, healthy bidirectional video recovery,
cold relay-to-P2P verification and the preceding phone cleanup remain open.
These policy gates do not establish satisfactory physical call quality.


Decoded audio interruptions and burst-capacity rollback (2252)
-------------------------------------------------------------

Poco returned. The 180-second 2250 warm P2P call remained in one media epoch.
Both cameras were requested for 50 seconds, but audio pressure kept both video
senders paused throughout that phase: no new interruptions there, and no video
was transmitted. This established the hold, not healthy mixed-media recovery.

The 2251 12-packet NetEq capacity experiment failed physical quality: before
video, the 15--55-second window contained 15 Mac and 12 Poco interruptions
(11.768/8.451 seconds). Cellular delays were worse in that run too; the comparison
does not attribute every pause to capacity. A controlled real Opus/NetEq PCM
trace nevertheless reproduced an additional buffer flush and concealed samples
with 12 packets. Production capacity is restored to 30 in Veil 262f2c53; the
PCM regression now checks rendered markers AND concealment/buffer flushes.
Standalone max-target experiments of 180/100 ms did not meet the recovery
quality gate and are not deployed. The 40-ms network fixture still retains
roughly 340-ms PCM latency shortly after jitter, returning to about 100 ms;
this rollback is not a claim that interactive audio latency has been solved.

A fresh RTP timestamp and low delay estimate previously allowed video despite
new decoded-audio interruptions. Local receive samples now track interruption
increments, and encrypted unicast health feedback carries optional `ap.i` with
a logical counter preserved across receive-engine repairs. Replay cannot renew
an event; a later healthy frame cannot erase a pending one. Video pauses on a
new interruption and requires twelve healthy samples before resuming. Group
receive stats expose each participant's interruptions, so one affected expected
participant pauses the local fanout. Legacy fields remain optional; relay
scheduling and transit metadata are unchanged. Group outgoing RTCP playout
feedback still carries delay only, not this interruption counter.

268 selected Flutter tests and six-file analysis pass. Removing either the
adapter interruption branch or group counter wiring reproduces the intended
regressions. Real native Call-plane tests pass, including independent blocked
video queues, sparse video/preview/recovery, capture mute and bounded telemetry.
An older feedback test still expected sparse sending under severe audio pressure;
it failed on the preceding adapter too and now asserts the existing full pause
and separate pause/ladder recovery steps.

Fresh 0.13.84+2252 Mac/Android builds have 94 production native exports, the
same SDK ABI and phone signer. Mac bundled code matches the fresh native code
section; independently stripped Android media bytes match the packaged library;
the installed full APK SHA-256 is
1f7e2f0d3807be9dca848ef4cb0f724de992558df0ca92a31f36682a9cca86d0.
The physical 180-second call rang in 0.410 seconds and both endpoints reported
active by 1.503 seconds, but its audio quality FAILED: P2P fell back to relay
and the Mac repeatedly rebuilt media. In epochs 3--11 it accepted hundreds of
audio packets while sending zero audio, generating zero decoded concealment,
and flushing NetEq up to 25 times. Zero reported delay in that state is not
healthy playout. The current default Mac audio device is a Bluetooth headset;
AVAudioEngine configuration-change recovery requires investigation. Both owned
apps, complete phone UID/package, helpers, remote ping and ADB forward are
verified stopped; the owned build VM is stopped too. Physical audio quality,
healthy bidirectional video recovery and cold relay-to-P2P validation remain
open. No release or push was performed.


Apple audio hardware configuration recovery (Mac 2253 / Poco 2252)
----------------------------------------------------------------

The Apple driver did not observe AVAudioEngineConfigurationChangeNotification.
The pinned Apple SDK explicitly says a hardware sample-rate/channel-count
change stops the engine and requires the client to reconnect/restart it. The
ADM's requested recording/playing flags remain true in that state, so the
existing start checks could report success without callbacks. Veil 3c214551
now coalesces configuration notifications for 250 ms and restores a stopped
engine on its existing serial graph queue. The notification handler never
tears down the engine on Apple's internal queue. Each engine generation owns
a detached observer state; clearing its owner during teardown prevents delayed
notifications from accessing a freed ADM or reviving an old engine.

A real silent AVAudioEngine stand stops only its own output engine and posts
the hardware-change notification. Playout resumes with the fix and stays
stopped (result=2) when the recovery call is removed. A second case destroys
the ADM with a notification pending and verifies clean completion. No identity,
network endpoint, microphone or system audio setting is used by this test.
The full native Call-plane suite passes after the change. Fresh Mac production
media still exports 94 functions, with no test hooks; bundle code matches the
fresh library and its seal/kernel version are verified. Android is unchanged
and remains the previously verified +2252 installation.

The subsequent 180-second physical call rang at 0.446 seconds and both endpoints
reported active at 1.512 seconds. It stayed in media epoch 1, but used relay
throughout (`no direct session to peer`). Both capture and receive continued;
there was no recurrence of the long zero-audio Mac sessions from +2252.
No natural hardware-change notification occurred in this run, so it does not
prove that configuration changes caused that preceding failure. Call quality
still FAILED: Mac counted 18 interruptions/14.259 seconds, Poco 6/5.269 seconds.
Mac NetEq flushed 24 times and discarded 712 packets; Poco flushed twice and
discarded 30. Native delay estimates peaked at 551/699 ms, respectively.
No video was transmitted or delivered at either endpoint, including the phase
with both cameras requested. These audio pauses therefore cannot be attributed
to transmitted video in this run. The Mac capture tap delivered 4096--5056
converted 48-kHz frames per callback (85--105 ms of PCM), another unresolved
source of bursty audio input; this is chunk duration, not acoustic latency.

The physical drivers, complete phone UID/package, owned Mac app, helpers,
remote ping and ADB forward are verified stopped. The prior cleanup briefly
saw a defunct probe child; reaping helpers before checking avoids counting an
exited child as a running process. Remaining work: direct-session establishment
on the cellular setup, relay queueing/packet bursts, capture callback cadence,
actual audio latency and quality, and healthy bidirectional video recovery.
No push, tag or release was performed.


Punched responder direction and Android packaging (2254)
-------------------------------------------------------

The 2253 native logs show a more specific P2P failure than the Dart NAT
retry message: three punched QUIC connections completed their authenticated
handshake, then Poco rejected their inbound direction as a duplicate and the
Mac immediately lost the stream. The explicit punched initiator already
bypassed the configured mesh's direction selection; the responder used the
ordinary listener path. Veil a8eb5efd applies the same direction exemption
only at the local punched-responder spawn boundary. Peer authentication,
P-Net/capacity admission and live-session replacement rules remain unchanged.

A real QUIC + OVL1 regression checks noncanonical configured inbound rejection
for a listener, successful punched admission and rejection of a second live
punched connection. Reverting the responder call site reproduces the intended
admission failure; source is restored byte for byte afterward. Thirty-eight
selected runtime checks pass, including handshake/identity expectations,
sovereign proofs, P-Net status, punch single-flight and runner ownership.

The standalone Android SDK helper also differed from the Flutter Gradle
feature policy: it enabled BoringSSL and produced an SDK needing an unbundled
libc++_shared.so. The first 2254 APK consequently failed during activity startup,
before a call. That failed stand was closed and verified; Poco was temporarily
returned to the working 2252 APK. Veil 19602459 aligns the Android helper with
Gradle's no-default-features policy, retaining explicit tls-boring opt-in.
The corrected SDK needs only liblog/libdl/libm/libc. The APK dependency gate
now reads every packaged ELF's DT_NEEDED through program headers (32/64-bit,
no host NDK needed) and rejects missing non-system libraries, including
transitive dependencies and copies bundled only for a different ABI. The real
failed APK is rejected and the working APK passes. Packaging fixture checks
and the existing build-support suite pass. The corrected installed APK's full
SHA-256 is dbb9d958ec1fbaba4455095acd297c719a7e0d9d1b3907e7690e1aeb0b7ac859.
Mac SDK code matches the freshly built artifact; media remains Mac 2253 /
Android 2252 to isolate the network change. Signer, bundle seal and version
are checked. No identity or history was reset.

The subsequent physical call rang in 0.399 seconds and both sides became active
by 1.219 seconds. P2P remained live for all 180 seconds, in media epoch 1 on
both endpoints. Audio quality still FAILS: Mac registered 44 interruptions /
44.383 seconds, Poco 19 / 21.490 seconds. Mac NetEq flushed 21 times and
discarded 600 packets; Poco flushed three times and discarded 58. Neither
endpoint transmitted or decoded video frames, including the requested-camera
phase. Local audio RTP admission peaked at 0/2 ms; native accepted-RTP gaps
peaked at 4.350/4.601 seconds. Direct transport loss/bursts, Apple capture
cadence and actual audio latency remain open. Camera recovery is not validated.
Both owned apps, complete phone UID/package, helpers, ping and ADB forward are
verified stopped. No push, tag or release was performed.


Hardware capture cadence and serialized route recovery (2255--2256)
-----------------------------------------------------------------

Mac capture now uses AVAudioSinkNode with prepared conversion buffers, retaining
an asynchronous tap fallback and the original iOS tap. On the physical Bluetooth
input, the new sink receives 320 frames at 16 kHz every 20 ms and delivers 960
frames at 48 kHz, instead of the preceding roughly 100-ms tap batches. Measured
output advances by 96,000 frames per 2,000 ms. A separate AVAudioConverter check
rules out duplicated samples in the old large output chunks. Native Apple
configuration recovery and the complete call-plane regression pass; production
Mac media exports exclude test hooks.

The reverse Poco-to-Mac 2255 call exposed another failure: a health-triggered
local repair could still await camera teardown when the peer announced relay.
The native controller returned false for a route switch during repair; the FSM
then ended the call. Route mutations now serialize, preserve the camera JNI
teardown fence, and recheck the original call ID after waiting and after stopping.
A queued request cannot revive a hung-up call or change a replacement call.
Existing call-service tests plus concurrency/retirement/error-release checks
pass (135 tests); targeted Flutter analysis is clean.

With that change, the same-direction 2256 physical call rings in 0.403 seconds,
is active on both endpoints by 1.039 seconds and stays active for 180 seconds.
Both endpoints move from P2P to relay around 38--40 seconds and continue, rather
than ending during recovery. Poco retains Android media 2252 and corrected SDK
2254; Mac uses the sink media. The installed signed APK is byte-verified:
4a472ce98f7cf777225d3cca87e1a8332d8db525c57faa2d6a1382ce4cd15309.
Identity/history are preserved. The initial simultaneous Flutter builds raced
on a generated Swift package; the Mac build was rerun after Android completed,
and the final bundle seal, Dart image and native code are verified.

Audio quality is still unresolved, and zero video frames were transmitted or
decoded despite a running Poco camera. P2P accepted-audio age peaks at 8.552 s
on Mac and 6.688 s on Poco while the peer mic is enabled. Transport traces show
stalled ACK progress and expiring outgoing datagrams on independent connections,
with no recorded event-queue stalls. Relay also has repeated interruptions.
A roughly 15-second gap in Poco capture coincides exactly with micOn=false;
the actual AAudio stop/close and later reopen take tens of milliseconds. It is
not evidence of a stuck microphone and is excluded from capture-failure claims.
Raw cumulative NetEq interruption counts include that muted interval.

An isolated real Opus/NetEq test uses two seconds of tone, ten seconds of exact
silent PCM, then four seconds of tone over a fixed 40-ms path. DTX reduces the
silent interval to 57 RTP packets, accepted-audio age stays below 390 ms, and
there are zero added interruptions/concealed samples; decoded tone resumes.
The regression also retains the preceding injected-jitter PCM checks. This
rules out intentional codec silence alone as the source of the physical gaps.
Further work remains on direct transport stalls/connection retirement, relay
bursts, acoustic latency and bidirectional video recovery. Both physical stands
are closed; phone UID/package, own Mac/helper processes, ping and ADB forward
are verified absent. No push, tag or release is performed.


Correlated network and mute observations (2256--2257)
----------------------------------------------------

During 2256's P2P outage, the independent Poco ICMP probe also has an 8.636-s
host-observed arrival gap; no reply arrives in the 35--40-s slice and late
replies report up to 4,849 ms RTT. The Mac probe stays below 66 ms. Several
Poco peer sessions are reaped together for unacknowledged keepalives around
the same time. Cellular remains the active default network, screen is awake,
the daemon wake lock is held, and device idle is inactive. These observations
support a general cellular path interruption during this particular pause;
they do not determine its carrier/modem cause or explain every audio pause.
The short no-app 2257 control also has variable Poco latency (29 replies,
median 32.5 ms, p95 594 ms, maximum 720 ms); Mac median is 49.456 ms and maximum
54.463 ms. Probe destination/rate and network conditions differ from the
actual media path, so this is corroboration rather than an acoustic-quality
measurement. Own pings and phone app UID/package are verified stopped.

Android touch events delivered to xVeil immediately precede both micOn changes
in the 15-second capture gap. No stand helper invokes /call_mic. The capture
stop/start follows the application's explicit mute state; no long native
stream-open/close operation occurs. This gap must remain separate from the
unresolved network interruptions in reports.


Muted-audio video recovery and distinct receiver feedback (2258)
---------------------------------------------------------------

A regression reproduced a video hold that never cleared after a measured
audio interruption when both endpoints subsequently muted their microphones.
No outgoing audio reports can arrive in that state. Explicit absence of both
audio directions now releases that hold to the sparse video floor. With the
local microphone muted but incoming voice expected, recovery needs twelve
consecutive healthy incoming samples, including native playout below 200 ms
when supported; missing measurements or renewed interruptions retain the hold.
Local microphone reactivation pauses video before restarting audio capture.

Native authenticated RR/SR observations now keep separate audio and video
snapshots with their respective 48/90-kHz jitter clocks and 15-second freshness.
Video reports can earn video growth when no outgoing audio is expected; they
cannot establish outgoing voice quality. Rooms require reports from every
connected receiver and aggregate the worst quality. Feedback remains inside
the existing endpoint-encrypted traffic: no media role or priority is exposed
to relay nodes, and no exported native ABI is added. Incoming audio playout
above 300 ms also pauses video even if packet arrivals remain fresh.

The initial measured-hold/mute regression failed before the fix. The selected
adapter, group controller and call-service suite now passes 213 tests; targeted
analysis reports no issues. The complete native call-plane regression passes,
including video report freshness, independent group reports, 90-kHz jitter
conversion, and audio progress while the video worker is blocked. Production
Mac and Android media are rebuilt without test exports. Both stand apps use
2258; the full installed signed Poco APK is byte-verified with SHA-256
700576d10a962e86e16a801264728b393debbe5029a8add830a63ac0957a1a71.
The corrected Rust SDK from 2254 is retained; identity/history are preserved.

The 240-second Mac-to-cellular-Poco call rings in 0.424 seconds and is active
on both sides by 1.128 seconds. P2P remains in epoch 1 until the explicit final
hangup. Both microphones are deliberately muted at 20.34 seconds, cameras
enabled at 21.11, Poco microphone enabled at 80.28, Mac microphone at 160.35,
and cameras disabled at 220.39. During the muted-camera phase each sender
transmits approximately 81/82 frames and each receiver decodes 65 frames;
fresh independent video reports are observed. This establishes bidirectional
video recovery after mute, not video recovery with healthy active voice.
After microphones resume, high audio playout delay holds video paused, with
final transmitted/decoded counts 88/82 and 65/66. Voice quality remains
unresolved: final native playout is 341/390 ms despite fresh packet arrivals.
Raw interruption totals include the intentional mute intervals and must not
be reported as network-only interruption counts. Acoustic latency and video
recovery under healthy active voice are still unverified. Both owned apps,
the full phone UID/package, helpers, ping and ADB forward are verified stopped.
No push, tag or release is performed.


Audio and file contention check (stand 2259, app 2258)
----------------------------------------------------

The same app binaries were tested for 180 seconds with both microphones
continuously enabled, cameras off, and a random 2-MiB Mac-to-Poco file transfer.
The call rings in 0.389 seconds and is active on both endpoints by 1.321 seconds.
Both move from relay to P2P by active +1.553 seconds, then remain in media epoch
3 until explicit hangup. File download runs at active +50.530--65.732 seconds;
full byte count and SHA-256 equality are verified. The owned download is
cancelled after verification, and its temporary plaintext phone file is removed.

In the file window neither endpoint adds a decoded-audio interruption. Mac/Poco
native accepted-audio age peaks at 307/317 ms; cumulative local RTP admission
maxima are 0/1 ms. This supports separation of audio from this file workload,
not a guarantee under every transfer size, route or saturated radio link.
The preceding active +5--50.395-second window adds 6/3 interruptions, with
median native playout 301.5/280.5 ms; after the transfer both endpoints add six
interruptions and playout medians remain 330/306 ms. The phone microphone is
not muted in this run, so these intervals do not have the preceding mute
confound. Cumulative local audio admission remains bounded at 0/2 ms.

At active +158, +162, +166, +170, +174 and +178 seconds both sides register
new interruptions. An unrelated Poco ICMP probe has 0.7--1.014-second RTT
spikes in the same intervals; Mac ICMP stays below 54 ms there. These are
correlated observations, not identification of a specific modem/carrier cause
or measurement of mouth-to-ear latency. Audio-only playout remains unresolved.
The full phone UID/package, own Mac app, helpers, ping and ADB forward are
verified absent after the stand. No new native build or APK installation was
needed for this control; the phone retains the byte-verified 2258 build.

The source audit confirms separate audio/video/screen IPC senders and separate
audio/video/screen drain tasks. Ordinary messaging, realtime control, mailbox
and file streams have their own IPC domains. One remaining transport-sharing
case is identified: screen datagrams and recoverable anonymous-file DATA both
select the endpoint's BACKGROUND QUIC source sibling. Their route pools and IPC
writers are separate, and the audio sibling is independent, but those two
sources do not yet have distinct QUIC congestion controllers. Neutral relay
shards remain role-independent; this audit does not authorize relay priorities.

The subsequent no-app 2260 control uses the same 250-ms ICMP interval and
destination for 192.39 seconds, with concurrent readers recording both paths.
xVeil remains absent throughout the control; the screen remains Awake, the
default network remains CELLULAR, and all 36 thermal snapshots report status 0.
Poco has 654 replies, median 36.1 ms, p95 885 ms, maximum 10,550 ms and maximum
host-observed inter-reply gap 15.612 seconds. Mac has 465 replies, median
51.206 ms, p95 101.896 ms, maximum 106.343 ms; reply loss also produces a
3.552-second arrival gap on that path. These external ICMP paths need not be
the call's peer path, and this non-simultaneous control does not apportion the
call's full latency. It does establish severe phone network delays without
xVeil, rather than attributing those delays to media/file queue contention.
Own host/remote pings are verified stopped and the phone app remains absent.
The normal call-quality and separate screen/file-connection work remain open.

Recoverable DATA source separation (2261)
---------------------------------------

The screen/file sharing identified above is corrected. Recoverable anonymous
file DATA now uses a fifth endpoint-only queue and its own lazy authenticated
QUIC source connection/congestion controller. Audio, video, screen and
recoverable DATA have distinct source connections. The aggregate queue cap
is unchanged; each lossy source retains its existing bounded depth and expiry.
Audio ACK/PTO/RTT/deadline pressure also limits this new file source through
the existing sparse secondary recovery policy.

The selector is carried only by an IPC header hint. An older local daemon sees
BACKGROUND, while the new daemon resolves the separate DATA source. The
two-bit network priority and relay framing remain unchanged; relays receive
neither a media role nor a new priority. No exported native function signature
is added. Reliable file controls retain the ordinary reliable lane.

The initial regression fails on the old implementation: file DATA consumes the
screen's bounded queue and evicts its packet. After the fix, 1618 tests pass
across veil-session, veil-proto, veil-ipc, veilclient and veilclient-ffi (12
existing tests remain ignored). A real four-source QUIC test proves distinct
exporter bindings and continued audio/video/file delivery after closing the
screen connection. A primary ACK blackout restricts file DATA without blocking
audio or neutral control. IPC compatibility/body preservation and neutral
relay framing tests pass; the native relay file-loss/ARQ regression passes.

These checks establish transport/source separation, not acoustic call quality
on the cellular phone. Fresh Mac/Android SDKs are packaged in stand app 2261;
the installed Poco APK is fully byte-verified with SHA-256
0fd45279c6535f57130fb13b5fd172106a12d2e42d9898895a988a1f072aef11.
Production media from 2258 is retained unchanged. The severe external delays
observed in the no-app control remain a separate limitation.

Screen capture across route rebuilds (2262/2263)
----------------------------------------------

The first Poco-to-Mac audio call rings in 0.398 seconds and is active by 0.983
seconds. Its audio-only media set cannot start the screen, so that stand is
explicitly ended and repeated with video negotiated and cameras disabled.
In the repeated 240-second stand, an authenticated offer takes 32.277 seconds
to arrive, then both endpoints are active at 33.299 seconds. Earlier realtime
copies arrive with a claimed physical sender and are correctly refused by the
existing provenance gate. Cold authenticated signaling remains unresolved;
this observation does not authorize weakening contact authentication.

Both microphones are muted at active +10 seconds, screen consent is requested
at +20.294 and completes at +90.327 (including stand UI automation delay).
A 2-MiB Poco-to-Mac file is received at +145.766, after 54.285 seconds of
download, with full size/hash equality. Microphones resume at +120 seconds.
At +114.160 the media sessions rebuild in epoch 3 and move from P2P to relay.
The phone had sent 44 screen frames before rebuilding, then sends no more
while its public call state still says screenOn. Code confirms that teardown
destroys the projection and the new session does not restore the screen.

The correction retains an already consented Android projection during a
rebuild of the same live call. Its old engine sink detaches synchronously
before teardown awaits; the replacement engine rebinds without obtaining
another projection token. Screen intent is kept in the controller and latest
screen-off changes survive an asynchronous route open. Hangup, user stop and
grant expiry retire the source; a stopped source cannot be resumed by sink
rebinding. macOS restores the requested screen source after rebuilding.
The method-channel lifetime/expiry tests and selected call, route, bitrate and
capture-security suite pass 210 tests; targeted analysis reports no issues.
Build 2263 is installed on Poco and its full APK is byte-verified with SHA-256
37ded12e9489e454924ba62770e87df25f9765d451736aefa15a79388ca03a2a.
The Mac stand bundle's seal, Dart version and native code are verified. The
180-second Poco-to-Mac video-capable call rings in 2.075 seconds and is active
on both endpoints by 6.752 seconds; cameras and microphones are disabled for
the capture lifetime check. Screen consent completes at active +13.694.
Before forced phone media repair at +17.839, Poco has sent four screen frames
and Mac has delivered four. The repair returns at +17.967; by +21.038 the
phone's new epoch 5 has sent three frames and Mac's retained epoch 3 has
delivered seven. Screen intent stays on and no second consent request occurs.
Screen-off at +21.146 clears public intent. Android reports no projection and
no ScreenCaptureService while the voice call remains active.

Microphones resume at +21.154/+21.313. At +56.326 both remain P2P, with native
audio admission maxima 0/2 ms and playout 334/402 ms. Across observations after
driver time +65 seconds, median playout is approximately 350/338 ms; fresh
packet arrivals alone do not establish low acoustic latency. Jitter-buffer
delay/flushes and cold authenticated offer delivery still need investigation.
Both owned apps, complete phone UID/package, helpers, ping and forward are
verified absent after the stand; the consented projection is also gone.

The 2262 stand does not establish healthy active voice: after microphones
resume, audio playout medians are 372/340 ms with interruptions; after screen
off the medians are 391/280 ms. Local audio admission maxima are 0/3 ms.
Mute periods and engine counter resets must not be counted as network-only
interruption deltas. Both owned apps, full phone UID/package, helpers, ping
and ADB forward are verified stopped after both stands. Identity/history are
preserved. No push, tag or release is performed.

Full duplex source and recovery capacity (2264)
----------------------------------------------

The shared eight-child QUIC cap prevented all six production source/transit
connections in each direction from warming simultaneously. A real TLS/QUIC
regression fails on the old implementation with a full-duplex source budget
timeout. Incoming children could consume the capacity needed to establish a
local source or authenticate its replacement.

Each direction now has seven slots: six generic source/transit connections
and one replacement candidate. The aggregate hard cap is fourteen, up from
eight. Both permits follow the actual child QUIC lifetime, including clones;
failed reservations and canceled handshakes release them. Incoming peers
cannot consume the outgoing reserve. The same limits apply to every peer,
independent of payload, and the source-slot count has a compile-time capacity
assertion. This increases the bounded peak resource allocation per peer; it
does not communicate media roles or priority to relays or change wire framing.

Transport/session suites pass 512 tests (six ignored), and native SDK tests
pass 223 (one ignored). The regression warms six children in each direction,
then blocks both primary connections for four seconds through neutral opaque
circuit identifiers. Both endpoints authenticate replacement connections,
retain the old sender until proof succeeds, deliver fresh audio within 600 ms
of recovery, and receive at least 140 post-outage packets per direction with
no duplicates. Saturated incoming children leave outgoing capacity available;
actual close releases capacity and replacement exporter keys differ.

Fresh Android and Mac SDKs and stand apps are built as 0.13.84+2264. The
installed Poco APK is fully byte-verified with SHA-256
6bdab8fed3402fac9146af854f4a6d5913a33f3616e2d93ef6e60a49927fc74a.
Independent AGP stripping reproduces the packaged SDK, media remains the
production 2258 implementation, and bundled native dependencies pass the
packaging check. Mac code sections, kernel version and bundle seal match.

In the 180-second Mac-to-cellular-Poco audio call, ringing takes 0.397 seconds
and both endpoints are active by 1.313 seconds. Microphones stay on and cameras
stay off. A 2-MiB file starts downloading at active +50.483 seconds, finishes
at +99.964 and passes a full SHA-256 comparison. Both endpoints move to P2P
around +4.587, then to relay at +93.662/+95.553 after a prolonged media gap.

This physical stand does not establish good voice quality. Even before the
file starts, both endpoints accumulate ten observed decoded interruptions,
with accepted audio age reaching 1775/1800 ms. During the file, age reaches
5541/6981 ms and observed interruption deltas are 16/14 across separate media
epochs. Counter resets are segmented by epoch, never subtracted across rebuilds.
After the file, interruptions continue (22/18 observed increments), with
playout medians 256.5/245.5 ms. Local RTP admission maxima remain 0/1 ms.
External ICMP reaches 1514 ms on Poco before the file and 1504/1402 ms during
and after it, versus Mac maxima 130.570/96.990/152.617 ms. This corroborates
cellular instability but does not explain every peer-path or decoded-audio
gap; ICMP is a different destination. File contention and receive-buffer
behavior still require investigation. Cold authenticated offer delivery is
not reproduced in this warm stand and is not declared fixed.

Own applications, the full phone UID/package, logcat/helper/ping processes and
ADB forward are verified absent after the stand. The Mac runtime log is
archived outside the bundle and its seal is verified again. Poco remains
available with the verified 2264 build installed; identity/history are intact.
No push, tag or release is performed.

Primary pressure across endpoint neighbors (2265)
------------------------------------------------

Source connections are independent, but the previous pressure gate was scoped
to one session neighbor. A P2P primary's stalled ACKs did not constrain local
file/video/screen producers using other relay neighbors on the same endpoint.
The new real TLS/QUIC regression fails before the correction: the primary
path is blacked out while the other connection delivers normally, and the
other connection's local DATA burst bypasses primary feedback.

Session runners now share the registry's endpoint-local activity/pressure
state. RTT, datagram expiry and PTO/congestion feedback from a locally authored
primary constrain local secondary datagrams on all its neighbor sessions.
One sparse recovery probe every 200 ms is shared across those producers;
normal admission resumes after the two-second pressure grace or after three
seconds without primary activity. Old concurrent observations cannot shorten
newer activity/pressure deadlines. No runner's teardown clears another
producer's shared state. Primary/control and neutral forwarded cells bypass
this producer gate; another node owns independent state. Reliable control
leases and the existing parent write-window policy remain separate.

Transport/session suites pass 515 tests (six ignored); native SDK suites pass
223 (one ignored). The two-connection blackout regression verifies healthy
alternate-path delivery, suppressed local bursts across neighbors, one shared
probe, preserved neutral/control and unrelated-node admission, and recovery
after the grace. Sixteen simultaneous consumers acquire exactly one probe.
Endpoint trace logs record the local gate's drop counts; source-slot arrays
also include recoverable DATA's private selector. No role, pressure or priority
metadata is added to relay framing or sent to remote nodes.

Build 2265 is installed on Poco, with full APK byte verification and SHA-256
0f549f362c97ca5695c16e9c69d5222fb3cd59fc7e8e43433890502dc3b37553.
Packaged SDK bytes match independent AGP stripping and contain the new local
pressure trace; production media remains unchanged. Mac SDK code sections,
Dart version and bundle seal are verified before and after the stand.

The 180-second Mac-to-cellular-Poco video-capable call rings in 0.405 seconds
and both endpoints are active by 2.433 seconds. Both settle on P2P at active
+1.331 and stay there. Cameras are disabled at start; Poco camera is requested
at +20.385 and disabled at +150 seconds. It captures up to 3802 frames at
approximately 30 fps during the observed requested window, but native video
send stays paused and encodes zero frames. This proves capture plus the
existing audio-first sender policy, not simultaneous encoded-video load.

A 512-KiB file downloads at active +50.507 to +57.058 and passes a full hash
comparison. Neither endpoint's decoded interruption count increases within
that short file window. Sizes and cellular conditions differ from 2264, so
this is not a controlled attribution of improvement to the new gate. Local
trace records 25/17 pressure drops on Mac slots 3/2 and 22/8 on Poco slots 3/2.
The recoverable DATA selector 4 is not observed in this physical trace; the
chosen content-stream backend still needs to be traced before claiming this
file exercises the anonymous DATA connection or its pressure gate.

Voice remains imperfect. Before the file, accepted packet age reaches
1799/1814 ms and decoded interruptions increase by 9/12. After the file,
playout medians are 361/414 ms, accepted age reaches 667/1093 ms, and observed
interruption increments are 7/3. RTP admission maxima are 0/8 ms. External
ICMP on Poco reaches 1563 ms before the file and 941 ms afterwards, while Mac
maxima stay below 54 ms; this is a different path and cannot explain every
voice gap. No microphone mute or media epoch reset occurs in these windows.

Both owned applications, the full phone UID/package, helpers, host/remote
pings and ADB forward are verified absent after the stand. Identity/history
are preserved and Poco remains available. The goal remains open for actual
content-stream path coverage and the remaining receive/audio delays.

Ordered source pressure across neighbors (2266)
----------------------------------------------

Content pulls can use a direct ordered AppOpen/AppData/AppClose stream, or an
anonymous stream after direct open fails. The former shares the canonical
reliable session, so the secondary DATAGRAM gate alone does not constrain it.
Successful initial and retry opens now log the actual selected backend, rather
than the ambiguous `p2p-or-fallback` label. This is diagnostic output only.

The registry's endpoint-local pressure state now also admits reliable authored
payloads before encryption: 4096 estimated wire bytes per 200 ms while the local
primary is active and pressured. Trusted local admission credits distinguish
these frames from transit; the private recoverable DATA selector also covers
its ordered compatibility path. No remote header selects this policy. Whole
oversized compatibility frames can progress alone. Primary and neutral queues
keep their admission policy. Source bytes and credits remain queued through a
hold; no packet is dropped or ciphertext nonce consumed. The existing canonical
QUIC window is not reduced on unrelated neighbors.

A source hold can skip the selected WRR class while preserving its FIFO head
and slot, so neutral work can pass. A batch boundary still flushes immediately.
The session wakes at the quota, pressure or primary-idle deadline; an already
idle writer cannot trigger a busy polling loop. A local trace records reliable
source pressure waits. Pressure expires after two seconds, or primary activity
after three seconds, without requiring a new incoming/outbox event.

The real TLS/QUIC regression runs the complete encrypted SessionRunner. An ACK
blackout on a different primary neighbor publishes pressure while its previous
RTT is below 150 ms and no datagram expiry has occurred. With the new admission
check disabled, all 187200 file bytes arrive inside the first 180 ms and the
behavioral assertion fails. With the check enabled, at most one 3900-byte data
segment passes that window; neutral transit passes while the file waits, and
all bytes and Open/Data/Close ordering survive the holds and cipher batches.
The peer receives the full file without additional incoming or producer events.
Sixteen simultaneous neighbor consumers acquire exactly one shared reliable
allowance; pressure/idle expiry and oversized-frame progress are covered.

Transport/session suites pass 517 tests (six ignored); native SDK suites pass
223 (one ignored). Flutter content transfer/reverse-pull suites pass 50 tests,
and analysis of the changed content pull file reports no issues.

Physical build 2266 is installed on Poco with full APK byte verification,
SHA-256 03ad34d429ef085ed5c1ef297a4633c41abad3324e2f3ec045a701383e00920f.
The packaged SDK matches independent AGP stripping and contains the new reliable
pressure trace. Production media remains build 2258; no test exports are
packaged. Mac SDK code sections, Dart version and bundle seal are verified.

The 180-second Mac-to-Poco audio call uses cellular on Poco. Its incoming ring
is observed at 10.419 seconds and both endpoints are active by 11.752 seconds.
The receiving call log sees the offer aged 9402 ms; this delayed signal is still
unresolved. Both media endpoints switch from relay to P2P at active +4.518,
then back to relay at +76.937 on Poco and +77.743 on Mac. Both microphones stay
on and both cameras off; this run does not exercise encoded video load.

The 2-MiB content download runs at active +30.322 to +127.118 (96.796 seconds),
with a full checksum match. Actual open/retry logs confirm anonymous and direct
session backends, including switches during retries. Mac records 34 reliable
source pressure waits, all at active +35.821 to +74.085 within the file window;
Poco records one within the same window. There are no reliable pressure waits
before/after the file. This establishes physical pressure-gate execution with
actual content-stream paths. Neither endpoint logs a recoverable DATA4 first
DATAGRAM send; an anonymous open alone is not proof of that carrier.

Receive interruptions remain. Before/file/after windows have observed decoded
interruption increments of 4/34/22 on Mac and 4/33/7 on Poco, segmented by media
epoch and excluding boundary events. Maximum accepted native RTP ages are
1109/5406/2637 ms on Mac and 1353/3595/2947 ms on Poco. Sender admission maxima
are 0 ms on Mac and 5/5/2 ms on Poco. Reported audio path delay medians are
351/275/204 ms and 297/470/511 ms respectively. An isolated positive 172725-ms
startup delay estimate on Poco is retained in raw evidence but is inconsistent
with call age; no absolute delay conclusion is drawn from that maximum.
Cellular external ICMP peaks are 1051/1717/1352 ms in those windows, versus
Mac peaks under 86 ms. The destinations differ from call peers, so this does
not explain every media gap. These timings, route transitions and differing
conditions do not provide a controlled attribution of audio improvement.

Both stand apps, the complete Android UID/package, helpers, pings and ADB
forward are verified absent afterward. The Mac runtime log is archived outside
the bundle and its seal verifies again. Poco remains accessible with identity
and history preserved. Raw traces and summaries are private under
`/private/tmp/xveil-call-2220` (`neteq2266-summary.json`, local policy/wait-phase
records, sample rows and endpoint logs). The goal remains open for delayed
signaling, the remaining native RTP gaps and receive/playout delay. The lack of
reliable pressure waits after relay fallback merits transport-feedback coverage
review; it is not proof of the cause of the remaining pauses.

Ordered primary transport feedback (2267)
-----------------------------------------

The local source-pressure publisher previously ran only when selecting a
DATAGRAM sender. Ordered primary traffic could therefore lose feedback when
the authenticated peer lacked the DATAGRAM decoder, neutral Forward support,
or the newer circuit carrier. Retaining a QUIC handle for feedback now has
separate authenticated permission from enabling its DATAGRAM sender/receiver.
Compatibility peers receive exactly the canonical encrypted ordered frames.

Before encrypting an ordered frame, the session observes its parent QUIC path
only for a complete locally authored primary frame. Trusted local queue metadata
and absence of a return carrier exclude forwarded work; an incoming REALTIME
header alone cannot activate the policy. The old CircuitData discriminant is
covered too. Pressure is published to the endpoint's existing shared source
state without reducing the parent window used by ordered primary bytes. A
stream swap clears feedback from the retired connection. No remote role or QoS
metadata is added, and relay forwarding keeps its neutral admission policy.

Three real TLS/QUIC SessionRunner regressions exercise each compatibility case.
A primary ACK blackout publishes pressure before RTT or DATAGRAM expiry can
reveal it. A separate healthy neighbor then holds its local file producer while
neutral work passes. Full encrypted file bytes, cipher order and timer-only
resumption are verified. Disabling only the ordered feedback call makes all
three tests fail because no pressure reaches the other neighbor. The session,
transport, SDK and runner integration suites pass 847 tests, with eight ignored.
This verifies the feedback path; physical audio improvement is not yet verified.

A counter review of physical build 2266 rules out ordinary sender silence for
the worst Mac receive gap: during its approximately 5.3-second sampled interval,
Poco's stable media epoch produces 257 payload audio packets, with no recorded
native transmit drops. Sender counters precede later transport processing, so
this does not locate the delay or prove delivery. Counter deltas remain positive
in the reviewed Poco receive gaps too. The goal remains open for actual route
coverage, end-to-end receive gaps and delayed signaling.

Physical relay-only build 2267 is installed on Poco with full APK verification,
SHA-256 3f7beddcf2fbecfe727c64061abdfbdbf6ada2a83cd6e6db275dcb2fa93348e3.
Both test profiles temporarily use global P2P denied, after checking that no
explicit per-contact allow defeats it; their original contacts policy is
restored and verified after the run. Media remains production build 2258.
The incoming ring is observed at 0.445 seconds and both endpoints are active
at 3.884 seconds. Both stay on relay for the 180-second audio run. This is a
different network condition from 2266, so it does not establish an improvement
attributable to the new code. Encoded video is not exercised here.

The 2-MiB file attempt starts at active +30.388 and times out at +150.440;
there is no successful full-file checksum and no file completion claim. New
ordered pressure and reliable source holds are absent on both endpoints. Thus
this physical run does not establish execution of the new QUIC feedback gate.
Poco instead records prolonged canonical writer stalls. Generic stream-only
transports and a swapped stream without a QUIC handle still lack a path-pressure
publisher; this needs separate coverage, rather than inferring their transport
from a failed/dialed QUIC URI or from missing traces.

Before/during/after the file attempt, accepted native RTP age maxima are
2795/2963/15771 ms on Mac and 2592/1516/1870 ms on Poco. Observed interruption
increments are 15/84/8 and 5/19/2, with media-epoch boundaries excluded. Native
send admission maxima are 0 ms on Mac and 1 ms on Poco. In the long Mac receive
gap beginning around active +150.6, Poco continues producing audio in epoch 1;
Mac has received no new native RTP by +164.15. Poco switches to epoch 3 at
+164.908, after the gap has already started; Mac receives again afterward.
The receiver gap therefore must not be attributed to the later media repair.
External cellular ICMP reaches 2617/1170/665 ms in these windows, against Mac
maxima below 54 ms. Its unrelated destination limits causal attribution.

Both owned apps, the entire Android UID/package, helpers, pings and ADB forward
are verified absent. The runtime Mac log is archived and its bundle seal passes
strict verification. Poco remains available; identity and history are preserved.
Evidence is private under `/private/tmp/xveil-call-2220` with prefix neteq2267.
The goal remains open for stream-only feedback, failed anonymous content pull,
remaining receive gaps, delayed signaling and actual encoded-video load.

Stream-only local producer feedback (2268)
-----------------------------------------

In physical 2267, Poco records 44 completed slow canonical writes, the longest
21358 ms. Missing QUIC feedback traces do not identify their transport. The
new source-only slow-write field distinguishes a locally authored primary
from generic control/transit without adding anything to the wire.

An authenticated local primary's complete frame now carries its shared source
activity through canonical encryption/batching into an endpoint-local writer
lease. If a partial write remains blocked for 150 ms, the writer publishes
pressure every 150 ms to other local producers. The partial-write future stays
pinned across feedback ticks: bytes, cipher nonce/order, and the original idle
progress deadline are preserved. Activity still comes from the producer;
feedback does not renew the activity of an old buffered blob. Raw/public writer
entrypoints, replies and neutral transit do not acquire this source metadata.
The metadata survives an ordinary stream swap through the new blob's local
admission, independently of a retired QUIC handle.

Ordered compatibility for local lossy secondary producers now also shares the
existing DATAGRAM recovery-probe budget. Only complete locally classified
secondary realtime frames without a reliable source credit enter that gate.
A rejected plaintext frame retains its FIFO position and wakes at the probe,
pressure or activity expiry. The existing lossy age policy can discard stale
frames before encryption; primary/control and neutral transit keep their
admission policy. Reliable file holds continue to preserve all bytes/credits.
No media role, deadline, source priority or preference is added to relay traffic.

A full encrypted SessionRunner regression blocks a stream-only primary on a
64-byte in-memory transport, with no QUIC handle, while another real TLS/QUIC
neighbor carries a file and a third healthy stream carries secondary realtime
and neutral frames. The held primary publishes pressure without incoming or
producer events. At most one secondary frame passes the first 180 ms; neutral
work passes, the file keeps all 11700 bytes and its cipher order, and fresh
secondary bytes pass after grace despite the intervening stale-frame drops.
Both complete primary frames decrypt after unblocking. This is a transport
backpressure regression, not a decoded PCM or physical cellular quality test.
Disabling the writer publisher makes it fail for missing pressure; disabling
only the ordered secondary gate makes it fail for secondary bypass.

Separate writer regressions verify neutral stalls cannot claim primary pressure,
complete byte/order preservation, pressure expiry, and that feedback ticks do
not renew a stalled writer's idle deadline. The changed session, native SDK and
runner integration suites pass 735 tests with eight ignored (408/223/104).
The unchanged transport suite previously passed 116 in cycle 2267.

Physical build 2268 has not been tested: Poco disconnected from ADB after the
completed 2267 stand and has been requested for reconnection. No test apps or
helpers remain running. Build 2267 remains installed with its identity/history
intact. The goal stays open for physical gate execution, encoded video load,
remaining audio gaps, anonymous content delivery and delayed signaling. This
local pressure policy cannot itself remove a network outage or infer congestion
on a remote relay path from a healthy first hop.

Production SDK binaries and stand apps for build 2268 are now prepared. Mac SDK
code sections, unchanged media 2258, Dart kernel version and strict bundle seal
are verified. The Android APK matches the original production signer, freshly
and independently stripped SDK bytes and unchanged media bytes; native dependency
and ABI checks pass. APK SHA-256 is
02dc29b18f53fbde5bdf2b9a7bc9cdc58a4147bd80c034f58bf27af1d0b852c7.
It is not installed because Poco is still absent from ADB. The complete build
manifest and corrected test-stage summary are private as build-screen-2268.json
and tests2268-summary.json. No stand apps, helpers or ADB forward remain running.

### Cycle 2269: primary waiting behind other ciphertext and slow progress

A blocked neutral canonical write could conceal a locally authored primary
waiting behind it, including a primary still in the scheduler while the eight
writer slots were full. Endpoint-only connection state now counts immutable
primary blobs with RAII leases and records scheduler freshness deadlines. A
blocked writer can publish shared local producer pressure in either case. The
state is per connection, cleared on retirement, and never changes relay roles
or wire metadata. Expired scheduler marks and discarded leases cannot claim
pressure on another live neighbor. Already committed bytes retain cipher order.

The pressure clock now spans partial writes. Progress in small increments
continues to renew the ordinary idle deadline but cannot conceal the total wait
for a primary. A six-byte, one-byte-per-60-ms regression failed before this fix.
Encrypted runner regressions cover one neutral prefix and 128 neutral prefixes
(640000 bytes, filling the writer), preserve every neutral byte and the healthy
neighbor's 11700-byte file, and admit fresh primary/secondary frames after stale
plaintext drops. Disabling either the scheduler mark or pending-blob observer
makes its corresponding regression fail for missing pressure.

Session, native SDK and integration gates pass 741 tests, eight ignored
(414/223/104). These are scheduling/transport regressions, not a physical audio
quality result. Poco returned to ADB; production SDK and stand build 2269 are
being prepared for a phone/computer test. Build 2267 is still on the phone;
media production build 2258 is unchanged. The goal remains open.

### Cycle 2269: Poco/Mac physical findings

Production-signed stand APK 2269 was installed with `adb install -r`; identity
and history were retained. Its full pulled installed APK matches SHA-256
5dcb405b4133f77120458aa1bccfa2a4db33f1cdbd0c5d211d58acb8c1775da7. Fresh
production Android/Mac SDKs, independently stripped Android SDK, Mac code
sections/strict seal and unchanged production media 2258 were verified. Poco
returned on Wi-Fi; before placing the call it was restored to the requested
cellular default route. No production /Applications bundle was replaced.

The first call denied P2P temporarily on both existing stand profiles, checking
that no explicit contact allow defeated the policy. Both original `contacts`
policies were saved beforehand and restored/verified afterward. Ringing was
observed at 0.513 s; both endpoints became active at 4.615 s. The same call
remained relay/epoch 1 for 240 s. A real 2 MiB file offered at active +90.26 s
finished downloading in 38.48 s, with the complete received SHA-256 matching
the source. This does not establish that the changed pressure code caused the
improvement over the previous file timeout: route/radio conditions varied.

Endpoint pressure was physically exercised on Poco: 65 ordered-primary
pressure observations and a completed 324-ms own primary write reported two
source pressure ticks. Mac did not report a slow canonical write. No reliable
secondary admission hold was recorded, so the full cross-producer gate is
still demonstrated by encrypted runner regressions rather than this stand.
Every recorded sealed relay admission used ordered compatibility, with
`datagram_transport=false`; other received generic datagrams do not establish
that the call's first hop used the neutral Forward DATAGRAM path.

Native receive-age maxima before/during/after the file were Mac
536/628/1075 ms and Poco 1726/1277/4141 ms. The observed interruption count
deltas in those windows were Mac 1/3/7 and Poco 32/4/44 (window boundaries
excluded, so these are not total call counts). Cell ICMP to a different
destination reached 722/712/1246 ms; it cannot identify the cause of the
end-to-end call gaps. Poco's camera did capture frames after active +30 s,
but video stayed paused and encoded frame counters stayed zero on both ends.
This is not a successful encoded-video load test.

A second attempt with the original contacts policy tried direct opening.
Neither initial direct exchange admitted the peer, and the call remained
relay/epoch 1 throughout. Mac logged an expired sovereign signing delegation;
this is a test-identity obstacle to direct certification, not proof of a
particular NAT or radio failure. Ringing took 0.599 s and both active 2.785 s.
Without a file, incoming audio stopped on both endpoints near call +110 s.
Between +110.08 and +130.08, native audio receive counters stayed unchanged
(Mac 5299, Poco 3711), while produced payload counters grew 5303→6299 and
5286→6240. Sender admission was at most 0/3 ms, worker-stalled stayed zero,
and no media rebuild occurred. Authenticated sealed-cell receive samples
also stopped while send samples continued. Both FSMs then logged the normal
20-s media-and-control liveness timeout. Logical call state was absent by
+131.20 s; the driver's eight-second confirmation ended at +139.76 s.

The receive stop is upstream of the sampled native audio worker. Its root
cause is unresolved: the timing alone does not prove cache TTL, and the
current IPC failure metric covers enqueue/pre-write failures, not every
asynchronous daemon refusal. A useful next boundary is sampled own sealed
cells at daemon IPC entry, together with daemon refusal reasons, matched to
the existing sender/authenticated-receiver samples. Existing relay route
repair depends on receiving a peer request; the autonomous silence recovery
currently applies to direct calls. Do not change timeouts or rebuild relay
media blindly before checking the failed delivery boundary.

Both stands have been closed, with no remaining owned helpers, macOS app
process, UID 10521/package processes, remote probe or ADB forward. The second
stand's private cleanup helper initially had an invalid numeric suffix after
copying; it was corrected, run explicitly, and the same process checks passed.
Runtime Mac logs were moved out of the bundle and its strict seal reverified.
Private evidence: neteq2269-summary.json, neteq2269p-summary.json,
neteq2269[p]-samples.ndjson, build-screen-2269.json and cleanup records.
Source changes are committed unsigned and unpushed. The goal remains open
for delivery-stop diagnosis, encoded video/screenshare load and complete
local producer admission coverage.

### Cycle 2270: observe the local delivery boundary

The active call-priority goal is unchanged. Cycle 2269 made progress: source
queue/partial-write defects were fixed and committed, and physical evidence
changed the next investigation to bidirectional loss between sealed send and
authenticated reception. The tree and Poco were revalidated before continuing.

Debug-only sparse sealed-cell observations now cover the SDK socket completion,
pre-write expiry/failure, daemon IPC read, source/rate refusal, handler entry and
relay queue admission/refusal. Samples use the existing epoch/sequence every
50 cells; no plaintext, key or new network field is logged or transmitted.
The local parser borrows bytes so enabling diagnostics does not copy entire
video cells. The debug switch is off by default. No routing policy, timeouts,
relay scheduling, codec or native media 2258 is changed.

Existing IPC/client suites pass 134/39 tests (five IPC ignored); these check the
changed execution paths, not physical call quality. Fresh production SDKs and
stand build 2270 were prepared for a no-file repeat with the original
contacts policy. Missing receive samples alone cannot distinguish a daemon
refusal from network loss; the added boundary samples are required before
choosing the next corrective change.

### Cycle 2270: physical delivery-boundary findings

Two no-file calls ran for 180 seconds after both endpoints became active.
Poco stayed on cellular; the computer used its normal network. Build 2270
used fresh production SDKs, unchanged production media 2258 and the existing
production APK signer. Installed APK bytes and the Mac SDK code section were
verified against the fresh outputs; identities/history were retained.

With the original contacts P2P policy, ringing took 8.20 seconds and both
endpoints became active at 9.11 seconds. P2P actually worked, starting around
14 seconds. Receive gaps remained: maximum sampled native audio age was
6,316 ms on Mac and 12,963 ms on Poco. Around 131 seconds, a silent direct
session triggered relay recovery; the call continued to the end. The earlier
expired delegation warning therefore does not establish that P2P is impossible
or explain those gaps by itself.

A second call temporarily denied P2P at both endpoints to isolate the relay
path. Ringing took 17.29 seconds and both were active at 17.93 seconds.
All 487 active samples used relay; maximum native audio age was 2,911/2,966 ms
(Mac/Poco). The persistent bidirectional stop seen in 2269p did not recur in
either call. This is not proof that its cause has been fixed.

Each sampled sealed cell written to local IPC had matching daemon-read,
handler-entry and successful relay-admission observations: 69/69 cells on each
side in the mixed call; 198/198 Mac and 197/197 Poco in the relay-only call.
No sampled source/rate refusal, writer expiry or socket failure was observed.
Admission is not end-to-end delivery, and these observations do not localize
loss farther along the route or the separate P2P receive gaps.

The camera captured but encoded video stayed paused (zero transmitted video
frames), so neither run proves quality under encoded video load. Duplicate
fanout/replay and authentication failures share the ingress drop diagnostic;
its count alone is not evidence of a cryptographic defect.

Both stands and their probes/helpers exited. Full Poco UID/package checks,
forward removal and Mac process checks passed. The relay-only test restored
both contacts P2P policies. Runtime logs were archived outside the Mac bundle
and its strict signature seal verified. Private evidence: neteq2270[r]-summary,
samples/result/cleanup, mac-2270[r].stdout and packaged/installed build manifests.

### Cycle 2271: retain ordinary small app-data origin

Source inspection found a separate endpoint priority gap: normal small SDK
AppIpcSend messages defaulted to the neutral INTERACTIVE local lane, so they
could bypass the primary source's byte/pressure budget on the ordered path.
Large source envelopes/streams already retained their owned admission path.

Ordinary SDK sends now select the existing IPC-only recoverable DATA lane.
Explicit media source selections and legacy media/lifecycle controls keep
their existing paths. The anonymous fallback stream producer explicitly
retains its INTERACTIVE flow-control lane for SYN/SYN_ACK/ACK/FIN/RST; DATA
and retransmitted DATA retain recoverable admission. The default reply-aware encoder also retains local
origin; anonymous reply routing may still use its existing independent
admission path. Local header hints are not copied to network frames. No relay
priority, payload role or new wire field is introduced. Generic neutral
transit remains INTERACTIVE; carrier absence alone never proves local origin.

This closes the small SDK-send bypass, not every internal origin path. In
particular, the separate single-frame ACK retry and internal control/RPC
producers still require a source-ownership audit. Physical audio quality and
the 2269p delivery stop remain open investigations.

Regression evidence: the real encrypted ordered runner delivered all 32 small
400-byte messages in order, let neutral transit pass during source pressure,
and resumed without further input. Reverting its local marker to INTERACTIVE
fails the same test (all 12,800 bytes bypass the first pressure window).
Reverting the SDK encoder also fails its origin test. Client/IPC/session/SDK
suites pass 40/135/415/223 tests (813 total; 12 ignored); the anonymous
flow-control and sender-isolation tests cover the changed classification.
The debug call API now exposes accepted peer capture state and sparse sealed
send/receive logs include local wall-clock milliseconds, without changing
wire bytes. Flutter analysis of the changed debug file passes. Fresh stand
2271 was prepared next; physical findings follow.

### Cycle 2271: physical message load and P2P receive gaps

Fresh production SDKs were built for Mac and Android and packaged in stand
0.13.84+2271. APK signer, full installed APK hash, independently stripped
Android SDK and the Mac SDK code section were verified. Native media 2258
and hidden-volume stayed unchanged. Poco data was preserved; its Wi-Fi
remained disabled. The production Mac application was not replaced.

The call rang at 8.46 seconds and both endpoints were active at 9.55 seconds.
It stayed active for the requested 180 seconds, switching from initial relay
to P2P and ending by explicit test hangup. While active, Poco sent 32 distinct
small messages to the computer. All 32 appeared exactly once, in source order,
within 11.73 seconds of starting that phase. This confirms delivery under
the changed local source classification; it does not measure acoustic delay.

Audio quality still failed: maximum sampled native audio ages were 6,182 ms
on Mac and 7,714 ms on Poco. At those gaps the peer's accepted audio capture
was on and receive telemetry was supported. Missing capture knowledge does
not explain these outages. The normal repair grace remains 10 seconds; the
3-second early direct-session check only falls back after a negative admission
result, which is eligibility rather than proof of primary media delivery.
Those facts are not yet a justification for changing timeouts or causing
additional route rebuilds.

All 21 Mac and 19 Poco sparse relay samples crossed socket completion,
daemon read, handler entry and successful queue admission. Matching decrypted
receive samples show asymmetric initial relay transit: Mac-to-Poco median
2,552 ms / maximum 5,383 ms, reverse median 84 ms / maximum 300 ms. The clock
probe's round-trip half-width was 17.8 ms. These are sparse sealed-cell
transport observations, not mouth-to-ear measurements or a whole-call loss
percentage. P2P matched samples usually arrived quickly (medians about 4/60 ms),
but 57/190 and 74/186 sparse direct sends had no matching receive observation.
Send observations precede final SDK/QUIC admission, so this still cannot
distinguish a sender-side expiry, transport loss or an unobserved ingress.

Independent local primary QUIC recovery attempts and cancellations on ACK
progress were observed on both endpoints. The next investigation must match
those events and sender admission/expiry to the actual receive gaps; an ACK
or a live parent control session alone does not prove audio is arriving.
Video remained paused with zero encoded frames, so mixed encoded video load
is still unverified. The earlier persistent 2269p relay stop did not recur.

The call driver and all stand/helpers exited. Full Poco UID/package checks,
remote probe removal, ADB-forward removal and Mac process checks passed.
Runtime logs were moved outside the Mac bundle and its strict seal verified.
Private evidence: neteq2271-summary/samples/result/cleanup, clock2271,
message-phase2271, build/installed native manifests and Mac/Poco runtime logs.

### Cycle 2272: recover established audio independently of parent admission

Cycle 2271 was progress: source admission changed, encrypted delivery tests
passed and the physical run narrowed the remaining outage. Current trees were
clean and Poco was available before continuing.

The 7.7-second Poco receive gap matches the Mac primary QUIC path: from about
t69 it stopped receiving ACKs, UDP sends were limited to PTO probes, and queued
datagrams expired. Replacement attempts at t70.75 and t73.77 timed out after
3 seconds in the connect phase; an authenticated replacement at t77.71 resumed
the primary. Event/timer queues did not stall. ACK-progress cancellation on
the opposite endpoint was not the cause of this longest gap. This localizes
the pause to primary transport delivery/recovery, not microphone intent or
native audio production; it does not identify the underlying network loss.

The call watchdog used parent direct-session admission as a prerequisite for
early recovery. A healthy parent/control path cannot establish that a separate
primary connection is delivering audio. Now, after the existing 3-second
receive deadline, previously flowing audio may trigger the already permitted
P2P-to-relay recovery without waiting for a negative parent query or for the
peer's repair request. Both parties must be direct; authenticated peer capture
must indicate audio on, audio receive telemetry must be available, and actual
audio must have arrived in the current receive session after the current
unmute/start boundary. New sessions and unmute without first audio retain
the ordinary 10-second grace. Existing fallback suppresses further P2P
upgrades in the same call and serializes route replacement.

No relay priority, role disclosure, mailbox delivery, native transport timeout
or QUIC congestion policy changed. The new policy gives missing established
audio precedence over ongoing RTCP/video and parent eligibility. It is a
recovery correction, not a claim that arbitrary cellular packet loss is fixed.

The old implementation fails the new independent-audio test despite live
parent admission and fresh video/RTCP. The updated call/route/audio activity/
bitrate/playout suites pass 215 tests. They cover flowing and stopped audio,
mute, unknown capture, legacy telemetry, startup, replacement-session grace,
unmute, in-progress repair, anonymous peer policy and no bounce after recovery.
Flutter analysis passes. Native SDK/media remain the verified production
2271/2258 outputs; stand 2272 is rebuilt for the physical recovery test next.


Physical stand 2272 (Mac and Poco on cellular) stayed active for the requested
180 seconds and ended by explicit hangup. Ringing took 9.086 seconds; both
endpoints were active at 10.306 seconds. The early established-audio recovery
was observed on Poco and the call subsequently stayed on relay. Sampled native
receive ages reached 4,154 ms on Mac and 3,508 ms on Poco: pauses remain, so
this is progress rather than completion of audio quality work. Polling has
observation gaps around session replacement; these sampled maxima cannot
establish the exact duration of every outage. All 32 concurrent test messages
arrived once and in order (11.489 seconds). Encoded video frames remained zero,
so simultaneous encoded-video load is still unverified. All 167/171 sampled
local relay writes reached daemon admission. Sparse matched relay cells had
medians of about 130/91 ms and maxima of about 6,499/3,716 ms, with a 15 ms
clock-probe half-width; these are transport observations, not acoustic delay.
Cleanup verified no owned Mac/helper processes, Poco UID/package processes,
remote probe or ADB forward remained. The runtime log was archived outside
the Mac bundle and its strict code-signing seal passed verification.

### Camera preview status mirroring

The local camera tile applied a horizontal transform to the entire video
widget, reversing its waiting text and icon. Group self tiles also transformed
waiting and stale-video labels. Mirroring now belongs to the decoded image
inside CallVideoFrameView, keeping every status label and placeholder upright.
Existing self-camera, remote-camera and screen-share orientation choices are
preserved; Android's native preview already mirrors only its texture.
The renderer regression checks actual horizontal render coordinates for
waiting text/icons, camera pixels and stale text/icons, including disabling
mirroring on a mounted view. Renderer and group overlay suites pass all 10
tests; analysis of the changed UI and regression test reports no issues.


### Cycle 2273: preserve source admission on single-frame ACK retry

Cycle 2272 was progress: source recovery and the UI correction changed the
current tree, and the physical run established remaining receive gaps. The
current root and Veil trees were clean; Poco was available on ADB.

Re-reading physical 2272 capture diagnostics establishes why no video load
was encoded: Poco camera capture was running at about 30 fps, while video
send remained paused by audio reservation. After t45, 321 samples report a
running camera and 322 report paused video. Native audio buffer estimates
reached 537/569 ms (Mac/Poco); 293/199 samples were at least 300 ms, with fresh
peer playout feedback also crossing the limit. This was not a camera startup
failure. Do not lower audio protection thresholds just to obtain video load;
a separate controlled healthy-path mixed-load proof remains required.

The single-frame end-to-end ACK retry path still submitted this node's
retained Forward frame as neutral INTERACTIVE data. It now keeps the existing
endpoint-only recoverable DATA selector, as the initial ordinary SDK send
does. Retrying no longer bypasses source scheduling or shared byte admission
under independent primary pressure. The wire header, E2E envelope, content ID,
ACK key, retry attempt policy and synchronous queue-refusal/reroute semantics
are unchanged. Only the hop and existing attempt suffix are patched as before.
This path owns locally registered pending messages; transit forwarding does
not call it. Chunk retries retain their separate bounded credit-waiting path.

The regression submits 32 real E2E envelopes through the retry producer and
session scheduler, admits primary and neutral transit ahead of that burst,
and verifies ordered complete delivery, unchanged wire headers/envelopes,
valid decryption and rejection of missing hops or invalid attempts. Restoring
the old neutral selector fails the ordering assertion. All four retry tests,
ten pending-ACK tests and eight encrypted QUIC source-pressure tests pass
(22 tests). The existing pressure fixtures verify retained byte order,
neutral transit, wakeups and cross-neighbor source throttling. No relay
priority or payload-role disclosure is added. Internal RPC/control origin
paths and physical audio pauses remain open; this cycle does not prove the
full audio-quality objective complete.


### Cycle 2273: packaged SDK and physical evidence

Fresh Mac/arm64 Android production-feature SDKs include Veil 2bfd1ddd and root
baa6ed87. Stand Dart build 0.13.84+2273 includes the camera-label correction.
Poco was updated in place with the same production signing certificate; its
pulled full APK hash matches the signed artifact. Independent Android SDK
stripping matches the packaged bytes, Mac SDK code sections match the fresh
build, ABI matches, and Mac strict signature verification passes. Native media
2258 and hidden-volume are unchanged. Source hashes include the ACK retry
producer and its runtime consumer. The production /Applications installation
was not replaced.

The 90-second Mac-to-cellular-Poco call rang at 0.417 seconds and both endpoints
were active at 2.207 seconds. It stayed active and ended by explicit hangup.
Most observations used P2P after initial relay: 165/164 P2P and 39/38 relay
active samples on Mac/Poco. Maximum sampled native audio ages were
2,887/2,908 ms; this still does not prove interruption-free or low-latency
acoustic playback. All 18/15 sampled local relay writes reached admission.
Camera capture ran but transmitted encoded video remained zero, paused by
audio reservation, so mixed encoded-video quality remains unverified.

The concurrent message phase did not complete its receiver check before
shutdown. Poco logged 32 successful send API responses. A separate 30-second
history check after both endpoints restarted found all 32 distinct, ordered
rows on Poco (status sent), but only one matching delivered row on Mac at
every observation. This is a newly observed delivery failure, not a successful
load test or proof of permanent loss. Its cause and relationship to the source
retry correction are unproven. During the original call, Poco additionally
logged 90 app.ratchet.open_failed observations, including 65 missing-ML-KEM-leg
prologue refusals and 19 authentication failures. These are in the reverse
direction from the message burst, so they do not by themselves explain its
missing messages. Do not weaken the existing downgrade/authentication guards.
The next investigation must capture both native sender and receiver errors,
queue admission and crypto state while reproducing the burst.

Both call and history stands passed cleanup: every owned process exited, no
Poco UID/package process or remote probe remained, and the test ADB forward
was removed. Mac runtime logs were archived and its strict seal rechecked.
The short history launch reused and overwrote the original Mac stdio file;
original-call Mac native stdout evidence is unavailable. Its Dart devlog,
API samples and result survive. Original-call Poco native logs were recovered
from the device ring buffer with an explicit timestamp window and saved as
poco-logcat2273-recovered.txt. Use the preserved call devlogs separately from
the later history devlogs; do not infer absent events from overwritten files.
Private evidence includes neteq2273 samples/result/summary/call-cleanup,
history2273 observations/cleanup, build/native/installed manifests and test
logs. This cycle changed source, verified packaging and exposed a delivery
failure. The full audio-priority goal remains active.


### Cycle 2274: preserve reliable delivery across simultaneous crypto starts

Cycle 2273 made progress by changing retry admission, rebuilding/installing the
SDK, and discovering the 32-to-1 delivery failure. The current trees were
clean. Poco is absent from authoritative ADB enumeration this cycle; no new
phone/Mac call stand was launched. A prepared quiet-message diagnostic stopped
at its first ADB forward before launching an app. Source work continued.

The previously ignored simultaneous-initiation regression fails on the original
Veil tree with AuthFailed. Both endpoints can replace their outstanding own
PQXDH roots with the other endpoint's root, leaving opposite sending/receiving
chains. This is a confirmed independent defect, not yet the established cause
of physical 2273's missing messages or voice gaps. Veil 448774f9 fixes this
without changing the wire format, primitive cryptography, relay scheduling or
payload-role visibility.

Verified crossed initiation chooses an initiator by (node, instance), retaining
one alternate receive session for already sealed messages. Pending prologues
remain attached until the corresponding root is answered. A bare frame that
opens under the alternate can select it, including a peer using the former
unconditional displacement policy. An unanswered sending chain beyond the
fresh linear skip window follows the incoming root so one-way peer recovery
is not pinned to an unreadable old chain. Only a verified same-device key can
create an alternate; a newer restart of an answered session retains the
existing freshness/authorship checks. Consumed keys under either root and
recognized prologue replays do not diagnose a wedge. Receivers recheck a
recognized prologue under the store lock after unlocked PQXDH work, preventing
concurrent admission from returning the same plaintext twice.

Ordinary conversations still write V3; conversations holding two roots write
V4 and read V2/V3/V4. V4 preserves both sessions and accepted prologue prefixes,
rejects nested alternates and malformed/trailing data, and costs at most two
primitive sessions per conversation. Older SDKs do not read V4: downgrade is
not supported for such persisted conversations. The alternate's skipped keys
are counted in the store budget; normal eviction protection remains intact.
Both sending positions are exposed and reservation recovery advances either
retained chain, including a receive-only chain that can later become a sender.
The snapshot exporter reserves its exact complete size before copying secrets
and zeroizes its output, avoiding an abandoned allocation during growth.

The native and host snapshot ceilings are now 1 MiB to cover two bounded
primitive skipped-key/tree banks and prologues. This is an input/output ceiling,
not a per-conversation allocation or a change to ordinary state size. The C
header and Rust/Dart ABI contracts were regenerated together (fe3251ea2a912196
prefix); regeneration also incorporates the existing source DATA-selector-4
API comment. The ABI guard prevents mixing the new Dart bindings with an older
native library. The pending-peer recovery test still requires its reply to
open immediately; it now allows a repeated own prologue because its inputs are
indistinguishable from crossed initiation, and a forced bare reply would
restore opposite-root displacement.

All 134 E2E and 93 primitive tests pass, with no ignored crypto regression.
Coverage includes 32 messages each way, reordered delivery, both stores
restored before completing the backlog, exact delivery ACK keys, consumed-key
replays after another restart, same-identity devices, an advanced unanswered
chain, forged same-node/instance claims, sixteen simultaneous receivers, two
sending reservations and a simulated non-arbitrating peer. Disabling crossed
retention makes the burst regression fail on actual AuthFailed after restore,
not on a format assertion. E2E Clippy passes with warnings denied.

Four production-feature native FFI tests pass, including a real crossed V4
snapshot returning two position records and refusing short buffers without
partial output. The host persistence/reservation/ABI suites pass 53 tests with
one environment-gated native check skipped. A freshly built production-feature
Mac SDK passes all seven live-node/ABI tests, including that gated check. An
additional real-ABI V4 test persists two retained chains, reserves both,
forgets the in-memory conversation to model a crash, restores the older
snapshot from the container and burns 32 indices in EACH chain. That test
passes. Native test nodes stop in their finally blocks; the test runner exited
and no flutter_tester process remains. No user app or phone installation was
changed this cycle; commits are unsigned and unpushed.

Private evidence is baseline2274-crossed, negative2274-crossed-burst-v2,
crypto2274-final-tests, ffi2274-final-tests, clippy2274-final,
host2274-ratchet-final-tests, host2274-native-tests,
host2274-crossed-live-tests, header2274 and sdk-mac2274-build under the existing
private scratch directory. The original-call receiver failure still needs a
new capture with both endpoint native logs; do not discard identities/history
or reset ratchets to mask it. Actual encoded-video/screen load alongside
low-latency acoustic audio, the physical gaps, and the remaining producer
admission audit are still unverified. The full audio-priority objective remains
active.

### Cycle 2275: separate locally authored network queries from neutral transit

Own SessionOutbox RPCs and the three NodeServices recursive-DHT fanout paths
previously used the same local INTERACTIVE scheduling class as opaque transit.
They could bypass endpoint audio-pressure limits. Own network requests now use
an internal sixth queue (selector 5, interactive WRR weight), separate reserved
FrameSender ingress and bounded admission credits retained through the priority
queue. It is not an IPC selector, capability or wire field. Encoded headers,
received/forwarded traffic, and relay policy remain unchanged. No remote caller
can select this class with the two-bit wire priority.

During authenticated pressure on an active local primary, all neighbors share
an independent 1,024-byte network allowance per 200 ms, distinct from the
4,096-byte reliable DATA allowance. Whole oversized compatibility frames can
progress alone. Source FIFO and credits survive deferral; a deadline wakes the
runner without a new producer/incoming event. Primary ingress remains separate,
and bounded interleaving prevents continuous primary/control producers from
starving neutral ingress. Closing control ingress wakes a producer even while
all its credits remain held by the scheduler. RPC replacement-session ownership
cannot consume or release another registration's credits.

Verification: 422 veil-session tests pass (six existing manual characterization
fixtures remain ignored); 648 veil-node-runtime tests pass (11 existing ignored).
Clippy on both libraries and their tests passes with --no-deps -D warnings.
The new actual TLS/QUIC fixtures exercise both SessionOutbox and FrameSender
producers, check unchanged decrypted query headers/bodies, neutral progress,
ordered once-only completion after pressure deadlines, and independent progress
when DATA is exhausted. An original-behavior negative baseline, restoring both
INTERACTIVE admission and the absence of retained RPC credits, fails because
3,504 bytes escape in the first pressure window. The source was restored exactly.
An earlier partial baseline retaining new credits instead fails DATA starvation;
it is not the evidence for the original bypass. Private logs: session2275-tests-v2,
runtime2275-tests, clippy2275-tests and negative2275-rpc-v2.

The camera-label regression was rechecked: four video_frame_view widget tests
pass; only camera pixels mirror, while waiting/stale text and icons remain
readable and screen sharing remains unmirrored. The correction is ee3da8bc.
No fixture app was launched by these tests and flutter_tester has exited.
Poco has returned on ADB; packaging and a fresh physical call/message check are
next. Acoustic delay, simultaneous encoded video and the older physical missing
message burst remain unverified. Other locally originated anonymous/network
producer paths have not all been audited; the full goal remains active.

### Cycle 2275: package verification and physical retry with returning Poco

Mac and arm64 Android SDKs were rebuilt from Veil ad49c3ff/root 8a027fbc,
including both crossed-root persistence and own-network admission. Stand version
0.13.84+2275 was built for production networking. Poco was updated in place:
production certificate matches, the pulled installed full APK matches the signed
artifact, independently stripped SDK bytes match the package, and both platforms'
ABI checks match. Mac SDK code sections match the raw rebuild and its initial
strict bundle seal passes. Native media remains 2258 and hidden-volume 2.6.1.
Poco has Wi-Fi disabled, USB charging and 97% charge at preparation. Existing
identities, histories and ratchets were preserved; no forget/reset was used.
The production /Applications installation was not replaced.

First run (2275) failed setup: Mac dialed and Poco did not ring before the
45.276-second observation deadline. The helper's exit code 0 is not a passed
call; its JSON explicitly records setup_failed. Message and camera phases did
not reach their active-call prerequisite, so it provides no audio/load result.
Poco logged prologue refusals with a missing ML-KEM asymmetric leg from the
known Mac peer. Later Dart logs show the cancel reaching Poco. The available
observations do not yet establish why the original offer was unreadable or
whether the later exchange repaired a legacy crypto state. Keep the guard.

Second run (2275b, same installed build/profiles) rang at 1.022 seconds; both
APIs first showed active at 21.105 seconds. It remained active for the requested
90 seconds and ended by explicit hangup. All 32 newly authored Poco-to-Mac rows
arrived exactly once in order, observed in 12.488 seconds. Before this run, only
2 of the older 32 `priority-2273` rows were on Mac; it stayed at 2 afterwards,
while Poco had 32 throughout. New success does not repair or explain that old
history gap, nor prove the cause of either setup outcome.

Maximum sampled native audio receive ages were 313/332 ms (Mac/Poco). These are
freshness observations, not an acoustic delay measurement. Native playout stats
reach two interruptions in one engine epoch, cumulative durations 803/503 ms;
audio delay maxima 510/407 ms and jitter-buffer maxima 560/424 ms. Poco sender
payload/RTP maximum gaps reach 360 ms; Mac maxima are 28/26 ms. A capture pause,
silence/DTX, dispatch stall and network loss have not been separated causally.
Most active observations used P2P (Mac 153 P2P/10 relay; Poco 154/59). Sparse
cross-device trace estimates include a Poco direct maximum around 1,168 ms;
the ADB clock probe bound is 21.5 ms and slightly negative Mac estimates expose
alignment uncertainty, so do not present these as precise acoustic latency.

Poco camera captures at about 30 fps (1,523 frames), but both video_tx_frames
remain zero and video_send_paused is set under audio reservation. This has not
verified simultaneous encoded-video quality; relaxing the audio guard would
hide the remaining playout issue. The full audio-priority goal remains active.

Both runs' owned apps, UID/package processes, remote probes and ADB forwarding
are verified closed. The second private cleanup script initially failed to parse
because a capture suffix was substituted into a numeric build field; it was
corrected and cleanup rerun successfully (cleanup2275b-recovery log). No helper
or app is left running. Mac's appended runtime log is archived privately as
mac2275-and-2275b-runtime-debug.log, then strict bundle seal verification passes
again. Distinct original stdout/logcat/devlogs for both runs survive; no history
launch overwrote either capture. Private evidence: build-screen/build-mac/installed
2275 manifests, physical/neteq/message-phase/cleanup captures for 2275 and 2275b,
plus neteq2275b-summary and its raw samples. No commits were signed or pushed.

### Cycle 2276: call-control dispatch must not await outbound device ACKs

The ordinary inbound lane awaited a call frame's ACK before dedup and call FSM
dispatch. An ACK to the authenticated sender device can need a slow outbound
route/certificate lookup. Holding that send holds both the answer and subsequent
ordinary-lane control events. Call signals now launch the same ACK asynchronously,
as the dedicated realtime lane already does. Dedup is still recorded before the
FSM callback; duplicates are ACKed without replaying the callback. Consent,
provenance, group authorization and persistence-before-ACK gates are unchanged.
No mailbox, wire priority or relay scheduling policy changes are introduced.

A regression holds the device-addressed ACK unresolved, then delivers a duplicate
answer and a route update. Original behavior times out at dispatch; the correction
dispatches answer and route once, in order, while all three receipts still start
their ACKs. All 40 realtime-call tests pass and targeted analysis reports no
issues. The combined realtime/durable run has 74 passes and five durable silence
policy failures. The same five failures occur with the original dispatch source;
they are existing failures, not a green full-suite claim. Private logs are
baseline2276-held-call-ack, baseline2276-durable, host2276-call-ack-final-tests,
realtime2276-final and analyze2276-call-ack-final.

Reanalysis of 2275b also corrects the interruption counts above: switching from
relay to P2P recreates the native media engine and resets its counters around
24.4 seconds. At least three interruptions per endpoint are observed across
engine epochs, so a maximum counter of two is not a whole-call total. Most early
playout gaps precede the message/camera load. Callee active is observed at 2.16 s
versus caller active at 21.058 s; the outbound ACK dependency is now proven by a
controlled test, but is not yet a proven cause of that physical delay. Physical
verification of this change, acoustic delay and simultaneous encoded video
remain outstanding; the full audio-priority goal remains active.

### Cycle 2276: returning Poco physical captures with asynchronous call ACK

Built Mac and Android 0.13.84+2276 from root ed7185d6 and Veil ad49c3ff,
with unchanged native media 2258. Production APK signer, full pulled installed
APK bytes, independently stripped SDK/media bytes, ABI, Mac SDK/media code
sections and strict bundle seal were verified. Poco updated in place with Wi-Fi
off and USB charging (99% at preparation). Actual identities, history and
ratchets were preserved. The production /Applications app was not replaced.

First run (2276) failed setup after 45.251 s. The offer's first logged realtime
dispatch on Poco was about 68.4 s old, after its cancel; the finished-call guard
correctly ignored it. One native decryption failure reports unavailable message
key (replay/too far behind), not the previous run's missing ML-KEM leg. Available
logs do not establish that this packet was the offer or explain its late arrival.
Sender live-leg success means local acceptance, not remote delivery. No active
call, message-load or video result can be claimed for this attempt.

Second run (2276b, same installed APK/profiles) rings at 0.381 s, with both APIs
active at 1.275 s. It stays active for the requested 90 s and ends by explicit
hangup. Call establishment improved in this attempt, but network variation and
the preceding failed attempt prevent attributing this change solely to the ACK
fix. All 32 newly authored rows arrive exactly once, in order, observed in
12.216 s. This cycle's message phase waits for both endpoints to show the same
active call before its 35-second offset; the earlier phase used callee active.

The older priority-2273 burst is finally complete without reset: Mac has 2/32
before the first run, and 32/32 before and after the second; Poco retains 32/32.
Recovery occurred between those observations. This does not establish which
retries repaired it or the cause of the original missing rows.

Audio is still not acceptable. Across sampled counter resets, Mac observes at
least eight native interruptions (2,741 ms accumulated) and Poco at least 17
(6,128 ms). Delay/jitter-buffer maxima are 561/567 ms on Mac and 408/402 ms on
Poco; receive freshness maxima are 1,795/897 ms. Mac discards 30 buffered audio
packets at approximately 47 s and another 30 at approximately 71 s, with native
buffer flushes and interruption growth. These are evidence of a playout failure
even while fresh packets subsequently arrive, not proof of the original burst's
cause. Around 76 s Poco logs early relay recovery for stalled established direct
audio; both controllers then recreate the media engine on the relay transition,
with additional interruption growth. This requires separating genuine direct
loss, delayed local telemetry and disruption introduced by route teardown.

Sparse aligned packet traces show direct-send maxima around 386/1,014 ms
(Mac/Poco) and relay-send maxima around 1,892/1,072 ms. The clock probe bound
is 14.5 ms; these are sparse packet observations, not acoustic delay. Initial
P2P success does not prove a stable link for the full call. Camera capture was
enabled at joint-active +31 s, but encoded video remains zero under audio
reservation. Simultaneous encoded-video/audio quality remains unverified;
do not relax the guard to label this check successful.

Both captures' owned apps, helpers, UID/package processes, remote probes and ADB
forwarding are verified closed. Runtime-added Mac logs are archived separately
as mac2276-runtime-debug and mac2276b-runtime-debug; strict bundle seal passes
again. Poco is still available over ADB. Private evidence is build-screen,
native-policy, installed and build-mac 2276 manifests; neteq2276/2276b captures;
message-phase2276b; neteq2276b-playout/summary; and both cleanup records.
Source correction is committed unsigned as ed7185d6; nothing has been pushed.
The full audio-priority goal remains active.

### Cycle 2277: preserve the media engine across relay/P2P route handover

Three receive-local NetEq smart-flushing experiments were rejected rather than
deployed. The default retained a long PCM tail after a one-second arrival burst;
a 120-ms threshold exceeded the 50-ms extra-concealment gate (2,485 extra samples),
and a 240-ms threshold failed both recovery and concealment. Private traces are
playout2277-smart-flush, smart-flush120 and smart-flush240. Experimental sources
were archived privately, then restored exactly. Production remains at the
30-packet capacity, fast acceleration, original flushing and uncapped target.

Route changes previously destroyed the entire media engine, including ADM,
Opus/NetEq, RTP sequence spaces and video streams. An additive native media ABI
now rebinds the existing shim to a caller-owned candidate channel. Registration
failure leaves the old channel active. The new callback is installed before
outbound ownership moves atomically, then the old callback is cleared through
the existing SDK owner/quiescence barrier. Calls, queues, RTP, receive buffers
and capture devices are kept. No wire, identity, relay priority or crypto policy
changes are made. Existing native engines without this optional symbol retain
the previous host path.

The host opens a sealed candidate for the same logical call and checks its
actual route, device/identity and media epoch before committing synchronously.
Current mic/camera/screen intent and receive state survive. Both non-onion
routes use the same 1,000-byte RTP ceiling before codec configuration freezes;
relay batching is configured on the candidate before binding. The retiring
outbound pump gets its existing 200-ms local admission deadline; hangup cancels
and closes all retiring handles. Receive telemetry now follows the current
physical route peer rather than the peer captured by the original timer. A
route_handovers diagnostic counts in-place transitions; the media epoch remains
unchanged. Genuine local receive-worker repair still rebuilds its failed engine.

Actual Opus/NetEq PCM fixtures pass silence/DTX and the unchanged injected-jitter
recovery gates. The new ten-second fixture switches channels twice, rejects an
unknown candidate and zero channel, verifies continuous RTP sequence numbers,
monotonic receive counts, rendered markers within 180 ms over a 40-ms path,
no added concealed samples/interruption counts, and cleared callbacks on teardown.
The real native Call-plane fixture also passes after rebinding already-running
audio/video: audio progresses with both video queues held, and separate feedback,
group fanout, low-rate encoding and bounded telemetry still pass. Private logs:
playout2277-handover, planes2277-handover. All 165 selected host call/route/seal
tests pass, and targeted three-file analysis has no issues. No app profiles were
opened by these fixtures; their binaries have exited. Fresh packaging and a
physical call with preserved Poco/Mac identities remain required. Native jitter,
first-offer delay and mixed encoded-video quality remain unresolved; the full
audio-priority goal stays active.

### Cycle 2277: physical handover verified; audio interruptions remain

Fresh production native media libraries, the SDK and host were packaged as
0.13.84+2277, then installed on Poco in place. Installed APK bytes, signing
certificate, native source/ABI checks and the strict Mac bundle seal pass.
The packaging source-dirty flag came from a generated duplicate JNI staging
file only; that file was removed after packaging and tracked sources are clean.
Actual profiles, identities and history were preserved; the /Applications
production app was not replaced. Poco remained on cellular with Wi-Fi off.

Mac calls Poco: ringing is observed at 0.436 s, both endpoints active at
1.341 s. The call stays active for 90 s and ends by explicit hangup. All 32
new message rows arrive exactly once in order, observed in 15.23 s; the older
priority-2273 rows remain complete on both endpoints without reset.

Natural direct-audio stalls trigger a P2P-to-relay handover around 17.635 s.
Each endpoint creates its controller once and logs one in-place route handover.
Media epoch remains 1 and receive counters never decrease: the physical run
verifies preservation of the live media engine. Camera starts around 30 s and
the message load later, so neither caused this initial direct stall. The planned
Poco policy change occurs only at 58.525 s, when both endpoints are already on
relay; contacts policy is restored at 84.318 s and verified again during cleanup.
That policy phase cannot be credited with inducing the earlier handover.

Audio quality still fails. Without counter resets, Mac records ten interruptions
totalling 7,869 ms, Poco fifteen totalling 11,179 ms. Delay/jitter-buffer maxima
are 1,376/535 ms on Mac and 578/579 ms on Poco; native receive-age maxima are
2,695/2,712 ms. Sparse matched packet traces show maxima of 3,028.6 ms direct
and 2,179.6 ms relay from Mac, and 998.4/1,420.4 ms from Poco, with a 16.6-ms
clock probe bound. These are sparse network observations, not acoustic latency.
They do not isolate which queue, transport or capture stage caused each pause.
Camera capture is enabled but encoded video remains zero under audio reservation;
mixed encoded-video quality remains unverified. Network variation prevents an
audio-quality comparison with the previous capture.

Owned apps, helper processes, UID/package processes, remote probes and ADB
forwarding are verified gone; Poco remains available. The runtime-added Mac log
is archived as mac2277-runtime-debug and the bundle seal verifies again. The
owned xveil-media builder VM is stopped; the user's default Colima VM remains
running. Private evidence: installed2277, native-verification2277,
neteq2277-result/playout/summary/cleanup and handover-phase2277. Native handover
is committed unsigned as Veil 23078ec2 and host 302155b9; nothing is pushed.
The full audio-priority goal remains active: multisecond direct/relay delays,
first-offer delay and actual mixed-media quality still require investigation.

Further audit of the same capture narrows some transport stalls. Direct local
slot 0 already uses an independent QUIC connection. Its sampled loss counters
reach 148 packets on Mac and three on Poco, unsent expired datagrams 214/56,
PTO counts four/three, and RTT estimates 597/894 ms. The sampled event-queue and
timer delays on these senders stay below 3 ms; authenticated datagram dispatch
maxima across the active-call receive windows are below 1.5 ms, with no receiver
rate limiting. This supports a transport/acknowledgment stall rather than a
seconds-long measured datagram handler, but does not isolate network loss from
every unobserved local stage.

The relay cell with the largest matched delay (2,179.6 ms from Mac) is observed
through socket_written, daemon_read, handler_enter and relay_queued. Those IPC
timestamps have one-second resolution: even using the latest end of the sampled
admission second, remote authenticated receipt is over 1.25 s later after the
16.6-ms clock uncertainty. Thus this delay cannot be wholly assigned to the
SDK sender lock or pre-write queue. Logged slow ordered writes elsewhere in the
call reach 1,922/2,646 ms, but are not correlated to this particular cell/hop;
they remain candidates, not a proven explanation. Evidence is the private
neteq2277-stage-audit record. More precise direct IPC and per-hop observations
are still needed before changing transport policy.

The screenshot's reversed waiting label is already fixed by ee3da8bc and is
included in installed build 2277: only camera pixels are mirrored. All nine
preview/pixel/source-freshness tests pass. The older source-shape assertion now
allows whitespace before screenSharing, retaining its mirror-decision check
across ordinary Dart formatting. This follow-up opens no app instances.

### Cycle 2278: correlate direct IPC and relay-origin admission precisely

Opt-in origin tracing now samples typed LOCAL_APP_RT_SEND sealed cells through
socket write, daemon receipt, handler entry and direct queue admission/refusal.
These correlate the same existing sealed epoch/sequence with native pre-send
and authenticated receipt, without adding a timestamp or source role to the
wire. Existing relay-origin samples include at_ms alongside their legacy
second-resolution at field, plus the first physical hop for each fan-out
admission. This distinguishes local admission from remote receipt and separates
the two accepted paths of one cell. No network relay parses media headers.

Parsing borrows local IPC bytes without copying ciphertext. Diagnostics remain
off by default and sample one in fifty nonzero sequences. New parser tests
cover typed direct/relay encoders, sampling gates, invalid magic, every truncated
direct payload and oversized declared length. All 137 enabled veil-ipc unit
tests pass; five existing tests remain ignored. Existing source authorization,
rate limiting, queues, priority and network encoding are unchanged. A fresh
physical trace is still needed; this is instrumentation, not an audio fix.

### Cycle 2278: physical local admission is fast; asymmetric receive loss found

Fresh SDK/host 0.13.84+2278 is installed in place on Poco with the verified
production signature and matching installed APK bytes. Native media remains
the verified 2277 build; trace source hashes are recorded and tracked sources
were clean when packaging. Ringing is observed at 4.132 s, both endpoints active
at 5.502 s. The call runs for 90 s and ends explicitly. All 32 new rows arrive
exactly once in order, observed in 7.413 s. No identities/history are reset.

The new samples locate local post-pre-send admission: direct SDK-to-socket
maxima are 3/1 ms (Mac/Poco), socket-to-daemon 1/2 ms, daemon-to-handler 1/1 ms,
and handler-to-queue 1/1 ms. Relay local stages are likewise at most 1 ms.
Sparse matched direct-send-to-authenticated-receive maxima are 263.1/469.9 ms,
relay 439.1/224.9 ms, with a 23.1-ms clock-probe bound. Unmatched direct cells
are counted separately (four/six); successful sample latency cannot rule out
loss. These stages begin after the native sender lock, not at mic capture.

Both endpoints start on relay and switch to P2P around observation +24.7 s.
Mac later returns to relay around +85.8 s; Poco still sends directly. Mac audio
receive count stops advancing and its receive age reaches 9,813 ms. Poco direct
samples at +88.3, +90.8, +93.0 and +95.5 s are locally queued but lack a Mac
authenticated-receive sample. An earlier no-channel sample shows a previously
authenticated incoming peer no longer present in the receive registry.
Source inspection exposes a deterministic defect: local outbound rebinding
unregisters the prior inbound peer immediately, although directions may use
different physical peer addresses/routes. The physical final gap is consistent
with this defect; logs do not isolate every lost network packet's cause.

Mac records two completed interruptions totalling 3,839 ms; Poco six totalling
5,066 ms. Receive age can outlast a completed-interruption counter. Peak
delay/jitter buffer are 479/404 and 478/618 ms. Mac keeps media epoch 1 across
two handovers, Poco across one. Video encoding stays zero under the audio guard,
so simultaneous encoded-video quality remains unverified. Apps, UID processes,
helpers/probes and forwarding are verified gone; the separately archived Mac
runtime log is removed from the bundle and its strict seal verifies again.
Evidence: neteq2278-result/stage-audit/playout/cleanup, source hashes and manifests.

### Cycle 2279: preserve independently routed incoming media

An actual Opus/NetEq fixture moves the receiver's local channel two seconds
before its sending peer, twice. The old implementation renders only 631/1000
nonsilent PCM ticks and fails the unchanged >950 gate, with timer lateness
4.94 ms. This reproduces route-induced silence without network congestion.

An additive native rebind operation now retains the previous authenticated
receive binding while switching only outbound transport. The host keeps one
receive-only handle per previous physical peer, releases a superseded binding
through the SDK owner/quiescence barrier, and fences all bindings at call end.
The retained handles use the same pinned logical call/peer/key material; media
still opens against its own cipher. Older engines keep their existing path.
Already-queued packets retain their 200-ms local deadline before superseded
handles close; the receive-only old route remains usable for the peer's
independently chosen direction, including after the new route receives data.

The fixed fixture renders 993/1000 nonsilent ticks, with no added concealed
samples/interruptions and all tone markers within the unchanged 180-ms gate.
It also rejects a bad candidate and attempts to release the active outbound
binding, accepts idempotent release, and tears down with an unacknowledged old
incoming leg still present. Callback ownership is empty afterwards. Existing
DTX/jitter/symmetric handover and native direct/group plane isolation pass;
164 selected host call/route/seal tests pass, targeted analysis is clean.
Evidence: asymmetric2279-before-metrics/after-metrics, playout/planes/host2279
receive-overlap logs. This fix still needs fresh native packaging and a real
Poco/Mac run. Network loss, first-offer delay and mixed encoded-media quality
remain unresolved; the full goal stays active.

### Cycle 2279: fresh native deployment and physical receive overlap

Production native media is rebuilt for Mac and arm64 Android (97 exports,
no test hooks), with both additive receive-overlap operations present. Fresh
SDK/host 0.13.84+2279 is installed on Poco in place; signature, installed APK
bytes, independently stripped native libraries, actual packaged SDK imports,
Mac code sections and strict bundle seal verify. Root 3d866f6b / Veil 0a00988e
are committed unsigned. No push/tag/release or /Applications replacement occurs.

Mac calls Poco: ringing at 11.982 s, both active at 12.915 s. The call runs
90 s and ends explicitly. Both start on relay, then switch to P2P; media epoch
stays 1. Mac keeps one receive-only physical peer, Poco none (same physical
peer on both of its routes). Native receive-age maxima are 635/374 ms. There
is no repeat of the previous capture's multi-second receive gap; however, this
capture has no late P2P-to-relay fallback, so the complete previous final-gap
scenario is not reproduced physically. The asymmetric PCM fixture proves the
deterministic old-binding loss separately. Network variation prevents assigning
every improvement in this capture solely to the fix.

Completed native interruptions are one per endpoint, 284 ms on Mac and 245 ms
on Poco; peak delay/jitter buffer 452/422 and 432/447 ms. All sampled direct
cells match authenticated receipt (96/43), with maxima 311.7/262.3 ms and a
16.6-ms clock bound. Local post-pre-send stages remain at most 4 ms. All 32
new message rows arrive exactly once in order, observed in 7.352 s. Old rows
remain complete; identities, history and ratchets are preserved.

Two remaining problems are now narrower. At setup, Poco logs several early
realtime offers rejected as unauthenticated/claimed. A later authenticated
offer is dispatched at age 10,929 ms; initial rejection is correct and must
not be relaxed. The next investigation is why the fast call path sends a form
the recipient cannot authenticate, then waits for its valid path. During the
late call, peer playout feedback remains 420/407 ms despite RTT 57/186 ms and
jitter 9/5 ms. Video stays paused, target 1,000 bps, encoded frames zero. Actual
encoded-video/audio/screen mixed quality remains unverified; investigate the
playout measurement and guard before altering policy.

Both apps, UID/package processes, helpers, remote probes and ADB forwarding are
verified gone. The Mac runtime log is archived separately and its strict seal
verifies again. The owned xveil-media builder VM is stopped; the user's default
Colima VM and default Docker context remain unchanged. Private evidence:
build-screen/native-policy/installed2279, native-verification2279-packaged,
neteq2279-result/stage-audit/playout/cleanup and message-phase2279. The full
audio-priority goal stays active; this is not a full audio-quality completion.

### Cycle 2280: repeated cold setup and terminal authentication diagnostics

Poco is available on cellular (Wi-Fi off). With the unchanged 2279 media
engine, one restart capture rings at 15.331 s, both endpoints active at
16.507 s; the subsequent reverse call rings at 0.820 s and becomes active at
1.256 s. This supports investigating cold preparation, but does not establish
whether the rejected earlier offers used legacy ML-KEM encryption or an
unproven ratchet. Both can reach the app as Claimed; neither may pass the
existing contact/offer authorization gate.

Sparse successful packet matches in those two calls show direct delays up to
932.8/1146.2 ms and 1889.8/1142.2 ms (Mac/Poco), with relay maxima
1529.8/803.2 ms in the second call. Individual local IPC stages remain at most
1 ms. The clock bound is 21.7 ms, measured after the capture; results assume
no intervening clock adjustment. Unmatched samples remain separate and are
not asserted to be network loss. These observations locate delay after local
admission, without identifying its complete cause.

A separate 85-second mixed attempt rings at 1.457 s after an eight-second
warmup call. Camera starts at about 13 s; encoded video remains zero under
audio reservation. Both endpoints keep engine epoch 3 throughout this call
(epoch advanced between calls, not on camera start or route handover).
Native interruptions reach 9/8126 ms on Mac and 25/29311 ms on Poco. A 512-KiB
file is offered, but its download does not complete within the explicitly
chosen 45-second observation deadline. The owned download is cancelled and
its temporary sink removed. This does not prove permanent file loss; actual
mixed encoded-video/audio quality remains unverified.

An opt-in, bounded terminal diagnostic now reports encryption form and sender
verdict only after local decryption. It records no addresses, content or keys,
adds no wire fields, and is absent from relay forwarding. The existing stand
trace switch enables it; default operation leaves it off. Authorization,
cryptography, queueing and relay policy are unchanged. All 269 dispatcher
tests pass. Veil d5bdbabb and root 793ccbed are committed unsigned/unpushed.

Fresh SDK/host diagnostic build 0.13.84+2280 is installed in place on Poco,
with the same signing certificate and verified installed APK. Mac code
sections/seal, Android stripped SDK bytes and packaged native dependencies
verify. Production media remains the exact 2279 artifact: CPP sources match
its manifest, 97 exports, no test hooks. The /Applications app is not replaced.

The new diagnostic capture rings at 3.475 s after restart and 1.153 s on the
reverse call; all observed terminal samples are ratchet/Signed (85 Mac,
48 Poco). Earlier Claimed offers do not recur here, so this capture does not
resolve their cause or prove a signaling fix. Audio still fails: during the
two 20-second calls, completed interruptions reach 8/3958 and 6/4255 ms on
Mac, 11/5218 and 11/8490 ms on Poco. Engines remain intact across handovers.

Every owned app/helper, UID/package process and ADB forward is verified gone
after each capture; runtime-added Mac logs are archived outside the bundle,
whose strict seal verifies again. Identities/history/ratchets are retained.
Private evidence: auth2280 and mixed2280 result/metric-summary/cleanup,
trace2280 result/metric-summary/terminal logs/cleanup, build-screen-2280,
installed2280, native-verification2280-packaged and dispatcher test log.
The full goal remains active; cold authentication, network delay and mixed
encoded-media quality still require work.


### Cycle 2281: prepared UDP transmit wait and physical audio evidence

Poco returned and is available on cellular, with Wi-Fi off. Veil b58743fa
adds generic local counters for the interval between QUIC packet preparation
and successful UDP socket handoff. The preparation time survives writability
waits and WouldBlock retries; a snapshot also reports the age of a transmit
still pending. These counters do not measure time in the kernel or network.
They inspect no producer roles or content and change neither scheduling,
congestion, authentication nor relay policy. The existing opt-in, once-per-second
source trace exports them. No new wire fields or native ABI symbols are added.

An actual TLS/UDP test holds socket writability for 150 ms without blocking the
executor, checks the in-progress age, releases the socket, verifies the original
datagram arrives, and observes a completed send stall. The existing runtime
stall test also passes. The full Quinn library suite passes 19 tests, with
3 upstream tests ignored. Standalone tests explicitly use the local patched
quinn-proto 0.11.15; the temporary test lockfile update is not committed.

Fresh SDK/host diagnostic build 0.13.84+2281 is installed in place on Poco with
the same signing certificate and verified installed APK. Mac code sections and
strict seal, Android independently stripped SDK bytes, production media exports
and packaged dependencies verify. C++ media sources and artifacts are still
exactly 2279, including receive overlap; /Applications is not replaced.

Two 45-second audio calls ring at 1.291 s after restart and 0.641 s on the
reverse call, both active at 2.595/1.010 s. The first call initially uses relay
and later P2P, with stable media epoch 1; the second remains P2P throughout,
with stable epoch 3. Completed native interruptions remain: Mac 2/722 ms and
0/0 ms, Poco 4/1642 ms and 5/1478 ms. Native receive-buffer estimates reach
408/566 ms in the first call and 453/572 ms in the second (Mac/Poco). This is
not an audio-quality completion, nor evidence that diagnostics fixed signaling.

Across sampled independent local-primary connection snapshots, completed
packet-to-UDP wait maxima are 702 us on Mac and 2087 us on Poco, with zero
100-ms send stalls and zero pending age in those snapshots. Event-queue maxima
are 408/1729 us, timer lateness at most 3841/2376 us, and receive dispatch at
most 981/1078 us. Connection maxima include their earlier lifetime; call-window
filtering prevents the first call's observations from including the second.
These measurements exclude a large observed socket-writability wait in this
capture. The pre-packet outgoing local-primary expiry remains 200 ms; no
outgoing expirations appear in these sampled primary connections.

Sparse successful direct sealed-cell matches take at most 593.4/859.6 ms in
the first call and 250.4/140.6 ms in the second (Mac/Poco sending). IPC stages
are at most 1 ms except one 8-ms Poco socket-to-daemon interval. The clock probe
bounds before/after are 21.8/23.9 ms; estimated offsets differ by 9.1 ms, within
those uncertainties. Matches are sparse sealed cells, not a complete audio
packet timing trace, and the one unmatched first-call send is not asserted to
be wire loss. Remaining delay may include kernel/network time and receive
playout; this does not isolate the cellular carrier as the cause.

Native buffer flushes coincide with some, but not all, completed interruptions:
first call Mac discards 30 packets and Poco 60; second call Mac discards none
and Poco 30 near the end. Prior reduced-capacity, target-cap and smart-flush
experiments failed their PCM/physical gates, so no such tuning is redeployed.
Further work must distinguish arrival bursts from receive-buffer recovery
using actual packet/PCM evidence. Encoded video and file coexistence remain
unverified by this audio-only capture.

All owned apps/helpers, phone UID/package processes and ADB forwarding are
verified gone. Runtime-added Mac logs are archived outside the bundle, whose
strict seal verifies again. Identities, history and ratchets are preserved.
Private evidence: udp2281-quinn-tests/full-tests; build-screen-2281,
native-policy2281, native-verification2281-packaged, installed2281;
trace2281 cold/warm result/playout/stage-audit; clocktrace2281 before/after;
neteqtrace2281-cleanup. The audio-priority goal remains active.


### Cycle 2282: scoped contact-device stream policy and remaining mixed failure

The old mixed2280 Mac runtime log contains five `stream-accept p2p DENIED`
records, each for a device address different from the known contact identity.
The failure was before the serve request, not evidence that audio scheduling
starved a payload already being served. The timeout observer also omits its
last progress values, so null done/total alone must not be read as zero progress.

MultiIdentitySession's stream policy looked up only a contact row at the raw
physical-device address. It now uses the existing policyContactFor helper with
THIS messaging instance's authenticated device-owner map and THIS storage view.
The messaging instance is assigned before its start/callbacks. Explicit device
rows retain precedence; unknown devices, blocked owners, anonymity posture and
P2P overrides remain subject to their previous gates. No wire authentication,
relay scheduling, producer budget, or audio/video guard is changed.

A regression boots the actual session factory, learns a device-owner pair from
an authenticated inbound message, then downloads and verifies a 90-KB file over
P2P with no anonymous fallback. It times out on the original factory and passes
after the change. It additionally verifies stream EOF for an unknown device,
a blocked owner, and an explicitly blocked device despite an accepted owner.
All 66 stream/session/contact-policy tests pass. Root d9d3561a is committed
unsigned and unpushed.

Host 0.13.84+2282 is built and installed in place on Poco. Its SDK is byte-for-byte
2281 (Veil b58743fa), C++ media byte-for-byte 2279; source hashes, packaged
imports/exports, signing certificate, installed APK, Mac code sections and strict
seal verify. Identities/history/ratchets are retained; /Applications is unchanged.

Physical mixed2282 still fails. The warmup rings at 3.861 s, both active at
4.738 s; the main reverse call rings at 19.806 s and becomes active at 20.200 s.
During its 85 active seconds native interruptions reach 2/405 ms on Mac and
6/2285 ms on Poco, with one engine epoch per endpoint. Camera is enabled, but
encoded video remains zero under the unchanged audio reservation, so actual
encoded-video/audio coexistence remains unverified.

A 512-KiB file is offered during the call. Forty-two owned partial-file size
probes report no positive size; the download times out after 45 seconds and
reports destination size zero. The Mac log still records six direct-stream
policy refusals and no serve request or completion. Thus resolving an ALREADY
PROVEN owner is tested, but the physical pair still has a policy/ownership
problem that must be distinguished from bandwidth admission. The fix is not
claimed to resolve this complete physical transfer.

Across the mixed capture, terminal authentication samples on Mac include
92 legacy ML-KEM/Claimed and 3 ratchet/Signed; Poco records 34 ratchet/Signed.
These aggregate terminal counts do not identify individual call offers or file
requests. They do establish that legacy unauthenticated delivery recurs, unlike
the all-Signed trace2280 capture. Next work must trace the authenticated identity/
device relation and the sender's legacy sealing choice; permission must not be
inferred from a claimed name or bypassed to make the test pass.

The owned download is cancelled, temporary sink removed, camera disabled and
calls hung up. All owned apps/helpers, phone UID/package processes and ADB
forwarding are verified gone, and runtime-added Mac logs archived outside the
bundle with its strict seal verified again. Private evidence: file2282-regression
before/after, file2282-stream-policy-tests, build-screen/native-policy/installed2282,
mixed2282 result/playout/runtime logs, voice-file2282 events and neteqmixed2282
cleanup. The full audio-priority goal remains active.


### Cycle 2283 — direct stream principal and physical reply route

`APP_OPEN` now carries the session-proved sovereign identity as local endpoint
metadata, separately from its physical opener. The IPC notification uses that
identity for application access checks; acceptor data/close replies still use the
physical opener route. Legacy peers and same-node opens keep their original
address; an unauthenticated hint cannot rename an initiator. No network or IPC
payload size, FFI contract, crypto state, or relay role/priority changes.

The actual dispatcher regression covers proved and legacy sessions. A Unix IPC
regression checks both application-visible authorization identity and bytes
returned to the physical device, plus a Claimed hint's fallback. All affected
app/dispatcher/IPC suites pass: 452 tests, 7 existing ignored tests. Veil
48038b54 and xVeil 003a173a are unsigned local commits.

Fresh SDK/host 0.13.84+2283 is installed on Poco in place with the existing
production signer. Packaged libraries, installed APK bytes, Mac native code
sections, version and strict bundle seal verify. C++ media remains exactly
2279; identities/history/ratchets and /Applications are retained. Poco Wi-Fi
is off, mobile data on.

The mixed2283 warmup rings at 3.682 s, both active at 5.000 s. The reverse main
call rings at 0.413 s, both active at 0.812 s, stays P2P throughout 85 active
seconds, and retains one engine epoch per endpoint. The 512-KiB file now
completes: first observed partial bytes at active 30.205 s, successful download
at 32.289 s (about 7 s after beginning), SHA-256 matches. Owned partial-file
probes distinguish an existing empty file from no partial file. This fixes the
physical transfer failure; it does not establish uninterrupted mixed media.

Native interruptions still reach Mac 4/1996 ms and Poco 8/3503 ms, including
interruptions before file transfer. Encoded video remains zero under the
unchanged audio reservation despite active camera capture. Sampled encrypted
cell delivery after local admission reaches 319.4 ms Mac→Poco and 787.6 ms
Poco→Mac, with a 19.5-ms initial clock-probe bound (no claim of acoustic delay).
Sampled prepared-packet-to-UDP maxima are 1356/3246 us, with zero 100-ms UDP
send stalls; primary datagram expiry counters reach 27/0. Those are cumulative
connection metrics, not packet-matched attribution. The queue-to-peer gap still
includes congestion waiting before packet preparation and kernel/carrier time.
A next packet-matched UDP handoff/receive observation is required to distinguish
these stages, without transmitting diagnostics or roles on the network.

Note: `audio_tx_rtp_queue_age_ms` is time since the LAST successful local
admission (`AudioSendStats::last_queued_ns_`), not residence time in a pending
queue. A ~400-ms value can be DTX cadence and must not be called queue backlog.

All owned apps/helpers and phone UID/package processes have exited; ADB forward
removed, camera off, call ended, owned download cancelled/sink removed, Mac
runtime logs archived outside the bundle and strict seal verified. Private
mixed2283 result/playout/stage-audit, file events, build/native/installed metadata,
stream2283 suite output and neteqmixed2283 cleanup retain the evidence. The
full audio-priority goal remains active.


### Cycles 2284–2285 — packet-matched UDP delay

A new default-off endpoint diagnostic samples encrypted UDP datagram hashes
(one in sixteen, selected by the hash), immediately after successful socket
handoff and before the peer's endpoint packet handler. GSO/GRO fragments are
hashed as their actual separate UDP datagrams. Logs contain only local time,
short correlation hash and size, without addresses, connection IDs, content,
source roles or wire changes. Hashes are diagnostic correlation, never an
authentication primitive. Runtime `/rt_trace` enables/disables the same local
gate through veil-session and veil-transport; relay priority is unchanged.

The segmentation regression passes. All 422 session tests pass (6 existing
ignored, plus one ignored doctest); an old primary-recovery fixture needed four
zero-initialized UDP-wait fields already introduced in 2281. The 2284 capture
had no UDP observations: the embedded runtime consumes `log`, while the first
diagnostic used `tracing` without a usable bridge on its task. Thus it supplies
no packet-matched UDP attribution. Its 60-second audio run still records
Mac 7/2186 ms and Poco 10/6275 ms of native interruptions, with cleanup verified.

2285 fixes emission through the existing embedded `log` bridge. A new regression
installs a log consumer, verifies selected GSO send/receive hashes actually
reach it, and verifies a disabled gate emits nothing. Both module tests and an
integrated veil-session cargo check pass. SDK/host 0.13.84+2285 is freshly built
and installed on Poco with the production signer, complete packaged/installed
bytes, SDK ABI/imports, unchanged media 2279 and strict Mac seal verified.
Unsigned local source commits: Veil c16cc15a/f7a00014, root adee5dc5/33cbd644.

The 2285 cold warmup rings at 17.655 s and becomes active at 18.976 s: cold call
setup remains a defect to trace separately. The following Poco→Mac call rings
at 0.901 s, becomes active at 1.280 s and stays P2P throughout 60 active seconds.
No file or camera runs. Native interruption counters reach Mac 2/783 ms and
Poco 3/956 ms, with one epoch per endpoint. Native receive-buffer estimates
reach 452/514 ms delay and 328/547 ms jitter buffer. These are not acoustic delay
measurements and this is not a quality pass.

Clock probes before/after the run give a conservative 19.5-ms correlation bound
and only -0.2 ms offset change. Matching exact encrypted UDP samples yields:
Mac→Poco 292 packets, median 6.7 ms, maximum 769.7 ms (14 over 200 ms, 2 over
500 ms); Poco→Mac 198, median 48.3 ms, maximum 382.3 ms (11 over 200 ms).
The 769.7-ms packet is handed off at active 35.9 s and read at 36.7 s; the
712.7-ms packet at 39.4/40.1 s. Poco's native interruption counter advances
at 36.709 s (+443 ms) and 40.478 s (+320 ms); Mac also advances at 36.709 s.
This temporal agreement supports a delivery-stall explanation, but the sampled
UDP packets include generic P2P payload/control/ACK traffic and are not each
identified as audio. Unmatched endpoint samples can be third-party/relay traffic
and must not be reported as observed P2P loss.

The delay of those matching packets is AFTER successful local socket handoff.
Thus pre-packet QUIC congestion/IPC/encoder admission cannot explain that part
of their delay. It still includes kernel send buffering, the mobile path,
kernel receive buffering and endpoint polling/scheduling. The next useful
boundary is kernel receive timestamps vs endpoint read time (or a controlled
route comparison); it is premature to blame only the carrier or to tune NetEq
blindly. This is progress in attribution, not a fix for the remaining pauses.

All owned applications/helpers and phone UID/package processes are verified
exited, forwarding removed and Mac runtime logs archived with its strict seal
verified. Poco remains Wi-Fi off/mobile data on. Identities/history/ratchets,
/Applications and network/relay role policy are retained. Private udp2284/2285
result/playout, udp2285 audit/interruption edges, before/after clocks,
neteqmixed2284/2285 cleanup and build/native/installed metadata retain evidence.
The full audio-priority goal remains active.


### Cycle 2286 — kernel receipt boundary and neutral relay comparison

Veil 32a8d34d/root d808e258 vendor the unchanged-version quinn-udp 0.5.14
baseline (archive checksum and upstream licenses retained) for a narrow,
default-off Linux/Android kernel receive timestamp extension. The Windows
transitive baseline stays pinned to windows-sys 0.60.2; the parent lockfile only
removes the UDP registry source/checksum. The Tokio socket opts in while local
`/rt_trace` is enabled. NEW nanosecond timestamps are preferred, with OLD fallback;
unsupported kernels continue with None. Disabled/default paths do not enable
timestamps. The ancillary buffer grows to include time beside existing packet
info, ECN and GRO. Metadata is local Rust state, never a packet/IPC/FFI field.

GRO has one shared receive timestamp, so those buffers are explicitly marked and
excluded from per-datagram attribution. Invalid/overflow times remain None.
The log sampler carries the kernel timestamp and sharing flag, without addresses,
content, connection IDs or roles. No relay scheduling/priority change is made.
Kernel timestamp semantics are documented in
https://docs.kernel.org/networking/timestamping.html; the boundary is software
kernel receipt, not an over-the-air hardware receive timestamp.

A committed loopback probe runs on actual Poco using the parent libc/socket2/
cfg_aliases baseline. Default-off yields None, then two packets deliberately
held before application read retain distinct kernel stamps near their send
syscalls: kernel-to-read 172 and 141 ms. Contents, ECN and destination survive;
disabling restores None. Probe exits and its owned remote executable is removed.
The log consumer/GRO/default-off regressions pass, locked veil-session cargo
check passes, and upstream UDP Mac tests pass (7, one existing ignored).

Fresh SDK/host 0.13.84+2286 is built and installed with the production signer;
source hashes, packaged/installed APK bytes, SDK ABI/imports, unchanged media
2279 and strict Mac seal verify. Identities/history/ratchets and /Applications
are retained.

The main udp2286 call rings at 0.404 s, both active at 0.932 s. It initially uses
P2P, then BOTH endpoints switch to relay at active 52.693 s without an engine
rebuild (140 P2P/21 relay samples). This is not 60 seconds of pure P2P. Native
interruptions reach Mac 5/2942 ms, Poco 14/11773 ms, with video/file absent.

Before/after clocks give a conservative 22.2-ms bound and -3.6-ms offset change.
Matching exact UDP bytes gives Mac→Poco 213 datagrams: median 5.86 ms, max
2739.86 ms. 190 have precise kernel stamps; 23 GRO-shared stamps are excluded.
Kernel-to-endpoint-read median is 0.083 ms and max 2.086 ms (read logging is
quantized to milliseconds). Maximum handoff-to-kernel is 2739.42 ms. Example:
a packet handed off at active 48.925 s reaches kernel at 51.665 s and is read
0.439 ms later. Others show 1046.77/935.06/879.61 ms before kernel and at most
1.79 ms afterward. Poco→Mac matches 156 packets, median 51.14 ms, max 1451.14 ms;
Mac kernel timestamps are unsupported by this Linux/Android patch. These are
sampled generic P2P packet observations, not an identification of every packet
as audio, and not an acoustic measurement. Packet-matched evidence locates
those long delays before Poco's software kernel-receive boundary, rather than
in its endpoint read task. Sender kernel/NIC, route, modem and ingress driver
remain included; blaming only the carrier would overstate the evidence.

A second 60-second run uses the same 2286 binaries with global P2P temporarily
`denied` through the product controller on both endpoints. The existing persisted
`contacts` values are saved before mutation and restored successfully afterward.
All 161 active samples per endpoint show relay, and encrypted cell traces show
only relay sends (Mac 63/Poco 24 sampled sends), not a merely changed UI label.
No network/mailbox policy or relay priority is introduced. Warmup rings at 3.458 s,
both active at 4.043 s; main at 1.294/1.689 s. Native interruptions remain
Mac 5/2764 ms, Poco 16/10500 ms. Sampled Mac→Poco relay cell delivery peaks at
1309.4 ms. Across that capture 134 ungrouped Poco kernel stamps show read median
0.112 ms/max 3.172 ms; 27 shared GRO buffers are excluded. Switching to this
ordinary relay route is not a quality fix.

Both runs close owned apps/helpers, verify phone UID/package processes exited,
remove forwarding and archive Mac runtime logs before verifying its strict seal.
P2P restoration is confirmed on BOTH endpoints. Private kernel2286 probe/check/
upstream logs, build/native/installed metadata, udp2286 audit/playout/route changes,
relay2286 stage audit/playout and neteqmixed/relay2286 cleanup retain evidence.
The full goal stays active: actual encoded video/screen coexistence with acceptable
audio is still unproved. Next inspect recovery after delivery stalls and delayed
packet bursts with a controlled PCM fixture before changing receive buffering
or audio path duplication; do not repeat failed NetEq cap/flush tuning blindly.

### Cycle 2287 — PCM outage recovery and awake Poco comparison

Veil b6b7edea adds two production-Opus/NetEq PCM scenarios to the existing
audio playout fixture and runner. No production codec, buffer, SDK, wire or
relay scheduling setting changes. The fixture holds packets before reception
for 1 second and then 2.7 seconds; one case releases old packets in send order
alongside new audio, the other drops the same outage's packets. Decoded tone
markers, rather than a jitter gauge alone, must recover below 300 ms at the
first post-outage marker and below 180 ms at all subsequent markers. Final
PCM must remain nonsilent for over 290/300 ticks. Timer lateness must stay below
30 ms, callbacks must be gone after destruction, and assertions ensure that
both the large burst and the loss control actually occur.

Both new scenarios pass against the unchanged 2279 test-hook media library,
matching the installed production engine source. The delayed case delivers
a 135-packet batch; six post-outage markers are 180.15, 100.21, 101.83, 97.25,
100.43 and 98.84 ms. The loss case drops 185 packets; markers are 91.00, 89.68,
86.89, 87.36, 88.76 and 89.92 ms. Both render all final 300 PCM ticks. This
controlled recovered path does not reproduce an additional multi-second
decoder recovery delay. It does not prove behavior under continuing mobile
jitter, or physical acoustic latency. Private audio-stall2287 evidence retains
source/library hashes and final gate logs. The runner's shell syntax also passes.

Physical power2287 reuses the existing installed/bundled 0.13.84+2286 binaries
and 2279 media, with Poco still on cellular and P2P policy contacts. Warmup rings
at 1.960 s/both active at 3.270 s. The main Poco-to-Mac call rings at 0.438 s and
both become active at 0.850 s, then runs 60 seconds. Both endpoints retain one
engine epoch. Of 159 active samples each, 147 show P2P and 12 relay; fallback
appears at test t=56.627 s. This is not a pure P2P run.

Fifteen power observations keep Awake, screen on, charging/stay-on and device
idle/light idle/low-power standby false. Fourteen observations after call startup
show the microphone service and two foreground services. An independent deviceidle
query during the call confirms ACTIVE/ACTIVE and force-idle false. The generic
monitor's `mState` matches a power/display field, so it must not be used as
deviceidle evidence. The retained explicit deviceidle query is authoritative.
Sleep/Doze is not supported as an explanation for this observed run.

Native interruptions remain Mac 5/9169 ms and Poco 7/5112 ms. Receive-age maxima
are 7160/8012 ms. Near the end both audio receive counters stop advancing;
the established-audio fallback keeps each engine but audio does not immediately
resume. Mac receives again around t=60.410 s; Poco does not show equivalent
recovery before the test ends. The missing future received packets must not be
reported as measured loss without a complete delivery window.

Packet-matched UDP timing, with a conservative 20.3-ms clock bound, shows
Mac-to-Poco 257 matches, median 7.37 ms/max 1312.37 ms. Precise kernel stamps
show maximum handoff-to-kernel 1196.73 ms and kernel-to-read 2.27 ms; shared
GRO stamps remain excluded. Poco-to-Mac 195 matches have median 46.64 ms and
max 1538.63 ms; Mac kernel receipt is not instrumented. These generic UDP
samples cannot account for the whole final audio gap on their own. Separately,
matched sealed primary cells show direct queue-to-authenticated-receive maxima
1201.4 ms Mac-to-Poco and 916.6 ms reverse. Local admission stages peak at
1–3 ms. Four sampled Mac relay sends near fallback have no matching receive
within the capture; the one reverse relay sample arrives after 712.6 ms.
This is a concrete next boundary to inspect: first sealed-cell delivery on the
replacement route, retaining the existing inbound overlap. Faster native buffer
flushing is not supported by the controlled PCM result.

Both owned stand applications, phone UID/package processes and PCM helpers are
verified exited; forwarding is removed and the Mac strict seal verifies. No
identities/history, /Applications, network policy or production libraries are
changed. Root retains the new test revision, not an invented 2287 app release.
Private power2287 call/playout, clocks, kernel audit, sealed-cell stage audit,
power/deviceidle observations and neteqpower2287 cleanup retain evidence.
The audio-priority goal remains active; these results are diagnostics and
regression coverage, not a fix for the remaining physical call pauses.

### Cycle 2288 — controlled route handover without a broken direct path

Root fadf92d8 adds authenticated, opt-in `/call_relay_recovery` to the existing
stand hook. It invokes the ordinary serialized direct-to-relay recovery and
authenticated peer announcement, rather than changing P2P policy or tearing
down the direct connection. Disposed, inactive, ringing, connecting and
non-direct postures cannot use it. CallService's 144 tests pass, including
anonymous/unknown posture protection and an active direct recovery announcement.
Host-only 0.13.84+2288 is installed on Poco and built for the Mac stand; packaged
SDK bytes remain exactly 2286 and production media exactly 2279. The APK signer,
installed whole-APK hash, native imports/exports, Mac code sections and strict
bundle seal verify. This is a diagnostic build, not a release tag.

Two 40-second voice calls retain flowing P2P receipt on both endpoints before
forcing recovery 10 seconds into the active call. Mac-initiated recovery rings
at 0.206 s/both active 1.142 s; both show relay within 0.360 s of the request.
Poco-initiated recovery rings at 0.401 s/both active 0.900 s; Poco shows relay
after 0.361 s and Mac after 0.736 s. Each keeps one engine epoch and neither
adds a native interruption after the request. Maximum post-request audio receive
ages are 520/377 ms in the first run and 745/463 ms in the second; some intentional
Opus DTX intervals are included. This does not reproduce the preceding
multi-second total gap and does not prove a failed network recovers equally fast.

A separate 75-second early2288 run enables Poco's camera about 5 seconds after
both endpoints become active and sends a 512-KiB file at about 20 seconds.
The main call rings at 0.590 s/both active 0.970 s. The file is received after
about 16 seconds with a matching SHA-256. Camera capture runs, but adaptive
audio reservation leaves encoded/received video at zero throughout. Native
interruptions remain Mac 5/5278 ms and Poco 16/13736 ms; 131 active samples
are P2P and 68 relay. Thus earlier camera activation did not demonstrate
acceptable actual encoded mixed traffic and is not a completion gate.

Owned applications, phase helpers and phone UID/package processes exit after
both stands; forwarding is removed, runtime logs archived and Mac strict seal
verified. Policies, cellular connectivity, identities/history and /Applications
are retained. Private forced2288 call/handover audit, early2288 samples/playout,
camera/file events and both cleanup reports retain evidence.

### Cycle 2289 — relay discovery must not reuse a direct-only cache hit

Inspection finds a concrete fallback bug: `warm_media_route` stops on any
cached route, including the destination's own direct session. Its background
discovery helper also immediately returns that direct cache hit and can query
the final direct peer again. The forced-relay sender correctly excludes that
peer, so discovering a usable relay can be suppressed precisely while the
direct cache entry survives. This source defect is distinct from a claim that
it explains every observed network interruption.

Veil 9fe4aa50 makes relay-only discovery select a non-destination, live cached
first hop and otherwise query ordinary mesh peers excluding the direct endpoint.
It preserves the direct cache entry and the existing ordinary discovery path.
Negative results are separated by discovery kind so an ordinary/direct miss
cannot suppress the independent fallback walk. Discovery remains bounded,
deduplicated and asynchronous; media never waits for its 500-ms deadline.
No traffic marker, encryption, mailbox path or relay scheduling change is made.

The new test drives the actual background warmup with direct and dead cached
routes. Ordinary lookup still uses the direct route; relay warmup sends exactly
two ordinary RecursiveQuery frames to mesh peers, suppresses duplicate in-flight
queries, accepts a newly learned live relay and retains the direct route.
The negative-cache test also checks discovery-kind isolation. Locked veil-ipc
tests pass: 139, with five pre-existing ignored and one pre-existing ignored
doctest.

Both embedded SDK targets are rebuilt from 9fe4aa50 and packaged in host build
0.13.84+2289. The complete production-signed APK installed on Poco matches its
local hash; SDK native bytes change while production media remains byte-for-byte
2279. Mac SDK code sections and strict bundle seal verify. No release is tagged.

A 75-second route2289 voice call rings at 2.524 s/both active at 3.261 s. It
starts through relay (8 Mac/7 Poco active samples), then upgrades to P2P for
192 samples each. There is no subsequent direct-to-relay fallback in this run.
Each endpoint keeps one engine epoch. Native interruptions remain Mac 8/4044 ms
and Poco 18/12801 ms; maximum audio receive ages are 2085/1778 ms. Packet-matched
Mac-to-Poco UDP has 363 matches, median 5.32 ms/max 1139.32 ms with a 24.6-ms
clock bound; precise kernel stamps show handoff-to-kernel max 920.84 ms and
kernel-to-read max 2.98 ms. Reverse UDP has 266 matches, median 50.18 ms/max
1194.68 ms. These are generic UDP samples, not a complete audio-loss measurement.
The three sampled sealed relay cells at the initial phase all arrive, after
31.8/48.8 ms forward and 77.2 ms reverse. This is not a failed-path recovery test.

A separate 30-second forced2289 Mac-to-Poco voice call verifies the new SDK's
explicit handover with healthy audio on both direct endpoints. It rings at
0.210 s/both active at 0.669 s; recovery is requested at t=11.016 s. Both show
relay 0.356 s later, retain one engine epoch and add no native interruptions
after that request. Maximum post-request audio receive ages are 516/198 ms.
Each endpoint already recorded one short interruption before handover; these
must not be attributed to the switch. Healthy-path handover does not prove that
an unavailable replacement route recovers equally quickly.

Both stands verify owned applications and phone UID/package processes exited,
forwarding removed and Mac strict seal valid. Cellular connectivity, identities,
history, P2P policy and /Applications are retained. Private route2289 UDP/stage/
playout audits, forced2289 handover audit and both cleanup reports retain the
evidence. Physical audio pauses and actual encoded mixed-video coverage remain
unresolved; this routing fix does not complete the audio-priority goal.

### Cycle 2290 — prolonged established relay delivery, still using build 2289

Poco is available over ADB, remains on cellular with Wi-Fi off, and initiates
a 120-second audio-only call against the Mac stand. Installed SDK/host remain
2289 and production media 2279; 2290 identifies this observation, not a new app
version. The call rings at 1.254 s/both active at 1.621 s. Healthy direct receipt
is verified before requesting the ordinary relay recovery at t=11.743 s;
both show relay 0.358 s later and retain one engine epoch throughout.

Each endpoint has 28 direct and 290 relay active samples. Subsequent established
relay audio still pauses: after the recovery request Mac adds 5 interruptions/
7565 ms and Poco 10/11240 ms. The first newly completed interruptions are
observed at t=39.499/35.360 s, well after handover. Audio receive ages peak at
3046/2765 ms. Neither video nor file transfer runs, and native receive-queue
drops remain zero. These are receive-stream metrics, not acoustic measurements.

All sparse sealed-cell samples match authenticated receipt: forward 117 relay
samples have queue-to-receive median 29.6 ms/max 2470.6 ms; reverse 60 have
median 82.4 ms/max 1703.4 ms. Each sampled local socket/daemon/handler/queue
stage peaks at 1 ms on relay sends. Several delayed cells are accepted at two
first hops, so origin fan-out does not eliminate this captured delay. First-hop
readiness reports neutral-Forward datagram transport false for all captured
source relay admissions; reliable compatibility fallback remains in use.
Generic connection admission samples cannot prove the timing of a particular
forwarded cell, and endpoint evidence does not separate intermediate relay
queues from final-hop network or receiver dispatch delays.

Cleanup verifies both owned applications, phone UID/package processes and
helpers exited; forwarding removed and the Mac strict seal valid. No identities,
history, network policy, /Applications or native binaries change in this cycle.
Private forced2290 call/playout/handover/stage audits and cleanup retain evidence.
The remaining boundary is delivery between first-hop admission and authenticated
endpoint receipt; do not attribute these multi-second gaps to the instantaneous
healthy handover or declare the full audio-priority goal complete.

### Cycle 2291 — distinguish local receipt queues after relay admission

New opt-in endpoint diagnostics retain process-local monotonic stamps before
daemon delivery encoding and after SDK delivery decoding. The authenticated
media receive sample consumes their ages only after the channel cipher opens
the cell. IncomingMessage, IPC frames, network formats, scheduling and relay
policy are unchanged. Missing boundaries report unknown (-1), including the
daemon stamp when SDK and daemon are separate processes.

The silent staging table hashes the complete ciphertext rather than trusting
an unverified epoch/sequence. It samples one in fifty existing sealed cells,
keeps first receipt across duplicates, is capped at 256 entries, expires after
30 seconds and clears when tracing is disabled. Unauthenticated observations
never emit a cell log. Tests verify duplicate timing, absent boundaries,
expiry, capacity and same-header/different-ciphertext isolation. Locked library
tests pass: IPC 141 (five pre-existing ignored), client SDK 40. Production media
is unchanged; rebuilt SDK packaging and physical measurements follow.

Both SDK targets are rebuilt from Veil 621cfbc9 and packaged in 0.13.84+2291.
Production signer, complete installed Poco APK hash, native dependencies and
exports, fresh SDK bytes and Mac code sections/strict seal verify. Production
media remains byte-for-byte 2279; no release is tagged or /Applications replaced.

A 120-second forced2291 Poco-to-Mac audio-only call rings at 0.992 s/both active
at 1.367 s. Healthy direct receipt is verified before recovery at t=11.520 s;
both show relay 0.353 s later and retain one engine epoch. Neither adds a native
interruption after recovery; one startup interruption each precedes it. Of 316
active samples each, 28 show direct and 288 relay. Sampled relay delivery peaks
at 268/384 ms, with all 118/67 source samples matched to authenticated receipt.
This run does not reproduce the preceding multi-second outage.

The new receiver boundaries are populated on actual delivered cells: daemon
encoding-to-authentication max 648 us Mac/4607 us Poco (67/118 relay samples),
SDK decoding-to-authentication max 462/816 us (74/129 direct+relay samples).
Direct ingress lacks the daemon stage and reports unknown rather than zero.
These measured local stages are fast in this run; they cannot exclude a stall
that did not occur. Maximum native audio delay is 339/338 ms, and no encoded
video or file transfer runs in this baseline.

### Cycle 2292 — relay voice with a concurrent 2-MiB file does not pass

This observation still uses installed SDK/host 2291 and production media 2279.
Poco stays cellular. A planned 150-second Poco-to-Mac voice call first verifies
healthy direct receipt, switches to relay at t=28.437 s, then begins a Mac-to-Poco
2-MiB file transfer about 20 seconds after becoming active. Cold setup is also
poor: warmup reaches both-active after 11.300 s; main rings after 17.861 s/both
active 18.243 s. No video is enabled.

Audio already has interruptions before the file offer, so coincidence does not
prove that file traffic caused the failure. Both audio receive counters stop
advancing around main t=43--44 s. At the last active sample (t=67.638 s) native
audio receipt ages reach 24865/23785 ms. The call is gone on both endpoints by
t=76.167 s; the harness records endpoint_lost and ends early, not a successful
150-second call. Keepalive timeout-close events begin around t=48.879--49.677 s,
after audio stops. The file reaches only 524288 of 2097152 bytes before the
owned download is cancelled during cleanup; it has no successful checksum gate.

Source relay cells still enter their local send stages quickly (each sampled
stage max 1 ms, except Mac handler entry 4 ms). Matched relay cells before the
freeze show first-hop-queue-to-authenticated-receipt max 1178/1119 ms. For those
received cells the new local decoder/authentication boundaries remain below
1 ms: daemon stage max 304/791 us, SDK stage 193/877 us. The timing evidence
places those observed delayed arrivals before local delivery encoding, rather
than in the measured receiver IPC/SDK stages. It does not locate packets that
never arrive: 25/14 relay source samples have no matched authentication before
capture ends, and must not be claimed as proved permanent loss. Each audio
engine keeps one epoch and reports zero native receive-queue drops.

Both stands verify owned apps/helpers and phone UID/package processes exited,
forwarding removed and Mac strict seal valid. Only task-owned failed-download
cache fragments are removed and their absence verified; identities/history,
P2P policy, cellular connectivity and /Applications remain intact. Private
forced2291/2292 call, stage, receive-boundary, handover, file and cleanup evidence
is retained. The goal remains active: the mixed file case fails, actual encoded
video/screen coexistence remains unproved, and neither the successful baseline
nor the new diagnostics establish a fix for this connection-wide outage.

### Cycle 2293 — independent cellular delay correlates with relay audio gaps

This 150-second Poco-to-Mac relay call uses the unchanged installed 2291 SDK/host
and production media 2279. Poco remains cellular with Wi-Fi off. Independent
public-target ICMP probes run simultaneously on both endpoints, with phone
clock calibration before and after the call (conservative bound 23.469 ms).
No SIM or network settings change. Main ring/both-active times are 1.091/1.488 s;
healthy direct recovery is requested at 11.711 s and both show relay 0.353 s
later. Each media engine retains one epoch. The call completes its full duration.

The concurrent Mac-to-Poco 2-MiB file finishes about 16 seconds after offer,
with matching checksum, and its owned transfer is cancelled during cleanup.
This disproves a deterministic 512-KiB transfer ceiling suggested by the prior
incomplete run; it does not establish reliable coexistence under every outage.
Audio still fails the quality criterion: native interruptions are Mac 14/9046 ms
and Poco 34/24407 ms, with maximum receive ages 2427/2106 ms. Receive-queue drops
remain zero; no actual video frames are encoded. All sparse relay-cell source
samples match authenticated receipt (148 forward/69 reverse), with delivery
peaks 1900.6/1941.4 ms. Measured local receive stages stay short: daemon encoding
to authentication max 870/3161 us, SDK decoding to authentication 786/2029 us.
These boundaries do not measure queues earlier than daemon encoding.

The independent Poco probe has 598 replies, median 38.5 ms and maximum 1354 ms;
Mac has 592 replies, median 8.834 ms and maximum 16.022 ms. Poco reply gaps of
roughly 1.17--1.58 seconds recur about every four seconds, including before file
offer and after file completion. A 2.601-second gap at elapsed 84.907--87.508 s
aligns with growing audio receive ages on both endpoints, reaching 2427/2106 ms.
Delayed ping replies also arrive in clusters at earlier audio gaps. This points
to a phone network-path contribution outside the measured IPC/SDK boundaries.
The public ICMP target uses a different path from media: correlation does not
identify the modem, operating system, carrier or relay as the sole cause, nor
explain all latency. Earlier app-closed ping controls also showed long delays.

Read-only current radio inspection finds two loaded, enabled SIMs. The first
slot has emergency-only service and no data connection; the second has an
active LTE data connection. Allowed radio technologies do not include NR.
Historical radio records and preferred-network-mode integers must not be read
as current 5G state. Shared-radio scanning is a hypothesis requiring a separate
controlled comparison; disabling a real SIM needs user authorization and has
not been performed.

Cleanup verifies owned apps, phone UID/package processes, probe processes and
forwarding absent. A transient probe-exit observation is resolved with a second
authoritative process check and cleanup retry; task-owned Mac runtime logs are
archived and the strict bundle seal verified. Private call, file, receive-stage,
independent-network and radio evidence remains outside the repository. No code,
installed binary, identity, history, P2P policy or /Applications changes. Physical
pauses, cold setup delays and encoded video/screen coexistence remain unresolved.

### Control 2294 — repeat app-closed probe with read-only radio observations

After Poco reconnects, a 90-second app-closed control runs independent ICMP on
both endpoints and captures private modem logs. Forty-five read-only service
snapshots show no registration transition: first slot remains out of service
with data disconnected; second slot remains in service with data connected.
Poco has 361 replies, median 33.2 ms/max 311 ms; Mac 352 replies, median
8.677 ms/max 27.834 ms. Neither has an observed reply gap over one second.
This control does not reproduce the periodic gaps in the preceding live call.
Together with older app-closed failures, it establishes variability rather than
a deterministic app-only or modem-only diagnosis. No SIM/network settings are
changed. Owned ping/log readers exit; remote probe and phone package absence
are verified. No application is launched by this control.

### Cycle 2295 — app-on voice comparison with independent modem logging

Using the same unchanged 2291/2279 binaries, a 90-second Poco-to-Mac voice call
captures independent ICMP and read-only radio logs, without a file or video.
Warmup still has slow setup (ring 19.902 s/both-active 21.202 s). Main setup is
fast (0.394/0.782 s). Healthy P2P recovery is requested at 11.106 s; each engine
retains one epoch and the call completes the requested active duration. No SIM,
P2P policy or connectivity setting changes.

The quality failure repeats without concurrent file traffic: Mac records
6 interruptions/5219 ms and Poco 19/17342 ms; maximum audio receive ages are
2118/2077 ms. All 84 forward/25 reverse sampled relay cells match authenticated
receipt; first-hop-queue-to-receipt maxima are 1653.6/1300.4 ms. Local receiver
boundaries remain short: daemon-to-authentication 430/4027 us and SDK-to-
authentication 268/1494 us. Native receive-queue drops remain zero, although
Poco records 720 discarded audio packets in playout. These are different
counters and must not be described as zero audio loss or acceptable quality.

Across warmup, main call and post-call observation, Poco ICMP has 569 replies,
median 36.3 ms/max 1514 ms and 19 observed reply gaps over one second; Mac has
583 replies, median 8.775 ms/max 12.85 ms and none. Phone reply timestamps, rather
than USB-reader timestamps, define these gaps; clock calibration bounds timing
by 23.051 ms. The largest 4.505-second gap in this whole capture must not be
reported as an active-call audio gap. Radio registration queries/responses all
occur before the main call; no recurring registration transition is captured
during its audio gaps. Activity-info requests are present, but their presence
alone is not evidence that they cause a radio pause. A spot check finds the
screen awake, thermal status zero and app CPU 37 percent (top), not proof that
every scheduler stall is excluded.

The app-closed control immediately preceding this call was healthy. Older
app-closed controls were not, so this sequence does not prove app causation or
exclude network variability. Both controlled comparisons narrow the next
investigation to endpoint traffic/load and the cellular path; the shared-SIM
hypothesis remains unverified, and no SIM is disabled. Cleanup retry resolves
another transient probe-exit observation; all owned apps/helpers and remote
probe exit, forwarding is removed, and archived Mac logs leave a valid strict
bundle seal. Numeric audits and sensitive raw modem logs remain private. These
observations do not resolve the audio-priority goal.

### Controls 2296/2297 — idle app traffic and UID attribution

Both controls use unchanged installed host/SDK 2291 and media 2279. The Poco
stays on cellular; no SIM/network settings change. The two stand applications
are unlocked and complete the ordinary endpoint exchange, then remain open
without a call for 60 seconds. Each control has 29 successful paired API gates
confirming call absence. No camera, screen, audio engine or file fixture is
started. Independent ICMP and private modem logging run throughout observation.

Idle2296 reproduces long independent delay: Poco has 196 replies, median
40.9 ms/max 15408 ms; Mac has 241, median 8.587 ms/max 12.532 ms. Device-wide
cellular-interface counters show median receive/send rates 22.843/37.799 kbit/s
and one-second peaks 788.935/1009.981 kbit/s, including startup. Those counters
alone cannot attribute traffic to a process or prove link saturation.

Idle2297 forces Android network-counter polling before startup and after the
idle window, with acknowledgement at each boundary. Standard UID histories
are summed only for MOBILE (numeric type 0 on this phone), excluding the
duplicate tagged-history section and Wi-Fi. The same 63 app mobile buckets
exist at both boundaries. Across 87.730 seconds including startup, xVeil
receives/sends 835161/1550945 bytes; all mobile UIDs total 861982/1579548 bytes.
Thus almost all accounted traffic belongs to xVeil, but this does not show
which protocol produces it or that its byte rate causes a radio outage.
This repeated idle probe reaches Poco max 1684 ms versus Mac 12.77 ms.
The absence of a call establishes that codec/camera/file traffic is not needed
for these independent delay failures. It does not establish deterministic app
causation: earlier app-closed controls also failed, and network conditions vary.

Both controls reap their owned network readers before lifecycle cleanup,
avoiding the earlier transient defunct-child observations. API tracing is
disabled and profiles locked; owned apps/helpers, complete phone UID/package,
remote probe and ADB forward are verified absent, and the Mac strict seal is
valid. Sensitive radio and network histories remain private. Production code,
installed binaries, identities/history and /Applications remain unchanged.

### Cycle 2298 — oversized local background frames retain spent allowance

Source inspection identifies a separate endpoint admission defect. While local
primary audio is active and pressured, reliable background producers share a
4096-byte/200-ms allowance and own network queries a separate 1024-byte/200-ms
allowance. A whole legacy frame larger than its allowance must be allowed to
progress, but the old implementation replenished all bytes at the next 200-ms
window. Repeated large frames could therefore exceed the intended sustained
budget on different neighbors even while primary pressure persisted.

Oversized frames now spend enough consecutive future windows to cover their
bytes. Refreshing primary activity/pressure does not replenish that debt.
The first indivisible frame still passes whole; this bounds sustained competing
traffic, not the serialization delay of that one frame. When pressure or primary
activity expires, the ordinary unthrottled behavior returns. Reliable FIFO,
admission credits, independent network-query allowance, loss-tolerant source
policy and neutral transit are retained. No relay priority, media-role label,
network format, cryptographic state or audio-quality threshold changes.

The initial regression fails on the old implementation at the first renewed
window. The stronger final case keeps primary/pressure fresh across their
original grace deadlines, verifies no new bytes pass until the oversized
allowance is paid, then verifies prompt normal resumption. A runner may wake
earlier to recheck pressure expiry without forgiving the debt. Existing tests
also verify independent query/file allowances and immediate pressure/idle
release. The locked veil-session library suite passes: 423, zero failed, six
pre-existing ignored, including actual encrypted QUIC scheduling/recovery and
neutral-transit tests. This defect is proved in admission; the idle captures do
not prove that oversized frames caused the physical Poco pauses. SDK rebuild
and physical verification follow separately.

Both SDK targets are rebuilt from Veil 18219f4e and packaged in stand host
0.13.84+2298. The source hash of the debt accounting is retained in the private
manifest; packaged SDK bytes differ from 2291. Original APK signer, complete
installed Poco APK hash, native imports/exports, independently stripped SDK,
fresh Mac SDK code sections and strict bundle seal verify. Production media
remains byte-for-byte 2279; no /Applications replacement, push or release occurs.

Forced2299 repeats 150 seconds of Poco-to-Mac audio with a concurrent 2-MiB
Mac-to-Poco file. Warmup rings/both-active at 0.406/1.011 s, main 0.610/1.017 s.
Healthy P2P recovery is requested at 11.382 s; both show relay 0.352 s later,
retain one engine epoch and complete the requested active duration. File offer
at active+20.242 s finishes at +29.263 s; its checksum matches at +29.483 s and
the owned download is cancelled normally. No video/screen capture is started.

This run still fails physical audio quality. Mac records 8 interruptions/
13641 ms and Poco 17/29644 ms, with maximum receive ages 8651/9617 ms and
native discarded-audio counts 136/450. Receive-queue drops remain zero; they
are not equivalent to discarded audio. Matched relay-cell delivery reaches
9877.8/5122.2 ms forward/reverse, while source local stages peak at 7 ms and
authenticated receiver stages at 3.938 ms. There are 20/2 source relay samples
unmatched before capture ends; these are not proof of permanent loss. All
captured source first hops still lack neutral-Forward datagram readiness and
retain the ordered compatibility carrier. The capture does not prove that
an oversized admission was exercised, so it cannot validate or reject that
specific fix's physical contribution merely by comparing interruption counts.

Independent probes still delay on Poco (706 replies, median 30.7 ms/max
5054 ms), versus Mac (736, median 8.805 ms/max 13.530 ms). As with earlier
controls, this does not localize all delay to the modem or carrier. Apps are
locked and tracing disabled before close; owned apps/helpers and complete
phone UID/package, remote probe and forwarding are verified absent. Reaped
probe readers eliminate the earlier cleanup race; strict Mac seal verifies.
SIMs, connectivity, P2P policy, identities and history are retained. The source
quota defect is fixed, but the physical pauses and encoded mixed-video/screen
quality remain unresolved; the goal stays active.

The next physical comparison (mixed2301, unchanged SDK/media build 2298)
requests 120 seconds of Poco-to-Mac video. Both endpoints become active at
2.387 s. P2P remains selected for about 63 seconds, then the call recovers to
relay without an engine restart and completes its requested duration. Before
recovery, Mac has 2 audio interruptions/1667 ms and Poco 3/2210 ms; the full
run reaches 9/8730 ms and 8/11157 ms respectively. Thus the failure also occurs
on P2P. No independent network probe was captured in this run, so it cannot
localize the delay to a carrier, modem or a particular transport stage.

Poco captures/processes 3566 camera frames, but both endpoints transmit and
decode zero video frames. Native video-send pause remains asserted: the audio
quality guard prevents video transmission. This is not an encoded mixed-media
pass, and video congestion cannot explain these pauses. All owned apps and
helpers, the Poco UID/package and ADB forwarding are verified absent afterward;
the Mac bundle seal verifies. Connectivity, SIMs and application data are kept.

`scripts/relay-media-control.py` adds a reproducible transport control using
three distinct SDK nodes, actual loopback QUIC sessions and sealed media through
a neutral middle node. Run with Python 3.11+ and `--sdk /absolute/path/to/SDK`;
it creates an owner-only fixture under `/private/tmp`, disables public discovery,
retains raw logs/keys privately and prints counters only. `--directory` reuses
only a marked private fixture. Named app binding is required by the native media
source-app check; an ephemeral binding is not an equivalent receiver.

The verified control receives 500/500 unique packets in each direction with
no duplicates, maximum delivery delays 4.8/4.5 ms, 20 source admissions all
using the fixture relay's neutral datagram transport, and 20 independent
datagram admissions. All three SDK nodes stop normally and leave no sockets.
This proves the current neutral datagram path works on loopback; it does not
prove audio playout quality, cellular delivery or priority under congestion.
A mobile comparison through a reachable current relay is still needed; the
physical pauses remain unresolved and the goal remains active.

The transport control now has `--compete-video --rate-kbps 1024`: 12 seconds
of audio-only traffic followed by 24 seconds of synthetic video overload.
Primary and video use separate IPC clients bound to the same named app, as in
the application. Three loopback UDP proxies share blind FIFO budgets; encrypted
datagrams are never parsed or classified, and no relay gets an audio priority.
Packet samples remain private; the printed summary reports counters only.
This fixture exercises transport scheduling without Opus/VP8 decoding or the
application's adaptive media feedback. It cannot prove audible call quality.

With SDK 18219f4e the audio-only baseline receives 600/600 packets both ways;
under overload it receives 1165/1200 and 1166/1200, with 95th-percentile delivery
delays 228.8/222.9 ms. Authenticated primary-path samples show QUIC losses while
RTT is below the 150-ms pressure threshold. `LocalReliableAdmission` previously
ignored new loss/congestion counters. It now treats their increases as local
primary pressure, alongside RTT/expiry/PTO feedback. Stable historical counters
do not renew pressure, and a fresh child's reset counters are retained. Neither
the wire format, relay scheduling nor the RTT/quality thresholds change.

Two regression tests cover low-RTT loss/congestion, counter reset and recovery
from historical loss; the full canonical session suite passes 425 tests with
6 pre-existing ignored. The rebuilt Mac SDK also passes the default real-QUIC
control with 500/500 packets both ways. The constrained comparison still fails
its lossless/sub-200-ms gate; acknowledging loss feedback alone does not finish
audio protection under overload. The failing result is retained, rather than
loosening the gate. All fixture nodes and the blind proxy worker stop, with no
remaining fixture sockets. The next required comparison must include actual
codec/playout and adaptive feedback; physical Poco pauses remain unresolved.


### Real codec relay control and cellular build 2309 (2026-10-08)

`scripts/relay-codec-control.py` extends the neutral loopback relay control to
real duplex Opus/NetEq PCM and VP8. It requires a media library compiled with
`VEIL_MEDIA_TEST_HOOKS=1`, Python `cryptography`, and Dart. The test-only duplex
constructor configures independent transport feedback and the 1000-byte RTP
ceiling before audio freezes engine configuration. No microphone, speaker,
application profile or production test-hook library is installed.

Example, using absolute paths to independently built stand libraries:

```sh
TMPDIR=/private/tmp/ python3 scripts/relay-codec-control.py   --sdk /private/tmp/stand-sdk/libveilclient_ffi.dylib   --media /private/tmp/stand-media/libveil_media.dylib   --rate-kbps 1024 --duration 100
```

Three distinct SDK nodes carry encrypted media through one neutral QUIC relay.
The shared directional UDP FIFO caps all encrypted packets equally; it has no
media classification. The endpoints use separate IPC writers for video and
reuse the real application adapter and receive/peer playout trackers from
`scripts/relay_codec_policy.dart`. Five-second authenticated health samples
travel through SDK relay delivery, never an out-of-band peer-stat shortcut.
A normal encrypted bootstrap delivery primes the fixture certificate caches:
the cached-only control API does not discover fresh recipient keys itself.
Capture/playout ticks run independently of stats and policy polling. Native
control acknowledgements are applied only after a successful native call.
Video starts at the actual adapter target, including fractional cadence.
Starting at the base 900 kbps instead produced an artificial first-frame burst
and is excluded from the application comparison.

The final repository-tool run (`codec2310`) has 15 seconds of measured audio
baseline followed by 80 seconds offering VP8. It delivered 20/17 encoded video
frames in opposite directions and all 80 tone transitions each way, with no
silent PCM ticks or native audio interruptions. Native receive-delay maxima
are 142/156 ms. Crucially, actual PCM frequency-edge latency has p95
131.6/178.3 ms and maxima 190.0/209.9 ms: the strict 200-ms gate FAILS despite
healthy native buffer estimates. No threshold is weakened. This verifies a
sparse codec/control path, not usable video cadence, physical cellular
quality, file contention or completion of audio priority. The shaper dropped
no packets. Its queue maxima are 109.1/91.3 ms. The audio driver interval
stayed below 14.9 ms, authenticated health counts are 21/21 including the
bootstrap, and all native/policy/thread error counters are zero.

Physical Poco remains on cellular with Wi-Fi disabled. Build 0.13.84+2309
contains SDK `ca9e2722`, including fresh QUIC loss/congestion feedback for
local primary pressure. Native packaging, APK signer/dependency checks and
installed APK hash verification passed. Production media remains build 2279;
the test-only duplex constructor is not packaged. `/Applications` is unchanged.

Before updating, build 2298's 90-second audio-only P2P call registered one
255-ms Poco startup interruption and none on Mac. Receive-delay p95 was
332/345 ms (Mac/Poco). With build 2309, the first two setup attempts did not
establish within the harness's 45-second limit; that limit is shorter than the
application's 75-second ring timeout. Logs include initially unauthenticated
claimed offers being refused and a first offer arriving about 59 seconds
late. This remains a signaling/authentication investigation, not proof of an
application timeout or justification to weaken source authentication.

The subsequent 120-second requested-video call rang in 0.422 s and became
active on both endpoints in 1.419 s. It switched from P2P to relay around the
first 30 seconds and remained in the same engine epoch. It registered
5 interruptions / 4.953 s on Mac and 12 / 12.402 s on Poco. Native receive-age
maxima are 2680/2696 ms; receive-delay maxima 1523/476 ms. Both video transmit
and receive counters remain zero, so these pauses are not evidence of encoded
video interference. All 233 sampled Poco relay admissions report no
independent datagram-capable hop; the compatibility ordered route remains a
material unisolated factor. A short concurrent ICMP probe near the call's end
has maxima 12.4/465 ms (Mac/Poco), not a matching route measurement or proof
that the carrier alone caused the media gaps.

Owned application, helper, phone UID/package and ping processes have exited;
ADB forwarding is removed and the Mac bundle seal is verified. The codec
fixture's capture thread and Dart helper exited, all three SDK stop calls
returned zero, and no fixture sockets remain. Goal remains unachieved.


### Primary RTP counters and bounded video recovery probe (2026-10-08)

Native media now reports `audio_tx_rtp_drops`, a counter of completed rejected
primary Opus RTP admissions, including padding/retransmissions on that RTP
source. It excludes video RTP and RTCP, and does not infer failure from
`attempts - queued`, which can include a pending admission. This endpoint-only
JSON field adds no network metadata or relay priority. The portable native
smoke covers pending admission, accepted audio and rejected audio separately.

Simply replacing the adapter's aggregate drop counter with this counter was
rejected after the real codec gate: video grew to 473/273 sent frames, decoded
PCM maxima reached 223.1/383.3 ms and one 150-ms audio interruption occurred.
That experimental policy is removed and was never installed on a phone.

The retained policy continues to use all local packet drops to reduce video
and prevent bitrate growth. Independently, twelve consecutive fresh healthy
audio samples with no new primary RTP failure may release the audio pause
only to the bottom video rung. Receiver age, actual playout, interruption,
RTCP freshness, loss and RTT guards remain required. Missing/invalid native
counters preserve previous conservative behavior, including group engines
which do not provide this per-source field. Unit regressions cover the sparse
probe, missing audio measurements restarting recovery, aggregate drops still
reducing video, independent primary failures, and older-library fallback.
All 69 adapter/playout tests pass; native counter smoke and Dart analysis pass.

The retained 100-second real codec control (`primaryprobe2312`) sent 92/87 VP8
frames, decoded 86/92, delivered all 80 tone transitions per direction, and
had zero native interruptions and zero quiet PCM ticks during the video
phase. Native receive-delay maxima are 197/128 ms, whereas decoded PCM p95 is
171.4/141.9 ms and maxima 211.9/152.3 ms. The strict 200-ms gate still FAILS;
this is not a completed quality fix or proof of a statistical improvement.
Driver/callback/authentication errors are absent. Audio thread and policy
helper exited; all SDK nodes stopped successfully and no fixture sockets
remain. Test libraries stay outside application bundles. Installed Poco and
Mac stand remain build 2309 with production media 2279; the new native counter
and bounded-probe policy are not installed there yet.

A remaining architectural task is to propagate trusted endpoint observations
of the final audio receiver into the node's shared local producer budget.
`LocalReliableAdmission.observe_primary_path` currently publishes pressure
from the first-hop QUIC handle, while native/Dart receiver playout observations
only drive the video adapter. A healthy fast relay admission does not prove a
healthy last mile, and those observations currently cannot restrain the
same endpoint's other reliable producers. Any extension must remain private
to authenticated local IPC, preserve separate queues and source ownership,
expire naturally after the local producer ends, and never classify audio or
prioritise ordinary transit on a relay. Real audio/video plus reliable-file
contention, followed by physical verification, remains required.

Trusted endpoint feedback and bounded DATA during healthy audio (2315–2318)
-------------------------------------------------------------------------

Poco was reconnected on cellular without changing Wi-Fi/SIM settings. A
90-second audio-only call on the installed 2309 build rang in 3.199 seconds
and both endpoints became active in 7.140 seconds. Most observations used
P2P, with no encoded video. The Mac recorded one 447-ms interruption; Poco
recorded two totaling 913 ms. Native receive-delay maxima were 699/471 ms.
These failures cannot all be attributed to video contention. Both owned apps,
logcat and the ADB forward were closed. A debug log written during late Mac
shutdown was preserved privately and removed after process exit; the stand
bundle's strict signature verification passes again.

LocalApp message 93 now carries a generic local source observation, with a
negotiated app↔daemon capability, owned application ID, boolean pressure and
original host sampling timestamp. Malformed, foreign, unnegotiated and stale
reports cannot mutate admission. Samples older than 1500 ms or more than
250 ms in the future are refused. SDK/FFI admission is bounded to 250 ms;
writer freshness and daemon timestamp validation prevent backlog from
renewing retired observations. Healthy reports do not erase another source's
pressure. The existing activity/pressure grace expires naturally. No content
role, destination, service class or new network flag is transmitted to peers.
The regenerated C header and both ABI contracts match the built host SDK.

The call controller reports once per second through its own media IPC binding
for audio-only calls as well as video calls, with one outstanding operation.
It uses authenticated fresh peer playout, separately measured receive age and
playout, interruptions and completed primary RTP failures. Missing expected
measurements restrain competing producers; twelve healthy observations earn
recovery. Muted directions are excluded and a call with no expected audio
stops refreshing the lease. Queued/skipped counts are exposed in diagnostics,
explicitly as IPC admission counts rather than daemon acknowledgments.

Actual file contention exposed another defect: healthy source observations
removed the entire reliable DATA limit, allowing a fast first hop to build a
downstream queue before the next pressure observation. Reliable local DATA
now retains its shared 4096-byte/200-ms allowance while a local primary is
active. Whole compatibility frames preserve byte debt and FIFO. The separate
recovery RPC allowance remains pressure-only; neutral transit is unchanged.
Pressure-specific writer regressions now probe that independent RPC allowance
instead of assuming healthy DATA is unlimited. All 427 session tests pass
(six pre-existing ignores), as do 143 IPC and 42 SDK unit tests. The invalid
FFI argument/handle regression passes. All 85 selected Flutter policy,
playout, preview and real-library ABI tests pass; analysis is clean.

The real codec control now optionally publishes the same source policy over
actual negotiated IPC and transfers encrypted file chunks through reliable
local DATA in both directions. The initial direct-stream attempt in the relay
topology was an invalid test: ordinary SDK streams require a direct peer; the
application uses anonymous streams or datagram fallback for that topology.
That failed fixture is retained privately, not treated as a product regression.
The supported DATA run before the healthy-source limit had complete files but
decoded PCM maxima of 440.5/480.0 ms and native interruptions. The first bounded
100-second run had maxima 221.1/241.3 ms, with files still in flight at teardown.

The retained 160-second bounded run delivered both 512-KiB files completely,
matching hashes, zero missing chunks, duplicates or authentication failures.
All 160 feedback submissions per endpoint were admitted. It delivered all 140
mixed-phase tone transitions per direction, zero quiet PCM ticks and zero
native interruptions, with actual VP8 transmit/receive frames. However decoded
PCM maxima were 230.6/250.5 ms (p95 228.9/249.7), and native receive maxima were
195/225 ms: the strict 200-ms quality gate still FAILS. The blind shared FIFO
shaper dropped no packets and its maximum queues were 112.6/106.8 ms. Driver
interval stayed below 17.44 ms. All file/audio/policy workers exited, all three
SDK nodes stopped and no fixture sockets remained. Raw evidence is private.
Test media libraries remain outside app bundles. Installed Mac/Poco remain
2309; these new SDK and application changes are not installed there yet.

The audio quality objective remains active. Receiver buffering and the
remaining source-to-playout delay need further work; reliable file completion
or unit tests do not establish physical cellular quality or meet the 200-ms
gate. Production SDK/media packaging and another physical verification remain
required before claiming the requested fix complete.

Veil implementation: fafa9559. Additional integration checks verify that a
bound client without negotiation is refused, and that a daemon without an
admission sink does not advertise the capability. Both pass. Commits for this
cycle are unsigned and unpushed; no release or installed identity was changed.


Origin pacing and packet-size isolation (2319–2322)
--------------------------------------------------

Poco is connected over ADB; cellular settings remain unchanged. The 160-second
real-Opus/DATA isolation with no video (2319) still failed the strict 200-ms
PCM gate: maxima 241.5/211.6 ms, native 212/181 ms. All tone transitions arrived,
with no PCM quiet ticks, native interruptions or blind-shaper UDP drops. Both
512-KiB files were incomplete at teardown. This rules out video as the sole
cause; it does not establish irreversible file loss.

Reliable source admission now charges exact wire bytes continuously at the
existing 4096-byte/200-ms rate. It does not accumulate idle credit, shares debt
across local neighbors, and preserves oversized compatibility frames until
primary idle expiry. Route-recovery RPCs retain their separate pressure-only
allowance; neutral transit is unchanged. The isolated 160-second pacing-only
run (2320) still failed: PCM maxima 221.1/231.7 ms, no quiet ticks/interruption,
and incomplete files. Exact pacing alone does not resolve audio delay.

An endpoint-only, trace-enabled admission sample records actual wire cost and
pending writer blobs without application identity, payload role or any new
network metadata. It measured 3940-byte ordinary source frames. A short 40-s
instrumented run (2321) recorded no asynchronous SDK send failures on either
file connection, but cannot establish eventual completion. The tool now
records those failures separately from IPC queue success and reports receipt
time only after complete hash-verified reassembly. Its optional no-video
mode is explicitly an isolation test, not the full media-priority gate.

During active local primary traffic, the origin registry now recommends
768-byte envelope pieces, yielding measured 1108-byte hop-encrypted frames.
Canonical packetization returns after primary idle expiry. The existing
chunk format, neutral relay header and receiver bounds are preserved. Large
valid transfers increase their segment size enough to retain the chunk-count
limit; adapters without advice retain canonical behavior. IPC tests exercise
small-frame sealed delivery through the real dispatcher and check relay
header neutrality, reassembly and large-transfer limits. All 145 IPC tests
pass (five previous ignores). The final 428 session tests also pass (six previous ignores).
The 220-second full audio/video/file run (2322) delivered both encrypted
512-KiB files with matching hashes in 83.8 seconds, no missing chunks,
duplicates, authentication failures or asynchronous SDK send failures. Actual
VP8 transmit/receive and all 200 mixed-phase PCM tone transitions per direction
were observed. There were no native interruptions, but three quiet 10-ms PCM
ticks on one side. PCM maxima were 198.5/283.3 ms (p95 162.5/238.8); native
maxima 189/210 ms. The strict quality gate still FAILS. Both directions' receive
age stayed at or below 42 ms, and the blind shared FIFO dropped no packets
(maximum queues 114.1/75.4 ms). Driver interval stayed below 20.51 ms. Files
completed roughly 104 seconds into the call; elevated receiver buffering on
one side persisted through 127 seconds. Video adaptation frequently reported
no source pressure despite native receive delay around 200 ms, and one sender
retained a 450-kbps target. The same packetization with no video (160 seconds, 2323) delivered both
files in 83.4 seconds with matching hashes, zero missing chunks/duplicates,
authentication or asynchronous send failures. All 140 tone transitions per
direction arrived, with zero quiet PCM ticks and native interruptions. PCM
p95 fell to 170.3/141.5 ms, but maxima were 209.6/210.2 ms, so the strict
200-ms gate still FAILS. Native receive maxima were 183/182 ms, receive age
23/22 ms, and blind FIFO queue maxima 101.1/92.3 ms with zero UDP drops.
Feedback delivery and all 160 IPC quality submissions per endpoint succeeded.
This isolates a remaining audio/file delay peak as well as the additional
video contention; reducing chunk size is useful but not a complete fix. All workers exited, all three
SDK nodes stopped, and fixture socket count is zero. Raw captures are
private, test nodes/helpers were reaped on exit in both final runs. These edits are not
yet installed on physical endpoints. The overall audio objective remains
active; laboratory improvement will still require cellular verification.

Veil implementation for this cycle: 0a636984. Commits are unsigned and
unpushed. Physical Mac/Poco remain on 2309; no app was opened or installed
during these isolated SDK runs. The audio quality goal remains active.


Pressure feedback and delayed ciphertext retention (2324–2328)
-------------------------------------------------------------

Blind FIFO tracing records only fixture link aliases, datagram sizes, queue
and release times in a bounded private ring; it neither parses nor prioritizes
payloads. The 160-second audio/file isolation (2324) still failed: decoded PCM
maxima 201.5/220.8 ms, with both 512-KiB files hash-complete in 83.4 seconds,
no quiet ticks or native interruptions. File-phase wire averages were about
81 KiB/s per direction, but transient packet bursts created a 100.9-ms queue.
Release lateness p95 was about 0.56 ms; the observation implicates bursts rather
than sustained average saturation, without establishing a physical radio cause.

Endpoint policy now protects audio at a native receive estimate of 160 ms,
recovering below 120 ms, leaving margin for source/codec/render work absent
from that estimate. Fresh poor peer playout immediately suspends video instead
of keeping an already earned video budget while stepping down the ladder.
Reliable local DATA charges 1024 bytes/200 ms during measured source pressure,
4096 otherwise, preserving existing debt and independent route recovery.
Relays and the network wire receive no media class or priority hint.
The targeted Flutter suite passes all 70 tests; final analysis is clean.

The 300-second mixed run (2325) improved actual audio: decoded PCM maxima
189.2/141.5 ms, all 280 mixed-phase tone edges per direction, no quiet PCM
or native interruptions. The overall gate still FAILED: files remained at
102400/313344 bytes with 206/103 missing chunks. No blind UDP drops, file-layer
authentication errors, duplicates or asynchronous send failure callbacks
occurred, but SDK logs showed repeated ratchet decrypt failures and signed
unopenable resets. IPC send waits reached 13.8/16.7 seconds. Video was sparse
(TX 53/221 and RX 204/48), not proof of sustained video quality.

A deterministic regression (2328) reproduces PqDowngrade when queued DATA is
opened after five priority health/reply epoch turns and a state round trip.
The former two-epoch receive-key pruning deleted still-deliverable message
keys. Regular RatchetStore import also deleted old gaps on every restart.
Both operations now preserve bounded unconsumed gaps: linear keys retain
MAX_SKIP_TOTAL=2000, tree nodes retain the per-chain 2048 and explicitly
checked conversation-wide 4096 ceilings. Old trees are cut at authenticated
pn; empty closed trees are removed, consumed keys remain unavailable, and
forged tags do not consume retained gaps or mutate the session. No old root,
DH secret or already consumed message key is retained for recovery.

Persisted primitive state is version 3 with the same field layout and exact
allocation accounting; it permits more than two receive tree chains within
the existing node budget. Versions 1 and 2 still import. An older SDK refuses
version 3, so downgrade after writing this state is not supported. On-wire
ratchet frames, PQ requirements, AEAD checks and negotiated network formats
are unchanged. Untrusted never-answered conversations remain subject to
store quotas, including on import; established correspondents are not swept.
The changed components pass 96 ratchet, 135 E2E, 145 IPC and 429 session tests
(805 total, with 11 previous unit-test ignores). Tests cover late DATA after
priority turns and restart, forgery/replay, v2 migration, empty-chain cleanup
and the total tree-key ceiling with rollback on refusal.


The first post-fix mixed run (2328) used a stricter blind 768-kbps directional
cap, rather than the previous 1024-kbps fixture cap. No SDK decrypt failures
or signed-unopenable resets occurred; all 61 feedback deliveries per endpoint
(including bootstrap) arrived. At 300 seconds files reached 516096/518144
bytes with 4/3 chunks missing, zero file authentication errors, duplicates or
asynchronous send failures. This establishes recovery of the earlier crypto
failure class, not complete file delivery. Decoded PCM maxima 299.9/470.0 ms
(p95 210.0/339.9) failed the audio gate; three quiet ticks occurred, no native
interruptions. Blind queue maxima reached 156.9/200.6 ms with zero UDP drops;
driver interval peaked at 33.86 ms. Only 26 video frames per sender were
produced. The bounded 100000-row trace truncated 15876 earlier rows, so its
remaining peak is not claimed to be the run's global peak. Every worker
exited, all three nodes stopped with result zero, and fixture sockets are zero.

The source implementation is Veil 51f0da3d, committed unsigned and unpushed.
Fresh production Android SDK and production Mac/Android media have been
built; test-only codec hooks are absent from those production media binaries.
Physical endpoints remain on 2309 pending a complete coexistence check.
No physical app was opened during these codec fixtures. The owned media VM
is stopped; the user's default VM remains running. Raw captures are private.


With the prior 1024-kbps cap restored, the 360-second mixed run (2329) still
FAILS the overall gate. One 512-KiB file hash-completed in 107.4 seconds;
the other remained at 507904 bytes with eight missing chunks. There were no
SDK decrypt failures, signed-unopenable resets, file authentication errors,
duplicates, asynchronous send failures or blind UDP drops. All 340 mixed-phase
PCM transitions arrived in each direction, with no quiet ticks or native
interruptions. PCM maxima were 218.9/240.4 ms (p95 159.4/180.1); native maxima
197/195 ms, receive age 81/63 ms. Actual VP8 TX 488/446 and RX 302/278 occurred.
Blind FIFO queues peaked at 116.8/109.8 ms; driver interval remained below
20.12 ms. A short Flutter test run overlapped this measurement, without
violating its driver interval gate; no network cause is inferred from that
host workload. All workers exited, three nodes stopped successfully, and
fixture sockets are zero. Crypto retention is fixed, but remaining delivery
and latency defects prevent claiming completion or installing this build.


An additional opt-in generic Forward-expiry diagnostic samples powers of two
only, recording count/age/TTL without addresses, identities, payloads or
application roles. It does not change relay scheduling or expiration. The
90-second diagnostic (2330) observed no Forward expiry, SDK decrypt failure,
file authentication failure, async send failure or blind UDP drop. File
receipt was 284672/260096 bytes at teardown; most missing indices were tails,
but the latter also lacked index 120 below its latest received index 130.
The short run cannot prove full delivery or rule out expiry in longer runs.
The benchmark now preserves missing indices explicitly for this distinction.
Both earlier long runs had only local secondary-source drop observations;
they do not establish whether an intermediate relay silently rejected a file
piece. The file API's final flag is anonymity, not an end-to-end ACK request;
its ordinary local DATA admission is not proof of terminal receipt. Follow-up
must examine relay admission/reassembly and the actual application's file
recovery path before claiming all missing data is a source-pacing defect.
All diagnostic workers exited, all nodes stopped with zero status, and all
fixture sockets were removed. No physical apps were started or updated.
The audio objective remains active. This cycle's changes are committed
unsigned and unpushed; production packaging/cellular validation remain pending.


### Forward expiration under local source backpressure (2026-10-08)

The longer 1024-kbps mixed fixture (2331) finally observed expired Forward
envelopes: sampled ages 31–32 seconds exceeded their unchanged 30-second
TTL. SDK queue/relay/IPC/decrypt/rate-limit counter deltas and blind UDP drops
were all zero; these counters do not count the early Forward TTL rejection.
Files reached 270336/307200 bytes, including holes below the latest received
index, not just pending tails. PCM maxima 239.6/240.2 ms still fail the
strict 200-ms gate. Driver maximum 17.31 ms was within the measurement gate.

An opt-in generic encrypted-chunk correlation fixture (2332, 120 seconds)
found eight transfers whose complete six-fragment sets were admitted at
the source and received by the relay, but only four or five fragments were
forwarded. The same capture sampled TTL rejection at ages 31–33 seconds.
This establishes loss before relay enqueue, despite no UDP drops, E2E
failures or asynchronous send failures. The shorter run's other missing
indices include pending tails and do not all establish loss. Both fixtures
joined every worker, stopped all three nodes successfully and left zero
fixture sockets. No physical application was started or updated.

The local reliable source now keeps four credits of sealed-frame lookahead,
weighted by 1536-byte units; one oversized compatibility frame owns the
whole lookahead. Credits survive ingress draining and scheduler queuing.
This bounds aging encrypted data before publishing without changing neutral
transit queues, primary reserve, wire metadata, relay fairness or TTL.
Tests use concurrent producers and consumers so genuine bounded admission
can apply backpressure; neutral traffic stays independent of a waiting file
producer. Completion of real simultaneous audio/video/file transfers and
physical cellular validation are still required.

The benchmark exposes existing generic runtime counters via local-only
admin metrics, verifies metrics are enabled and records before/after deltas.
Optional chunk traces contain bounded random fragment identifiers and
source/receive/enqueue timestamps plus age/TTL; they are off by default and
do not identify application media roles or disclose payloads. Raw fixture
keys, identifiers and captures remain private.


The weighted-lookahead fixture (2334, 360 seconds, the same 1024-kbps blind
cap) delivered both 512-KiB files with exact hashes and no missing chunks:
129.7/123.0 seconds from submission. Every generic drop/decrypt counter delta
was zero; reassembly reached 256 messages at each endpoint. No Forward
expiry occurred, and the largest recorded envelope age was six seconds.
All 340 mixed-phase PCM transitions arrived per direction, with zero quiet
ticks or native interruptions. Actual VP8 TX 153/191 and RX 136/108 occurred.
PCM maxima improved to 181.7/201.5 ms, p95 150.3/170.5 ms; the latter still
fails the strict 200-ms gate. Native delay maxima 163/184 ms and blind FIFO
maxima 90.9/89.4 ms leave an outstanding latency issue. Driver maximum was
24.91 ms. All workers exited, three node stops returned zero and sockets
were removed. Session tests pass: 430 passed, six existing unit ignores,
plus one ignored documentation test. These results resolve the demonstrated
TTL/file-loss defect, not the complete audio/physical/screen-share objective.

The largest residual PCM delays began immediately after file/video startup.
At 21 seconds the filtered native delay estimate was only 63/53 ms while
the current jitter buffers were already 152/143 ms. Native WebRTC
GetDelayEstimate uses FilteredCurrentDelayMs plus device playout delay;
jitter_buffer_ms instead reports currentBufferSize. The current adapter
and peer feedback consume only the filtered estimate. This is evidence
for examining delayed endpoint congestion response, not proof that all
remaining physical network pauses have the same cause.


The endpoint guard now takes the maximum of the validated filtered delay
and current jitter-buffer occupancy, both for local video adaptation and
for authenticated peer playout/source-pressure feedback. A stalled worker
or missing/invalid delay estimate cannot become a healthy sample merely
because a buffer value exists. Older media libraries without a valid buffer
field retain their validated delay estimate. Neither the 200-ms measurement
gate nor the 160/120-ms degradation/recovery margins changed. Regression
tests reproduce a 53-ms filtered estimate with a 163-ms buffer, immediate
video reservation and recovery only after the buffer drains. All 79 focused
Dart tests pass; static analysis of the four changed files reports no issues.
A fresh real mixed codec fixture is pending; this unit result is not proof
of acoustic or physical cellular quality. Production Mac and Android SDK
binaries were rebuilt from ab705e8c, without changing the exported ABI.


The follow-up 2335 fixture PASSes the complete real Opus/VP8/file gate at
360 seconds with the unchanged 1024-kbps blind cap. Both files hash-complete
with no missing chunks in 197.7/167.9 seconds. All 340 mixed-phase PCM
transitions per direction arrive, maxima 181.0/191.5 ms, p95 160.0/159.5 ms,
zero quiet ticks and native interruptions. Actual VP8 TX 228/489 and RX
479/182 occurred. Native filtered-delay maxima 151/154 ms and current-buffer
maxima 151/162 ms are recorded separately. Blind FIFO maxima 116.9/90.2 ms,
zero UDP drops; driver maximum 30.92 ms stays within the 40-ms fixture gate.
All workers exit, three nodes stop successfully and fixture sockets are zero.
This verifies synthetic decoded audio with real codecs and file coexistence
on the constrained relay; it does not establish physical cellular quality,
camera/screen capture correctness or acoustic microphone-to-speaker latency.
Production packaging and physical validation follow this successful gate.


Production debug build 0.13.84+2335 is packaged and installed on Poco, with
Mac stand updated; /Applications is untouched. Mac code sections match the
fresh SDK and native media; packaged Android native libraries match their
independently stripped inputs. The APK signer matches the installed prior
application and the complete installed APK hash matches the signed artifact.
Production media exports contain no test-only hooks; SDK ABI is unchanged.
The update preserves profiles, identities, history and cryptographic state.

Physical validation FAILS at call setup, before any audio measurement:
Poco→Mac audio, Poco→Mac video and Mac→Poco audio never reached ringing or
both-active within 45.1/45.2/45.3 seconds. Both APIs were ready with realStack
true; outgoing offers were logged but no corresponding incoming offer was
observed. These samples do not prove the cause or physical media quality.
The pre-call exchange returned admitted=true, while raw identity-addressed
status returned admitted=false/hasCert=false; alias/device routing must be
checked before treating those status observations as a contradiction or
a routing diagnosis. Recorded invite/destination prefixes match the saved
fixture peers, but full physical-device/receive-address probes remain needed.
No app data was wiped, policy/SIM/Wi-Fi settings were not changed.

Every owned Mac/Android app/helper is stopped, ADB forward removed and Poco
package processes are zero. A late Mac SDK debug log was archived privately
and removed from the owned stand bundle after process exit; its strict seal
verifies again. Raw logs, probes, identifiers, credentials and device config
remain private. The objective remains active: physical signaling recovery,
cellular audio/video quality and screen-share coexistence remain unverified.

Follow-up physical probes compare complete saved contact addresses with
the actual device, sovereign identity and receive addresses. Both saved
contacts match the actual sovereign identities; every probed physical and
identity address reports no admitted session. Public-mode hasCert=false is
normal and is not an admission failure by itself. No routing policy changed.

SDK 9c38f39f fixes an independently reproduced false hole-punch success:
the old shortcut treated an open TX sender reservation as a completed peer
session. It now consults the same committed live-session snapshot as the
PNet status provider, including verified sovereign aliases. The baseline
regression returned Connected for a reserved unknown peer; the fix returns
UnknownPeer. Five hole-punch tests, four provider tests and the committed
running-session lifecycle test pass; formatting passes. The latter verifies
that a genuine live connection remains an idempotent success without a new
punch attempt. This correction is not yet proof of the physical invitation
failure's sole cause. Fresh production SDK builds and physical retesting
follow; audio/video/screen quality remains unverified on these devices.

Production debug build 0.13.84+2336 now packages SDK 9c38f39f on both
platforms and is installed on Poco without wiping data; Mac stand is updated.
The APK signer and complete installed artifact match, fresh native code and
production media exports verify, and the ABI stays unchanged. The physical
exchange now reports admitted=false consistently with raw session status on
both devices. Poco→Mac audio still fails setup at 45.043 seconds, with no
incoming realtime signal. Thus correcting the false success did not itself
restore signaling. Owned-process vmmap confirms the bundled SDK image is
loaded; Rust runtime logs are in the Mac stdout/logcat captures, distinct
from the native media diagnostic file.

Read-only admin snapshots after a longer warm-up show Mac sessions 1→3→3
at uptime 13/44/74 seconds and Poco sessions 0→0→0 at 17/47/77 seconds.
Bare TCP probes from the phone to three active Mac relay addresses complete
in 0.203/0.148/0.152 seconds; the HTTPS control also connects. Staged obfs4
keys match in memory. Android reports cellular enabled, Wi-Fi disabled,
awake/active idle state and no effective standard network-policy block for
the app UID. These observations exclude several simple explanations, but
do not prove why the app's transport/peer handshakes time out; bare TCP from
ADB is not an authenticated SDK handshake in the application process.
Separately, Mac logs show expired sovereign signing delegation preventing
fresh ML-KEM and relay-key certificates. Existing credential-based renewal
is required; no validity checks or identities were bypassed/reset.

All owned app/helper processes are stopped after the probes, Poco package
processes and ADB forwards are zero, and the owned Mac bundle's strict seal
verifies. Captures, addresses, credentials and cryptographic material remain
private. Physical audio/video/screen validation is still pending, with
signaling and cold network admission requiring further investigation.

Further physical controls isolate network entry from media quality. An
owner-only temporary native helper on Poco loads the exact packaged 2336
SDK and uses a new canonical test identity plus authenticated loopback TCP
admin/IPC. It establishes a peer session by 20 seconds, still live at 60,
with advancing health ticks and a successful PoW-walk response. The installed
profile remains closed and untouched during this control. Early Unix-socket
fixture/config failures are not SDK connectivity results. Every temporary
native process stops successfully and its remote directory is removed.

The installed app then receives three temporarily registered bootstrap
invites from peers authenticated by the Mac stand. Poco sessions become
1/6/6 at uptime 15/45/75 seconds, versus 0/0/0 in the earlier discovery-only
run. Its earlier discovered rows did not match the Mac's working addresses.
This isolates a discovery/entry-path problem; manual registration is a
diagnostic workaround, not an autonomous bootstrap fix. The subsequent
Poco→Mac call rings in 0.406 seconds and both endpoints are active in 1.162.
Thus the expired Mac signing delegation warning alone does not prevent this
cached-profile call from connecting.

Physical audio still FAILS quality. In 90 seconds with automatic routing,
Mac/Poco interruption counts are 24/16, accumulated interruption duration
14.455/12.125 seconds and filtered-delay maxima 754/719 ms. There is one
P2P→relay handover around 50 seconds. Forcing the already permitted relay
route immediately after connection does not cure it: another 90-second
audio call records 24/26 interruptions, 19.782/22.989 seconds and maxima
564/470 ms. A requested video call connects but reports zero transmitted
and delivered video frames, so it is not proof of audio/video coexistence.

Source RTP queue admission takes at most 1 ms in the relay audio control
(3 ms in the requested-video run). The legacy audio_tx_rtp_queue_age_ms
field measures time since the last admission, not packet queue residence.
Generic opt-in session traces nevertheless locate a downstream wait:
Poco ordered primary-source writes of only 406/409 bytes take 1432/382 ms,
with writer waits 1277/224 ms and queue depths 67/17. Other body reads take
up to 2992 ms. These are local transport observations, not proof of relay
prioritization or its cause; socket/TCP versus wrapper waits must be isolated.
Relay fairness, wire privacy and device network policies were not changed.
All owned stand apps/helpers exit, temporary directories are removed and
the Mac strict bundle seal verifies. The full media objective remains active.

The next SDK diagnostic adds opt-in, bounded local obfs4 write-wait probes
behind the existing VEIL_RT_TRACE/embedded debug toggle. They sample TCP
RTT, retransmissions, congestion window and socket backlog at the first
Pending and after a slow re-poll/completion, with local ciphertext remaining
and poll gaps. Durations include task scheduling, not just network latency.
Process-local connection numbers contain no peer identity; no media labels,
wire changes, relay priorities or socket tuning are introduced. Missing
platform fields stay unavailable rather than falsely reporting zero.
Darwin TCP_CONNECTION_INFO uses packed TFO bitfields that libc 0.2 expands
incorrectly; native-header offsets and Android TCP_INFO offsets were checked
with the system compiler. Five obfs4 stream tests, two socket/wait tests and
five transport smoke tests pass; fresh production-feature SDK builds succeed
on Mac and Android. This is instrumentation, not yet a fix for physical pauses.

The 2349 Poco→Mac relay audio control rings in 0.421 seconds and connects
in 0.988, but still fails quality: 22/24 interruptions, 26.280/26.797 seconds
of accumulated interruption, and delay maxima 690/484 ms. TCP write-wait
snapshots on Poco prove actual kernel backlog/retransmission rather than a
large obfs4 wrapper buffer: 54–114 KiB not yet sent, only 503–662 ciphertext
bytes pending locally, retransmissions increasing and waits up to 2263 ms.
Polling continues within 153 ms. This does not locate where packets are lost.
The video control has real camera capture (853/686 local frames), but zero
encoded/delivered frames and both endpoints' 21-second liveness timeout;
coexistence validation is still failing. Owned apps/helpers and forwards exit.

A standalone socket control on the same Poco exposes a concrete existing
MSS-clamp defect. Setting TCP_MAXSEG=1200 after connect leaves client/peer
MSS at 32767/32768 on loopback; setting it before connect negotiates 1188
on both sides. SDK connect_tcp_stream used only the late call. It now also
sets the existing limit before connect on Linux/Android, so it is advertised
in the SYN. Darwin rejects the pre-connect option in the matching control,
so its established-socket handling is retained. A Linux/Android regression
checks both connected endpoints, and socket diagnostics now report send MSS.
Four host TCP/obfs4 tests and two diagnostic tests pass, both native builds
succeed, and the temporary phone control is removed. These changes introduce
no media classification, relay priority or new routing policy. Physical
call quality must be measured again before declaring this a complete cure.

The actual Rust transport test binary also runs on Poco: all 12 TCP-related
tests pass, including the new pre-connect negotiation regression; its owned
temporary directory is removed. Build 0.13.84+2350 packages SDK 2c363127 on
both platforms with the unchanged ABI and production media exports. The
same-signer APK is installed without wiping data, pulled back and hash-checked;
Mac native code and strict seal verify. Package source state is clean.

Two further Poco→Mac controls each remain active for the requested 90 seconds.
Audio rings/connects in 0.425/1.033 seconds; camera mode in 0.412/1.376.
Real TCP snapshots consistently show send MSS 1188, proving the negotiation
fix is deployed. It is NOT a full quality fix: waits still reach 3326 ms,
TCP RTT reaches 1.396 seconds and retransmissions continue, even in samples
with zero not-yet-sent bytes (in-flight data can still occupy the send buffer).
Audio interruption counts are 26/26, durations 23.790/27.687 seconds and
filtered-delay maxima 774/414 ms. Camera mode has 2682/2634 captured frames,
21/19 interruptions, 14.438/13.953 seconds and maxima 510/485 ms; native
video_send_paused remains 1 on both endpoints and encoded/delivered frames
remain zero. Audio protection must not be disabled to manufacture a video
pass. Local RTP admission is at most 1 ms in audio and 3 ms in camera mode;
remaining waits are downstream. No successful physical coexistence result
is claimed, and discovery, loss/ACK waits and transport separation still need
work. Every owned app/helper process and forward is verified absent and the
Mac bundle's strict seal verifies after cleanup. No commits are signed/pushed.

SDK 1b4d4404 fixes a separate buffered-write defect: the session writer
could accept the last plaintext frame while obfs4 still held ciphertext,
then wait for the next queued frame without flushing. OVL1 handshake flights
also lacked a flush before waiting for a reply. Both regressions fail against
the old implementation and pass with the fix. The writer keeps its existing
local source-pressure lease through flush; partial writes renew the 30-second
idle budget, while flush, which exposes no partial progress, has a bounded
30-second completion budget. Nine writer-progress tests and the buffered
handshake regression pass. This is not yet proof of a physical pause cure.

SDK 3d198382 supplies independent obfs4/TCP transport children with fresh,
domain-separated channel bindings, seven bounded slots per direction and
canonical-parent cancellation. Only the dialing endpoint opens TCP children;
accepted children are duplex rather than reverse-dialing a client's source
port. A real obfs4 child passes the existing exporter-bound canonical-session
proof; a proof captured on another connection fails. Exact handshake reads
also preserve subsequent coalesced bytes; the old boundary regression fails,
but occurrence in the installed production handshake has not been proved.

All 434 host session tests (six existing ignores), 123 host transport tests,
five transport smoke tests, two transport doc tests and 59 obfs4 tests pass.
The five independent-TCP tests also pass on the actual Poco, including a
roundtrip while the parent's real TCP write is blocked, fresh bindings,
parent-drop cancellation, sibling survival and budget reclamation. Its
exclusive temporary fixture is removed and helper/app processes are absent.
Formatting passes. This transport primitive is NOT yet activated in call or
session routing: generic capability negotiation and canonical child dispatch
must still be connected before claiming TCP media separation. No media labels,
relay priority requests, identity admissions or wire framing changes are added.

Production debug build 0.13.84+2351 packages the committed SDK 3d198382 on
Mac and Poco. Both fresh native builds succeed; the packaged Android SDK
contains the new final-frame and handshake flush paths. The SDK ABI remains
unchanged, native dependency checks pass and media exports remain production
only. The same-signer update preserves installed data; the full pulled APK
matches the signed artifact. The Mac stand's native code and strict seal
verify. The transport primitive remains explicitly inactive in runtime routing.

Two subsequent Poco→Mac controls stay active for 90 seconds each. Audio
rings/connects in 1.523/2.217 seconds; camera mode in 0.392/2.482. Network
warm-up still uses temporary known-peer registration, not a discovery fix.
Quality still FAILS: audio interruption counts are 24/14 (Mac/Poco), durations
27.511/13.853 seconds and filtered-delay maxima 533/960 ms. Camera mode
records 24/12 interruptions, 22.821/5.817 seconds and maxima 505/968 ms.
These telemetry observations do not establish acoustic latency or controlled
improvement over earlier network conditions. Source RTP admission is at most
1 ms in audio and 5 ms in camera mode. Camera capture is real (2732/2667
local frames), but video_send_paused remains 1 and encoded/delivered frames
remain zero; this is not a successful coexistence test.

Two opt-in phone TCP snapshots now observe flush, send MSS 1188, roughly
107/112 KiB queued and 97/104 KiB not yet sent, with retransmissions and RTO
around 2.4 seconds. Their observed Pending duration is 151 ms; these sparse
samples do not establish the full call-pause duration or its exact location.
Existing QUIC datagram traces also include independent-path sends, so all
traffic in this run must not be described as TCP. Generic ordered children
still need authenticated capability negotiation, canonical registry dispatch
and local source/neutral transit selection before deployment. Relay fairness
and wire privacy remain unchanged. All owned app/helper processes and ADB
forwards are verified absent; captures stay private and the Mac strict seal
verifies after cleanup. Commits remain unsigned and unpushed; the media goal
is active and no complete physical quality fix is claimed.

### Ordered child record plane and shared listener — 2026-10-08

SDK 440829b1 adds a bounded loss-tolerant record codec on authenticated
independent obfs4/TCP children. Its only framing field is an encrypted two-byte
length; producer role, local priority and expiry are not transmitted. Each
direction has a 64 KiB byte/metadata budget. Outgoing reservations remain held
through flush, and expiry can cancel a write only before any bytes were accepted.
An incomplete record closes the entire child instead of corrupting subsequent
framing. Incoming records have identical oldest-first eviction and a 200 ms
local residence bound; this is not a bound on TCP transit time. Reliable
messages must never use this codec. Local writer progress is not ACK or RTT.

The runtime's shared encrypted listener now distinguishes ordinary OVL1 from
generic auxiliary proofs on both QUIC and obfs4/TCP. Ordered children require
the fresh accepted transport's binding and the live canonical parent's proof
before acquiring one of seven incoming leases. They create no peer identity or
new dispatcher budget. Parent retirement immediately rejects admission and
wakes idle child I/O. A stale registration guard cannot remove a replacement
registration. Ordinary OVL1 bytes and existing QUIC dispatch are preserved.

All ten record tests, six binding tests and nine shared-registry tests pass on
the actual Poco, using freshly compiled Android test executables. The registry
test blocks a real canonical TCP write and exchanges authenticated records on
three independently bound children through the same listener; dropping one
child leaves its sibling alive. Tests also cover replay on a different fresh
transport, retired/pending parents, malformed lengths, queue expiry, bounded
admission and lease reclamation. The exclusive phone fixture was removed and
helper/application processes were verified absent; no app/data reset occurred.

Host gates pass: 133 transport unit tests, five smoke tests, two doc tests,
442 session tests (six existing ignores), and the final six binding/nine
registry tests after the prefix/payload coalescing change. Production macOS and
Android FFI builds and formatting succeed; the compiled ABI is unchanged.
The installed apps remain build 2351. This commit prepares the record plane
and shared receiver only: normal SessionRunner still offers QUIC children.
Ordered capability negotiation, source selection and duplex pool ownership
remain to be connected before deployment and another physical call-quality
test. These protocol tests do not establish that the physical audio pauses
are fixed or that encoded video can coexist successfully with audio.

SDK 4c87ebcc makes the existing session sender, authenticated VDF receiver and
neutral duplex return carrier work with either QUIC datagrams or parent-bound
ordered records. The shared decoder retains canonical peer attribution,
fragment/replay checks, frame eligibility, dispatcher admission and violation
tracking. Queue admission accounts for the ordered prefix and tiny-record
metadata floor. Full/expired queues drop the lossy frame without marking the
child broken or replaying partial fragments on the reliable stream. Genuine
QUIC diagnostics remain available; ordered diagnostics explicitly report only
local queue/flush counters and do not synthesize RTT/CWND/ACK fields.

Three additional deterministic tests exercise the actual common receiver and
return carrier: damaged/replayed fragments and reliable frames cannot reach
dispatch; the existing dispatcher budget can refuse eligible frames; violations
reach the canonical ban tracker; neutral return traffic retains INTERACTIVE
priority and bandwidth admission; and full/expired ordered queues recover
without losing parent lifetime. These duplex fixtures isolate codec and
admission behavior, while the separate real-obfs4 registry tests establish the
encrypted transport binding and connection budgets.

The final frozen source passes 445 host session tests (six existing ignores),
ten ordered-record tests and all 28 relevant tests on the actual Poco (10
records, 6 bindings, 9 shared registry, 3 common receiver). Both production FFI
builds, unchanged ABI verification and formatting pass. The existing camera
placeholder fix ee3da8bc was also checked: all four video-frame widget tests
pass with TMPDIR=/private/tmp/. Mirroring applies only to camera pixels, not
waiting/stale labels. Phone fixtures/helpers and the Mac stand process are
verified absent. Installed apps remain 2351; no update, release, data reset or
physical call-quality cure is claimed in this cycle. Ordered-child capability
negotiation and live session pool/source selection still need activation.

SDK 9e247eec activates parent-bound ordered children in the normal runtime and
SessionRunner. Both peers must explicitly negotiate the marked ordered-child
capability together with the existing authenticated flow codec and rekey. Old
peers retain the ordered compatibility path. The original TCP dialer warms six
generic duplex connections: four local source slots and two neutral circuit
shards, under the existing seven-child directional quota. Accepted endpoints
reuse the duplex children rather than dialing an ephemeral client port. Local
source roles never appear in proofs or record metadata; relays retain neutral
admission and dispatch. Ordinary reliable messages/RPC/files still use the
canonical reliable plane. Readiness, retirement, bounded reconnect backoff and
normal key rotation now apply to ordered children as well as QUIC children.
Ordered source pressure uses actual local expiry/flush observations; no QUIC
RTT/ACK/CWND metrics are synthesized.

The actual SessionRunner tests exchange small and fragmented frames in both
directions over real obfs4/TCP children, including a deliberately Pending
canonical writer and ordinary negotiated rekey. Rekey retires old lossy records,
so the transition test continues producing fresh media, validates every received
payload and rejects duplicates, checks a two-second delivery gap bound and
requires every source to deliver both before and after rekey. It does not assert
lossless delivery across retirement. A reproduced cancellation leak was fixed:
runner cancellation now aborts its owned canonical writer, releasing the stream
and dial authority; tests verify children and canonical transport retire.

The full integration run also exposed two fixture issues: a live slow proxy
receiver must acknowledge keepalives, and these tests must share the rotation
tests' lock while the process-global 1–2 second lifetime override is active.
Final host gates pass: 445 session tests (six existing ignores), 829 protocol
tests, 649 runtime tests (11 existing ignores), and 106 runner integration tests
(one existing ignore). The rekey delivery check also passes five successive
repeats. Production macOS/Android FFI and final Android test executables build;
macOS ABI is unchanged and Android production source freshness is verified.
Poco is absent from both ADB and the macOS USB list despite the reconnect report.
No new phone test, app installation or physical call-quality improvement is
claimed here. Existing installed apps remain 2351; deployments on both endpoints
and relays are needed to exercise the new capability on a physical call.

SDK 217bcd2d extends the existing four-node A–R1–R2–C integration
fixture to real obfs4/TCP as well as QUIC. Two new tests use normal
SessionRunner, shared ordered-child listener proofs, encrypted circuit cells,
forward dispatch and duplex neutral return carriers. The blocked-canonical
writer scenario delivers both endpoint source classes through two neutral
relay shards in both directions. The rekey scenario waits for every canonical
link to rotate and every ordered pool to bind again, then verifies source
and transit use in the new generation. Relay diagnostics must remain zero
for all four local source classes; payload order/content and duplicates are
checked, and every child must disappear after canonical teardown. Fixture
tasks now abort on failed assertions too, and the process-wide rotation
override is isolated with the same lock as the other session tests.

All four QUIC/TCP chain variants pass; the full host runner suite passes
108 tests with one existing ignore. The final Android runner executable
builds and is verified as fresh ARM64 ELF containing both new ordered chain
scenarios; execution on Android is pending because Poco remains absent from
ADB. No production runtime code changed in this test-only SDK commit.

The preceding frozen production source was packaged as stand/APK build 2354
with SDK 9e247eec. Packaging checks verify the committed source pin, unchanged
ABI, SDK native hashes, same Android signer, production media exports/imports
and strict macOS seal. These artifacts are prepared, not installed on Poco;
installed phone data and identities remain untouched. The controlled chain
checks prove routing and neutral relay behavior, not physical audio quality.
A physical mixed audio/video/screen/file call still needs an available phone,
and new ordered capability must be deployed on the participating hops.

### Physical build 2354 with returned Poco — 2026-10-08

Poco is available again over ADB. Fresh ARM64 runner executables pass both
ordered-child tests and all four neutral QUIC/TCP chain variants on the actual
phone (six tests total); the temporary executables and helper processes are
removed. Production build 2354 is installed with `adb install -r`, preserving
identity/history. The complete pulled APK matches the prepared signed APK.
Both app runtimes use SDK 9e247eec; SDK 217bcd2d adds tests only, so production
runtime source is unchanged. The owned Mac stand is build 2354 too; the normal
/Applications installation is untouched. Poco remains cellular with Wi-Fi off.

Four 90-second Poco-to-Mac calls reach ringing/active in 0.450/1.472,
1.488/1.931, 0.461/0.957 and 0.462/1.318 seconds respectively. All remain active
to the end, with no observed endpoint loss or timeout. This uses a 60-second
warm-up and temporary runtime registration of known authenticated peers, so
it does not prove unattended cold bootstrap. The first two calls force the
already permitted relay recovery; the latter two keep normal selection and
actually remain P2P. These physical relay captures initialize QUIC parallel
carriers, with no observed ordered-child initialization; the fixture name
`tcp2354` must not be treated as proof of a physical ordered route.

| Physical observation | Mac interruptions / total ms | Poco interruptions / total ms |
| --- | ---: | ---: |
| Relay audio | 7 / 4408 | 7 / 6782 |
| Relay camera enabled | 6 / 2518 | 7 / 3689 |
| P2P audio | 9 / 5163 | 12 / 5606 |
| P2P camera enabled | 7 / 2520 | 7 / 2813 |

These are native playout telemetry, not direct acoustic PCM measurements. Audio
quality still fails. Camera capture advances on both endpoints, but the source
guard pauses video throughout the measured camera calls: zero frames encode,
transmit or arrive remotely. This is not evidence of successful mixed video,
screen and audio quality. Production media remains the existing 30-packet
Opus receive buffer with fast acceleration, FEC and DTX; previously rejected
small-buffer and target-delay experiments are not reintroduced.

Sparse matching local source cells across SDK entry, IPC socket write, daemon
read, handler entry and direct enqueue yields 184 Mac and 190 Poco matches.
Direct enqueue is within 3/6 ms respectively (p95 1 ms), and sampled successful
receive decoding/authentication is below 1.1/3.8 ms. These short local boundaries
do not prove that all earlier transport queues were short or that unmatched
cells were permanently lost.

Paired samples of identical encrypted UDP bytes during the P2P audio period
place substantial delay after Mac `try_send` succeeds and before the Android
kernel receive timestamp. Of 440 pairs, p95 excess above the fastest observed
arrival is 281 ms and maximum excess is 1923 ms; Android kernel-to-poll maximum
is 3.94 ms. The camera period has 480 pairs, maximum excess 389 ms and
kernel-to-poll maximum 2.51 ms. Reverse audio has 436 pairs with maximum excess
1510 ms, but Mac has no valid kernel receive timestamp, so its poll scheduling
cannot be separated from path delay. Pairing is encrypted-byte sampling on
active connections, which also carry controls; individual UDP packets are not
proved to be audio. Receiver timestamps can be coalesced by GRO. Wall-clock
one-way values are not reported as absolute latency: post-test calibration
bounds Poco-minus-Mac offset at -126.93..-84.23 ms but cannot establish an
unchanged offset throughout earlier calls. Excess delay assumes approximately
constant offset over the observation. The localized forward interval includes
Mac kernel/driver queues, Wi-Fi, Internet/NAT and phone radio arrival. It does
not identify a carrier, modem, OS or relay as the sole cause.

A further 120-second Mac-to-Poco P2P audio call with an own 2-MiB attachment
remains active throughout. Final native interruptions are Mac 8/2182 ms and
Poco 1/213 ms; audio RTP admission maximum is 0 ms on both endpoints. The
attachment is offered but its initial 120-second encrypted-download observer
times out, with several direct-stream writes stalling after 6758 bytes and
chunk retries verifying 3/8 pieces near call completion. This is not proof of
permanent loss or a successful mixed-file gate. The harness initially calls
an invalid cancel path; a separate owned stand uses `/download_cancel` and
verifies that this exact content ID is absent from durable pending downloads.

An independent 2-MiB encrypted-download control without any call completes
all eight verified pieces approximately ten seconds after the offer. Reliable
source admission is visibly paced during the voice run. The existing shared
endpoint allowance under source pressure is 1024 wire bytes per 200 ms; even
an ideal 2-MiB payload cannot finish in 120 seconds at that ceiling. Retries,
envelope overhead and other local producers cost additional allowance. A
short observer timeout therefore must not be classified as a new permanent
transfer failure solely from this run. The longer-observer repeat below tests
completion after voice ends without removing the audio guard or increasing
relay priority.

The longer-observer repeat (`load2354retry`) reaches ringing/active in
0.465/1.168 s and remains P2P/active for the requested 120 seconds. Final native
interruptions are Mac 10/6363 ms and Poco 10/5321 ms, with RTP admission maximum
0/2 ms. The encrypted-file observer nevertheless times out after 240 seconds,
including roughly two minutes after call hangup. Four of eight pieces verify;
there is no COMPLETE event. Later stream attempts repeatedly fail to obtain a
manifest, and a retry-open eventually becomes unavailable. Source-admission
traces return to `primary_active=false` after the call, so persistent source
pressure alone does not explain the whole post-call failure. The earlier
120-second observer was insufficient to establish a cause; extending it does
not cure this physical transfer. The own transfer is cancelled successfully
through the correct endpoint. There is no successful checksum/mixed-file gate
for this repeat, and its root cause remains open.

Every stand ends with owned Mac/logcat/helper processes absent, Poco app/UID
processes absent, ADB forwarding removed, trace disabled and the owned Mac
bundle's strict seal valid. A fresh process check after the final stand also
passes. Captures, credentials, peer IDs, addresses and timing fingerprints stay
in the restricted private scratch directory. This cycle changes only this
evidence record, not relay scheduling, production media tuning or user network
policy. Audio pauses, persistent video suppression, encoded screen coexistence
and the incomplete mixed-file transfer remain unresolved; the goal is active.

### Healthy DTX control and Apple UDP receive boundary — 2026-10-08

SDK 00d4cce7 extends the real Opus silence regression to inspect both native
playout delay and current packet buffer through ten seconds of DTX, then time
the first decoded resumed tone. A fresh test-only Mac media library from the
unchanged production engine passes: 57 silence RTP packets, maximum receive
age 391 ms, filtered delay 40 ms, current buffer 46 ms and resumed PCM at 100 ms.
There is no added concealment or interruption. The gate requires both gauges
below 120 ms and actual resumed PCM below 160 ms, in addition to the existing
DTX/activity checks. This excludes normal silence on a healthy controlled path
as the explanation for the persistent physical video pause; it does not prove
that cellular audio/video quality is fixed. No native media tuning changes.

Mac previously reported unknown kernel receipt time, preventing separation of
reverse network delay from receive polling. The SDK now opts Apple UDP sockets
into SO_TIMESTAMP only while the existing local trace is enabled, decodes
SCM_TIMESTAMP's Unix timeval safely into nanoseconds with microsecond precision,
and disables the option when tracing stops. Missing or unsupported metadata
stays unknown; no role/priority is added to wire traffic or relay scheduling.
Real IPv4/IPv6 socket tests deliberately delay the reader by 40 ms and verify
that the timestamp precedes that delay, payload stays intact, and off/on/off
tracing produces absent/present/absent metadata. Both standard and fast Apple
UDP backends pass eight tests, with one existing ignored test each.

A bounded, PID-filtered interface capture script is prepared in the private
scratch directory. Opening BPF needs administrator access unavailable to the
agent, so an optional manual capture request is pending. The conditional stand
warms normally but skips its call because no capture is ready; cleanup verifies
owned app/helper and Poco package processes absent and forwarding removed.
No privileged capture occurred. The new SDK diagnostics are committed and the
source pin updated here; installed phone/stand still use frozen build 2354 until
new native production artifacts are compiled and packaged. The goal remains
active: physical audio pauses and mixed media/file quality remain unverified.

The Mac production SDK then builds successfully with the standard embedded,
production-seeds, packet-tunnel and tls-boring feature set. The owned ad-hoc
Mac stand is packaged as 0.13.84+2359 from the committed source; Dart image
version and strict seal verify. Poco remains frozen 2354/SDK 9e247eec, whose
Android timestamp diagnostic already exists. No phone installation or network
policy change is needed for this Mac-only addition.

A new 90-second cellular Poco-to-Mac audio call (`kernel2359`) keeps normal
selection, actually remains P2P, rings after 2.605 s and becomes active after
3.752 s. It stays active for the full requested duration. Native telemetry
still fails audio quality: final Mac 23 interruptions/12294 ms, Poco
14/6604 ms, delay estimates 372/460 ms and RTP admission maximum 0/1 ms.
No video/screen/file is sent in this latency-boundary control; it is not a
mixed-media quality gate.

The new Apple receipt metadata works in the real embedded runtime. All 999
sampled UDP receive observations on each endpoint have nonzero kernel stamps.
During the interior primary-source windows, 397 unique encrypted-byte pairs
Mac-to-Poco have maximum arrival excess above the fastest pair 2121 ms
(p95 262 ms); kernel-to-logged-read maximum is 9.276 ms. The reverse has
492 unique pairs with maximum arrival excess 1118 ms (p95 528 ms) and
kernel-to-logged-read maximum 1.289 ms. No nonunique pairs or unknown receipt
stamps occur in these matched samples. Read timestamps are logged in whole
milliseconds, so small negative submillisecond differences are quantization,
not negative queue latency. Generic UDP pairs include controls and cannot all
be labelled audio packets. Observed excess is after successful sender socket
handoff and before receiver kernel receipt, on both legs, rather than in the
measured receive polling. It still includes sender kernel/driver queues and
both physical network paths; it does not prove an individual carrier/modem or
all possible application queues are the cause.

Phone wall-clock calibration now brackets the call both before and after:
Poco-minus-Mac intervals -101.75..-67.66 and -103.40..-63.89 ms respectively.
They overlap; they do not rule out a clock step between observations. Reported
arrival excess assumes approximately constant offset, and raw one-way wall
values are not treated as exact latency. Captures/correlation tags remain
private. The final controller and fresh follow-up checks verify apps/helpers,
Poco package processes and ADB forwards absent; strict Mac seal still passes.
The optional privileged interface capture remains unexecuted. These new
boundaries refine the next investigation; source priority/segregation still
needs successful physical encoded video/screen/file coexistence evidence,
and no elimination of the physical audio pauses is claimed.

### Independent endpoint stream admission (2026-10-08, probe 2360)

The IPC remote stream writer had one pending reliable write for the entire
client. A stream waiting for capacity in the middle of a segmented write kept
independent streams, including streams to other peers, behind that admission.
It did not hold the IPC read loop, but it serialized unrelated reliable source
interactions. A regression commits a first segment, blocks the second, and
requests two other streams: the original implementation fails the 200 ms gate.

The writer now owns at most one admission future per stream and polls these
independently in rotation. The existing per-stream write window and client
stream cap bound queued bytes and active futures. Data and close retain each
stream's FIFO. Select cancellation retains partially committed admissions;
cancelling one stream drops only its queued and pending work. No tasks are
spawned and no application role or scheduling priority is added on the wire.
This removes an endpoint queue dependency; ordinary reliable bytes still use
their canonical ordered session transport and this is not evidence of a new
separate physical connection for them.

The new regression verifies independent completion and exact reconstruction of
the delayed file, with no duplicate prefix and a final close after data. A
second gate cancels one of two partial writes, reuses its local id with a new
route, and verifies the surviving stream and absence of stale data/close. A
real Unix IPC socket test verifies another peer's write and exact StreamWindow
credit return while the first admission remains blocked. The complete default
veil-ipc suite passes 148 tests, with five existing ignored tests and one
existing ignored doc-test. These are controlled endpoint tests, not a new
physical mixed-media quality pass; installed phone and stand are unchanged.

The earlier `load2354retry` sender log also contains 30-second payload write
timeouts at source offset zero and at a resumed offset. Its serving code applies
that deadline to each full 256 KiB write, although the endpoint's pressured
background allowance is 1024 wire bytes per 200 ms. Even without overhead or
competition, 256 KiB needs 51.2 seconds at that allowance. The source offset
advances only when the whole write returns; it cannot show whether bytes were
progressing inside that interval. This exposes a mismatch between the claimed
write-idle bound and the actual whole-write deadline. A progress-aware deadline
still needs implementation and verification; the queue change alone is not
claimed to fix the earlier incomplete physical download. Persistent audio
pauses and zero encoded video in the camera probes also remain unresolved.

### Progress-aware bulk write idle (2026-10-08, probe 2361)

The production transport adapters now optionally expose local reliable write
admission progress. The SDK's direct and anonymous Dart stream wrappers send a
large write through one worker isolate and one allocation, invoking existing
native writes in bounded 2048-byte slices only when progress is requested.
Counts return to the caller isolate; no callback or Finalizable wrapper crosses
into the worker. The stream write gate covers the whole original write, and
anonymous FIN shares that gate, preventing another write or FIN from interleaving
the slices. The default write path retains its single native call. Errors stop
at the accepted prefix. This changes neither the native ABI nor wire priorities,
and these counts do not acknowledge peer receipt.

Content serving uses a 30-second deadline since the last newly admitted bytes
instead of a 30-second deadline for the entire 256 KiB block. Repeated, stale
or out-of-range counts cannot renew the deadline. The existing failure path
still aborts the stream; late results cannot restart the timer, complete twice
or escape as an unhandled write error. A transport without progress support
keeps the prior bounded whole-write fallback.

Four fake-clock gates cover a progressing 75-second write, a stalled write with
invalid/repeated counts, late worker failure, legacy fallback, and preservation
of the actual write error. Together with the existing content stream transfer
tests, 53 tests pass. A test-only C FFI boundary separately holds native writes
until the Dart event loop permits them: both direct and anonymous progress
writes preserve the exact rolling byte checksum and total, leave the event
loop responsive, emit intermediate monotonic counts, and keep FIN after data.
Injected native failure after a prefix neither sends nor reports the suffix.
The original blocked-worker/FIFO probe also passes. Targeted analysis is clean.

Poco is absent from ADB at this point, so the new large-write behavior has not
yet been verified during a physical cellular call. No app instances were
launched for these gates. SDK and application changes are committed locally;
no signing, push or release is requested for this cycle. Physical audio pauses,
encoded video/screen coexistence, and full connection separation of ordinary
reliable traffic remain outstanding; the goal remains active.

The standard embedded production SDK builds successfully with node-embedded,
production-seeds, packet-tunnel and tls-boring. The owned Mac ad-hoc stand is
prepared as 0.13.84+2362 from the committed changes, with the existing production
native media library unchanged. Its Dart image version and strict bundle seal
verify. Fresh process checks find no owned stand or SDK write-probe processes.
ADB still lists no devices; no physical call or phone installation is performed
in this cycle. The 2 KiB progress cadence matches a single SDK STREAM_DATA chunk
and its native byte/FIFO/failure gates pass after the final cadence adjustment.

### Cancellation of direct native stream I/O (2026-10-08, probe 2363)

Closing a direct FFI stream previously removed only its generational handle.
Calls that had already cloned the stream retained its Arc and could remain
parked in a read, write, or either half's mutex indefinitely. Consequently a
timed-out background transfer could keep its native worker and stream resources
after the application's abort path. When the last Arc did finally leave on a
foreign FFI thread, SdkStream::Drop also skipped STREAM_CLOSE because that thread
had no Tokio context, leaving the peer-side stream until later cleanup.

Each direct FFI stream now retains a local close signal. Closing the handle
wakes both halves, including mutex waiters, and a call entering its runtime
after close observes the retained signal before admitting even ready I/O. These
in-flight calls return the existing closed error. The final stream destructor
drops both SDK halves under their own runtime, allowing the existing close
frame to be sent. No new FFI function, wire field, relay priority or dependency
is introduced. Anonymous streams already have their explicit abort handle and
are unchanged by this native fix.

The regression uses the real C entry points, SDK and Unix IPC server. One writer
exhausts its negotiated source credit, another waits for its mutex, and two
readers wait for data/mutex. The old code fails: close leaves those calls waiting
for network activity. With the fix all four calls and their last Arc stop within
the 250 ms gate before any source permits or peer data are released. Another
stream of the same client stays alive and successfully receives its data. After
the controlled source is released, the peer sees the neutral background close
and removes that stream's bridge entry. Both success and the negative control
join their workers and shut down the temporary server.

A separate race gate closes before any cancellation subscription exists and
verifies that a ready operation cannot admit bytes afterwards. The default FFI
suite passes 127 tests before that additional gate; the final complete suite
with node-embedded, production-seeds, packet-tunnel and tls-boring passes 246
tests with two existing ignored tests and five existing ignored doc-tests.
Header regeneration leaves the C header and both ABI contracts byte-identical
(56397b1da476491a…). No regression process remains. Changes are committed
locally and the source pin is updated here. Poco remains absent from ADB;
cellular audio/video and full mixed-media coexistence are still unverified, and
the goal remains active.

### Physical cellular checks after Poco reconnects (2026-10-08, build 2363)

Poco returns on cellular data. Both owned endpoints now use SDK 39168872 and
application 0.13.84+2363. The Android APK retains its previous certificate;
packaged native SDK/media bytes match independently stripped build references.
Production media libraries remain unchanged (Mac 2325, Android 2326). Installation
uses an update, preserving the phone's identity and encrypted storage. The owned
Mac stand's Dart version and strict bundle seal verify.

Three bounded calls use the normally selected route and finally clean up their
owned processes. The first two checks temporarily register existing runtime
peers and warm discovery; their setup times therefore describe a prepared stand.
The third omits that registration and the attachment.

* Audio plus a 2 MiB attachment: ring 0.388 s, both active 1.593 s; the call
  survives 120 seconds. Its route starts on P2P and later repairs through relay.
  The encrypted download completes all eight validated pieces in 146.792 s from
  offering the file, after call hangup. Direct retries and an IPC writer closure
  still occur; anonymous stream retries encounter the accepted-contact/grant
  check and fall back to encrypted chunk delivery. This establishes eventual
  completion in this run, with substantial recovery cost.
* Camera plus another 2 MiB attachment: ring 0.386 s, both active 2.046 s; the
  call survives 90 seconds on P2P. Both cameras are enabled, but native video
  send remains paused and encoded-frame counts stay zero while the microphones
  are enabled. At 71.959 s both microphones are explicitly disabled for a
  diagnostic phase. Encoding starts around 72.9/73.2 s: Mac sends 30 frames and
  receives 22; Poco sends 25 and delivers 20, with 19 decoded texture frames
  observed. The camera/encoder/video path works when audio expectations are
  withdrawn. This phase establishes no simultaneous healthy audio/video result.
  The attachment completes in 140.337 s; its materialized destination is exactly
  2 MiB and its SHA-256 matches the source. The owned plaintext phone scratch
  file is removed after verification.
* Audio without attachment or manual peer registration: ring 1.512 s, both
  active 2.439 s; the call survives 90 seconds on P2P. Receive-stream playout
  counters still report Mac 8 interruptions / 5718 ms and Poco 14 / 7929 ms.
  Pauses therefore reproduce without the attachment or that preparation step.

In the last call, deterministic encrypted UDP sampling matches 440 unique
Mac-to-Poco packets and 359 Poco-to-Mac packets during the active window. At
constant clock offset, excess delay above each direction's minimum reaches
1081/1805 ms (p95 130/508 ms). Receiver kernel timestamp to socket-read trace
maxima are 12.962/0.919 ms; sampled SDK delivery age maxima are 0.524/3.086 ms.
These are generic encrypted UDP observations, including control traffic, and
the minimum-relative calculation is not an absolute acoustic latency. Bounded
ADB clock calibrations before and after overlap; a transient clock step inside
the call is not excluded. The measured large packet delays lie after successful
sender UDP admission and before receiver kernel receipt. Sender kernel/driver,
host Wi-Fi, Internet/NAT and the cellular leg remain within that interval; the
measurement does not identify one of them as the sole cause.

The complete file checks verify progress and recovery after the recent stream
queue/idle/cancellation changes. Physical audio pauses, simultaneous encoded
audio/video/screen operation and separation of ordinary reliable traffic still
require work. Repeated anonymous content-stream authorization failures also
remain: a claimed anonymous opener cannot acquire an identity mapping simply
because it requested a known content ID. The goal remains active.

Each call's cleanup verifies zero owned Mac/helper processes, zero phone
package/UID processes and removal of its ADB forwarding. Fresh final checks
confirm the installed phone package is versionCode 2363, the owned stand is
stopped, its strict bundle seal is valid, and no live stand resource record
remains. User applications and the default VM are untouched.

### Retiring stale partial ordered records (2026-10-08, SDK 37c76eb3)

The independent TCP record plane previously allowed a partial write/flush to
hold its child for 30 seconds. Its explicit local deadline skipped a record
only before the first byte, and records without a deadline had no queue-age
bound. Consequently stale data could retain a source slot despite the existing
200 ms receive residence limit.

Every outgoing loss-tolerant record now has the same 200 ms maximum lifetime
from admission, including its queue time. A caller's tighter deadline remains
effective. Before any byte is accepted, expiry skips that record and keeps the
connection usable. After progress, expiry cancels the complete child, wakes its
reader and releases queued credits; subsequent framing never follows a partial
record. Buffered plaintext acceptance also retains the deadline through flush.
The normal source pool observes the closed child and replaces its authenticated
connection. Producer roles and deadlines are absent from proofs and framing;
relay admission remains neutral. Ordinary reliable application bytes continue
through their reliable transport.

Two new gates fail against the previous source. The final transport suite passes
144 tests, including 13 record tests; its five obfs4 integration tests and two
doc-tests also pass. The session suite passes 446 tests with six existing
ignores and one existing ignored doc-test. A new real-obfs4 regression verifies
the expiry of a partially admitted record, remote I/O closure, lease reclamation,
fresh exporter-bound replacement and surviving sibling/canonical traffic.
Existing normal-runner key rotation and exact reliable-file tests pass.

On the actual Poco, 32 ARM checks pass: 13 records, six bindings, ten shared
registry tests and three normal receiver tests. Temporary executables and their
private directory are removed; no test helper or app process remains. Production
embedded FFI builds succeed for macOS (with tls-boring) and Android (its usual
pure Rust TLS). The ABI and wire framing remain unchanged. Physical cellular
audio pauses and the full requested interaction separation remain outstanding;
these gates establish bounded child lifetime and isolation, not acoustic quality.

Both application artifacts are updated to 0.13.84+2364. The phone APK's native
SDK matches an independently stripped production build, its certificate matches
2363, and packaged media/hidden-volume libraries are byte-identical to 2363.
The update preserves application data. The owned Mac stand's Dart version and
strict seal verify. A bounded boot check unlocks both existing profiles and
observes ready native stacks; lsof confirms the Mac loads its bundled fresh SDK.
The phone's installed versionCode is 2364. No call is made in this final boot
check. Cleanup verifies stopped apps/helpers and removed ADB forwarding; the
Mac strict seal remains valid after removing its generated debug log.


### Showing the audio reserve in the call UI (2026-10-08, build 2365)

A two-minute physical Mac/Poco video call on build 2364 reproduces the unresolved
quality issue without a concurrent file transfer. Ringing begins at 0.843 s and
both endpoints are active at 3.189 s. Both microphones and cameras remain enabled.
The call automatically changes from P2P to relay around 69 s without changing its
media epoch. Sampled interruption maxima are 20 / 20,182 ms on Mac and
22 / 17,553 ms on Poco. Native accepted-audio ages peak at 2,837 / 3,008 ms,
and native receive-delay estimates at 830 / 2,667 ms. These are native buffering
and continuity measurements, not acoustic end-to-end latency or attribution to a
carrier. Source RTP admission maxima are 0 / 4 ms, with no source RTP drops.
Both encoders produce zero video frames: the existing audio reserve keeps their
senders paused. No diagnostic microphone mute or forced video override is used.
The final cleanup confirms no owned app/helper processes or forwarding remain.

The direct-call UI previously hid this automatic pause unless the independent,
dismissible weak-link suggestion was raised. It now shows a live localized status
explaining that video transmission resumes automatically once audio is stable;
camera/screen capture remains enabled. The status follows accepted native pause
and resume controls, retains its preceding value when a worker rejects a change,
and is cleared when the media session stops. Capture-off hides it. Dismissing the
optional suggestion cannot hide an ongoing reserve. This is local UI state;
no extra protocol field or relay priority is introduced.

The focused call/UI/quality/service suite passes 225 tests. Four new widget cases
cover live pause/resume, dismissal independence, capture-off, and narrow Russian
layout. Two pre-existing audio-feedback fixtures still expected recovery at
140 ms and delayed degradation; their assertions are updated to the already
implemented <120 ms recovery and immediate pause policy. The stale/replayed sample
case now uses genuinely healthy feedback before breaking the recovery streak.
Production adaptation thresholds are unchanged. Targeted Dart analysis and
whitespace validation pass. APK and owned Mac stand builds 0.13.84+2365 succeed;
the Poco update preserves data and signing identity, and its SDK/media/hidden-volume
libraries are byte-identical to 2364.

A subsequent 35-second physical video call on 2365 starts ringing at 0.416 s
and is active on both endpoints at 2.167 s. Authenticated UI trees on both Mac
and Poco contain the new pause status while both microphones/cameras remain on;
each endpoint's local diagnostic pause flag agrees with native video_send_paused.
The phone retains Wi-Fi off, mobile data on, and its default route is cellular.
Owned app/helper processes and ADB forwarding are absent after teardown, and the
Mac strict bundle seal verifies. This validates the UI fix and installation;
physical audio pauses and healthy simultaneous encoded video remain unresolved.
Separation of ordinary reliable traffic also remains outstanding.


### Lossless auxiliary record foundation (2026-10-08, SDK c67915f6)

Ordinary reliable application traffic still shares its canonical ordered
connection; the 200-ms loss-tolerant child codec cannot safely replace it.
A separate `reliable_records` primitive now supplies lossless FIFO framing for
an independently authenticated byte stream. Each direction has 64 KiB of byte
credits and a 128-record queue bound. Reads reserve credits before allocation;
a slow consumer backpressures only this connection. Records have no expiry or
eviction. Sender completion follows the complete write and flush, with credits
retained throughout buffered plaintext acceptance. Cancelling an admitted send
does not insert a new prefix into its partial record. Completed incoming records
remain readable after transport EOF/error; owner retirement discards them and
wakes pending admissions/reads/writes.

The reliable binding uses a distinct generic encrypted preface (`VPAUX002`) and
separate hello/ACK/key/session-id domains. Proofs retain fresh transport exporter
binding and canonical-parent lifetime. A lossy proof cannot be reinterpreted as
reliable or vice versa, including preface tampering; record constructors reject
credentials of the other mode. New wrappers reject admission and queued delivery
once the parent retires. Producer roles, priority requests and slot numbers are
absent from both proof and record framing. Existing VPAUX001 domains and the
current capabilities advertisement remain unchanged.

A first actual QUIC test demonstrated that dropping a child byte stream alone
leaves its real connection and quota watcher alive when raw clones are retained.
The reliable QUIC constructor now verifies the actual child's exporter and owns
its complete transport. Owner drop, parent retirement or I/O failure closes that
child. The regression now passes with retained raw clones, reclaimed quota and
surviving canonical datagrams; an unrelated parent handle is rejected without
closing that parent.

Nine transport gates cover exact 256-KiB FIFO recovery after a three-second
consumer stall, bounded credits, cancelled partial writes, completion only after
flush, EOF-tail delivery, malformed/truncated records, owner retirement and
independent sibling I/O. Five new binding gates cover mode/authentication
separation, immediate retirement, 128 exact encrypted AppData frames on actual
obfs4/TCP after a 500-ms receive pause, and actual QUIC cleanup. AppData sequence
is zero as in the current IPC stream path; ciphertext and byte order remain exact.
The host suites before the final QUIC ownership refinement pass 450 session tests
(with six existing ignores), 153 transport tests, five obfs4 integration tests and
two transport doc-tests. All 11 binding tests (six existing, five new) pass after
the final refinement. The new QUIC ownership gate failed before the refinement.

The final ARM executables pass 20 checks on Poco: nine records and 11 bindings.
Compilation postdates all relevant source changes, and executables contain the
new gate names. Helpers have exited, their private phone directory is removed,
and the phone app remains closed. No stand app is started in this cycle. The
installed 2365 application and its native libraries are not replaced.

This is a prerequisite, not live application routing: the shared-listener
registry, negotiated capability, normal-runner stream ownership/FIFO/rekey/error
handling and source scheduling still need integration before ordinary files or
requests may use these channels. No reliable traffic is moved onto the expiring
record plane. Physical call pauses, healthy audio/video coexistence and complete
interaction separation remain unresolved; the original goal stays active.

### Lossless shared-listener admission and frame ownership (2026-10-09, SDK 683f4254)

The existing shared-listener dispatcher now recognizes VPAUX002 on QUIC and
ordered transports. Its canonical-parent registration has an optional reliable
inbox: without an explicit owner opt-in, the child receives no ACK and closes.
The old loss-tolerant inbox never receives reliable children. Opt-in shares the
same parent, registration token, per-peer transport quota and retirement;
it creates no identity row. The verified child waits for its canonical owner to
finish ACK/flush. The resulting owner retains both reliable I/O and the actual
QUIC connection or TCP accounting lease. Queue rejection, cancellation and
retirement close/reclaim children while canonical traffic survives.

`ReliableFrameChannel` owns a dedicated TX cipher and a bounded plaintext FIFO
(64 KiB, at most 64 queued frames). Producers admit complete `FrameEnvelope`s;
one writer encrypts only after admission has committed. Dropping a completion
receipt never retracts sealed bytes or burns a nonce without delivery. A full
queue returns the original envelope, including its endpoint source credit.
Both byte and source credits survive buffered transport acceptance until the
complete write/flush. Receivers serialize their RX cipher across cancellation-safe
record consumption and synchronous authentication. Malformed or altered frames
fail the child; transport EOF preserves completed authenticated receive records,
whereas explicit owner retirement discards them. New admissions check canonical
authority synchronously before any retirement watcher has to run. All scheduling
metadata remains local; no audio/video role, priority request or deadline is added
to proofs, records or OVL1 headers.

Fifteen shared-listener tests cover both transport types, including an actual
obfs4/TCP AppOpen, 64 exact AppData chunks (256 KiB, sequence zero), and AppClose
after a 500-ms consumer pause. Nine frame-owner tests cover cancelled receipts,
32 concurrent producers, bounded admission without nonce gaps, cancelled receive,
malformed plaintext, authenticated header alteration, retained-handle retirement,
EOF-tail delivery and source-credit retention through a controlled flush stall.
The final host session suite passes 465 tests with six existing ignores; the
unchanged transport suite passes 153 tests, five obfs4 integration tests and two
doc-tests. Final ARM executables postdate all modified sources and contain the new
test markers. On Poco, nine frame-owner, fifteen registry and eleven binding tests
pass (35 total). The owned helper exited and its private directory was removed;
the phone app remained closed, and no Mac stand was launched in this cycle.

The installed 2365 applications/native libraries remain unchanged. Capability
advertisement and normal-runner stream selection are not enabled yet. Before
activation, integration must pin each complete App stream to one carrier, carry
responses on that same child, preserve source admission, and explicitly abort
affected streams on child failure/rekey. A full canonical writer must not prevent
independent child admission. The existing six generic children plus a reliable
child must also preserve replacement capacity. Physical call pauses and healthy
simultaneous audio/video remain unresolved; these gates do not establish an
improvement in real cellular calls. The original goal remains active.

### Canonical-owned reliable duplex pool (2026-10-09, SDK 66b1f655)

`ParallelSession` and `OrderedSession` now optionally own one duplex reliable
child alongside their existing source and neutral children. The trusted offer's
`with_reliable()` opts the same registration into its reliable inbox; its default
is false. Shared QUIC/TCP listeners use the existing registry, while exclusively
owned punched QUIC accepts classify reliable proofs before the old datagram
receiver. The original transport dialer alone establishes the reliable child;
the accepted endpoint uses its duplex return path. This avoids trying to dial a
TCP client's source port or a QUIC client endpoint without a server listener.
The child handshake uses its actual fresh exporter, flushes hello/ACK, and retains
transport/accounting ownership through failure or cancelled binding.

Every peer has the same eight generic connection slots per direction on both
transport types: six existing children, one reliable child, and one replacement.
The two direction partitions remain separate. No audio/video label, scheduling
request or client-specific privilege is added. A compile-time assertion preserves
replacement capacity. The ordered pool gate observes all seven normal children
live simultaneously with exactly one outgoing slot still available.

The worker publishes an owned readiness snapshot with a child generation ID.
Its cancellation-safe `next()` returns authenticated frames/read errors with that
ID, readiness changes, or a terminal `Stopped` event. Ordinary child EOF retains
its completed receive tail until the canonical reader explicitly acknowledges
failure; reconnect cannot silently discard queued frames or move an existing
stream onto new keys. Session drop/rekey closes retained snapshots and replaces
the pool under a new parent. Binding retries are bounded and back off, with only
one handshake attempt and one incoming candidate at a time.

An adversarial lifetime gate caught a defect in the intermediate worker: clearing
the readiness owner before retiring externally retained snapshots left a queued
authenticated frame readable after the actual canonical TCP owner ended. The
gate first failed, then passed after retirement moved before publication cleanup.
It waits for the record reader's actual received counter before closing the
canonical transport; it does not assume a sleep proves queued data. Worker exit
and panic cleanup also close snapshots before publishing an empty state.

Four actual-I/O pool gates exercise normal ordered-session construction, seven
concurrent children/replacement capacity, duplex data, rekey and fresh child IDs,
EOF-tail recovery and explicit failure acknowledgement, exclusive punched QUIC
acceptance, actual quota reclamation and canonical stream survival. The final
host suites pass 469 session tests (six existing ignores), 153 transport tests,
five obfs4 integrations and two transport doc-tests. Final ARM executables
postdate the last source changes. Poco passes four pool, nine frame-owner,
fifteen registry, eleven binding, five stream-transport and two QUIC-accept tests
(46 total). The transport helper originally expected four stream tests; its
counter assertion failed after all five native tests passed. The remaining two
QUIC gates then ran separately and passed. Both private helper directories were
removed and helpers/app processes are absent. No Mac stand or app install occurs
in this cycle; installed applications/native libraries remain build 2365.

This completes pool lifetime integration, not activation in normal application
traffic. New capability advertisement/negotiation and the canonical runner's
complete-stream selection, reply routing, failure/rekey aborts, byte reservations
and independent admission while its old writer is full still need integration.
The offer remains disabled in production until those paths are implemented and
verified. Real cellular audio pauses and simultaneous healthy audio/video remain
unresolved; no physical call improvement is claimed. The original goal is active.


### Normal-runner reliable App streams (2026-10-09, SDK ad284ea8)

The canonical `SessionRunner` now selects one carrier at AppOpen admission and
pins the whole App stream to that canonical connection or one authenticated
reliable child generation. Open/data/receipt/close and window updates cannot
change carriers midway through a stream. A failed child leaves a bounded
ownership tombstone: queued old data is never replayed on the canonical
connection or a replacement child's keys. Streams opened before readiness remain
canonical. The ownership map is bounded to 1,024 stream IDs per session.

The scheduler reserves both actor bytes and queue capacity before popping
plaintext. Cancelling an unused reservation returns credits without publishing
anything or consuming a nonce. Parent retirement rejects retained reservations
synchronously. A full canonical writer defers its own heads while allowing
eligible App source heads to enter the child. Endpoint source admission remains
in force; no remote priority, application role or relay privilege is added.

Incoming child frames use the normal authenticated peer and app dispatcher.
Responses stay plaintext in a bounded FIFO (512 entries / 64 KiB) until the
child writer and endpoint bandwidth admission allow commitment. A full writer
or temporary bandwidth denial leaves the reply queued and does not consume a
nonce. RX continues while replies wait, rather than stopping both sides of a
duplex transfer behind their TX writers. Resource exhaustion fails the child
explicitly. Child TX/RX and replies count toward parent rekey thresholds and
transport accounting without using the canonical connection's cipher.

Trusted teardown bypasses remote rate limits to release stream-table entries,
IPC receive senders and pending Open/Close receipt waiters. Endpoint close
notifications occur only for still-active streams; waiter cleanup also runs for
already-closed streams. An incoming close is not locally complete until the
normal dispatcher accepts it. An outgoing close remains abortable until a
remote acceptance arrives. Window-update body stream IDs use the same stored
carrier even when their header stream ID is zero; conflicting IDs are rejected.

Two real obfs4/TCP integration gates drive normal runners, independent frame
ciphers and real app dispatchers in both directions. They transfer ordered
2-KiB chunks without duplicates and carry Open/Close receipts on the child.
Each canonical writer is blocked on actual I/O and receives 400 queued 16-KiB
frames. A local admission counter proves the child accepts while that writer's
queue has zero capacity; a sleep or connection count alone is not the witness.
Aborting a runner releases pending receipts, closes IPC readers and produces
one endpoint close per active stream. Unit gates cover sticky carrier ownership,
scope changes, replacement/rekey tombstones, close completion, window updates,
reply bounds and actual encrypted reply recovery after byte-credit saturation.

The host selected gates pass 61 session tests (two existing ignores) and six
runner integrations, including four existing opaque-datagram backlog checks.
The full session suite passes 479 tests (six existing ignores); two ordered
DATAGRAM and four endpoint source-budget integration regressions also pass.
The strengthened zero-capacity writer witness passes both new integration gates.
The final ARM test executable postdates the final source changes. Poco passes
four actual-I/O pool, eleven frame-owner and eight stream/reply tests (23 total).
The owned native helper exits, its private directory is removed and the app
remains stopped. CodeGraph cannot resolve this new path with the missing
rust-analyzer toolchain; conclusions are checked against the focused sources
and executable gates, not inferred from its empty graph slice.

A separate physical 90-second Mac/Poco video call uses installed build 2365;
it does not contain this new runner integration. Poco stays on cellular data
with Wi-Fi off. Ringing takes 409 ms and both endpoints become active at 2.354 s.
Both microphones and cameras are on, but encoded video TX/RX frames stay zero:
the automatic audio protection pauses video. The increasing video-labelled
queue counters are RTCP packets, not encoded video frames. Native statistics
report 9 audio interruptions / 18,300 ms on Mac and 19 / 29,968 ms on Poco;
maximum receive audio buffer delay is 675 / 550 ms. These are sampled native
counters, not acoustic end-to-end latency measurements. Both owned app instances
are hung up, locked and stopped; their processes and the ADB forward are absent,
and the Mac stand bundle seal verifies. Applications are not upgraded here.

Capability advertisement/negotiation and actual normal-runner rekey/crash
integration gates remain before production activation and updated physical
file/call tests. `with_reliable()` remains opt-in; production offers remain off.
Video recovery and cellular audio interruptions remain unresolved. The original
quality/isolation goal remains active.


### Reliable carrier capability activation (2026-10-09)

The marked capability extension now uses its remaining bit, bit 7, for generic
`SUPPORTS_RELIABLE_PARALLEL`. The helper requires explicit parent ordered-codec
or QUIC-duplex support plus coordinated rekey. The shared local advertisement
factory includes it in full and resumed handshakes; legacy resumes without
fresh authenticated metadata still expose no extra permissions. A resume gate
flips bit 7 and confirms the capability MAC rejects the change. Legacy prefixes,
random padding and old loss-tolerant capability bits alone cannot enable it.
No audio/video label, deadline, relay priority or client privilege is advertised.

Node runtime derives this permission from authenticated remote capabilities.
Ordered offers opt in only with that permission; QUIC offers additionally
require the peer's duplex implementation and preserve shared-listener guards.
The unchanged eight-connection-per-direction generic quota applies equally to
all peers. A once-per-session local first-send log now proves an App source
actually enters a child, rather than merely observing a capability announcement.

A third normal-runner obfs4 integration gate releases both blocked canonical
writers after proving independent App transfer, completes the real canonical
rekey exchange, checks both endpoints abort old App streams and release receipt
waiters/readers, then opens fresh child streams and decrypts fresh data. It
attempts to send old stream data too; the receiver sees only the new stream.
The initial idle fixture failed to rekey because keepalive/idle timers are
intentionally disabled in these fixtures. Sending normal padding through the
canonical connection wakes the real loop to evaluate rekey age; no key or worker
state is replaced by the test. Backlog frames are now valid session padding.

All three normal-runner reliable integration gates pass. Twenty-five handshake
gates pass, including actual full and resumed exchanges with reliable permission
assertions. The final capability/admission selection passes one protocol and 62
session tests (two existing ignores). Node-runtime test targets compile, but the
`reliable` filter selects zero runtime tests; their compilation alone is not a
runtime behavioral claim. App builds/installation and actual audio/video/file
behavior remain the next verification step. The quality/isolation goal remains
active; cellular audio interruptions and automatic video recovery are not fixed
by declaring support.


The slow-IPC-reader integration found an additional lifecycle defect before app
installation: a dispatcher-generated AppClose was queued correctly, but its
stream pin did not record that it was closing. The returned acceptance therefore
left the pin active, and later session retirement generated a duplicate endpoint
close. Recording the response's carrier admission before queuing fixes this
without treating an unflushed close as complete. A fourth actual-TCP gate
receives duplex return data into a one-entry IPC channel, overflows it, verifies
the resulting child Close/receipt, preserves the already-completed reader tail,
then retires the runner and checks only its still-active stream emits a close.
The gate passes with the fix and fails on the old runner with the expected
extra-close assertion. All four integration gates and eight stream/reply unit
gates pass. Initial native libraries were built before this finding; they are
not installed and must be rebuilt from the final committed source.


### Installed reliable carrier and physical cellular checks (2026-10-09)

Private stand build 0.13.84+2370 contains SDK 890508d8 on the owned Mac
stand and Poco. The installed APK matches the signed artifact byte for byte;
its signer matches the prior installation, preserving application data. The
packaged SDK matches the fresh stripped native build. Media remains the prior
Mac 2325 / Android 2326 code, and hidden-volume is unchanged. The owned Mac
bundle passes strict seal verification. The Applications installation is not
replaced by this stand cycle.

The initial 90-second relay video call rings at 0.427 seconds and is active on
both ends at 2.218 seconds. Cameras and microphones are enabled. Automatic audio
protection keeps encoded video at zero. Native interruptions total 1 / 255 ms
on Mac and 4 / 1,249 ms on Poco; these are native counters, not acoustic latency.
A following relay call with a 2-MiB attachment fails its download after about
184 seconds, recording 10 / 8,607 ms and 21 / 20,322 ms of interruptions. No
first-child-send marker occurs in that initial session. Repeated App stream-open
code 6 means source admission failed; it does not alone distinguish absent
sessions from unavailable routed admission. No physical carrier-isolation or
quality success is claimed for that run.

After restarting the same installed builds, direct admission initially reports
false and subsequently becomes true after endpoint exchange settles. Both
endpoints then report live direct admission. A 32-KiB attachment completes in
1.59 seconds with a matching SHA-256. Each endpoint logs its first reliable-child
App send. Thus the new carrier is exercised physically, rather than merely
advertised. An ensuing video call rings at 0.410 seconds and both ends are active
at 1.339 seconds. A 2-MiB attachment completes in 149.651 seconds with matching
SHA-256, including time after the 100-second call ends. This is not a claim that
all of the file completed during the call.

That call starts on P2P and both ends switch to relay at about 49.65 seconds.
Video remains automatically paused, with zero encoded transmit/receive frames.
Native interruptions total 5 / 5,344 ms and 11 / 10,719 ms; maximum native receive
ages are 2,786 / 2,807 ms. Locally queued audio admission stays at 0 / 2 ms. The
physical quality goal therefore still fails. QUIC primary recovery starts near
39 seconds; on Poco its replacement authenticates, then is cancelled about six
milliseconds later on old-path ACK progress. Mac recovery candidates are also
cancelled repeatedly. These observations motivate inspecting replacement result
adoption; they do not establish that one race explains every audio interruption.

Both owned applications are hung up, locked, and stopped after each stand cycle.
Their processes, Poco package UID processes, and the owned ADB forward are absent;
the Mac seal verifies after removing its late stand debug log. Poco remains on
cellular with Wi-Fi off. No relay role/priority metadata or traffic privilege is
introduced. Audio quality and automatic video recovery remain unresolved.


### Verified primary replacement adoption race (2026-10-09)

`ParallelSession::prepare_frame` now polls/adopts a completed authenticated child
before evaluating ACK progress on the old sender. Previously the reverse order
could cancel even a candidate whose exporter-bound proof had already finished
and whose result was waiting in the oneshot. Still-pending candidates can be
cancelled on old-path recovery; failed candidates cannot displace a usable old
channel. No congestion state is reset on the old connection, no stale datagram
is replayed, and neutral transit cannot request primary recovery.

A real TLS/QUIC gate stages a completed exporter-authenticated replacement,
sends a valid datagram through the old child and waits for its real ACK, then
runs the production selection. The gate checks the replacement is adopted once,
its exporter differs, a fresh datagram arrives, and canonical stream bytes still
round-trip. Restoring the old ordering makes that gate fail with the expected
zero-versus-one replacement assertion; fixed source is restored byte for byte.
The final recovery selection passes six gates, including Cubic/BBR four-second
outage recovery, full-duplex source/shard capacity and source independence; one
pre-existing manual attribution gate remains ignored. This is a proven lifecycle
fix, not proof that physical cellular audio meets the quality target. Updated
stand installation and a new physical run follow.


### Follow-up stand 2371 and concurrently completed file cache (2026-10-09)

Stand 2371 packages SDK 07f2776f on Mac and Poco. The Mac native code matches
its fresh build, media/volume code is unchanged, and its strict seal passes.
The installed APK matches the signed artifact; its signer matches the actual
prior installation and its SDK bytes differ from that installation. Identities
and data are preserved.

Direct admission stays false at both endpoints through the pre-call wait, so
the next 100-second camera/microphone call uses relay throughout. Ring is at
0.417 seconds; both endpoints are active at 1.884 seconds. Native interruptions
are 0 / 0 ms on Mac and 6 / 1,447 ms on Poco; maximum native receive delay is
455 / 385 ms, maximum native receive age 911 / 517 ms. Video remains paused with
zero encoded frames. This cannot validate the fixed QUIC replacement race on
the phone, because this run has no direct session. It also cannot establish a
quality improvement over the different prior routes. The 2-MiB plaintext save
fails after 131.842 seconds. Both owned apps and the ADB forward are closed and
verified absent after the run.

The preceding 32-KiB plaintext save reports failure after 118.65 seconds. A
subsequent query finds the complete blob inside Poco's encrypted store; saving
that same blob again takes 0.596 seconds and its SHA-256 matches the source. Thus
this case is not loss of file bytes: background receipt succeeds while the
concurrent explicit save keeps retrying its unavailable stream and reports a
false failure. A stream retry now checks for the newly completed local blob,
aborts any still-owned initial stream and exports through the existing verified
store/sink path before opening another route. Cancellation and disposal are
checked again after awaiting the store/abort. Partial stored pieces are not a
complete blob and retain the existing range resume behavior.

The regression gate completes a local blob while the first remote stream emits
EOF, leaves further remote streams unusable, and requires byte-exact plaintext,
its saved-path completion event, one sink close, no failure event and no second
network open. It passes with the fix. Removing the check makes the gate time
out; fixed bytes are restored afterwards. Six focused stream/export lifecycle
gates pass, including cancellation, disposal, partial stored-piece resume and
plaintext range resume. Audio interruptions, native buffering delay, direct
route establishment and automatic video recovery remain open work.


Stand 2372 installs the concurrent-cache retry fix on Poco and the owned Mac
stand with SDK 07f2776f. Signed APK bytes match the actual installed package,
the signing identity is preserved, the native SDK matches its verified artifact,
and media/hidden-volume are unchanged. Mac native code matches the same SDK,
its Dart image carries 2372 and its seal verifies. No further native rebuild or
official release is performed for this Dart change.

A fresh 32-KiB physical attachment save fails after 99.34 seconds. Direct
admission is false and endpoint candidates are zero at both early snapshots;
Poco has one active session at the initial native snapshot. This run does not
prove that a usable local blob arrived during the save, so it cannot confirm the
cache-race fix physically, or classify this failure as that race. The successful
matching-hash cache export on 2371 and the deterministic failing-old/passing-new
host gate remain the evidence for the specific change. Network file delivery,
route discovery and audio quality remain unresolved. Both owned apps, their
processes and the owned ADB forward are verified absent after the final run;
Mac strict seal verification passes. Commits are unsigned and unpushed.

### Audio recovery after jitter followed by DTX — 2026-10-09

Veil 160e067d changes receiver-local NetEq reordering-history decay from the
WebRTC default 0.9993 to 0.95. Packet capacity remains 30, fast acceleration,
underrun-estimator configuration and Opus settings remain unchanged. This
changes neither transport scheduling nor any wire metadata or relay policy.

A new actual decoded-PCM gate injects the existing 40/300-ms jitter burst
between seconds two and four, then sends ten seconds of silence over the
recovered 40-ms path before resuming speech. The production baseline receives
57 DTX packets, has no additional concealed samples or interruptions during
silence, and has only 43 ms of current packet buffering; nevertheless its
filtered delay remains 202 ms and resumed speech takes 340 ms. The gate fails
with the old production media library. A private preferred-delay trace shows
the old target remains 280 ms through silence. Changing only the underrun
forget factor to 0.9 does not improve resumed PCM (still 340 ms); changing only
reordering decay to 0.95 does. This separates the responsible estimator from
ordinary DTX cadence and from the previously rejected capacity/flush changes.

The fixed production source passes all seven PCM scenarios: healthy DTX,
jitter followed by DTX, continuous speech under jitter, symmetric/asymmetric
channel handover, queued-delivery stall and delivery loss. The new scenario
resumes speech in 140 ms, ends silence with filtered delay at most 82 ms, and
adds no concealment or interruptions. Timer lateness is below 5 ms. An initial
run with 50.8-ms host timer lateness is discarded; its strict timing gate is
retained and the full repeat passes.

In a separate unchanged continuous-speech control, the 30-packet baseline's
five-second/seven-second decoded markers take 340/342 ms, versus 231/140 ms
with the change. Concealed samples are 20710 versus 20273, with the same two
interruptions and one buffer flush. These controlled results establish a
local audio recovery improvement; they do not yet establish physical cellular
call quality or successful automatic video recovery. Those require the next
stand installation and live Mac/Poco measurement.

Stand 2373 installs fresh production media on the owned Mac stand and Poco
without test exports (97 public media symbols on each platform). Mac media
code matches the independently built library, SDK code is unchanged, the Dart
image carries 2373 and the bundle seal verifies. Android media matches its
independently stripped artifact; SDK/hidden-volume are unchanged. The signer
matches the actual previous installed package, installed APK bytes match the
verified signed artifact, and existing app data is preserved. Poco's active
default transport is cellular with Wi-Fi off. The owned build VM is stopped
before the live test; the user's default VM is untouched.

The 90-second live video call rings after 0.633 seconds and becomes active on
both endpoints after 2.503 seconds, using relay throughout. Both microphones
and camera controls remain on. Mac/Poco native interruption maxima are 6/9,
lasting 2930/5006 ms. Filtered delay maxima are 499/529 ms; current audio
buffering reaches 569/531 ms, and receive age reaches 1185/1223 ms. Source
admission maxima are 0/2 ms; neither worker stalls. Automatic audio protection
keeps video paused throughout, with zero encoded or received video frames.
Thus this physical run still fails audio/video quality. It does not justify
claiming that the controlled recovery improvement resolves the cellular path,
or that camera enablement proves video delivery. The next investigation must
separate the current preferred buffering target from its filtered estimate and
actual packet accumulation under the repeated live arrival gaps.

Both owned apps, their processes, the phone package/UID and the owned ADB
forward are verified absent afterwards. The Mac seal verifies after removing
the owned late debug log. Private diagnostic archives and timestamped sample
data are retained. No release or push is performed.

The following native diagnostic addition exports `audio_jb_target_ms` from
WebRTC's `jitter_buffer_preferred_ms` alongside the filtered estimate and
current packet-buffer occupancy. It is sampled on the existing audio worker,
with the same freshness/receive-packet requirements; it changes no audio
controller, Dart protection threshold, transport metadata or relay behavior.
Production Mac and Android builds pass with the unchanged 97-symbol ABI.
This field is for attributing the remaining live buffering before choosing
another adaptation change; the currently installed 2373 does not contain it.

Stand 2374 subsequently installs that diagnostic field (Veil 7922d8b9) on
both owned stands. It retains the 2373 audio configuration, unchanged SDK and
hidden-volume, matching previous Android signer and byte-verified installed
APK. Mac production media code matches its independent build, the kernel
carries 2374 and the seal verifies. Both camera controls and microphones stay
enabled throughout the second 90-second relay call: ringing starts in
0.411 seconds and both endpoints are active in 2.087 seconds. Video remains
automatically paused, with zero encoded/received frames. Mac/Poco interruption
maxima are 1/4, lasting 490/1347 ms, but filtered delay reaches 531/407 ms and
current buffering reaches 531/432 ms. Preferred target reaches 340/300 ms.
Neither worker stalls; source admission maxima remain 0/2 ms. Different live
arrival gaps prevent attributing the lower interruption count versus 2373 to
the diagnostic-only change.

At 36 seconds the Mac target is 300 ms while current buffering is 41 ms;
Poco's target is 280 ms with 108 ms buffered. At 56 seconds both targets are
300 ms with 140/157 ms buffered. Thus the target itself can remain high beside
low current occupancy; this is not solely slow feedback filtering. The next
controlled case must warm the estimators before introducing a burst, unlike
the existing two-to-four-second startup burst, and check actual resumed PCM
before changing more adaptation parameters. Both owned apps/processes and
the phone package/UID/ADB forward are verified absent after the test. Diagnostic
archives and the strict Mac seal are retained; all commits remain unpushed.

A private follow-up warms the same real Opus/NetEq fixture for twenty seconds,
moves its 40/300-ms burst to seconds twenty-to-twenty-two, then measures ten
healthy DTX seconds and resumed PCM. The installed configuration (only reorder
decay 0.95) still passes: 140-ms resumed PCM, target down to 20 ms before
resumption, zero added concealment/interruptions, timer lateness below 5 ms.
Thus estimator warm-up plus one recovered burst does not reproduce the live
persistent 280/300-ms target. No additional underrun-memory change is made on
that hypothesis. Further attribution must examine repeated live arrival gaps
and actual route/transport behavior; successful single-burst recovery is not
proof of acceptable buffering on the physical relay path.

### Physical carrier and peer permission attribution — 2026-10-09

The 2374 native ingress-spacing trace includes a 711.7-ms interarrival gap
at the Mac receiver. Source admission stays below 2 ms and neither media
worker stalls, so the next investigation follows the actual route/carrier,
rather than another unproved NetEq capacity or memory reduction. Captured
logs contain no session channel-enable marker, but absence alone cannot
identify a missing provider versus missing authenticated peer permission.

A new `session.channels_offered` local event records those independently,
after all identity/admission gates pass: available QUIC/ordered providers and
authenticated peer datagram/flow/rekey/parallel/reliable permissions. Its local
link number correlates with the existing session snapshot; it contains no
application role, priority, peer address or new wire metadata. The production
Mac FFI build passes with embedded-node/production-seed/packet-tunnel features
and the fresh library contains the event. No scheduling or negotiation policy
is changed by this diagnostic addition.

The previous endpoint exchange knows two/three peer endpoints at Mac/Poco;
neither is admitted. This supersedes the zero-candidate state of earlier runs.
Address-free punch results report mainly no usable NAT mapping at Mac and
NAT signaling timeout at Poco. `hasCert=false` is not itself a direct-connect
failure: the native public-mode status provider explicitly allows admission
without a private-network membership certificate. Controlled startup with the
new event is needed to attribute the actual carrier permissions.

The controlled Mac 2375 / Poco 2374 startup captures four authenticated
channel-offer records. All have an ordered auxiliary provider available,
datagram/rekey permissions true, but opaque-flow, parallel ordered/QUIC and
reliable parallel permissions false. The live Mac snapshot has two
obfs4/TCP sessions. Thus the provider is present, while these peers have not
negotiated its codec/child protocol; the runner correctly retains the common
ordered compatibility carrier. This establishes why independent channels are
not activated on this observed path, without guessing remote version numbers
or treating every relay in the network as equivalent. A test route with an
updated controlled relay or working direct peer is needed for physical
verification of independent connections. Both owned apps/processes, phone
package/UID and the ADB forward are verified absent; the Mac seal verifies.

The NAT responder independently selected its socket family from the first
reflector, ignoring the initiator's public srflx candidates. With a mixed
reflector list this could answer an IPv4 request with an IPv6-only mapping
(or vice versa), leaving the initiator's existing socket unable to punch it.
The responder now validates public srflx candidates before UDP discovery,
selects the first compatible reflector family and uses that same family for
both discovery and punching. Token, network-tag and identity verification
remain intact; no application role or relay scheduling policy is added.

Two regression gates exercise the production socket-owning responder. The
first puts an incompatible reflector first and requires the compatible real
loopback UDP socket to receive discovery in both IPv4 and IPv6 cases, with
no traffic to the incompatible socket. The second requires no discovery for
empty/private-srflx/host-only offers. Neither test answers discovery, so no
packet is sent to its synthetic public candidate. Both pass with the fix,
both fail with the original responder, and both pass again after restoring
and formatting the fixed source. Runtime instances are stopped before final
assertions and temporary config files are removed. The observed phone NAT
failures are not yet attributed to this defect; physical installation and
verification remain necessary.


Stand 2376 subsequently installs Veil 09aece09 on both owned endpoints,
including the responder-family fix and local channel-offer diagnostic. Mac
SDK code matches its independently built library, media code remains the
verified 2374 configuration, version and strict seal verify. The signed
Android APK matches independently stripped native libraries, retains the
previous installed signer and hidden-volume, passes dependency checks, and
the pulled installed APK matches the verified package byte for byte. Install
uses replacement without clearing application data. Poco remains on the
active cellular default network with Wi-Fi disabled.

After normal endpoint exchange and a further thirty-second admission wait,
neither endpoint has a direct session. A phone-originated ninety-second video
call rings in 0.469 seconds and both endpoints become active in 2.506 seconds.
All active samples retain enabled microphones and cameras. The selected route
remains relay throughout, and video protection pauses transmission throughout:
zero encoded and received video frames on both endpoints. Mac/Poco filtered
audio-delay maxima are 525/524 ms, current jitter-buffer maxima 488/604 ms,
and preferred targets both reach 450 ms. Native receive-age maxima are
716/953 ms. Interruption maxima are 1/2, lasting 310/1185 ms. Source RTP
admission maxima remain 0/2 ms and neither media worker stalls. This does not
prove improvement over other live calls or acceptable audio/video quality.

Twelve authenticated Mac channel-offer records again show an ordered child
provider available but no peer opaque-flow or parallel/reliable permission;
all observed sessions therefore retain the compatibility carrier. Endpoint
logs continue to report mostly unusable mapping on Mac and signaling timeout
on Poco. The responder fix is not demonstrated as the cause of, or a cure
for, these remaining physical failures. Independent channels still require
an admitted direct peer or a compatible relay path; unsupported remote
protocols must not be forced. No media classification or priority is added
to relay traffic. Both owned applications/processes, phone package/UID and
ADB forward are verified absent after the call, and the Mac seal verifies.
Private diagnostic archives retain the actual samples and installation proof.


### Bound NAT coordinator waits within the direct-path deadline — 2026-10-09

A separate address-free mapping probe sends the protocol's fixed 64-byte
requests to seven public UDP reflectors actually announced in the 2376 run.
None returns a valid token-matching response within 2.5 seconds. This is
consistent with the Mac's unusable-mapping result but does not distinguish
network filtering, unavailable reflector services or another delivery failure.
It does not establish that changing the NetEq target would restore quality.

The initiator's coordinator ladder also ignored its shared punch deadline:
each of four coordinators could independently consume 1.5 seconds even when
the staged dial had only four seconds before its handshake reserve. A real
runtime regression enters discovery through an actual loopback UDP socket,
returns a valid non-hairpin mapping, then leaves four registered coordinator
sessions silent. No coordinator answers, so no packet is punched toward the
synthetic public mapping. The original code fails the latency gate with a
6.0099-second call-path attempt despite the declared five-second overall budget.

The staged initiator now supplies its absolute deadline to the ladder, which
limits each coordinator wait to the smaller of its normal timeout and remaining
time, and stops when exhausted. Existing public per-coordinator APIs retain
their normal independent timeout semantics. Each wait expires normally so its
registered oneshot waiter is removed; an outer future cancellation would not
provide that cleanup. The final production-runtime gate records 4.0024 seconds,
three actual NAT request frames, zero remaining waiters and zero single-flight
slots. The fixture counts NAT frames specifically, excluding unrelated control
traffic in the registered send queues. The previous fixture's generic queue
count could not establish how many NAT requests were sent and was corrected.

All three focused gates pass, including immediate coordinator refusal and
skipping a tokenless stale response to use the next coordinator. Runtime
instances stop and temporary configuration files are removed. This fixes a
bounded-attempt defect; it does not make the observed public relay path
negotiate independent channels or prove the physical audio/video goal complete.


Production embedded FFI builds with the deadline fix pass on both macOS and
Android. Stand 2377 is built sequentially for both platforms. Mac SDK/media
code sections, production-only media exports, version marker and strict seal
verify; media retains the unchanged 2374 configuration. The signed Android
package verifies the fresh independently stripped SDK and unchanged media,
previous signing identity, hidden-volume bytes and native dependencies. Its
SDK differs from 2376. Replacement installation preserves application data,
and the actual installed package matches the verified APK byte for byte.
Owned Mac app processes, phone package/UID processes and the test ADB forward
are absent; the Mac seal verifies after installation. No further physical
quality claim is made for 2377: the deadline gate proves bounded attempts,
while the last actual camera-enabled call remains the failing 2376 relay run.

### Physical path controls and isolated Linux relay preparation — 2026-10-09

The unchanged 2377 stands produce eighteen authenticated channel offers across
Mac and Poco. Every offer permits datagrams and rekeying but denies opaque
flows and all parallel/reliable channels; the actual path therefore remains
the compatibility carrier. This network-only run makes no new call-quality
claim. Both owned apps, phone package/UID and ADB forward are absent afterward,
and the Mac seal verifies after archiving its late diagnostic log.

Seven announced public UDP reflectors do not answer on Mac or on Poco, including
probes under the actual foreground application's UID. Generic UDP DNS probes
and authenticated-peer TCP connection controls succeed on Mac; reflector routes
use the physical IPv4 interface. Neither endpoint has a global IPv6 address.
These observations do not distinguish reflector unavailability from selective
network filtering, and do not establish a global UDP or VPN failure.

The project's private operational inventory identifies two SSH-accessible owned
servers. An isolated directory on the second server holds the current CLI and
an existing loopback regression executable; existing services, containers,
configuration and firewall are unchanged. Fresh ports are checked free. No
inventory addresses, identities, credentials or bootstrap descriptors are
committed. A compatible temporary relay remains to be launched and measured.

Building the CLI for x86_64 Linux musl exposes a portability defect in the UDP
receive-time diagnostic: libc does not export SO_TIMESTAMPNS_NEW there. The
vendored socket backend now uses the kernel time64 option number (64, with
SPARC's separate 0x42 numbering) and guarded ancillary decoding, preserving
the legacy fallback and opt-in behavior. The release CLI cross-build succeeds.
On the actual Linux server, the existing IPv4/IPv6 loopback test passes all
false/true/false toggles and verifies that timestamps precede a reader delayed
40 ms; one test passes in 0.24 seconds. No SPARC execution, physical call quality
or independent-carrier success is inferred from this portability gate. No
relay media role, priority or QoS metadata is introduced.

### Compatible own-relay calls and the neutral Forward selection gap — 2026-10-09

An isolated current Linux CLI relay runs under a fresh normally mined identity,
production deployment PSK, empty builtin seeds, private admin socket and fresh
TCP/UDP ports. Its timed transient unit leaves existing services, containers,
firewall and configurations unchanged. Both installed 2377 clients authenticate
its opaque-flow and parallel ordered/reliable permissions. Runtime registration
uses the CLI's canonical bootstrap URI encoding, not generic URL encoding.
An already registered peer refreshes natively even when the app API reports
`alreadyRegistered`; that report alone cannot establish an absent connection.

Three camera-enabled 90-second calls remain unsuccessful quality checks. In the
first two, ordinary legacy routes are still available. The final controlled
topology closes legacy *stand* sessions only while the owned relay is active,
without bans, saved configuration changes or wire negotiation overrides. Both
ends then have one active authenticated session to the owned relay. The final
call rings in 9.495 s and is active on both ends in 11.837 s; it remains relayed.
All active samples have microphones and cameras enabled. Video transmission is
automatically paused throughout: no encoded or received frames. Mac/Poco maxima
are audio delay 806/403 ms, current jitter buffer 544/590 ms, preferred target
450/420 ms and native receive age 2803/2869 ms. Interruption maxima are 9/22,
lasting 7531/19891 ms. Source RTP admissions remain 0/5 ms and media workers do
not stall. Different network conditions and topology control prevent a causal
performance comparison with previous calls. No concurrent file or screen load
is claimed for these runs.

Endpoint logs prove ordered independent `relay_forward` sends to the owned
relay. Its log proves independent receives but no outgoing datagram send. The
production ordered sender's neutral branch accepts only CircuitDatagram; an
ordinary neutral Delivery::Forward therefore returns to the canonical stream.
The QUIC sibling selector has the same omission, although its primary datagram
fallback can conceal it. Offering channel capabilities alone does not prove
that the forward hop uses the channels.

Neutral Forward now selects one of the *existing two* bounded neutral shards.
Selection uses only the already visible recipient routing value and original
sender, salted per canonical session; app IDs, endpoints, content, timestamps,
TTL and traffic-class hints have no effect. Circuit selection is preserved.
Ordinary transit FIFO, admission, quotas and budgets remain in place. No relay
media classification, priority privilege, new wire field or larger pool is
introduced. Unsupported peer negotiation keeps the canonical compatibility
path. Separate source channels still do not imply separate audio/video streams
at each neutral transit hop; this change separates neutral Forward from the
canonical transport without exposing a source's media roles.

A real obfs4/TCP regression waits for all six authenticated child connections,
then submits Forward through the ordinary neutral queue in both directions with
the canonical writer blocked. The original production selectors fail this gate
in 2.01 s. Corrected selectors deliver exact payloads through neutral children,
with zero local-primary/bulk diagnostics. Three focused integration gates pass,
including forbidden unnegotiated child delivery and legacy canonical delivery;
the routing-shard role/content independence unit gate also passes. An earlier
fixture sent before child authentication, then incorrectly expected seven rather
than six children; those failures do not prove the production selection defect.
The final original/fixed comparison uses the same six-child readiness barrier.
Physical call quality after this change remains to be measured.

The owned UDP reflector also answers locally. During scoped server capture,
six 64-byte requests arrive and six replies leave its network interface; the
Mac socket still receives no valid response. Correctly quoted app-UID probes on
Poco receive three valid token-matching 64-byte replies. Their elapsed helper
time includes netcat's two-second linger and is not a network RTT measurement.
The server INPUT policy is ACCEPT. This narrows the Mac return-path problem
but does not identify its cause; no system VPN or network policy is changed.

All three owned app stands, phone package/UID processes, ADB forwards and topology
helpers are verified absent afterward; the Mac seal verifies. The temporary
relay is stopped, its executable process and fresh listening ports are absent,
its private directory is removed and its SSH control helper is closed. Raw
addresses, identities, bootstrap descriptors and packet captures stay private.

The four existing real two-relay circuit-chain gates also pass (QUIC and
obfs4/TCP, each with and without canonical rekey), with bounded neutral shards,
exact payloads, no duplicate cells and retired children after teardown. These
gates check preservation of the shared selectors; they do not replace the
pending physical Forward/audio/video measurement.

### Physical neutral Forward fix verification — 2026-10-09

The clean SDK 6fd000ca Linux CLI cross-build completes successfully. A fresh
isolated relay runs this exact hashed binary; installed Mac/Poco clients remain
2377, avoiding an unnecessary client rebuild for the relay-side selector check.
The controlled single-own-relay topology makes a new 90-second camera-enabled
call. It rings in 0.425 s and is active on both ends in 2.299 s. Relay logs now
prove two outgoing `relay_forward` sends with neutral local slot 1 and
`independent=true`, in addition to the endpoint-independent carrier records.
This verifies use of the corrected forward hop on the physical cellular path.

This call still fails the quality criterion. All active microphones and cameras
are enabled, while video stays automatically paused and no video frames are
encoded or received. Mac/Poco maxima are audio delay 526/582 ms, current jitter
buffer 588/613 ms, preferred target 450 ms on both ends and receive age
2250/513 ms. Interruption maxima are 2/7, lasting 2477/2193 ms. Source admission
maxima remain 0/2 ms and neither media worker stalls. NetEq records discarded
packets, requiring further arrival/transport analysis; the new measurements do
not prove their cause. They do not establish a causal quality improvement over
the previous different topology/network samples or acceptable audio/video.
No file/screen concurrency or acoustic speech validation is claimed.

Owned Mac and phone app/package/UID processes, topology helpers and ADB forward
are verified absent after the run, and the Mac seal verifies. The isolated relay
is stopped; its process and fresh ports are absent, its directory removed and
its SSH helper closed. Existing server services, configuration and firewall,
the user's default Mac application and saved endpoint network policy are unchanged.
Raw source-to-receiver counters, carrier records and binary metadata stay private.

### Physical TCP backlog and inbound MSS negotiation — 2026-10-09

A further controlled own-relay call uses unchanged 2377 endpoints and SDK
6fd000ca on the relay. A temporary generic server collector samples TCP_INFO
via `ss` every 200 ms, with ordinary session snapshots every ten samples. It
collects no media roles or payloads and changes no scheduling or priorities.
974 snapshots span 215.795 seconds, with no `ss` failures. Server epoch and
Mac driver epoch provide approximate alignment, not a measured clock offset.
The call rings in 33.207 seconds and is active on both ends in 34.555 seconds;
the requested active window lasts 90 seconds. Neutral independent Forward
sends remain present. All active microphones and cameras are enabled; video
stays automatically paused, with zero encoded or received frames.

Quality fails again. Mac/Poco interruption maxima are 43/24, lasting
29495/24448 ms; receive-age maxima are 3699/4668 ms. Source RTP admissions
remain 0/2 ms, with no stalled media workers or source RTP drops. A server-to-Mac
TCP connection has up to 100877 bytes in its send queue, 97293 not yet sent,
826 additional retransmitted segments and 372776 additional retransmitted
bytes during the active window. Its RTO reaches 3872 ms and its send MSS falls
from 1248 to 1024, 512 and 256 bytes. Server-to-phone connections also show
backlog, retransmissions and RTOs exceeding four seconds. These are actual
kernel transport waits; the snapshots do not locate packet loss or prove the
cause of every playout interruption. Low smoothed RTT alone does not establish
a healthy transport. Raw connection/address mapping and time series stay private.

The listener has a separate concrete gap in its existing MSS safety policy.
Linux `TCP_MAXSEG` applied after accept cannot change the already negotiated
send MSS. A real isolated Linux loopback control gives client/server MSS
21845/22528 bytes for that late setting, versus 1188/1188 when the same 1200-byte
limit is set before listen, for both IPv4 and IPv6. SDK c85ad257 applies this
existing limit before listen on Linux/Android in the shared TCP binder and
uses that binder for obfs4. Established-socket fallback on other platforms
remains. No new transport class, wire field, relay priority or firewall rule
is introduced. The two real TCP/obfs4 listener regressions fail against the
original code (negotiated MSS 21845), then pass with the fix. Seven Linux TCP
and obfs4 tests pass, including exact round trips and wrong-PSK rejection.
This is a negotiation fix, not yet proof of acceptable physical call quality.

Owned Mac and phone stands, package/UID processes, topology helpers and ADB
forward are verified absent after the measurement; the Mac bundle seal verifies.
The generic TCP collector is inactive with MainPID zero and no remaining
collector process. The isolated relay process and ports are absent, its private
directory is removed and its SSH helper is closed. Linux control/test sockets
and their private executable directories are also cleaned up.

The four existing TCP/obfs4 unit gates also pass on macOS. The clean c85ad257
Linux CLI cross-build then runs a second isolated relay process with the same
normally mined owned test identity and unchanged 2377 clients. Its new TCP
connections start at MSS 1188, including the Mac leg, proving the listener fix
is deployed. The 90-second camera-enabled call rings in 0.414 s and is active
in 1.676 s. Audio still fails quality: Mac/Poco interruption maxima are 10/10,
lasting 14956/9949 ms; receive-age maxima are 7051/4085 ms. Source payload gaps
are at most 26/423 ms and RTP admission remains 0/2 ms, so these multi-second
receive gaps cannot be explained by those source sampling gaps alone. Neither
media worker stalls; source RTP drops stay zero. Audio delay reaches 640/533 ms.
Both cameras remain enabled in active samples, but video is automatically
paused throughout with zero encoded/received frames. No file/screen or acoustic
validation is claimed.

829 generic TCP snapshots have no sampling-command failures. Transport queues
and retransmissions remain: one server-to-Mac connection reaches 123142 queued
bytes and falls from MSS 1188 to 1024 before disappearing; a later connection
remains at 1188. Server-to-phone backlog reaches 143066 bytes, with RTO up to
5168 ms across the sampled connections. This verifies a specific negotiation
correction, without establishing the cause of each network wait or a causal
quality improvement between the different live network samples. Apps, UID
processes, helpers, forwards, collector, relay, ports and owned directory are
again verified cleaned up, with a valid Mac bundle seal.

A separate temporary UDP echo control binds only otherwise-free UDP ports 443
and 39181. Its equal-size 64-byte token echo changes no existing service or
firewall and carries no media role. Mac receives zero matching replies in six
probes; app-UID Poco receives four matching replies in four probes. Netcat's
elapsed times include its two-second linger and are not RTTs. The previous
scoped reflector capture also has matching request-destination/reply-source
IPs, so a changed response source does not explain that Mac probe failure.
These results establish neither a universal UDP block nor its location or cause.
The temporary echo process is stopped, its directory removed and SSH helper
closed afterward.

### Physical mixed QUIC/TCP relay path — 2026-10-09

The same clean c85ad257 relay binary and normally mined owned identity run with
an additional otherwise-free QUIC listener on UDP 443. Ordinary bootstrap
invites select QUIC for Poco and obfs4/TCP for Mac, without overriding peer
permissions or endpoint network policy. Endpoint session observations confirm
those schemes. In the 90-second window after both ends become active, all 41
server session snapshots for each peer retain that same transport. The phone
does not silently revert to TCP in these observations. Relay QoS and wire
privacy remain unchanged.

The incoming signal appears in 1.557 seconds, but both endpoints become active
only at 38.809 seconds. Quality still fails: over the aligned active window,
Mac/Poco audio delay reaches 884/524 ms, receive age 2563/2606 ms and interruption
counts 7/11, lasting 5210/8611 ms. Source payload gaps are at most 31/430 ms,
RTP admission 0/2 ms, with zero source RTP drops and no stalled media workers.
Cameras are enabled in all active samples; automatic audio protection keeps
video paused with zero encoded/received frames. Mac starts its local media
before the caller receives acceptance, so unaligned cumulative packet counts
cannot be used to infer packet loss.

The 985 generic TCP snapshots have no sampling-command errors. Both active
server-to-Mac TCP connections show zero additional retransmissions; maximum
send queues are 9692/8706 bytes, RTT 43.014/44.691 ms and RTO 244/245 ms.
Thus the previous large TCP backlog/retransmission symptom is absent on the
sampled Mac leg of this mixed run while media delays remain. These observations
do not measure QUIC one-way loss/jitter or endpoint processing delay and do not
prove which causes the remaining pauses. UDP success alone is not a latency
measurement. No file/screen coexistence or acoustic speech validation is claimed.

Owned apps, package/UID processes, topology helper and ADB forward are absent
afterward, and the Mac bundle seal verifies. Collector MainPID is zero, with
no collector process. The relay executable and owned TCP/high UDP/UDP 443
listeners are absent, its private directory is removed and its SSH helper is
closed. The cleanup assertion initially also matched an unrelated existing
TCP 443 listener; it was corrected to distinguish the owned UDP port, then the
cleanup verification and directory removal completed. The existing TCP service
is preserved. Addresses, identities, descriptors and raw time series stay private.

### Native mobile UDP latency controls — 2026-10-09

A native C helper runs under Poco's application UID with xVeil closed, sending
64-byte connected UDP token probes every 100 ms for 60 seconds plus a
three-second receive grace period. RTT uses the phone's monotonic clock,
excluding ADB transport and netcat linger. Source sends have no failures or
duplicates and a maximum gap of 110.811 ms. Of 573 sent probes, 553 return:
RTT median 88.435 ms, p95 2347.288 ms and maximum 5142.887 ms. The server records
554 probes, leaving 19 unobserved before its receive loop and one observed
there without a matching phone response during the measurement. This establishes
latency tails outside the media/SDK pipeline, without locating the loss or
proving that bare UDP explains a particular call's delay.

Two simultaneous native probes then use separate test servers S1/S2 and Linux
receive timestamps enabled only on their temporary echo sockets. S1 receives
567 of 571 probes; S2 receives 568 of 572. Each server-observed probe returns
to the phone. RTT medians are 49.267/81.576 ms, p95 896.227/974.981 ms and maxima
1470.460/1510.227 ms. Source gaps stay below 112 ms. All server observations
have kernel receive timestamps: kernel-to-reader maxima are 3.762/0.449 ms,
and echo processing after read takes at most 1.714/0.449 ms. These controls
exclude a multi-second userspace echo stall in this run. Relative upload-phase
variation exceeds 1.4 seconds on both paths before server kernel arrival;
this is not calibrated absolute one-way latency or proof of which mobile/kernel/
network component caused the variation. Apps are closed during these probes;
their flow and load differ from a live QUIC call.

A further pair of sequential controls alternates packet lengths
64/1200/1280/1400/1452 bytes on each server with IPv4 don't-fragment enabled.
All lengths pass. S1 returns 551/573 probes and S2 552/573, without source send
failures or duplicates. Per-size losses and p95 RTTs are similar within each
sample, with maxima up to 2913.500/3037.517 ms. Kernel-to-reader maxima are
2.810/1.078 ms. This does not reproduce a size-specific UDP black hole in these
controls; it does not certify the QUIC path's MTU, fragmentation policy or call
quality. No transport MTU settings are changed on this evidence.

All helper binaries run from newly created private app directories and are
removed afterward, along with their staging files. Their processes are verified
absent. Temporary server units/processes and owned UDP sockets are stopped,
their private directories removed and SSH helpers closed. Existing server
services, phone data and saved network settings are preserved. A read-only
phone snapshot has mobile data on, Wi-Fi off, device awake and idle mode off;
it is not continuous power or network-state evidence. Raw addresses, tokens,
timestamps and packet correlation stay private.

### Local call-control receipt boundaries — 2026-10-09

The mixed call's full endpoint logs show the Mac live answer leg returning in
148 ms; Poco's first handled answer has age 35726 ms. Ordinary independent
QUIC forwarding is already ready near the start of the call, so a 35-second
wait to authenticate that child is not established. These logs do not reveal
when the phone daemon/FFI handed the signal to Dart and cannot locate the wait.

Existing accepted call/endpoint debug log entries now include monotonic Dart
queue and handler durations, plus the call's wall-clock age at Dart admission.
This distinguishes the serialized consent/dispatch lane from delays before
Dart admission. It measures neither native receive waits nor remote clock
offset. Consent, dedup, ACK, queue limits and scheduling remain unchanged;
there are no new relay-visible fields, media roles or priorities. All 45
realtime-control and inbound-backpressure tests pass.

A 60-second mixed-path call on unchanged native endpoints rings in 0.425 s
and becomes active in 2.258 s, so it does not reproduce the delayed answer.
Mac/Poco receive-age maxima still reach 4469/4019 ms, with 5/8 interruptions
lasting 6737/10439 ms. Cameras remain on, automatic audio protection pauses
video throughout and frame counters remain zero. A temporary Flutter attach
reports four reloaded libraries, but the phone's signal logs retain their
previous format without the new receipt/queue fields. That reload is not
accepted as timing-boundary evidence. The attached tool and all owned app,
UID, forward, collector and relay processes are verified closed; the Mac seal
verifies. The persistent phone APK remains the baseline after that run.

An APK rebuild packages the receipt diagnostics explicitly: its Dart kernel
contains the new marker and the old APK does not. The diagnostic package is
installed over Poco with the same signer and without removing data. Its native
SDK and media libraries match the 2377 baseline byte for byte; its SDK version
define names that actual e48ecd61 source, rather than the newer relay checkout.
Mac remains on 2377 and the owned relay on c85ad257. The installed APK bytes
are verified against the signed output. This is a receiver-observation change,
not a native transport upgrade or a release.

This 60-second call rings on Mac in 33.588 s and reaches both-active in 35.110 s.
Poco's 15 accepted signal records include the new boundaries: maximum Dart
queue wait is 1 ms and handler time 10 ms. Its received answer has 0 ms queue
wait and 10 ms handler time, with negative wall-clock age demonstrating why
remote age must not be treated as calibrated one-way latency. That answer is
quick in this run; the long delay is the incoming offer on Mac, whose old Dart
build does not have the new boundaries. The earlier 35-second answer wait
is therefore not reproduced or located by this measurement.

Quality remains below the criterion. Mac/Poco native receive-age maxima are
1949/293 ms, interruption maxima 17/2 lasting 10323/441 ms, and audio delay
876/476 ms. Source admissions remain 0/2 ms with no stalled workers or source
RTP drops. Both cameras are enabled; video stays automatically paused and
frame counters remain zero. Quiet microphone captures and cumulative counters
are not an acoustic speech test, and this different network sample cannot
establish a causal improvement. No file/screen coexistence is claimed.
Owned apps, phone UID processes, helpers and ADB forward are verified absent,
the Mac seal verifies, and collector/relay processes, owned ports, remote
directory and SSH helper are verified cleaned up. The diagnostic APK stays
installed and closed on Poco; its existing identity and history are preserved.

Opaque ingress connection continuity at relay hops (2026-10-09)
-------------------------------------------------------------

SDK 5d37d26e fixes a remaining connection-selection collapse. Previously,
neutral Forward selection hashed only sender and recipient: two independent
authenticated incoming connections for that same route used the same outgoing
connection. Source separation therefore did not survive that relay hop.

The authenticated child carrier now supplies a process-local allocation
identity and a weak lifetime witness. Immediate Forward dispatch preserves
that witness through sovereign/direct, scored, multipath and gateway forwarding
in the existing ordinary INTERACTIVE queue. Session selection assigns distinct
live ingress connections distinct generic outgoing connections. No role,
priority, endpoint or application label is added to a frame or handshake.
Allocation tokens are never serialized and their debug representation is
redacted. Retired parents invalidate witnesses; expired owners are reaped
before comparing identities, including allocation-address reuse.

This uses the existing six outgoing datagram connections, shared with local
source allocations. Ownership is first come and bounded: neither an incoming
connection nor a local audio producer can evict another live owner. Source
readiness and recovery follow the physical assignment; diagnostics keep source
logical counters separate from neutral transit counters even when their
physical connection indices overlap. Legacy connections retain role-blind
routing buckets, with idle bucket ownership expiring after 30 seconds.
Relay admission, FIFO service, bandwidth accounting and connection quotas are
unchanged. The pool leaves the existing separate reliable child and one
authenticated primary replacement within the transport's directional quota.

A regression uses the production ordered-pool selector, exporter-bound child
key derivation and authenticated record I/O. One 32-byte duplex pipe is left
unread until an actual record write blocks. A second incoming connection with
the same Forward sender/recipient delivers and decrypts its complete frame
within 250 ms on its independently selected pipe. Restoring routing-only
selection by ignoring the ingress witness makes this test fail with the
intended merged-connection assertion; the current selector passes. This
control restores the old selection semantics, rather than testing an entire
previous release. All 487 session tests pass (6 existing tests ignored), as
do all 270 dispatcher tests. Changed files pass rustfmt and diff whitespace
checks; workspace-wide fmt still reports pre-existing ordering differences in
the unchanged session and transport lib.rs files.
The clean SDK commit also builds the Linux x86_64 musl relay CLI successfully;
that artifact is ready for the next owned-relay call check.

Limits remain explicit. At pool saturation, or before generic connections are
authenticated, compatibility fallback does not guarantee separation. The DHT
RecursiveRelay fallback is outside this datagram selection path. This gate
proves blocked-connection independence, not acoustic quality, mobile network
latency or simultaneous video/file/screen operation. Video in the preceding
physical runs was automatically paused by endpoint audio protection, with both
cameras enabled and zero transmitted video frames. It was not disabled to
demonstrate successful video delivery. No new physical call result is claimed
while Poco is absent from ADB.

Forward isolation through the production relay pipeline (2026-10-09)
------------------------------------------------------------------

SDK e971b9ab adds four integration gates to the existing A <-> R1 <-> R2 <-> C
fixture: QUIC and obfs4/TCP, each with and without actual canonical rekey.
All four source-local datagram producers send in both directions with the
same logical sender, recipient, application and endpoint. They traverse the
production SessionRunner, FrameDispatcher admission and forwarding, ordinary
outboxes, child selection and terminal app delivery over real local sockets.
The fixture supplies canonical session keys; actual exporter-bound child
handshakes and encrypted record/datagram I/O run normally. It does not perform
production identity mining or replace a physical microphone/camera test.

Observation wraps the dispatcher without changing its methods or accounting.
Every Forward header must remain INTERACTIVE. At every neighbor connection,
including both bridge directions and both terminal endpoints, four distinct
live authenticated ingress witnesses must be observed. Expired witnesses are
removed, so neither early canonical fallback nor connections from the preceding
credential generation can satisfy this requirement. This is stronger than
counting total neutral physical slots, which can include an early legacy
bucket. All received payloads are checked in sequence, duplicate queues must
be empty and every relay's source-role counters remain zero. The same checks
pass again after all canonical sessions rekey.

A control on the initial three-producer fixture changes actual Delivery
dispatch to discard ingress ownership, while leaving its queues and outgoing
selector intact. That control fails with the intended same-route connection
collapse assertion. Production dispatcher bytes are then restored exactly.
The strengthened four-producer gates pass, and the final complete runner suite
passes 118 tests with one existing test ignored. The existing ordered-source
fixture now requests all source channels before observing readiness, rather
than assuming that construction of physical connections reserves every local
source. Each poll requests all producers, avoiding serial warmup across its
deliberately short one-second credential generations.

The tests retire their runners and verify zero owned child connections and
Unsupported readiness for all four local producers. Cargo and runner-test
processes are verified absent afterwards. No GUI apps, production relay
services, VPN policies or phone data are changed in this cycle. Poco remains
absent from ADB. Physical audio latency, video resumption and simultaneous
file/screen operation remain unverified; the active quality task is not complete.


Neutral datagram lifetime and resumed Poco checks (2026-10-09)
-------------------------------------------------------------

SDK 1bd916e9 bounds every session loss-tolerant QUIC datagram's unsent
residence to 200 ms, matching the existing ordered-record policy. This also
caps a caller's longer local deadline; a shorter source deadline is retained.
The policy includes opaque transit datagrams. It neither classifies their
payload nor changes relay FIFO admission, priority, quotas or bandwidth
accounting. Deadlines remain local monotonic state, with no new wire field.
Reliable messages and stream bytes continue on their existing delivery path.
Already transmitted packets cannot be recalled by this bound.

The regression admits 21 datagrams on a real encrypted QUIC connection and
holds its single runtime thread for 300 ms before any of them can transmit.
After resuming, only the fresh datagram arrives on that same connection, the
expiry counter advances by at least 21 and no stale payload follows. Restoring
the former raw QUIC send path fails the intended stale-delivery assertion.
The production file is restored byte for byte, and the test passes again.
All 488 session tests pass (6 existing tests ignored); the four production
Forward tests through two relays also pass, covering QUIC, obfs4/TCP and actual
canonical rekey. Changed files pass rustfmt and whitespace checks. The clean
SDK commit builds the Linux x86_64 musl relay successfully.

Physical clients remain Mac stand 2377 and Poco 2391, both with native SDK
e48ecd61 and the earlier media implementation. Thus these measurements test
a change to the owned relay, rather than deployment of the new SDK to either
client. Poco uses mobile data with Wi-Fi off. Both cameras and microphones
are requested on; no manual video disable or concurrent file load is used.

Attempt 2393 did not establish a valid owned-relay baseline on the Mac: its
initial connection closed, subsequent handshakes timed out, and none of the
controller's Mac observations saw an active owned-relay session. No incoming
call appeared within 45 seconds. The later stands use a fresh TCP port, omit
the extra Mac join request and require an authenticated owned canonical
session on both clients before placing the call. Relay logs are captured with
a bounded streaming copy that preserves partial bytes on timeout; the TCP
collector is captured independently. Attempt 2393's lost relay capture is
not presented as evidence.

Two subsequent 60-second calls complete over the owned relay, with the Mac
using obfs4/TCP and Poco using QUIC. Values below are native/API measurements
from those individual runs, including startup; they are not acoustic speech
latency measurements or a statistical estimate of reliability.

| Measurement | 2395, relay 5d37d26e | 2397, relay 1bd916e9 |
| --- | --- | --- |
| Incoming ring / both active | 0.418 s / 5.216 s | 33.810 s / 35.193 s |
| Median native audio delay, Mac / Poco | 181 / 132.5 ms | 306.5 / 269.5 ms |
| Maximum audio receive age, Mac / Poco | 2240 / 2259 ms | 401 / 473 ms |
| Interruption count, Mac / Poco | 17 / 18 | 2 / 1 |
| Total interruption duration, Mac / Poco | 14859 / 15153 ms | 339 / 167 ms |
| Transmitted / received video frames | 0 / 0 on both clients | 0 / 0 on both clients |
| Maximum relay QUIC queued bytes | 27157 | 0 |
| Relay QUIC expired outgoing datagrams | 0 | 0 |

The expiry regression demonstrates the fixed stale-queue behavior, but the
physical second run did not exercise expiry: its queue stayed empty. Its
shorter receive gaps therefore cannot be attributed to this fix. Conversely,
the long offer delay remains a separate unresolved result even though both
owned canonical sessions were active before the call. Camera capture is
approximately 30 fps on both clients, while endpoint audio protection keeps
video transmission paused. In 2397 native playout targets remain around
260-320 ms and exceed the adapter's recovery threshold; a clean local worker
or low RTT alone is insufficient to release that hold. Weakening that audio
protection is not a demonstrated quality fix.

The 2395 relay's datagram dispatch peaks at 1.192 ms. QUIC event processing
peaks at 0.806 ms on the relay and 3.095 ms on Poco, with timer lateness up to
6.412 ms. Neither endpoint reports a stalled media worker. The Mac's accepted
TCP connections negotiate MSS/advmss 1188 and have sampled RTT around 42 ms.
These observations help exclude seconds of local handler blockage in that
run; they do not establish where every network stall originates.

The topology controller also closes newly discovered neighbors repeatedly
(23 Mac and 21 Poco sessions in 2397). Their reconnect work is a possible
stand load and must not be mistaken for normal steady network operation.
Attempt 2398 prepares a phone TCP comparison that stops these closures before
the call and checks the actual canonical transport. Poco disappears from ADB
before the helper can even create its forward, so no client apps or call are
started in that attempt. Its owned relay and collector are stopped, their
processes/listeners verified absent, and their private remote directory removed.
Both completed stands verify the phone package UID empty, the owned Mac and
helper processes absent, the ADB forward removed and the Mac bundle seal valid.

Offer-delay diagnosis, physical video recovery, simultaneous file/screen
operation and acoustic speech quality remain unfinished. No release or
production relay deployment is implied by these stand results.

### Endpoint signaling queue correction and resumed Poco checks — 2026-10-09

Poco returns on mobile data with Wi-Fi off. Stand 2399 checks actual canonical
obfs4/TCP on both endpoints before calling and stops the topology controller
before the measured call, removing continuous forced neighbor closures. The
ring takes 1.537 seconds, but both endpoints become active only at 34.374
seconds. Poco records the answer with receipt age 31124 ms, queue wait 0 ms and
handler time 7 ms. Remote clock offsets affect absolute ages, but cannot explain
the approximately 32-second setup wait seen by the stand controller.

Matching 2397's rejected offer to its durable frame id and Poco's native source
and media-device binding confirms that it belongs to the test call. Its early
copies arrive under Poco's physical address with claimed provenance; only the
later ratchet-authenticated identity copy rings. The consent check is retained.
An expired Mac signing delegation warning remains, but earlier successful calls
already establish that this warning alone does not explain every setup delay.

Both clients are then rebuilt as 2400 with SDK 1bd916e9, instead of changing
only the relay. Packaging verifies the new native code, the unchanged production
media 2374, identical Android signing identity and an in-place installation.
The first Android build exhausts the external build-cache disk; removing only
obsolete local SDK compilation outputs allows a successful rebuild. Stand 2401
uses Mac TCP and Poco QUIC with the controller stopped before measurement.
Long signaling and audio receive gaps still reproduce with the updated clients.

Source inspection finds a separate concrete producer-isolation defect: both
cached per-device compatibility-control fan-out and its ordinary relay fallback
override the endpoint's local signaling lane with REALTIME, the primary media
lane. SDK 685705b6 preserves the local lane instead. Legacy media's default
primary mapping is retained; encrypted payloads, neutral Forward headers,
recipient proofs, replay checks and relay scheduling are unchanged. Compatibility
control still has no optional traffic-class suffix.

The regression fills the real SessionTxRegistry primary queue, leaves it
undrained, and drives the production IPC handler through both cached addressing
branches. Before the correction no control frame survives; afterwards control
uses INTERACTIVE while primary payloads remain intact. The received ciphertext
still opens with authenticated provenance, and the inter-node wire stays neutral.
All 149 IPC tests pass (5 existing tests ignored), including the actual IPC
server test updated to require the corrected local signaling lane. Rustfmt and
whitespace checks pass. The SDK correction is committed without signing/pushing.

Both clients are rebuilt and verified as 2403 with SDK 685705b6, then Poco is
updated in place with the same signer. Stand 2404 repeats the Mac TCP / Poco
QUIC path through the unchanged, verified 1bd916e9 relay. The initial join
request reports alreadyRegistered; the subsequent actual canonical-session and
transport checks pass on both endpoints. This is not a missing relay connection.

| Measurement | 2399, clients e48ecd61, both TCP | 2401, clients 1bd916e9 | 2404, clients 685705b6 |
| --- | --- | --- | --- |
| Ring / both active | 1.537 / 34.374 s | 34.034 / 35.417 s | 1.536 / 2.737 s |
| Median native audio delay, Mac / Poco | 296.5 / 331.5 ms | 375 / 426 ms | 331 / 334.5 ms |
| Maximum audio receive age, Mac / Poco | 311 / 722 ms | 2242 / 2454 ms | 339 / 446 ms |
| Native interruption count, Mac / Poco | 4 / 0 | 12 / 13 | 0 / 0 |
| Native interruption duration, Mac / Poco | 1000 / 0 ms | 7586 / 6591 ms | 0 / 0 ms |
| Video transmitted / received | 0 / 0 on both | 0 / 0 on both | 0 / 0 on both |

Each measured period lasts 60 seconds after both endpoints become active;
delay medians use that common active period. Cameras/microphones are requested
on, with no manual video disable, concurrent file load or acoustic speech proof.
Video remains held by audio protection. These individual runs do not prove a
reliability rate or assign all physical improvement to the queue correction.
In 2404 sampled daemon-to-media receipt ages peak at 190 us on Mac / 5540 us on
Poco. Sparse cross-device cell timestamps vary by roughly 309–314 ms, but use
uncalibrated wall clocks and do not locate the exact network/capture boundary.

2404's final relay-log SSH copy exits 255 after retaining 65536 bytes; that
partial capture must not be treated as a complete relay log. Independent TCP
capture succeeds. All owned apps, UID processes, helpers and ADB forwards are
verified absent after each stand; relay units are stopped, directories removed,
and the owned Mac bundle seal verifies. The 330-ms receiver buffering, reliable
video recovery, file/screen coexistence and speech quality remain unfinished.

### Direct signaling isolation and audio arrival measurement — 2026-10-09

SDK c94c8be3 also corrects the direct FFI signaling path: `veil_send_realtime`
used BACKGROUND (the screen producer), whereas compatibility relay control now
uses INTERACTIVE. Direct signaling now uses the same local control queue. This
does not allocate a fifth named media datagram child or promise physical
isolation during cold-channel fallback. Four producers remain audio REALTIME,
camera BULK, screen BACKGROUND and recoverable data lane 4. The existing wire
neutrality regression passes for all four public local priorities: their
encoded inter-node frames are identical. Relay scheduling and wire metadata
remain unchanged.

An explicitly enabled media diagnostic collects at most 4096 incoming audio
RTP metadata samples per shim in memory (sequence, RTP timestamp, payload length,
monotonic ingress and drain times). It records no payload, addresses, identities
or keys and performs no per-packet file I/O. Stop fences delivery before writing
the samples to `VEIL_MEDIA_DIAG_PATH`; without that environment setting there
is no collection or output. A real native Call smoke run with diagnostics on
passes stalled audio/video queues, callback teardown and restart, producing six
bounded trace batches. Both FFI targets compile and the production Mac media
library exports no test hooks.

Both clients are rebuilt as 2405 with SDK c94c8be3. Mac media additionally carries
the new diagnostic; Android retains production media 2374 and its existing audio
configuration. The Mac SDK/media code sections match the fresh native outputs,
its app seal verifies, and Poco's in-place install uses the same signer with the
pulled installed APK exactly matching the verified package. Identities/history
are retained. The isolated relay remains the verified 1bd916e9 binary.

Stand 2406 verifies Mac TCP / Poco QUIC, then stops topology closures before a
60-second video call with both microphones and cameras requested on. Ring takes
1.168 s; both endpoints are active at 2.635 s. Median native audio delay is
374 / 348 ms (Mac / Poco), with maxima 442 / 443 ms. Native interruptions are
7 / 1, totaling 1994 / 186 ms. Video remains automatically held (zero transmitted
and received frames); no concurrent file transfer or acoustic speech proof is
performed.

Mac collects 2845 audio RTP arrivals over 60.086 s. Every observed sequence step
is one: no receiver-side sequence gaps, duplicates or reordering appear in that
trace. Nevertheless, consecutive packets with a 20-ms RTP timestamp step have
arrival gaps up to 744.741 ms; 508 adjacent arrivals are less than 1 ms apart.
The relative arrival-versus-RTP phase spans 744.316 ms. Legitimate DTX timestamp
gaps are accounted for separately. Drain wait is median 0.013 ms, p99 0.022 ms,
maximum 0.044 ms. The delivery queue therefore cannot explain these pauses;
source pacing and the path before authenticated receiver ingress remain to be
separated. The sparse telemetry reports Poco's maximum source RTP gap at 400 ms
(which includes DTX) and maximum admission time at 1 ms.

Relay TCP sampling also finds one established connection with 478 cumulative
retransmissions, 268710 retransmitted bytes and an RTO maximum of 1936 ms during
the captured stand lifecycle. These are connection-level counters, not a proven
mapping to the audio producer or to each pause. Other child connections have
no observed retransmissions; those facts cannot be generalized to every flow.

Attempts 2407 and 2408 compare both endpoints on QUIC without codec/buffer
changes. The latter uses a different previously normally mined owned relay
identity, checking the stale-address hypothesis. In both attempts Poco has an
owned QUIC session and Mac has none; actual transport preflight fails before a
call is started. Thus no audio comparison is obtained, and the precise cause
of Mac's QUIC connection failure remains open. The configured/repeated join
response alone is not treated as proof of lost connectivity.

All three stands verify owned Mac/phone/helper processes absent, the phone UID
empty, forwards removed, relay units stopped and private remote folders removed.
The Mac bundle seal remains valid. The queue isolation correction and these
measurements are committed unsigned and unpushed. Physical pause elimination,
video recovery, file/screen coexistence and acoustic speech quality remain open.

### UDP controls and a completed both-QUIC call — 2026-10-09

The previous turn is progress: SDK c94c8be3/root a2fb791d correct direct
signaling isolation and record an authenticated audio arrival boundary. The
current source trees are clean at the start of this continuation and Poco is
available over ADB with build 2405. No client code, codec or jitter-buffer
configuration is changed in the measurements below.

Matching the owned relay's registered peer to Mac's reconnect diagnostics in
2407/2408 finds a 10-second transport connection timeout. Repeated joins log
`redialed=true`; stale registration alone does not explain the missing session.
Control 2410 runs a temporary echo listener on the otherwise free UDP port 443
of the same host. All 20 Mac 1200-byte probes return intact; median RTT is
41.81 ms. That excludes a blanket UDP-443 failure during this control, not
every QUIC-specific or intermittent failure.

Private transport-only probe 2411 uses the current veil-transport and patched
Quinn sources with self-signed test material, not an app identity/session. It
connects to the isolated relay's QUIC transport in 471 ms and closes without
exchanging application data. Its Rustls, AWS-LC and Quinn versions match the
client workspace; its separately resolved Tokio is 1.53.2 versus the installed
client's 1.52.3. Thus this is a transport/path control, not an identical embedded
runtime. The final wire-log SSH read fails with exit 255 and zero retained
bytes; no packet-capture conclusion is drawn from that missing artifact.
Relay cleanup succeeds independently, and a subsequent exact-unit audit verifies
both owned capture processes absent.

Stand 2412 starts both existing app builds on the same isolated relay and
performs three standalone QUIC probes while the apps are running. All succeed
(73, 175, 67 ms). Both app canonical sessions are then verified to be QUIC;
the topology controller stops before calling. The earlier Mac failures are
therefore not a persistent inability to use QUIC. Their precise transient cause
is not established. Ring takes 0.409 s; both endpoints become active at 2.784 s.
Microphones/cameras are requested on for a common 60-second active period.

| Both-QUIC 2412 measurement | Mac | Poco |
| --- | --- | --- |
| Median / maximum native audio delay | 231 / 518 ms | 324 / 716 ms |
| Maximum sampled native receive age | 10785 ms | 12209 ms |
| Cumulative native interruption count | 13 | 11 |
| Cumulative native interruption duration | 21959 ms | 21523 ms |
| Video transmitted / received | 0 / 0 | 0 / 0 |

The native diagnostic file appends across app launches. The initial private
analysis accidentally concatenates 2406's 2845 samples with 2412's new batch;
those combined timing/sequence figures are invalid. Re-analysis selects the
last `audio.rtp.ingress.begin` batch only: 2336 arrivals over 61.447 s. It shows
sequence gaps/reordering and a maximum actual arrival gap of 10362.823 ms.
Audio drain wait is median 0.014 ms, p99 0.029 ms, maximum 0.072 ms. Relative
arrival-versus-RTP phase spans 2129.256 ms; this includes sender pacing and path
variation, not a calibrated one-way network delay. Video remains held by audio
protection, with no concurrent file/screen load or acoustic speech proof.

The owned Poco-to-relay session records no-ACK recovery attempts, outgoing
datagram expirations, two 3-second replacement binding timeouts and a keepalive
teardown with probe age 10942 ms and genuine-data receive age 5000 ms. The
existing authenticated child activity feeds parent liveness; it is not simply
ignored by the timer. Relay snapshots reach PTO count 4 and 317 outgoing
expirations; Poco snapshots reach PTO count 5 and 300 expirations. Local dispatch
maxima are about 1.3 ms, relay timer lateness is below 3.3 ms and event handling
below 4.9 ms. These observations locate a transport-progress failure/reconnect
episode, but do not distinguish carrier loss, endpoint scheduling/pacing or
every upstream cause. The completed QUIC call disproves a TCP-only explanation.

All owned echo, capture, relay, app/helper processes and forwards are verified
closed; private remote directories are removed and Poco's package has no process.
No production relay or host routing setting is changed. Audio/source separation
is retained, but pause elimination, recovery quality, simultaneous file/screen
operation and acoustic speech quality remain unverified. The goal stays active.

### Generic outgoing datagram recovery — 2026-10-09

SDK 4a754fa6 extends authenticated replacement from the primary local source
to every recently selected outgoing datagram child in the bounded session
pool. Opaque forwarded traffic previously never entered the replacement
policy. Each physical channel now observes its own ACK progress, PTO,
in-flight bytes and expired unsent datagrams. Idle ACK silence alone does not
start a replacement. A session-wide round-robin schedule permits one pending
replacement and spaces attempts by two seconds, without inspecting source
roles, payloads or queue hints. The existing connection quota and shared
reliable channel are unchanged; no priority or recovery field is sent on wire.

The old sender remains usable until the candidate's exporter-bound proof is
verified. A failed candidate does not displace it. Genuine old-channel ACK
progress cancels a still-pending candidate; an already verified candidate wins
the existing ACK race. Cold-channel retry delay does not additionally delay
replacement of a usable old sender. The first generalized implementation did
add that extra 500 ms and failed two existing source recovery gates. An exact
old-code/old-fixture control passed; removing the extra wait restores those
gates without relaxing their 600 ms threshold.

The new real TLS/QUIC fixture carries neutral Delivery::Forward cells in both
directions with all six ordinary child slots occupied, then cuts its uniformly
treated link for four seconds. A replacement-disabled control must reproduce
delayed recovery. With recovery enabled, both directions authenticate a new
channel, deliver fresh cells within 600 ms after link restoration, avoid
duplicates, and resume faster than the control. This fixture exercises actual
selection, binding and encrypted datagram I/O, not the full relay dispatcher.
The four existing production two-relay Forward gates separately pass for QUIC
and obfs4/TCP, including actual canonical rekey. The complete session suite
passes 490 tests, with six existing tests and one doctest ignored. Changed
files pass rustfmt and whitespace checks. No new physical call result is
claimed at this point; clients and the owned relay are being rebuilt together.

### Physical P2P control after generic recovery — 2026-10-09

SDK 4a754fa6/root 6dae70ce builds the Mac and Android native clients and the
owned Linux musl relay. Both apps identify as 0.13.84+2414. Mac retains
production media build 2405 (opt-in RTP metadata); Poco retains media 2374.
Mac code sections match the freshly built libraries and its bundle seal is
valid. Poco installs in place with the same signer; the pulled installed APK
matches the verified package exactly. Identities and history are preserved.

Stand 2414 verifies both bootstrap canonical connections to the owned relay
as QUIC and stops topology closures before calling. Unlike 2399/2401/2404/
2406/2412, whose active-call samples all report `relay`, every active 2414
sample reports `p2p` at both ends. Direct AppRtData channel logs corroborate
that route. Therefore this physical call does not verify the new relay-side
recovery or provide a comparison on the same route as those earlier calls.
Ring takes 0.419 s; both ends are active at 1.777 s. Microphones/cameras remain
requested on throughout the common 60-second period, with no file/screen load.

| P2P 2414 measurement | Mac | Poco |
| --- | --- | --- |
| Median / maximum native audio delay | 172 / 569 ms | 456 / 895 ms |
| Maximum sampled native receive age | 2235 ms | 2369 ms |
| Cumulative native interruptions / duration | 14 / 13862 ms | 14 / 9484 ms |
| Video transmitted / received | 0 / 0 | 0 / 0 |

The fresh Mac RTP batch contains 3026 packets over 60.969 s, sequence gaps and
891 adjacent arrivals less than 1 ms apart. Its largest adjacent-sequence,
20-ms-RTP arrival interval is 1265.666 ms. Drain wait is median 0.013 ms,
p99 0.023 ms and maximum 0.064 ms. Sparse authenticated cell samples match
66 Poco-to-Mac and 44 Mac-to-Poco cells, with relative send-to-receive delay
spans of 1335/1043 ms. The sampled local source path from native direct send
through socket write, daemon read and session admission takes at most 1/4 ms
on Mac/Poco; sampled receiver SDK delivery takes at most 0.617/5.805 ms.

Existing encrypted UDP fingerprints independently match 351 Poco-to-Mac and
268 Mac-to-Poco datagrams, all with receiver kernel timestamps. Relative
send-to-kernel phase spans are 1388.836/2396.702 ms. Kernel-to-socket-read
maxima are 1.627 ms on Mac and 3.728 ms on Poco. Millisecond log quantization
can produce sub-millisecond negative differences; 30 Poco observations share
a GRO timestamp. These are software kernel receipt stamps, not radio/hardware
arrival times. They establish latency variation before the userspace receiver,
without locating its precise lower-stack, modem or carrier cause, calibrating
absolute one-way latency, or identifying encrypted UDP samples as audio.

Mac starts eight outgoing child replacements: seven cancel after old-channel
ACK progress and one verifies/switches. Poco starts none. No change to that
policy is justified solely by this observation. All owned apps/helpers are
verified absent, Poco's UID and ADB forward are empty, the three exact relay/
collector/capture units have MainPID=0 and are inactive, and the remote folder
is removed. The quality goal remains active; an explicit authenticated relay
control is next, with no stored policy change.

### Relay controls and closed-child ownership — 2026-10-09

Stand 2415 starts on relay but upgrades to P2P after 5.256 s; it is not a
60-second relay control. Stand 2416 waits for direct readiness, requests the
existing authenticated relay recovery, then verifies relay at both ends for
60.32 s. Its owned canonical connections are QUIC, and actual Forward sends
confirm the owned relay carries the call. Both cameras and microphones are
requested on; video still transmits no frames. Ring takes 18.897 s and both
ends are active at 20.202 s, so call setup delay also remains unresolved.

| Pure relay 2416 measurement | Mac | Poco |
| --- | --- | --- |
| Median / maximum native audio delay | 303 / 1362 ms | 331 / 520 ms |
| Maximum sampled receive age | 13548 ms | 10008 ms |
| Interruption counter increments | 23 | 25 |
| Interruption duration increments | 43255 ms | 25091 ms |

Poco's counters reset once during that phase. The table sums positive changes
and values after a reset rather than subtracting the final and initial values.
These remain native counters, not an acoustic intelligibility measurement.
Some final relay/packet captures hit SSH read deadlines and are partial.

Stands 2417/2418 instead expose only an owned obfs4/TCP listener. Their active
call samples stay on relay, but the calls end early. The private driver wrongly
described a null call state as a direct upgrade; its guard now requires an
active call explicitly reporting P2P. In 2418 both endpoints report a liveness
timeout after 23/24 s of silence. Mac receives 220 audio packets before the
stall, and Poco receives none. Importantly, Mac attempts **zero outgoing audio
RTP packets** in both 2417 and 2418, whereas it sends audio in 2414–2416.
Therefore Poco's missing audio does not establish a TCP delivery defect.
The opposite-direction stall still needs investigation: Poco queues 1084
audio RTP packets in 2418, but its owned relay session is eventually reaped
after an unacknowledged keepalive and stale genuine receive activity.

The fresh Mac audio-device log identifies a capture failure after a hardware
configuration notification: both the sink connection and fallback tap reject
the retained graph format. Playback restarts, while recording remains requested
and produces no RTP. SDK cb562e73 reconnects using `inputFormatForBus`, the
hardware format, rather than the retained output format. Apple documents both
[preserved connection formats after configuration changes](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
and the [input node's inability to convert hardware formats](https://developer.apple.com/documentation/avfaudio/avaudioinputnode).
The real Apple playback configuration/queued-teardown smoke passes; it does
not exercise microphone capture. Physical verification of this fix is next.

Separately, a strengthened real QUIC replacement/old-ACK race test reproduces
retained closed-child ownership on the preceding SDK: a strong in-flight
carrier reference continues returning a live ingress key after its child is
closed, pinning a downstream slot while the canonical parent remains active.
SDK 68518bc1 checks the actual transport's terminal state before exposing that
key or spending send admission. A real encrypted ordered-record test covers
the same retained-reference case, fallback admission and slot reuse without
canonical rekey. This is a confirmed lifecycle defect; it has not been shown
to cause these physical call stalls. Production carrier witnesses are weak.

Verification passes 491 session tests (six existing ignored), 145 transport
tests and four production two-relay Forward/rekey gates over QUIC and TCP.
Changed Rust files pass rustfmt and whitespace checks. The Mac media rebuild
exports no test hooks. No relay traffic roles, admission priorities, wire
fields, connection quotas or persistent network preferences change.
Owned apps/helpers from 2415–2418 are closed, their UID/ADB forward cleared,
and all exact relay/capture/collector units are inactive with MainPID=0;
their remote directories are removed. Physical quality remains unresolved.

### Physical capture verification and relay control separation — 2026-10-09

Build 0.13.84+2420 packages SDK 68518bc1 on both clients and the owned Linux
relay, production Mac media 2420 and unchanged Android media 2374. Code-section
comparison, production exports, bundle sealing, same-signer in-place Android
installation and installed-package verification pass. Stand 2420 again uses
only the owned TCP listener and stops topology closures before the call.

The previous capture failure does not recur: Mac attempts/sends 1877 audio
RTP packets, including 1869 payload packets, with no capture-format exception.
Poco's SDK receives 1895 records on the corresponding independent connection,
and the relay receives/forwards the same record count. This verifies restored
capture and network record progress, **not** remote audio playout: Poco never
receives the call answer and therefore never starts its media engine. The
callee rings at 0.814 s and becomes active; the caller stays dialing until the
stand's 45-second setup gate ends the run. Later health/transport signals
arrive, but neither live nor durable answer retries appear in its call log.

The relay's complete compressed captures now survive collection. Mac reports
133 reliable-writer pressure observations on its owned relay connection.
Control's compatibility relay encoding omits the generic datagram suffix even
when the first hop explicitly negotiated support; that leaves control sharing
the reliable writer, unlike the progressing media connection. This establishes
a separation gap, without yet proving it accounts for the missing answer.

The repair uses existing neutral INTERACTIVE datagrams for agreed first-hop
connections, including cached per-device/identity fan-out. First hops without
that negotiation retain the suffix-free encoding. No new role, scheduling
priority, key authority or plaintext is exposed. A mixed-capability source test
fails on preceding code at the datagram eligibility assertion, then passes
after repair; it exercises both ordinary and cached-device branches, preserves
the same authenticated ciphertext across copies and verifies the older wire
shape. IPC passes 150 tests, with five existing ignored and one doctest ignored.
Physical verification of the control change remains outstanding.

Stand 2420's apps/helpers have exited, the phone UID and ADB forward are clear,
the three exact remote units have MainPID=0/inactive, their directory is removed
and the Mac seal remains valid. No acoustic speech, simultaneous file/screen
load or successful video transmission is claimed for this run.

### Physical TCP relay control after negotiated signaling — 2026-10-09

Build 0.13.84+2422 packages SDK 1d1d6c0c on both clients and the owned relay;
Mac media stays 2420 and Android media stays 2374. Fresh library/code-section,
export/seal and installed same-signer APK verification pass. Four real
two-relay Forward/rekey integration gates also pass after the IPC change.
The first stand (2422) fails before apps launch with AddressInUse and is
cleaned up. Retry 2423 checks separate TCP/reflector ports before launching;
it changes no persistent network policy and closes no other process.

The 2423 call rings at 0.419 s, both endpoints become active at 2.420 s, and
authenticated relay recovery is confirmed at 3.207 s. Every sampled active
endpoint stays explicitly on relay for the subsequent 60.226 s. Both owned
canonical connections use TCP; the topology controller is stopped before
calling. Unlike 2420, the answer reaches Poco and both media engines run.
This single physical success does not prove the earlier missing-answer cause
or all reconnect cases fixed. Both cameras/microphones are requested on.

| Pure TCP relay 2423 measurement | Mac | Poco |
| --- | --- | --- |
| Median / maximum native audio delay | 378 / 440 ms | 330 / 522 ms |
| Median / maximum sampled receive age | 15 / 659 ms | 155 / 2437 ms |
| Interruption counter increments | 3 | 11 |
| Interruption duration increments | 1376 ms | 7550 ms |
| Maximum outgoing / incoming audio packet count | 1584 / 3001 | 3022 / 1404 |
| Video transmitted | 0 | 0 |

Counters do not reset during the measured phase. This is bidirectional network
audio progress without call timeout, not proof of continuous intelligible
speech. Residual interruptions and high playout buffering remain. Both ends
report video held by audio protection; video has not been verified working.
No file/screen load or buffer/codec changes are introduced for this comparison.

All captures collect completely. Owned apps/helpers are absent, the phone UID
and ADB forward are clear, all three exact remote units are inactive with
MainPID=0 and their directory is removed; Mac sealing passes. The overall
audio/video quality goal remains active.

### Speech observation and TCP unsent backlog — 2026-10-09

Stand 2425 uses the unchanged 2422 client/relay SDK and media libraries.
Ringing takes 0.417 s, both endpoints become active at 1.933 s and authenticated
relay recovery completes at 4.613 s. The subsequent 119.757 s of sampled active
calls stay on relay. The user confirms speaking intermittently, with nearby
phone/laptop causing audible echo; speech slightly breaks up on the computer.
The user did not assess playback on the phone. Speech intervals were not marked,
so interruption counters cannot be equated to seconds of lost spoken words.

| TCP relay 2425 measurement | Mac | Poco |
| --- | --- | --- |
| Median / maximum native audio delay | 208 / 577 ms | 208.5 / 900 ms |
| Maximum sampled receive age | 2696 ms | 4900 ms |
| Interruption counter increments | 36 | 29 |
| Interruption duration increments | 32114 ms | 27550 ms |
| Maximum outgoing / incoming audio packets | 4002 / 6028 | 6112 / 3893 |
| Video transmitted | 0 | 0 |

Counters do not reset. Cameras and microphones are enabled, but audio protection
holds video throughout; no working video is claimed. Repeat stand 2426 stops
before calling: the Mac has the temporary relay identity already registered but
does not establish the new owned canonical path. This is a stand setup failure,
not an observed call timeout. Both stands' owned apps/helpers have exited, the
phone UID/ADB forward are clear, all six exact remote units are inactive with
MainPID=0, their directories are removed and the owned Mac seal verifies.

Further analysis of the preceding 2423 run finds stable Mac capture timing:
sampled wall time minus captured PCM duration spans only 2 ms. Matched unique
authenticated endpoint cell samples have relative timing spans of 6042 ms for
Mac-to-Poco and 591 ms in reverse. These are relative spans with an unknown
clock offset, not calibrated one-way latency; generic cell samples include
control/RTCP and do not identify every cell as a spoken audio packet. Source
IPC stages for two late primary-slot samples are within the same logged
millisecond; sampled receiver SDK processing stays below 2.4 ms.

The owned relay's 0.2-second TCP snapshots expose an outgoing socket that grows
to 126942 bytes queued, including 116374 bytes not yet sent, while acknowledgments
stall and retransmissions occur. Its receive window remains nonzero. This
coincides with late endpoint samples; exact socket-to-channel correspondence
and the original network loss cause have not been established. The existing
64 KiB SO_SNDBUF request can become 128 KiB on Linux; a completed userspace
write/flush therefore does not mean bytes have left that kernel queue.

A separate real Linux socket probe with a stalled small-window reader measures
86800 unsent bytes under the preceding policy, 5208 with a 4096-byte
TCP_NOTSENT_LOWAT threshold, and 17360 with a 16384-byte threshold. All accepted
bytes arrive unchanged after reading resumes. This supports applying an equal
unsent readiness threshold to all Linux/Android TCP sockets, without any
payload classification, scheduling priority or wire-format change. The kernel
may overshoot the threshold by a segment/current write; it is not a strict
byte cap and does not bound already-transmitted unacknowledged data.
See the [Linux kernel socket policy documentation](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html).

SDK 5c207cd3 applies a best-effort 4096-byte TCP_NOTSENT_LOWAT to all
outgoing and accepted Linux/Android TCP sockets through their shared send-buffer
setup, including obfs4. Unsupported kernels retain the preceding SO_SNDBUF
clamp. macOS and other platforms retain their current policy. No application
role, per-user exception or new negotiation is introduced.

The new Linux regression fails on preceding code at the absent socket threshold
and passes after repair. It exercises a real stalled receiver, checks both
outgoing/accepted sockets, measures the actual unsent queue with SIOCOUTQNSD,
then verifies all accepted bytes unchanged after reads resume. Eight Linux
TCP/obfs4 regressions, 145 native Mac transport tests and four real two-relay
Forward/rekey gates pass. Physical sound/video and bulk throughput improvements
from this kernel change are not established by those gates.

### Physical TCP speech with unsent threshold — 2026-10-09

Both clients package 0.13.84+2427 / SDK 5c207cd3; the owned relay uses the same
SDK. Mac/Android media libraries remain 2420/2374. Fresh code-section/export/seal
checks and same-signer in-place phone installation pass; identity/history stay
intact. Stand 2428 allows an extra bounded canonical warmup after 2426's setup
failure and stops its topology controller before calling.

Ringing takes 0.780 s and both endpoints become active at 2.345 s. They remain
on relay without a direct upgrade; the stable relay measurement starts at
17.382 s and spans 119.914 s. The user is instructed to speak first into Poco
and then the computer, with private instruction timestamps preserved. The user
describes the resulting connection as feeling poor; direction-specific audible
quality is not supplied. These are instruction windows, not a recording or
transcription of exact speech intervals.

| TCP relay 2428 measurement | Mac | Poco |
| --- | --- | --- |
| Median / maximum native audio delay | 299 / 623 ms | 188 / 633 ms |
| Maximum sampled receive age | 13155 ms | 15980 ms |
| Interruption counter increments | 24 | 28 |
| Interruption duration increments | 19136 ms | 27507 ms |
| Maximum outgoing / incoming audio packets | 6018 / 5903 | 7127 / 4670 |
| Video transmitted | 0 | 0 |

Counters do not reset; audio protection still holds both enabled cameras.
Receive ages grow at the end while the app reports an active call. At 129.814 s
Poco's owned canonical session is reaped after an unacknowledged probe and
13317 ms of stale authenticated data. Its late generic receiver trace shows no
decode rejections, but little complete dispatched traffic. The relay still
observes byte/ACK progress on some other connections during this interval;
this does not establish a total radio outage or a single kernel-queue cause.

TCP_NOTSENT_LOWAT does not provide the hoped-for small hard queue bound in this
physical run: the owned relay reaches 65024 unsent bytes on one socket. The
small-window Linux regression demonstrates its own scenario, not an 8 KiB bound
for all congestion/window patterns. Further transport/recovery work is required;
no sound/video quality fix or improvement over 2425 is claimed. No file/screen
load is introduced. Owned apps/helpers exit, the phone UID/ADB forward are clear,
the three exact remote units stop and their directory is removed; Mac sealing
passes. The overall goal remains active.

### Local relay recovery without inbound signaling — 2026-10-09

The call heartbeat already detects a silent receive stream after its ten-second
grace and asks the peer to repair. Its local fallback previously handles only
P2P; on relay, loss of the peer's health/request signal leaves local recovery
unstarted. The media controller's separate self-heal covers a stalled local
worker with continuing ingress, which does not cover absent network ingress.

The heartbeat now also invokes the existing guarded local repair for an active
silent relay call. It keeps the agreed route, existing ten-second grace,
rebuild suppression and fresh receive-session grace. Peer repair requests still
use the existing live signaling paths. No mailbox delivery or network priority
is introduced. A regression fails on preceding code (zero local repairs without
a peer heartbeat) and passes after the change; it also covers pending rebuilds
and replacement-session grace. A healthy flowing relay call remains unrepaired.
Physical verification of this recovery change is still required.

### Physical relay receive rebuilding and subjective speech — 2026-10-09

The recovery change passes 149 call-service/route-operation tests and is
committed as cc5b3823. Build 0.13.84+2429 packages it on both clients with the
unchanged 5c207cd3 SDK and 2420/2374 media libraries. Fresh library/seal checks
and same-signer in-place phone installation pass. Stand 2430 rings at 1.884 s,
both endpoints are active at 3.282 s and authenticated relay recovery finishes
at 5.275 s; 159.807 s of subsequent samples remain explicitly on relay.

Both endpoints complete one native relay-session rebuild without ending the
call: Mac's new epoch appears at 42.348 s and Poco's rebuild spans sampled
45.298–45.781 s. There are no local-worker-starvation or rebuild-failure logs.
These rebuilds occur during natural stalls, before fault injection. The user
reports that sound is better in this run. This is subjective improvement,
not a controlled proof of uninterrupted speech or an attribution of every
rebuild to the local heartbeat rather than a possible peer request. An explicit
local-heartbeat diagnostic is added for subsequent attribution.

Only the owned relay process is then paused by SIGSTOP for 15.000 s at call
124.024–139.024 s, with a guarded finally restoring SIGCONT. Both calls remain
active and receive audio afterwards. Some audio arrives during that interval;
the stand does not isolate all alternate routes, so this is not proof of
recovery from a complete network blackout. No new media-session rebuild is
observed during this injected pause.

Before injection, maximum sampled receive ages still reach 13081 ms on Mac
and 10025 ms on Poco. Interruption counters reset once with each rebuild;
summing positive changes gives 31 / 51 interruptions and 29556 / 60730 ms
of interruption duration over that phase. These counters include silence and
do not measure missing spoken words. After relay resume, maximum receive ages
are 680 / 664 ms, with 2 / 4 interruption increments (615 / 1136 ms). Cameras
remain enabled but video transmission stays zero under audio protection.

Three Mac samples immediately after the remote rebuild report an implausible
native delay estimate of 174765–174787 ms while jitter-buffer values are
164–504 ms and the call is only about 48 s old. This is a further timing-metric
anomaly to investigate, not evidence of 174-second speech latency.

Owned apps/helpers exit, the phone UID/ADB forward are clear, the exact three
remote units have MainPID=0/inactive and their directory is removed; the owned
Mac seal verifies. Long natural stalls, video and timing-estimate correctness
remain unresolved. No release or push is made.


### Audio playout measurement after a sender rebuild (2026-10-09)

A real Opus/NetEq regression keeps the receiver and authenticated channel
alive while recreating the sender twice, retaining queued old RTP. The
identity-derived SSRC stays the same but the RTP timestamp origin changes.
The old exported delay reaches 174787 ms while the actual buffer peaks at
63 ms and six decoded tone markers arrive within 80–144 ms; the new
regression rejects this inconsistent adaptation input.

Veil now exports `audio_delay_ms` from the actual number of queued audio
samples plus the ADM's reported playout delay. The original timestamp-span
filter remains visible as `audio_filtered_delay_ms`; NetEq itself and its RTP
timeline are unchanged. Both individual and group playout feedback use the
new measurement. This is local queue telemetry, not a one-way network delay
measurement. Existing receive freshness, worker-stall, losses and interruption
checks still apply, and relay scheduling/metadata are unchanged.

The fixed sender-rebuild case peaks at 56 ms with six PCM marker latencies
79–99 ms. Five additional real PCM cases pass: silence after jitter, delayed
packet batches, dropped packets, synchronous and asynchronous channel
handover. A further backlog gate measures 402 ms in both actual buffered
samples and the exported signal, then recovers six tone markers within
100–182 ms: genuine accumulated audio is not hidden by a delay ceiling.
All 62 app bitrate-adaptation tests pass. These native tests use a synthetic
ADM, not physical microphones or a cellular path; long physical-network
stalls and simultaneous media/other-traffic verification remain outstanding.


#### Physical build 2432 / stand 2434

Both owned clients use production media built from veil 71da840d, with no
native test exports. The unchanged Rust FFI/temporary relay binaries remain
from 5c207cd3; the cached-binary gate verifies that intervening SDK changes
are confined to `flutter/veil_media/`. The signed phone APK is replaced in
place and its installed bytes are verified; the owned Mac code sections and
strict app seal match the fresh production build. Identities are preserved.
The private media-build VM is stopped and Docker's `colima` context/default
VM are preserved. A first setup attempt loses its SSH status channel before
apps launch; its exact relay directory/unit are removed, then a fresh stand
uses a bounded retry for the read-only startup check.

The phone-originated call rings after 0.413 s, both endpoints are active at
2.648 s, and relay routes remain stable at 17.963 s. There are 428 subsequent
samples spanning 159.824 s with both active on relay. The initial owned TCP
canonical path is verified; public alternate connections can reappear and
this is not an exclusive-route isolation test. No media rebuild or local
silent-relay repair occurs. Current playout queue medians/maxima are 374/513
ms on Mac and 144.5/593 ms on Poco; raw filtered medians/maxima are 359/702
and 487/1601 ms. Maximum accepted-audio receive ages in this relay phase are
641/2798 ms. Interruption increments are 11/33 (4020/18457 ms), with no
counter reset; these include silence and do not measure lost spoken words.

Cameras stay enabled on both endpoints, but video transmission and remote
frames remain zero under audio protection. A 2-MiB attachment offer arrives
on the phone; its concurrent plaintext download fails after 170.111 s and
is cancelled. The phone logs 24 stream attempts and missing manifests; Mac
logs six authorization denials from one stream origin that differs from the
phone's logical identity, plus three stream resets. Both clients report
secondary identities. Device-origin authentication/mapping needs a separate
check before attributing this failure to bandwidth or stream scheduling.
No authorization gate is relaxed. Simultaneous video/screen/file transfer
has therefore not passed, and physical audio buffering remains unresolved.

Owned Mac/logcat/topology processes are audited absent, the phone package
UID and owned ADB forward are clear, and all three exact remote units report
MainPID=0/inactive with their directory removed. The Mac seal verifies after
stand-log removal. No push or release is made.


#### Verified device binding on realtime control (2026-10-09)

A read-only stand probe confirms the rejected stream origin is Poco's actual
transport device address; both contact rows are accepted. Mac's transport,
invite and receive addresses coincide, while Poco's transport differs from
its identity. The earlier application `isMaster` flag alone did not establish
the transport-address relationship.

The realtime adapter omitted `srcDevice`, and the separate control dispatcher
did not retain the authenticated device/identity relation learned on that
lane. It now uses the ordinary inbound conversion and shares the verified
binding helper. Offers and endpoint announcements still pass their existing
provenance/consent gates; claimed follow-ups cannot bind a device. Binding
happens before event dedup so a later authenticated copy can add evidence
without delivering the event twice. File-stream authorization is unchanged:
unverified DHT owner claims cannot authorize content.

A new offer regression fails against the previous code, then passes with the
fix. Additional gates cover claimed answers and duplicate endpoint evidence;
an end-to-end stream test downloads and compares file bytes after learning
the device solely from authenticated realtime control. All 95 tests across
realtime call signaling, inbound conversion and content streams pass. These
are local tests; the next physical stand checks whether the native delivery
actually supplies the proof. Probe apps/logcat have exited, the phone package
UID and owned forward are absent, and the Mac seal verifies after log removal.

The root fix is committed as e4356d0c (unsigned, unpushed). Owned Mac build
2436 completes and passes strict seal/code-section verification, reusing
production native media build 2432 and unchanged FFI 5c207cd3. It has not
been launched. Poco remains on build 2432; no Android packaging/install or
new physical call is performed after the goal reports paused. The planned
physical validation therefore remains pending. All probe-owned processes
and forwards are already audited absent.


#### Resumed physical validation: build 2436 / stand 2437

The goal resumes. Android build 2436 installs in place with the same signer;
installed native-library bytes match the expected production build. Mac stays
on owned build 2436; both reuse media 2432/FFI 5c207cd3. The phone-originated
call rings at 0.403 s, Mac accepts, but Poco remains dialing until the stand's
45.138-second setup observation gate ends. The ordinary answer is logged on
Poco with an age of 43996 ms just before that cutoff. This is a stand cutoff,
not the app's 75-second ring timeout. Mac's fast answer retries occur promptly
at about 0.27, 0.66, 1.55 and 3.19 s after the first answer; a stalled retry
timer therefore does not explain this failure. Healthy-call/audio/file/video
validation has not run in this attempt.

Mac records one authenticated realtime device binding, confirming native
delivery supplies the evidence needed by the new helper. Stand 2437's exact
owned apps/helpers are absent, phone UID/forward are clear, all three remote
units report MainPID=0/inactive with their directory removed, and strict Mac
sealing passes. The next same-build run reverses the caller and observes setup
for the app's actual ring window to separate the measured delivery delay from
the previous stand's shorter cutoff.


#### Verified device contact rows: stand 2438 and repair

With the same build 2436, Mac-originated calling rings at 0.395 s, both ends
are active at 2.342 s and relay routes stabilize at 17.639 s. There are 422
both-active relay samples spanning 159.776 s, with no media-epoch reset and
no local outgoing audio RTP drops. Audio receive-age maxima are 6754/7588 ms
(Mac/Poco); actual playout queue medians/maxima are 391/571 and 49/531 ms.
Interruption increments are 21/17 with 30799/34261 ms duration. These counters
include silence; they are not a measure of missing spoken words. Cameras stay
on, but transmitted/remote video frames remain zero under audio protection.
The concurrent 2-MiB file offer arrives, yet download fails after 190.763 s.
All exact owned apps/helpers, phone UID/forward and three remote units are
audited stopped; the remote directory and failed fixture are removed and the
Mac seal passes. This still does not verify simultaneous healthy media/file
traffic, or establish a causal comparison with earlier stands.

The bounded final dev-log ring lacked the early device proof. The complete
owned app log does contain it: Poco's actual transport device is correctly
bound to its accepted logical contact before serving. Nineteen stream denials
name that same device. The read-only contact probe also contains a legacy
`pendingIncoming` row under the device address. The serving gate's direct-row
`??` precedence lets that pending row mask the accepted identity; the P2P
policy helper has the same precedence. No missing native proof is established
by this run: the earlier partial-log interpretation was incorrect.

The common contact selector now lives in a pure domain helper used by stream
serving, ordinary P2P policy and all-online identity sessions. A verified owner
selects the identity's contact settings/consent even when the device has a
pending row. An explicit device block still wins; an accepted device cannot
bypass a blocked/pending/unknown verified owner. Unproven devices use only
their own contact row; source claims and unverified DHT aliases grant nothing.

The realtime-only stream regression gains the physical stand's pending device
row and fails on the old precedence, then passes with the repair and compares
all downloaded bytes. Owner/device status combinations and unknown-owner
gates pass alongside existing content authorization, transfer and realtime
control tests: 106 tests total. Physical confirmation remains pending.


#### Physical contact-precedence verification: build 2439 / stand 2440

The committed fix 677e68a6 is packaged on both owned clients as build 2439.
Production media stays build 2432/SDK 71da840d; unchanged FFI/relay binaries
stay 5c207cd3. Strict Mac seal/code-section and installed same-signer Android
package/library verification pass. Before calling, Mac's contact snapshot
confirms the actual Poco device row is still `pendingIncoming` while its
identity row is accepted; the repro data is preserved.

Mac-originated calling rings at 0.766 s, both ends become active at 2.660 s,
and direct readiness is seen before explicit authenticated relay recovery
at 5.168 s. Both routes report relay at 5.530 s. There are 423 subsequent
both-active relay samples spanning 159.876 s. Initial owned TCP canonical
connections are verified, but public alternate paths may reappear: this is
not exclusive owned-path isolation. Cameras/mics remain on; transmitted and
remote video frames stay zero under audio protection.

The concurrent 2-MiB plain-file download now succeeds with exact destination
SHA-256 and no stream authorization denial. Total transfer time is 177.054 s,
and the download finishes 31.965 s AFTER hangup. This proves end-to-end file
recovery with the old pending row, not full-speed concurrent file/media flow.
Normal bulk stream trace is disabled, so the capture cannot name the successful
carrier or attribute all waiting time to stream admission alone.

Audio receive-age maxima remain 2933/3585 ms (Mac/Poco). Actual playout queue
medians/maxima are 218/615 and 42/596 ms; interruption increments are 34/21
with 28498/20377 ms duration. No media epoch/counter reset or local audio RTP
drop occurs. These include silence and do not prove speech intelligibility.
The different initial direct path/setup and changing cellular conditions also
prevent attributing lower maxima to the contact-precedence fix.

Current endpoint source admission deliberately limits competing reliable data
to 1024 wire bytes per 200 ms under pressure (5 KiB/s shared across neighbors),
or 4096/200 ms during healthy primary activity (20 KiB/s); oversized frames
spend proportional future time. This is local policy, not relay priority. A
2-MiB file cannot be assumed to finish within a 160-second pressured call.
The next useful verification retains a healthy permitted P2P route instead of
forcing relay, observes actual file progress/idle behavior with bulk tracing,
and then verifies concurrent video/screen and audio. The source budget is not
relaxed merely to pass a file timer. Physical pauses and healthy simultaneous
video/screen/file operation still remain unresolved; the original goal is active.

All exact owned Mac/logcat/topology processes are absent, the phone package UID
and ADB forward are clear, all three remote units have MainPID=0/inactive with
their directory removed, the successful fixture is removed, and the Mac seal
passes. No SDK edit, push or release occurs in this cycle.


#### Natural route validation: build 2441 / stands 2442 and 2443

Both clients reuse production media build 2432 and FFI 5c207cd3. Build 2441
adds only the existing bulk-stream diagnostic define; same-signer Android
installation/package bytes and strict Mac seal/code sections verify.

Stand 2442 cannot establish P2P during its 65-second observation. Full native
logs, however, contain successful peer-to-peer punches during warmup and a
subsequent rejection of the actual phone device as banned. The stand topology
controller closes that direct session: `kill_session` also installs a 30-second
auto-ban. This contaminates the natural-route experiment. Its later NAT failures
are not clean evidence of an application traversal defect. No file or screen
phase runs. The next stand removes the topology controller entirely and never
requests relay recovery; other neighbor sessions are preserved.

In corrected stand 2443, Mac-originated ringing occurs at 0.385 s and both
ends become active/P2P at 1.733 s. The automatic media policy changes both
routes to relay at 25.786 s after established direct audio stops arriving.
No stand session closure occurs. There are 479 both-active samples spanning
180.342 s; media epoch remains 1. The direct phase's actual queue median/max
is 226/551 ms on Mac and 376/580 ms on Poco, with accepted-audio receive-age
maxima 2783/2971 ms. During the relay phase with BOTH microphones still on,
queue median/max is 317/589 and 90/583 ms, receive-age maxima 3542/3930 ms.
Outgoing audio admission maxima are 0/6 ms, with one Mac RTP drop near startup
and none on Poco. These are queue/ingress measurements, not acoustic latency
or proof of intelligibility; interruption counters also include silence.

At 95.847 s Poco's microphone intent becomes false and native recording stops.
The user confirms switching it off. Subsequent missing Poco-to-Mac audio is
therefore excluded from defect attribution and the both-microphones-on phase.
Cameras stay requested on; encoded/remote video remains zero under audio
protection. The test does not establish healthy simultaneous video and sound.

The concurrent 2-MiB file uses an initial direct-session manifest probe. The
payload's first attempt opens an anonymous stream, reads 10240 bytes and ends
on the existing 20-second payload-idle timeout. The second anonymous attempt
gets no manifest. A third direct-session attempt resumes; its final resume
point is piece 4/offset 1048576. The 240-second download observation expires,
257.139 s after the offer sequence starts and 92.216 s after hangup. No complete
destination digest is obtained. Server-side `queued`/`complete` trace messages
mean bytes accepted by the native writer, not bytes received by the peer.
This rules out treating the rapid serve trace as successful delivery. The
capture does not establish whether file opening causes the direct audio stall.

Only the exact owned Mac app window is selected for screen capture; there is
no fallback to whole-display capture. The debug API reports the request handled,
but its returned call and all subsequent samples have screenOn=false. No screen
frames or successful capture are claimed, and the specific start failure remains
unattributed. Native source inspection reveals a separate rollback defect:
desktop screen start stops the camera before opening its replacement, while
both one-to-one and group controllers leave that camera stopped on failure.

A shared desktop start transaction now rolls back the endpoint source queue
and restores camera capture only when current camera intent and the original
call/engine ownership still permit it. Capture rejection or exception returns
false; a disabled camera is not reopened. Successful screen capture keeps the
camera stopped. Group camera intent is retained while a share owns the source.
The group-controller regression fails for camera-on rejection/exception before
the repair and passes afterward. Six transaction tests, existing camera-state
tests and the full group-media module pass: 41 tests. Two pre-existing group
policy tests also fail against the unmodified controller: their healthy 140-ms
fixture exceeds the current 120-ms recovery threshold, and their delayed-audio
expectation predates the pause policy. Fixtures now use 100-ms healthy feedback,
expect an actual hold under pressure, and verify resume before climbing. No
production audio threshold is relaxed. Analysis of all five changed Dart files
passes. Owned Mac build 2444 packages the committed rollback repair;
its kernel version and transaction symbol, strict seal and original production
native code sections verify. Poco remains on build 2441. Subsequent stand 2445
physically verifies rollback, as recorded below.

Both stands' exact owned apps/logcat/helpers have exited; phone UID and forward
are clear; all three remote units per stand report MainPID=0/inactive and each
owned remote directory is removed. The failed plaintext fixture is removed and
strict Mac sealing passes. Raw captures stay private. SDK/network policy is
unchanged; no push/release occurs. Audio stalls, stable P2P and simultaneous
video/screen/file quality remain unresolved; the original goal stays active.


#### Isolated audio and camera rollback: stands 2445 and 2447

Mac build 2444 and Poco build 2441 retain media build 2432 and native FFI
5c207cd3. Neither stand closes neighbor sessions, runs the topology controller,
or requests relay recovery. Both microphones start on; subsequent user changes
are respected. The earlier Poco mute in stand 2443 is user-confirmed and remains
excluded from defect attribution.

Stand 2445 rings at 0.400 s, becomes active/P2P at 2.117 s and automatically
moves both media routes to relay at 29.651 s. The file phase does not begin until
77.149 s, so file opening is not necessary for this direct-audio failure. A fresh
64-KiB file completes before hangup, with the destination SHA-256 matching the
source. Its explicit plaintext save takes 115.002 s. The receiver also starts
an automatic encrypted download: that copy finishes earlier while the explicit
stream save continues. These observations must not be treated as the throughput
of one isolated transfer. Later redundant piece replies are dropped after the
automatic fetch has already completed.

Only the owned Mac app window is selected for screen capture. Start still
returns screenOn=false; the request-handled debug status is not a successful
capture. However, local camera frames now continue after failure: 3891 near
132 s, 4002 at 136 s, 4265 at 145 s and 4869 at 165 s. The previous build froze
at 3466 after the same failed transition. This physically verifies camera
rollback; it does not establish why capture itself fails or successful screen
transmission. Stable simultaneous audio/video/screen remains unverified.

Stand 2447 adds a private Mac syscall tracer to the owned process only. It
records UDP send/receive time, size, socket and addresses, never contents. A
local loopback smoke verifies unchanged bytes through sendto/recvfrom and
sendmsg/recvmsg, four UDP records, exclusion of TCP and mode 0600. The loaded
tracer PID matches the owned stand PID. No production bundle, global loader
setting, VPN, routing or relay policy is changed. The existing opt-in native
trace independently correlates sampled encrypted datagrams by fingerprint
across both clients and records their kernel receive timestamps.

This call is AUDIO ONLY, with no file or screen phase. Ringing is at 0.390 s,
both endpoints become active/P2P at 2.069 s and automatically change to relay
at 67.754 s. Both microphone intents stay on. Primary outgoing channels report
independent=true; each QUIC connection has its own flow/congestion state but
shares its parent's UDP endpoint. Actual audio queue medians/maxima during
P2P are 226.5/529 ms (Mac) and 89.5/551 ms (Poco); accepted-audio receive-age
maxima are 2827/2568 ms. After handover, queue medians/maxima are 463/595 and
437/507 ms, receive-age maxima 3894/5173 ms. Media epoch remains 1 and outgoing
audio admission maxima are 0/2 ms. Silence and background sound prevent these
counters from establishing speech intelligibility.

The Mac syscall peer port matches its baseline authenticated phone QUIC
session. Its incoming UDP has a 2.683-second gap immediately before handover,
while outgoing socket writes continue. Matching encrypted datagrams gives
158 phone-to-Mac and 298 Mac-to-phone observations while both routes still
report P2P. Send-to-receive wall-clock deltas vary by 2472/2404 ms respectively.
Device clocks differ, so these are within-direction delay spans, not absolute
one-way latency. For these matched samples the interval from kernel arrival
to endpoint trace is below 5 ms on Mac and below 3 ms on Poco; sub-millisecond
negative values reflect trace millisecond rounding. The long delay is already
present before arrival in the receiving OS. It includes sender kernel/driver,
network/NAT and receiver interface scheduling; this does not isolate the mobile
carrier or exclude other unsampled/local defects. In particular it is not
proof that a decoder, video transfer or file opening caused this path delay.

A separate file defect is reproduced with real messaging controllers: when an
automatic encrypted piece fetch is active, both one-holder and multi-holder
plaintext saves open an additional reliable stream for the same content.
Both regressions fail against the original controller with one extra network
open. The save paths now join the active encrypted fetch using the existing
parked-export path before trying a new stream; after verification the stored
copy is exported. An existing plaintext sink is not treated as an encrypted
fetch. Both new regressions pass and verify exact bytes, one sink close and no
second network open. The full stream-transfer, stale-fetch eviction, content
transfer and auto-resume modules pass: 81 tests. Analysis reports no errors or
warnings, with one pre-existing underscore-style information message in the
stream test fixture. Test build 0.13.84+2449 packages the committed repair
for Mac and Android. Mac strict sealing, source hashes and original native
code sections verify; Android signing, kernel version and all sixteen packaged
native libraries match the verified installed build 2441. The new Mac app is
not launched and the signed Android APK is not installed while Poco is absent.
Physical installation/verification of this repair is still pending; no claim
is made that it removes the file-independent pauses.

Both stands close their exact owned Mac/logcat processes and the phone app;
the normal cleanup checks the phone UID and forward absent while connected.
All three exact remote units per stand are inactive/MainPID=0 and each owned
remote directory is removed; strict Mac sealing passes. Stand 2445 also passes
a subsequent live phone audit. Poco disconnects from ADB after stand 2447;
the later phone audit is unavailable, while its earlier cleanup verification
is retained. Reconnection is requested for the next physical check. Raw
captures and correlation details remain in the private stand directory. No
SDK or relay policy change, push or release occurs; the original goal is active.


#### Desktop screen permission prerequisite: local stand 2451

A fresh continuation finds the worktree clean at 6c4c0246 and no Android devices
in the current ADB list. The preceding cycle made progress: it repaired active
file-fetch joining, passed 81 tests and produced verified build 2449. No old
stand/build process is assumed live or restarted from a state file.

With Poco unavailable, a read-only permission probe runs inside the exact owned
Mac build 2449 process. A test-only inserted library dispatches to that process's
main queue and calls CGPreflightScreenCaptureAccess; the probe PID matches the
launched app. Its result is false. It never calls CGRequestScreenCaptureAccess,
starts capture, records audio/video or changes TCC/system settings. Native source
inspection confirms both desktop backends require existing access or successful
user permission before starting. Thus screen transmission on the current test
build needs a user-granted OS permission. This is a current prerequisite check,
not a retrospective attribution of stand 2445's failure: the ad-hoc binary has
changed since that earlier capture attempt.

The app remains locked; unauthenticated health/devices requests return HTTP
errors and are not interpreted as media failures. The permission probe itself
does not depend on those API requests. The owned app is terminated, its exact
PID is absent, its runtime log is archived/removed from the bundle, and strict
sealing passes. The installed application, native libraries, network/relay
policy, VPN, routing and system permissions are unchanged. The user is asked
to grant screen recording for the test build; the earlier Poco reconnection
request remains pending. Audio-under-file-load verification, usable simultaneous
video/screen and the full original goal remain incomplete. Raw evidence stays
private; no push or release occurs.

#### Physical audio/file verification: stand 2453

Poco returns and receives signed build 0.13.84+2449 through an in-place install
with the existing signer. The pulled installed APK matches the verified artifact;
all sixteen packaged native libraries remain unchanged from build 2441. Identity,
history and ratchet state are preserved. The actual default network's transport
field reports CELLULAR, without WIFI or VPN; the NOT_VPN capability is not treated
as a VPN transport. Mac uses the verified owned build 2449. No production app,
relay policy, OS permission or network setting is changed.

This stand observes natural routing without closing neighbor sessions, adding
bans or requesting relay recovery. Both canonical relay connections are verified,
but the network is not claimed to be isolated to that relay. Ringing takes 4.941 s,
both endpoints become active at 6.775 s and report P2P at 9.514 s. A fresh 64-KiB
Mac-to-Poco attachment starts at 81.939 s. Both endpoints change to relay at
184.414 s; the requested 210-second active call finishes without an endpoint
timeout. Both microphones remain enabled in the sampled call state. The user
speaks intermittently and reports no apparent interruptions. This is useful
listening feedback, not a complete speech-quality or latency measurement.

Before the file starts, receive-queue medians/maxima are 380/525 ms on Mac and
376/602 ms on Poco. During the direct-route file phase they are 301/525 and
312/524 ms; accepted-audio receive-age maxima reach 3964/3752 ms. After handover,
receive-age maxima reach 2327/6806 ms. The media epoch stays 1, and outgoing audio
admission maxima remain 0/3 ms. Cameras capture roughly 30 fps, but encoded and
remote video frame counters stay zero: the audio-protection policy remains paused.
This does not verify working video or sufficient simultaneous audio/video quality.
Screen capture is intentionally not requested because the read-only permission
probe for the exact current Mac build still reports no access.

The attachment eventually passes exact destination SHA-256 verification, but
takes 265.048 s from the offer, finishing about 130 s after hangup. Early stream
manifest probes time out; the first payload attempt stalls after 4096/65536 bytes,
and retries follow. Sender `stream-serve complete` logs only queued writes and are
not interpreted as delivery. This run does not reproduce the active-fetch join
regression: the explicit save starts after a stream-materialized offer, with no
logged active encrypted fetch to join. Inline manifests arrive much later and the
pending plaintext save suppresses automatic download. Thus installing the join
repair is physically verified, while this run neither establishes that it fixes
these stream stalls nor proves its no-second-stream case on the phones.

Exact sampled encrypted UDP matches in a bounded direct-route interval provide
648 phone-to-Mac and 722 Mac-to-phone observations. Within-direction wall-clock
delay spans are 830/813 ms, not absolute one-way latency because device clocks
differ. Kernel-arrival-to-endpoint-trace maxima are 6.2/5.9 ms; small negative
values reflect millisecond rounding. These samples cover generic connections,
not exclusively audio. Reflector addresses are kept separate from peer endpoints.
The measurements do not identify the cause of the reliable stream stalls.

Cleanup verifies the phone app's UID/package absent while USB is still connected,
removes its own forward and deletes the verified plaintext fixture. Exact owned
Mac/logcat PIDs exit, the three exact remote units are inactive with MainPID=0,
the owned remote directory is removed, and strict Mac sealing passes. A later
phone audit is unavailable after USB disconnects; the earlier live cleanup proof
is retained instead of reporting an absent device as a running app. Reconnection
is requested for the next measurement. Evidence remains private. The original
goal stays active: reliable file latency, healthy audio under load and usable
simultaneous video/screen remain unresolved. No push or release occurs.

#### Endpoint reliable admission fairness: stand 2454 and build 2455

The next continuation checks both worktrees clean and initially finds no phone
in ADB. Stand 2453's native pressure traces show a deep reliable queue before
the test file starts: Poco reports depth 286 near 76 seconds and 288 near
78 seconds; Mac also has a queue above 100. Existing successful-admission traces
lack a peer field, so those captures cannot identify which runner consumed the
shared budget. These depths are an investigation lead, not proof that they
explain the attachment's full 265-second delay, especially its late completion
after audio stopped.

Source inspection and a deterministic negative test establish a separate
endpoint defect: a busy session runner can win each shared reliable byte-budget
deadline while another runner has eligible authored data waiting. Returning
both runners to the previous admission policy makes the new regression fail on
the first competing turn. This is an endpoint scheduling defect, without any
need for application roles, remote hints or relay priority.

Each runner now owns a local admission guard and joins a FIFO of waiting runners
before waiting for byte debt. A successful admission consumes its turn; the
runner can rejoin at the tail for its next frame. A drain pass without an
eligible waiting local write cancels its turn, and dropping the guard on session
exit does the same. Cancellation retains already charged byte debt. The existing
node-wide rates, whole-frame charges, primary audio reservation, separate recovery
allowance, reliable ordering and neutral transit handling remain in place. Source
admission diagnostics now include the existing peer identifier for correlation.
No queue position, media role or new scheduling field is put on the wire.

The regression deliberately wakes the busy runner first at every deadline across
16 competing turns and checks alternating progress without multiplying the
global allowance. Further cases cover cancellation, session exit, retained debt,
independent recovery allowance and primary-idle expiry. All 11 local-source tests
pass. The full veil-session suite passes 494 tests, with 6 existing ignored tests
and one ignored doctest, including real QUIC backlog, primary isolation and
neutral transit coverage. The later diagnostic peer-field addition changes no
scheduling behavior and compiles in both platform builds. SDK commit 450218d0
contains the repair; both production-feature FFI builds succeed. The Mac FFI's
183 public veil/UniFFI exports match the previous bundled library.

Owned test build 0.13.84+2455 is prepared for Mac and Android. Mac strict sealing,
kernel version and native code-section comparisons pass. The signed Android APK
has the same signer as build 2449, the expected kernel/version code and sixteen
native libraries; only libveilclient_ffi changes, while the media library remains
the verified build 2432. APK construction initially fails during overlapping
Flutter package refreshes; after the Mac build exits, Android builds sequentially
with --no-pub. No application source or dependency is changed for that retry.

Poco reappears and receives build 2455 through a same-signer in-place replacement;
pulling the installed APK verifies its exact signed bytes. Before launching the
next stand, the actual default network reports WIFI. The test is held before
starting any app/call and the user is asked to restore the intended cellular
connection. Network settings are not changed. The owned Mac build is not launched,
and the phone test app is not started by this cycle. Stand 2456 helpers are prepared
with natural routing and an unchanged older relay for wire compatibility, but the
physical comparison has not run. Thus no claim is made that this repair fixes the
observed file stalls, restores usable video, or completes the audio-first goal.
Commits remain unsigned and unpushed; no release or production-app replacement
occurs. Evidence and signed stand artifacts remain private.

#### Cellular comparison and mixed relay paths: stand 2456

After the user disables Wi-Fi, the actual default network reports CELLULAR,
without WIFI or VPN. Verified build 0.13.84+2455 runs on both endpoints with SDK
450218d0 and unchanged native media build 2432. The owned neutral relay remains
at compatible SDK 5c207cd3. Natural routing is observed; other neighbors remain
connected and the test is not claimed to be isolated to that relay.

Ringing takes 1.174 s; both endpoints become active and report P2P at 2.252 s.
Both naturally switch to relay at 65.457 s, before the file offer at 77.311 s.
The fresh 64-KiB Mac-to-Poco file passes exact destination SHA-256 verification
63.380 s after its offer, before hangup. This improves on stand 2453's 265.048 s,
but changing network conditions and routes prevent attributing the improvement
solely to reliable admission fairness. The transfer remains slow.

This run exercises the active-fetch export repair: the inline manifest starts
an encrypted automatic fetch before the explicit download-to-file request.
The save logs that it is parked for export after the active fetch; exact saved
bytes subsequently pass verification. Early plaintext stream opens probe the
manifest and precede the explicit save; they are not a second stream opened by
that parked save. The verified destination fixture is deleted after the test.

Both microphones remain on in the sampled state. The user confirms audibility
but cannot speak because the household is asleep. This supplies no new speech
intelligibility, interruption or acoustic-latency verdict; no further audible
tests are started. Cameras capture about 30 fps, but encoded and remote video
frame counters stay zero and every sample reports video paused for audio.
Screen capture is not requested: permission has not been verified for this new
ad-hoc Mac build. The earlier build's permission result is not reused as proof.

Before handover, receive-queue median/max values are 347/527 ms on Mac and
230/530 ms on Poco. During the relay file phase they are 254/541 and
155.5/544 ms; accepted-audio receive-age maxima reach 5955/6074 ms. After the
file, queue medians/maxima are 143/619 and 42/612 ms. Media epoch remains 1 and
outgoing audio admission maxima remain 0/3 ms. These are packet/queue observations,
not measured acoustic latency. Usable simultaneous audio/video is not verified.

Bounded direct-route encrypted UDP matching yields 213 phone-to-Mac and 231
Mac-to-phone observations. Within-direction wall-clock delay spans are
1123/1223 ms, not absolute one-way delays; kernel-arrival-to-endpoint-trace
maxima are 2.3/2.1 ms. Generic connections and sampled delivered packets cannot
establish the timing of all audio or missing packets. Remote TCP capture is
incomplete after collection timeouts, so it cannot establish complete relay
write/arrival timing.

Origin traces reveal one primary source/destination pair using a negotiated
neutral datagram hop throughout the relay phase while also queueing a duplicate
through five other hops without that transport. Their 29 slow canonical
primary writes reach 5625 ms, including delays before the file offer. The
negotiated hop itself also has three slow canonical primary writes, up to
2316 ms: negotiated capability alone is not proof that every frame used a
separate child. Source inspection confirms that bounded origin diversity adds
the second copy after a successful datagram admission and can select an ordered
hop for it. These traces establish mixed origin carriers, not that every slow
copy reached the receiver or caused a particular audible interruption.

Final cleanup verifies the exact Mac and logcat PIDs exited, Poco's app UID is
absent while ADB is connected, and the owned forward is removed. All three owned
remote units are inactive with MainPID=0, the owned remote directory is removed,
and strict Mac sealing passes. Raw evidence remains private. The audio-first
goal remains incomplete; no release, push or production-app replacement occurs.

SDK commit c8b0026b repairs origin diversity for these small primary cells.
After a negotiated neutral datagram hop accepts a copy, additional copies stay
within that transport group. A second negotiated hop still receives identical
ciphertext and replay ID; one usable hop now receives one copy rather than
adding an ordered duplicate. If all negotiated-hop admissions fail, the existing
ordered compatibility fallback remains. Queue admission is still not receipt:
this intentionally reduces mixed-transport path diversity and needs a physical
comparison for delivery and audio quality. It neither fixes every canonical
fallback nor proves that the retained datagram route is healthy end to end.

A regression runs through the real IPC handler with zero, one and two negotiated
hops, plus first-hop and all-negotiated-hop refusal. The previous policy fails
the first case by admitting an extra ordered copy; this is an assertion failure,
not a compilation failure. With the repair, all 151 veil-ipc library tests pass,
with 5 existing ignored tests. Existing diversity, signaling, wire neutrality,
legacy fallback and request-isolation tests remain green. Only local origin
selection changes; relay scheduling, encrypted payloads and wire priorities do
not. This new revision has not yet been rebuilt into or installed on either
stand endpoint; build 2455 still contains SDK 450218d0. The physical results
above measure that earlier revision, not c8b0026b. No new audible test runs.

#### Quiet packaging and Poco update: build 2457

The continuation revalidates both worktrees clean at xVeil 46b66421 and SDK
c8b0026b. The previous cycle is progress: it changes origin route selection,
reproduces the old defect by assertion and passes the IPC suite. The household
is asleep, so no new calls or speech requests are made. This cycle prepares the
physical comparison rather than claiming a new audio-quality result.

Fresh production-feature FFI builds succeed for Mac and arm64 Android. Mac uses
the existing private native cache. The shared build volume has less than 1 GiB
free, so Android's existing host/cross release cache is copied to a private
directory on the main disk and built there; shared caches are not deleted or
replaced. Both raw FFI artifacts differ from the preserved SDK 450218d0 copies.
The Mac FFI retains the same 183 public veil/UniFFI exports. Source-commit and
clean-worktree guards cover both platform builds.

Owned test build 0.13.84+2457 is packaged sequentially for Mac and Android to
avoid the earlier Flutter package-refresh collision. Mac kernel version,
embedded SDK version, strict/deep sealing and bundled code-section comparisons
pass. Native media remains build 2432. The signed APK has the same signer as
installed build 2455, the exact expected stripped FFI/media bytes, version code
2457 and the correct embedded SDK version. Its sixteen native-library names
match the pulled baseline APK; only libveilclient_ffi.so changes.

Poco is available and its app is already stopped before installation. A
same-signer in-place update preserves application data, without uninstalling.
The installed APK is pulled back and matches the signed artifact byte for byte.
After installation the owned package is force-stopped and its entire UID is
verified absent. The owned Mac stand process is also absent and sealing still
passes. No apps or calls are launched in this cycle, no relay policy or network
setting is changed, and /Applications remains untouched. The phone now contains
the route-selection repair; the Mac stand bundle is ready for the next test.
Mixed-path delivery, healthy audio under load and usable simultaneous video
and screen still need runtime evidence. Commits remain unsigned and unpushed;
there is no release. Raw logs, snapshots and signed stand artifacts stay private.

#### Negotiated source channels retain separation during outages: quiet test 2458

The next cycle revalidates xVeil ebd0b9c9 and SDK c8b0026b clean. Build 2457 is
still the installed phone artifact and owned Mac stand bundle. That preceding
cycle is progress: fresh platform builds, verified packaging and an exact
same-signer installation make the earlier repair testable. No live call or
speech request is made while the household is asleep.

Source inspection finds a further separation defect in the session runner.
When a negotiated independent source child is not ready, QUIC selection can
return the canonical parent's DATAGRAM sender. Ordered selection returns no
sender and restores the lossy frame into the queue, where the reliable parent
writer can consume it. Encoding errors and permanent send failures can also
restore such frames to that writer. Thus negotiating children does not by itself
prevent a fresh source packet from sharing ordinary traffic's carrier.

SDK 60907142 now retains separation for trusted local lossy sources after
independent-child negotiation. An unavailable child, encoding error or permanent
send error drops that packet before any canonical encryption, instead of using
the parent. A failed selected sender is retired through the existing recovery
path. The next fresh packet can use a prepared replacement; old packets are not
replayed into another carrier. This can produce a gap while a child warms and
does not prove the radio/network can meet a particular latency target. Legacy
sessions without negotiated children keep compatibility, and neutral forwarded
INTERACTIVE traffic retains its existing selection and service. Wire roles,
relay priority and ordinary reliable frame handling are unchanged.

The negative regression runs the real scheduler, FrameOutbox and QUIC sockets
with the recipient's child registration initially absent. Before the repair a
source packet arrives on the actual canonical DATAGRAM connection and fails the
parent-isolation assertion. A separate real obfs4/TCP test disables only the new
predicate to reproduce ordered fallback; its parent stream receives source
bytes and fails by assertion. These negative controls compile successfully.
With the repair, the QUIC case observes actual delivery on all three independent
source planes while finding neither canonical UDP data nor ordered parent data.
The obfs4/TCP case finds no media bytes on the parent and then successfully
decrypts an ordinary parent frame, checking that discarded media did not burn
its implicit cipher nonce.

The full veil-session library suite passes 496 tests, with 6 existing ignored
tests. A subsequent test-only extension, committed as f341c235, also passes:
after closing and recreating the recipient's child service, all three sources
deliver again without parent spill. It requires no further production change.
These are quiet transport tests with synthetic packets, not microphone,
speech-quality or simultaneous real video/screen measurements. No apps or calls
are launched, no system permission or network setting is changed, and no native
stand library is rebuilt in this cycle. Build 2457 still contains c8b0026b, not
this new repair. The full audio-first goal remains unverified. Evidence stays
private; commits are unsigned and unpushed and no release occurs.

#### Fresh native receive proof before leaving P2P: stand 2462 / repair 2464

Build 0.13.84+2459 packages freshly rebuilt SDK f341c235 on both endpoints,
with native media still at build 2432. Public FFI exports, bundled native code,
kernel versions and strict/deep Mac sealing pass. The sixteen APK native
libraries match the pulled 2457 baseline except for the intended FFI update.
Same-signer in-place installation is verified by pulling the exact signed APK
back from Poco. A read-only preflight in this exact owned Mac build reports no
screen-capture permission; it requests none and exits. Screen sharing remains
unverified.

The user subsequently permits calls while keeping the computer's speakers off.
Stand 2461 stops before placing a call because a copied helper refers to the
old resource filename; its owned applications and all three remote units are
independently audited closed. The repaired stand 2462 verifies Poco's cellular
default route and muted, zero-volume Mac output without changing settings.
Both clients attach to a fresh owned neutral relay; other sessions are retained.
No topology controller or diagnostic relay-recovery request runs.

Poco calls Mac: ringing is observed at 0.684 s and both endpoints are active
on P2P at 2.676 s. Poco changes to relay at 69.945 s, followed by Mac at
70.451 s. The 64-KiB attachment starts only at 77.815 s and completes with
an exact SHA-256 match in 68.614 s. These differing directions and network
conditions are not a controlled comparison with stand 2456. Cameras capture
on both endpoints but encoded and received video frames remain zero. Actual
audio receive gaps reach 6.655/6.329 s and current buffers 577/535 ms; healthy
audio and simultaneous video are still not established. No speech assessment
is made. Cleanup independently verifies both owned local processes, Poco's
entire UID, the forward and all three remote units absent, the owned remote
directory removed, Mac sealing valid, and output still muted at volume zero.

The logs identify a concrete false P2P failure decision. At call time 69.207 s,
Poco's current native snapshot already has a new accepted audio RTP packet and
native receive age 2 ms, while the route remains P2P. At 69.392 s it nevertheless
logs established direct audio stalled and begins relay recovery. The FSM uses
the previous one-second activity sample, which still predates this recovery.
QUIC retransmission/expiry evidence explains an intermittent delivery pause,
but does not establish permanent path loss or the cause of that pause.

Repair 2464 rechecks the engine's accepted-audio arrival time immediately before
an early route change. A fresh receive timestamp cancels the cached outage;
only a confirmed current gap keeps the early recovery. Missing, failed or
bounded-out reads do not certify an outage, and async continuations revalidate
the current call/device and recovery state. The read leaves interruption and
playout-feedback counters untouched. Genuine outages, legacy admission probes,
ordinary repair grace, relay neutrality and privacy posture stay intact.

The regression supplies stale periodic state and a resumed native receiver:
removing only the new recheck reproduces the actual unwanted relay transition
by assertion after successful compilation. With the repair the call/activity
suites pass 159 tests, including confirmed stoppage, unavailable/error/timeout
snapshots and a late read after disposal. Source is restored exactly after the
negative control. This is a route-decision repair, not a claim that cellular
pauses, video adaptation or overall call quality are fixed. Evidence remains
private; commits are unsigned and unpushed.

#### Installed recheck and natural-route validation: build 2465 / stand 2466

Repair f2e31e08 passes the final 159-test call/activity suites and targeted Dart
analysis. Packaging build 0.13.84+2465 keeps SDK f341c235 and native media 2432;
all sixteen APK native libraries are byte-identical to installed build 2459.
Kernel versions, native bytes and Mac strict/deep sealing pass. Poco receives
a same-signer in-place update, verified by pulling back the exact signed APK.
The owned Mac stand bundle contains the same repair. /Applications, identities,
history, system permissions and network settings are not modified.

Stand 2466 independently rechecks cellular default transport and zero-volume,
muted Mac output. The owned neutral relay and other neighbors are available;
no forced route switch or topology controller runs. Both cameras stay on.
Poco-to-Mac ringing is observed at 0.695 s, both endpoints become active on P2P
at 3.555 s, and P2P remains in use for the approximately 210-second active call.
The 64-KiB file starts at 123.809 s, completes with an exact SHA-256 match in
73.188 s, and finishes before hangup. There is no early fallback or cancelled
cached-outage log in this run: it does not reproduce the earlier recovery race,
and differing radio conditions prevent attributing its stability to the patch
alone. The negative regression and stand 2462's resumed-RTP-before-fallback
timestamps supply the specific route-decision evidence.

Audio still needs work. Before the file, median current receive buffers are
249 ms on Mac and 379 ms on Poco, reaching 493/590 ms; during the file their
medians are 273/341 ms. Native receive ages peak at 748/522 ms before the file
and 651/446 ms during it. Neither camera produces encoded or delivered video
frames: the audio safeguard remains engaged in every measured active sample.
No human speech assessment or screen test is made. The cause of the earlier
transport pause and usable simultaneous audio/video/screen remain unresolved.

Independent final cleanup verifies both exact owned local processes exited,
Poco's entire UID absent while ADB is available, the forward removed, all three
owned remote units inactive with zero MainPID, the owned directory removed,
Mac strict/deep sealing valid, and speaker output still muted at volume zero.
Stand 2466's raw evidence and artifact metadata remain private. Both worktrees
are clean before this journal update; there is no push, signed commit or release.

#### Correlating the P2P pause with socket delivery: repair 2467 / stand 2469

SDK b3cb3c67 assigns each QUIC connection a process-local diagnostic ordinal.
The same ordinal appears in the existing opt-in path counters and sampled
encrypted UDP send log. It is not a pointer, socket address, wire connection
ID, media role or authorization token. Clones retain it; new connections get
a different ordinal. Receive correlation continues to use the exact encrypted
datagram digest. Scheduling, admission, wire bytes and relay policy are unchanged.
Two tests of the production correlation module and the real-socket transit
expiry test pass, including disabled tracing, GSO segmentation, matching
digests and stable/distinct connection ordinals. The standalone Cargo test
attempts hit excluded-package/dependency-resolution issues; the module tests
run with rustc against the workspace's compiled log dependency. No full-suite
claim is made for this diagnostic change.

Fresh FFI builds for both endpoints are packaged in 0.13.84+2468, with media
still at 2432. Mac code sections and sealing match the fresh artifacts. The
APK has the same signer as installed 2465 and changes only the intended FFI
among its sixteen native libraries. In-place installation is verified by
pulling back the exact signed APK. Stand 2469 retains other neighbors, uses a
fresh owned neutral relay, verifies cellular default transport and muted,
zero-volume Mac output, and makes no forced route or topology change.

Poco-to-Mac ringing takes 0.758 s; both endpoints are active on P2P at 1.731 s.
P2P remains for approximately 210 seconds. The 64-KiB file starts at 121.908 s
and completes with an exact SHA-256 match in 17.747 s. The fresh native-audio
recheck cancels a cached direct outage on each endpoint; neither makes an
early relay transition. Both cameras capture, but encoded/delivered video
remains zero. Median current audio buffers are 291/310.5 ms on Mac/Poco,
reaching 580/587 ms. Native receive age reaches 3118/2899 ms. This is not a
healthy audio/video result, and no human speech assessment is made.

Connection ordinals now identify the actual primary source datagrams on both
ends. Of the sampled sends in the measured active window, 698/698 Mac-to-Poco
datagrams match at Poco and 491/499 Poco-to-Mac datagrams match at Mac. These
are sampled observations, not a whole-stream loss estimate. Socket handoff to
peer read reaches 3127 ms toward Poco and 1485 ms toward Mac; the corresponding
p95 values are 849/738 ms. Phone-clock measurements bracket the test: estimated
phone-minus-Mac time changes by 1.1 ms, with midpoint uncertainty bounds of
24.1/20.9 ms. Millisecond log rounding limits interpretation of near-zero
one-way delays. Nongrouped receive samples show kernel-to-read delay at Poco
at most 19.9 ms, p95 1.7 ms; Mac's maximum is 1.3 ms at this resolution.

Matching exact send samples to Mac syscall time and size yields 695 unique
matches, all on one tuple; reverse-direction samples yield 469 unique matches,
all on that same peer's receive tuple. Ambiguous matches are excluded. The
whole tuple continues sending during the pause (largest observed send gap
275 ms), while receive stops for 3184 ms near call time 74 seconds. An exact
primary datagram handed to the socket at 74.201 s is timestamped at the phone
kernel at 77.323 s and read at 77.328 s. Other datagrams accumulate and arrive
in a burst. The observed primary drivers report no event-queue, timer or UDP
send stalls at their 100-ms diagnostic threshold.

Independent relay TCP flows matching the phone's public source address also
stop receiving ACKs in this interval. A four-segment flight starts around
75.944 s, retries three times, and clears at 77.514 s; a separate active flow
accumulates unacknowledged data and clears then too. Relay-clock midpoint
uncertainty is approximately 71 ms. Thus the pause spans different transports
and destinations sharing the phone's access path. It is consistent with a
phone/access-network stall before socket delivery; the modem, vendor power
policy, carrier and other shared path components are not yet distinguished.
This does not establish a carrier defect or exclude every possible phone
power mechanism.

The user's specific hypothesis about veil's own economy/batching mode is
checked separately. xVeil does not attach VeilLifecycleBinding or call the
background-tier setter. withOutboundCoalescing is an unused helper; it is not
in the composition chain. An authenticated read of the running installed Poco
node in preflight 2470 confirms background_mode=false, effective keepalive and
route-probe factors 1, no low-battery threshold, and no outbound batch window
or batch-always setting in the actual runtime config. SDK default coalescing
is consequently off. When configured, that coalescer also bypasses REALTIME
and INTERACTIVE; independent source QUIC datagrams bypass its ordered drain.
This specific mechanism does not explain the measured pause. No economy or
system power setting is changed. Android's recorded battery-saver state is
off and its last sleep predates the test; these observations alone do not
certify vendor-specific or modem power policy.

Independent stand cleanup verifies both owned Mac/logcat processes exited,
Poco's entire UID absent, forwarding removed, all three owned remote units
inactive with zero MainPID, the owned remote directory removed, Mac sealing
valid and speaker output still muted at zero. The additional phone-only
preflight places no call and independently verifies its entire UID and forward
absent after stopping. All raw addresses, digests, radio logs and identities
remain private. Audio recovery/adaptation and usable concurrent video/screen
remain unresolved; commits are unsigned and unpushed.

#### Further phone power checks and recurring audio jitter: cycle 2471

Read-only Android checks find xVeil on the user's power allowlist, inactive=false,
with background execution and wake locks allowed. The recorded wake-lock duration
is approximately 213 seconds, covering stand 2469's 210-second call. The later
netpolicy snapshot reports no effective UID network block; this is a post-call
observation, not a complete history of vendor rules during the call. The MIUI
powerkeeper service is unavailable through this dumpsys interface. No power,
network, permission or routing settings are changed.

The retained radio log contains 70 distinct modem activity reports within the
call window. All report sleep time zero, including reports bracketing both
large packet pauses. Reports use UNKNOWN RAT/frequency; their transmit/receive
values are not treated as cumulative counters. These reports do not identify
a cell handover or prove that every modem/firmware power mechanism is inactive.
Together with the existing awake state and application wake lock, they provide
no evidence for disabling a currently active economy mode to repair this call.

A new Opus/NetEq PCM scenario alternates 40/300-ms packet delivery delay every
200 ms for ten seconds, then restores the 40-ms path for eighteen seconds.
It checks actual decoded tone markers, not only buffer gauges: production
playout must recover below 400/300/180 ms at the 13/15/17-second markers and
remain below 180 ms thereafter. It also retains the unchanged 30-packet control,
concealment/flush comparison and strict 30-ms host timer-lateness gate. The
extended smoke runner includes this scenario. One final-source attempt is
excluded because the host timer gate rejects it; the unchanged retry passes.
Production marker latency falls from approximately 340 ms during the bursts
to 239/150/99 ms at those recovery markers, with no additional flush and fewer
concealed samples than the control. This synthetic healthy recovery does not
prove cellular speech quality or usable simultaneous video/screen.
The original short-burst PCM scenario also passes; other smoke modes and the
full SDK suite are not rerun for this test-only extension.

The fresh test-only native library uses the existing production media settings.
Physical apps are not launched or installed in this cycle; the Poco UID and
owned Mac app are independently absent, and Mac output remains muted at zero.
The shared phone/access-path pauses remain unresolved. Raw radio data and
diagnostics stay private; no relay classification or prioritization is added.

#### Independent access-path probes and a real relay transition: stand 2472

The same installed 2468/media-2432 endpoints run a natural 210-second video
call, preceded by approximately a minute of independent traffic measurement.
Separate small native programs on Poco and Mac exchange five synthetic UDP
and TCP probes per second with a fresh owned observer. They bypass xVeil and
carry no voice/video data. The observer applies no role classification or
priority. Poco's default network is verified cellular; Mac's default and
observer route use en0. Mac speaker output stays muted at zero. Existing
sessions and network/power settings are preserved; there is no route controller.

In the baseline window, both phone protocols receive all 290 probe replies;
median RTT is 85/91 ms for UDP/TCP. During the measured call window, UDP
receives 959 of 999 replies and TCP eventually receives all 999. Phone UDP/TCP
reply gaps reach 9756/9951 ms around call seconds 123--133. Sends continue with
at most 14-ms probe timer lateness; UDP kernel-to-read delay peaks at 5.8 ms.
In that interval the observer receives all 55 Mac requests on each protocol,
while 25 of 55 phone UDP requests never arrive. Phone TCP requests sent near
124 seconds only reach the observer near 133 seconds. This distinguishes a
real delivery problem before observer reception from an xVeil audio-worker
pause. It does not identify the carrier, modem or other shared path component,
or prove that sending the attachment caused the pause.

Independent Mac probes also show trouble: only 614 of 999 call-window UDP
replies arrive before teardown; TCP returns 669 within the capture, with a
maximum measured RTT of 56.4 seconds. The incomplete TCP reply count is not
treated as packet loss. Requests reach the observer promptly while replies
accumulate delay after observer reception; its logged reply timestamp precedes
the nonblocking output queue and is not proof of exact kernel handoff time.
The observer continues processing other probes. A later read-only qdisc check
finds no netem. One-way estimates remain approximate: clock midpoint bounds
are 22.1/19.3 ms for phone and 48.2/95.8 ms for observer before/after the test.
Measured offset changes remain within those combined bounds. RTT and reply-gap
measurements use one endpoint's clock and do not require clock synchronization.

Ringing takes 0.689 seconds; both ends become active on P2P at 1.552 seconds.
The 64-KiB attachment starts at 121.573 seconds and arrives with an exact hash
match in 44.275 seconds. Both ends move to relay at 127.077 seconds. Earlier,
the fresh native check cancels another cached direct outage; at this transition
it instead measures genuine 3232/3478-ms receive ages. Thus this transition
is supported by actual audio silence and the independent delivery pause,
rather than the stale-snapshot defect repaired in f2e31e08. Source inspection
finds that the current relay handover seals/opens a candidate and commits its
native binding without first proving timely delivery on that candidate.
Opening a local handle remains weaker than evidence of a usable replacement.

Video remains unencoded despite enabled cameras. Native receive age reaches
9949/13088 ms on Mac/Poco; current audio buffers reach 562/541 ms. The result
does not establish healthy audio/video or screen sharing. The complete relay
SDK log is unavailable after a timed-out SSH capture; conclusions use retained
endpoint logs, probe logs and observer probe receipt records, not that log.

Independent cleanup verifies both app/logcat processes and the whole Poco UID
exited, both native probe processes exited, the phone probe binary and ADB
forward removed, all four owned remote units inactive with zero MainPID, and
the owned remote directory absent. Mac sealing is valid and output stays
muted at zero. Raw addresses, identities, capture files and diagnostic tokens
remain private. Delivery-validated route replacement and usable concurrent
audio/video/screen remain open; no new production settings are deployed.


#### Candidate delivery qualification: cycle 2473

The specific veil economy mode is still not implicated: the installed phone
reported background_mode=false and no outbound batch window/threshold in
preflight 2470. The configured ordered coalescer bypasses REALTIME and
INTERACTIVE; source QUIC datagrams use their independent drain. No system
power policy, network configuration or relay scheduling is changed.

SDK 4fadc275 adds a 24-byte request/reply inside the existing directional VME1
seal. A random per-attempt nonce, requested path and kind remain encrypted;
they add no outer media role, timestamp or relay priority. The host pins the
identity app/destination for direct replies and the physical device app and
destination for ordinary relay replies. The receiver forces the requested
path, rather than echoing on the current call route. Claimed envelope sources
cannot choose a reply destination. Anonymous channels reject configuration.
Contexts, concurrent echoes, attempts and reply age are bounded. A candidate
reply under another identity/device alias is accepted only after its call
AEAD opens, and never enters WebRTC or its receive/activity counters.

xVeil enables this control before starting an ordinary call's engine. A live
engine-preserving handover waits for a matching echo within 600 ms before
rebind and rechecks engine, epoch, call and peer ownership after the await.
An unproven candidate closes while the old sender/receiver remains owned;
the call service retains an active direct session and backs off five seconds.
A failed replacement with no surviving old session still ends the call.
Older engines without safe rebind keep their existing live route. Initial
startup and destructive local engine recovery are not delivery-qualified
handovers; those existing flows are not claimed fixed by this change.

Verification: seven new/targeted codec and real Unix IPC dispatcher/echo tests
pass, as do all 52 media-filtered SDK tests and 175 root call/seal/operation
tests. Tampering, old/late/replayed replies, candidate aliasing, pending-attempt
ownership, pinned reply destinations, neutral relay framing and unchanged
old RTP reception are exercised. Portable client-only compilation, package
Clippy without dependency lints, ABI regeneration and targeted Dart analysis
pass. The IPC test captures the final session sink; it does not measure a
physical network, PCM quality, video or screen sharing. Existing installed
2468 endpoints have not received these new ABIs at this checkpoint. A fresh
Mac/Android build and quiet physical qualification test are the next step.
