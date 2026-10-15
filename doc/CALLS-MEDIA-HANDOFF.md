# Calls media handoff

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
