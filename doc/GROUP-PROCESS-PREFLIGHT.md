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
