# Source pressure and video frame attribution

## Retained change

`CallAudioSourcePressure` previously returned `true` after a known small audio
concealment/catch-up, even with healthy fresh buffer measurements. That report
contracts the node-local source flight window and DATA budgets. It is stronger
than the video ladder's independent three-second hold on growth.

Known small damage with otherwise healthy measurements now leaves transport
pressure clear. The video ladder retains its own transient growth hold. Actual
RTP loss, interruption, significant accumulated damage, sustained growing/capped
buffers and genuine pressure recovery retain their protections. Missing duration
support keeps the conservative legacy behavior; missing buffer feedback does
not become a healthy report. The regression also preserves eight earned healthy
observations across a small event during recovery from genuine pressure.

Primary traffic retains its normal QUIC controller and debits the node-local
ledger ahead of competing work. No relay priority, wire label, C ABI or server
configuration changes are introduced by this source-pressure fix.

## Instrumentation and established evidence

Veil `bffc1343` adds opt-in, bounded metadata for encoded images, each group
fanout copy and decoder output. Recording reserves memory before streams start;
file writes occur during teardown. SSRC/RTP timestamp offsets are established
from the capture rather than assumed zero. Native trace truncation, missing
footers and ambiguous matches are rejected.

In the 120-second attribution capture, all eight byte-derived pixel cuts had
native first-to-marker times of 0–21 microseconds; two encodes fit one RTP packet.
All their original cells were accepted by the local transport. Four frame/path
observations did not decode; missing original seals were absent at the receiving
SDK while retransmitted RTP eventually completed the payload 0.8–1.0 seconds
after encoding. This locates the missing work after local admission; it does
not identify a particular relay or prove a physical network drop.

On the relevant connections, QUIC telemetry also reports outgoing datagrams
expiring near 200 ms and local-window blocking. The reported blocked window
uses `local_congestion_window`, which includes the node-local source flight cap;
it is not simply the ordinary congestion controller's window. Further SDK
investigation must distinguish that local limiter from actual path congestion.

See `before-attribution.json`. That 120-second run is an attribution experiment,
not a full contention qualification. Its audio marker maximum was 240.20 ms.

## Controlled attempts and final retained configuration

Removing the extra pixel cap alone produced 160×120–320×240, but only 1.05–3.61
final-minute decoded FPS and failed every final motion path. Adding the source
pressure fix to that candidate reduced pressure reports and outgoing expiry
counts, but still did not establish better smoothness. Those pixel-cap removals
were rejected and saved as an unapplied patch, not enabled code.

The final run uses the original pixel guard and the revised source-pressure
policy. Conditions: 360 measured seconds, three isolated SDK/media processes,
six media directions, a neutral 1024 kbit/s FIFO relay and three concurrent
encrypted 512 KiB files. All 2,112 synthetic audio markers and all files arrived.
All six final motion gates passed. Final-minute decoded rates were 2.07–2.83 FPS
at 80×60. The peak acoustic marker delay was 200.22 ms. The original strict
200 ms gate therefore still reports failure; the user deferred that target and
the gate has not been rewritten.

Transport-pressure reports were limited to the startup period (17–19 samples
per device), but outgoing expiry persists. The remaining low resolution/FPS and
SDK transport constraints are not solved. `comparisons.json` retains rejected
results, including offered-load differences; raw expiry totals alone do not
establish a change in loss probability.

The final SDK source diagnostic stream exhausted its explicit row bound. The
analyzer refuses full admission attribution for that run. Its `--native-only`
mode separately validates complete native/decoder recorders, explicitly marks
SDK admission as unaudited, and does not relax any original capture gate.

## Verification and limits

- 218 targeted Flutter adaptation tests passed; two-file Dart analysis passed.
- The final code also withholds healthy feedback for an explicitly stalled
  audio worker. This final guard was added after capture and regression-tested;
  every one of the 1,080 measured worker snapshots had `worker_stalled=0`, so
  the added condition preserves all measured decisions. No additional complete
  capture of that final guard is claimed.
- 16 related Python analysis tests passed. Replay/padding, distinct peers,
  timestamp wrap/offset ambiguity, truncated/missing metadata are covered.
- Native budget/packet trace smokes passed. A real fanout accounting run verifies
  both peer copies and an SDK refusal are recorded separately.
- The retained native library passed the complete call-planes smoke, including
  Opus delivery with both video queues stalled, restart and teardown.
- Hook/production export sets remain unchanged (135/101).

Synthetic tones and decoder counters do not prove intelligibility of live
speech, device microphone/headphone volume, or physical screen presentation.
This cycle is progress toward the full goal, not a completion claim. Owned
processes were reaped, nodes stopped and sockets closed; cleanup proofs are
included. Foreign multi-device work was preserved.
