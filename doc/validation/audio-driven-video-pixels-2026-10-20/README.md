# Measured audio feedback reaches native video sizing

## Retained implementation

The application and codec fixtures now pass the same measured audio decision
to native source sizing for both ordinary and group calls. This decision is
separate from the transport's cold/recovery reservation and group floor
override. Missing measurements are unknown, not healthy. When no audio is
expected, video may recover while the audio transport reservation expires.
Native feedback is synchronous and independent of the SDK admission ACK.

Two additive optional media entrypoints accept unknown / healthy / pressured
states. Older media binaries return unsupported through the Dart wrappers;
older callers retain the previous native sizing behavior. No SDK ABI, network
frame, relay classification or relay scheduling change is introduced.

With explicit feedback enabled:

- Measured pressure reduces source pixel area by half, bounded by the existing
  coarse source floor and at most one cut per three seconds. This works with
  unchanged minimum bitrate and with encodes that fit their byte budget.
- Fresh healthy observations and distinct active encodes earn one 25% area
  recovery step after at least four observations over three seconds. A paused
  source, repeated timestamps, unknown feedback and gaps earn no growth.
- One moderate encoded overshoot with fresh healthy audio does not contract
  resolution. Sustained overshoot and four-times oversized frames retain
  protection. Encoded reference frames are always forwarded unchanged.
- Raising the requested/actual bitrate alone cannot bypass the explicit pixel
  policy. Recovery also works when the host is already at its bitrate ceiling.

The entrypoints only update bounded state under the existing pixel-budget
mutex. They do not invoke a media worker, perform network work, or write files.

## Verification

- 84 targeted Flutter tests and nine-file Dart analysis pass. Tests distinguish
  current measurements from the transport recovery latch, preserve unknown
  measurements, and verify native delivery continues while the SDK ACK waits.
- Native budget tests cover pressure before the first encode, small frames at
  the bitrate floor, bounded recovery, stale/duplicate feedback, and no banking
  while video is paused. Legacy budget cases still pass.
- Real ordinary/group C ABI tests pass with flat small images: pressure changes
  pixels at an unchanged 15 kbit/s budget, returns within 50 ms with video
  queues held, and fresh active feedback subsequently restores pixels.
- The default native call-planes smoke passes, including real Opus delivery
  while video queues are held, restart and teardown. The new mode is included
  in the standard native smoke runner.
- macOS hook / production builds export 137 / 103 symbols: exactly two additions.
  Required Dart symbol checks pass. Production has no test hooks and loads
  against the unchanged SDK binary. Build/source hashes are recorded.
- Both Python fixture files compile. Complete native image/fanout/decode
  recorders validate in native-only mode; SDK admission is explicitly unaudited
  in that mode.

The initial feature regression was a compile failure because the original
budget had no audio-feedback method. It is not presented as an old runtime
failure. The earlier captures in `../video-pixel-feedback-2026-10-20` establish
the ordinary-call resolution problem and the rejected inference approaches.

## Controlled results and remaining work

All captures use the same clean SDK binary, real Opus/VP8, synthetic 320×240
camera input, a neutral 1024 kbit/s FIFO and competing encrypted 512 KiB files.

| Measurement | Retained baseline | New native feedback |
| --- | --- | --- |
| Ordinary call final dimensions, both directions | 80×60 | 320×240 |
| Ordinary call final-minute decoded FPS | 2.05–2.10 | 6.98–12.02 |
| Ordinary call peak native audio buffer | 156 / 159 ms | 137 / 152 ms |
| Ordinary call native interruptions | 0 / 0 | 0 / 0 |
| Ordinary call files | both hashes complete | both hashes complete |
| Group final dimensions, six directions | 80×60 | 320×240 |
| Group final-minute decoded FPS | 1.78–2.79 | 1.19–1.90 |
| Group final motion gates passed | 6/6 | 4/6 |
| Group acoustic marker peak | 200.17 ms | 230.11 ms |
| Group audio recovery discards after 60 s, summed over workers | 0 ms | 200 ms |

The pair capture lasts 180 measured seconds and passes the complete original
fixture. The group capture lasts 360 measured seconds: all 2,112 audio markers
and all three files arrive, but two final motion gates fail (12 and 13 changes
against 14 required). Its strict acoustic gate also remains unchanged and
fails. The user deferred that 200 ms target; no replacement gate was invented.
Native playout buffer delay and acoustic marker delay are different metrics.

The two earlier group prototypes discarded 930 / 1210 ms after 60 s; this run
discards 200 ms over the same observation interval. Sums across workers are
not one listener's outage duration and these independent runs do not establish
a deterministic improvement ratio. Occasional damage is allowed by the user;
there is no zero-damage acceptance rule.

Each group worker accepted all 360 native hints. No pressure-driven pixel cut
occurred in this capture; the small measured damage did not cross the retained
pressure threshold. One worker performed five healthy recovery steps after
byte-derived caps, and both pair workers also recovered caps. The pressured
branch is verified by the explicit real-engine tests above, not by claiming a
network pressure event absent from the capture.

Ordinary-call quality is improved, while group smoothness is still unresolved.
The source flight window remains near its old floor (median 5808, maximum
7260 bytes). Further work must trace actual queued/blocked work and delivery,
rather than infer source demand from an empty QUIC transmit buffer alone.
The current code calls local `app_limited` when `buf.is_empty()` and congestion
is not marked blocked; this is an investigation lead, not a proven new bug.

Synthetic markers, decoder counters and the explicit engine test do not prove
live speech intelligibility, headphone volume, real screen presentation,
physical cellular behavior or all source-contention combinations. The full
audio/video goal remains active. This cycle retains the measured feedback
mechanism and reports the group limitations; it does not claim completion.

All owned processes were reaped, node stop results checked and fixture sockets
closed. Foreign root/SDK work was preserved. No app installation, push, release
or relay update was performed.
