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
