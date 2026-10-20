# Current audio priority / separated interaction audit — 2026-10-20

## Objective and current implementation

Keep sound ahead of video, screen sharing and other network work, with separate
channels/parts for different interactions. Relay forwarding remains opaque and
neutral; no new media labels or relay priority are used.

| Requirement | Current source / evidence | Result |
|---|---|---|
| Independent audio, camera, screen and control send work | `VeilFlutterTransport` owns distinct clients/bindings and attaches secondary/screen/feedback/control senders; SDK `MediaSenderSlot` and per-plane producers/ingress | Implemented; blocked video/screen/control/warm tests pass |
| Audio processing does not wait for video processing | Native audio/video Calls, worker/network queues and `AudioPacketPriority`; real Opus coordination smoke | 368 packets decoded; secondary yield/resume checks pass |
| Audio ahead of reliable files / other interaction work locally | Separate stream client, generic message/control/maintenance/mailbox/sibling clients; session/source admission retains primary reserve | Three-party real SDK contention below; all expected sound transitions and files delivered |
| Relay chain/forwarders do not get an audio priority tag | Clean SDK delivery/anonymity paths normalize forward queue/header class; local source lanes do not become remote scheduling classes | Relay-neutrality regression passes; owned relay topology verified |
| Quality can return when capacity returns | Current production Dart group policy + native codec and source budget; live FIFO capacity step | All six video paths reach ~14.4 FPS at 320×240; steady sound peaks 120–130 ms |
| Changes remain reviewable and tests leave no running stand | Root code commits, source/binary fingerprints and independent process/socket checks | Verified; own commits unsigned, no push/release |

Independent logical channels, IPC writers/pumps and codec workers are used.
Modern peers can additionally use generic independently authenticated QUIC
children. The capacity-step trace records 42 successful connection/binding
pairs across local slots 0–7. The peer sees generic proofs, not a media role.
Compatibility/fallback paths can still share an underlying session/socket and
all paths share physical capacity; this is not a dedicated-connection guarantee
for every interaction on every transport.
Local scheduling and source admission protect sound without asking a relay to
prioritize it. The ordinary wire forwarding class remains INTERACTIVE, including
normalization of legacy REALTIME hints. PoW-walk policy is not changed here.

## Current-state checks

- Root shared adapter is commit `165f711a`; both controlled captures record its
  exact source hash. SDK binary is `70a99c1f`, with ABI hash
  `07a6d433c34307e2089b9589cd1397a65e707e7d60e35db23160e8a9500a2638`.
- **430 Flutter tests** pass for bitrate policy, calls and direct/group source
  arbitration/media. Targeted analysis is clean; macOS/Android profile 12630
  builds pass. The new 16 → 200 → 16 ms regression fails on the old source and
  passes after remeasuring healthy startup rather than retiring it permanently.
- **49 freshly compiled SDK media-priority tests** pass from a clean export,
  including direct/relay audio under a blocked video writer, blocked screen
  independence, separate camera/screen assembly, anonymous audio during blocked
  video/control/warm work, deadlines, repair and cleanup.
- A freshly compiled dispatcher test verifies forwarding never grants priority
  to a legacy REALTIME request. An initial invocation omitted the required seed
  feature and failed compilation; the corrected invocation with
  `veil-bootstrap/production-seeds` passes.
- Native production packet/yield coordination and the **real Opus smoke** pass:
  368 packets decode, constrained sending yields video before lengthening active
  audio, and short-ACK/resume/clock checks pass.

The standalone phone disappeared from ADB before 12630 installation. Its
preceding 12629 test verified the new Camera2 size and decoded 540×960 video with
all 290 sound transitions delivered. This audit's new RTT startup branch is
proven by shared-policy tests; it is not claimed as a newly listened-to phone
call. These are networking/coordination checks, not a hardware loudness or
subjective speech-quality verdict.

## Two controlled contention captures

Three separate SDK/codec processes communicate only through one owned relay.
Start/end star topology is verified: session counts 3/1/1/1. Each participant
sends audio/video to two peers and one AES-GCM-authenticated encrypted 512 KiB
file to the next participant. The blind UDP FIFO sees opaque packets only,
with a shared **1024 kbit/s per direction** limit across all fixture links.
No physical microphone or speaker is used. Native capture clocks have no lost
rows, failures, late intervals or deadline misses in the capacity-step capture.

| Observation | Constant 1024 kbit/s | 1024 → 8192 kbit/s at 120 s |
|---|---:|---:|
| Expected sound transitions delivered | 2112 / 2112 | 2112 / 2112 |
| Missing sound transitions | 0 | 0 |
| Overall loaded-phase acoustic peak | 280.08 ms | 210.25 ms, before the capacity step |
| Files complete, authenticated/hash checked | 3 / 3 | 3 / 3 |
| File completion time from capture start | 351.75–351.84 s | 183.99–195.77 s |
| Last-minute decoded FPS, six paths | 1.29–2.39 | 14.39–14.45 |
| Final decoded resolution | 240×180 / 320×240 | 320×240 on all paths |
| Tail content-progress gate | 3 / 6 meet 14 changes | 6 / 6 meet 14 changes |

The capacity switch actually applied at **120.002718 s**, 1,024,000 → 8,192,000
bit/s. In that same running call, sound peaks are 150.10–150.23 ms during seconds
120–180 and **120.11–130.17 ms** during seconds 180–360; all 1068 expected steady
phase transitions match. Phase analysis retains ordinals from complete source
and decoded captures. It never rephases a late periodic stream. Its default
output reproduces the original six raw summaries exactly; all three existing
ordinal/delay regression tests pass after adding optional analysis phase ranges.

This demonstrates recovery after available capacity changes, with all streams
still active; it does not attribute all frame-rate variation to the latest RTT
patch. The constant-capacity run exercises five relative-RTT warning observations,
with startup already retired before those observations; it proves no budget
increase on those observations, not preservation of a still-active shortcut.
The capacity-step run has no such observations.

## Preserve the raw failed gates

Both original fixture `ok` / `contention_qualification` values remain **false**.
The capacity-step run's workers, video, files, topology and cleanup checks pass;
its overall gate fails because the original strict `<200 ms` acoustic check
includes 200.08 and 210.25 ms peaks in the congested pre-step segment. The user
explicitly deferred that strict acoustic target. It has not been relaxed,
rewritten or reported green. The constant run also misses one expected tail
content change on three low-FPS paths. That run does not establish smooth video
on a saturated link. A local priority policy cannot create link capacity or
preempt traffic already queued at a neutral relay.

Native 10 ms PCM timing is not a hardware acoustic or subjective speech test.
The complete raw captures and failed summaries are retained privately; bounded
source hashes, counters, peaks, topology and cleanup are committed beside this
report. The broader goal is not a guarantee of latency or video quality on every
network. The implemented/verified result is interaction isolation, sound-first
local scheduling/adaptation, neutral relays and quality recovery with headroom.

## Cleanup and provenance

All owned fixture/helper/worker/policy PIDs from both live process snapshots are
absent. All four node stops per capture return zero; worker file threads and
policy processes exit; no fixture sockets remain. The capacity-step timer also
exits. No GUI app or phone instance was opened in this audit; the phone's ordinary
APK remains unchanged. SDK sources used in tests and selected libraries match
clean commit `70a99c1f`; foreign root and SDK WIP is excluded and untouched.
No relay deployment, push, release or signing of commits was performed.
