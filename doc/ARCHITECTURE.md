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
