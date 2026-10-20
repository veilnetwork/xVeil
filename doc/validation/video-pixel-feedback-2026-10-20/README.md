# Video pixel caps need measured audio feedback

## Established problem

The retained pixel guard can reduce source resolution after one moderately
oversized encoded image. With a low actual encoder allocation, that cap can
remain through later host budget increases. The new recovery regression fails
against retained SDK `b7f84b86`: raising the host profile does not grant the
bounded source-pixel recovery step. This confirms a source sizing problem in
addition to the local transport limitations previously recorded.

The user deferred the strict 200 ms acoustic target and accepts occasional
media damage if it causes quality adaptation. No zero-damage acceptance rule
or replacement acoustic target was introduced in this investigation.

## Two controlled prototypes, neither enabled

1. **Sustained overshoot.** Moderate overshoot needs at least three encodes and
   three seconds of continuous fresh evidence. An undersized frame, changed
   byte budget or six-second callback gap resets evidence; duplicate timestamps
   earn none. A four-times oversized frame and missing timestamps keep immediate
   protection.
2. **Host backoff and recovery.** The first rule plus immediate protection after
   an explicit host budget decrease, and one bounded 25% pixel-area step on a
   larger host budget. A cold low starting profile is not a measured failure;
   repeated profiles and native bitrate fluctuations earn no source growth.

Both preserve frame bytes, reference-frame delivery, local preview, SDK
deadlines, public interfaces and relay behavior. They change endpoint source
sizing. Their source patches are archived here and are **not applied**.

### Ordinary two-endpoint call

180 measured seconds per run, neutral 1024 kbit/s FIFO relay, production
anonymous profile (150 kbit/s / 15 FPS ceiling), synthetic 320×240 camera,
real Opus/VP8 and two competing encrypted 512 KiB files. The same SDK binary
and current Dart policies were used across all three runs.

| Result | Retained baseline | Prototype 1 | Prototype 2 |
| --- | --- | --- | --- |
| Final resolution, both directions | 80×60 | 320×240 | 320×240 |
| Final-minute decoded FPS | 2.05–2.10 | 7.63–7.68 | 11.34–12.41 |
| Peak native playout buffer, each direction | 156 / 159 ms | 101 / 115 ms | 136 / 132 ms |
| Native interruption count | 0 / 0 | 0 / 0 | 0 / 0 |
| Both file hashes complete | yes | yes | yes |
| Original fixture result | false | true | true |

The baseline has a 290.16 ms acoustic marker maximum, exceeding the unchanged
original gate. That target is deferred, not rewritten. Native buffer delays
and acoustic marker delays are different measurements. Both prototypes passed
the original complete pair fixture; this does not prove live speech quality,
physical screen presentation or a mobile network call.

### Three-endpoint contention

360 measured seconds, three isolated SDK/media workers, six media directions,
the same neutral 1024 kbit/s FIFO and three encrypted 512 KiB files.

| Result | Retained baseline | Prototype 1 | Prototype 2 |
| --- | --- | --- | --- |
| All 2112 audio markers delivered | yes | yes | yes |
| All file hashes complete | yes | yes | yes |
| Final resolution, all directions | 80×60 | 320×240 | 320×240 |
| Final-minute decoded FPS range | 1.78–2.79 | 1.12–2.97 | 1.22–1.51 |
| Final motion gates passed | 6/6 | 6/6 | 2/6 |
| Peak acoustic marker delay | 200.17 ms | 250.09 ms | 250.13 ms |
| Audio recovery operations after 60 s, summed over workers | 0 | 77 | 107 |
| Discarded audio after 60 s, summed over workers | 0 ms | 930 ms | 1210 ms |

Prototype 2 has 13/14 required final content changes on four paths. The gates
remain unchanged. Recovery/discard counters were inspected in addition to
sparse synthetic markers: complete markers alone miss smaller audio damage.
These counters are not a speech intelligibility score, and sums across
workers are not a single listener's outage duration.

The prototypes demonstrate a large avoidable quality loss in ordinary calls,
but do not establish the required protection under group contention. Neither
is retained globally. This decision is not based on exceeding 200 ms or on a
requirement that every small impairment disappear.

## Why inferring audio pressure from bitrate did not work

The group source can already be at its minimum video budget while measured
audio still asks secondary work to yield. A new pressure episode need not
produce a smaller selected bitrate. Pixel sizing receives encoded size and
selected/actual bitrate, but not that measured audio decision. Changing only
the oversize hysteresis or recognizing host bitrate changes misses this case.

The application already computes the required signal in
`lib/state/veil_call_media.dart` and `lib/state/veil_group_call_media.dart`.
The group path computes `_sourcePressured` in `_reportSourcePressure`, feeds
the SDK through `reportLocalSourcePressure`, and passes it into the Dart video
adapter. It does not feed that decision into the native pixel budget.

Next implementation: pass fresh measured audio pressure to native source
sizing for both call types. Pressure must reduce source cost even at an
unchanged bitrate floor; healthy feedback must permit bounded recovery without
waiting for another bitrate change. Unknown/stale feedback must not earn
growth. Product and stand must call the same API. Relay scheduling and wire
classification remain outside this endpoint policy.

Distinguish the measured decision from the extra transport floor override in
`_reportSourcePressure`: a cold reservation alone is not measured audio damage.
Deliver the native hint independently of the asynchronous SDK admission ACK.
Recovery must also work when the selected bitrate is already at its ceiling.
Regression coverage must include pressure while encoded frames fit their byte
budget, and pressure while the selected bitrate stays at its floor. These are
the cases the two prototypes cannot reliably express.

## Verification and restoration

- Prototype budget regressions passed, including transient rejection,
  sustained pressure, large-frame protection, fresh time, host backoff and
  bounded recovery. The recovery regression is red against retained source.
- Real native frame-sizing/preview tests passed for both call types. The
  prototype test distinguishes a larger group request from a real larger
  allocation: the plaintext mock has no receiver feedback. That test edit is
  archived with the prototype, not retained as a relaxed project gate.
- Hook export sets remain identical (135 symbols). No production binary was
  installed or published; public media/SDK interfaces were not changed.
- Complete native image/fanout/decode metadata was validated separately in
  native-only mode. SDK admission remains explicitly unaudited in that mode.
- All owned fixture/helper/policy processes were reaped, worker/thread exits
  checked, nodes stopped, and fixture sockets closed. Group cleanup includes
  final summary PIDs as well as the earlier process snapshot.
- All three owned experimental source/test files were restored byte-for-byte
  from SDK HEAD. The original budget smoke passes after restoration. Foreign
  root and SDK work was preserved.

The two patches, comparisons, build hashes and cleanup/test proofs accompany
this report. Raw captures remain in the private cache paths recorded there.
