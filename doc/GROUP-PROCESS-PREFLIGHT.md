# Three-party group audio preflight

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
loss, local drop/recovery deltas, or fresh growing/full peer buffers. Its ladder
is 20/32, 40/32, 40/24, 40/16 (milliseconds/kbit/s). Recovery needs eight fresh,
complete room-wide healthy observations after a quiet period. Cached reports,
muted capture, counter resets and failed retunes cannot manufacture recovery
or repeated cuts. The controller runs it even without video. Old engines keep
their existing codec through the optional API/ABI fallback.

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
