# Audio damage duration and video degradation

## Change

Video previously counted repeated small concealment/catch-up events without
measuring their size. The preceding 360-second capture included about 11/27 ms
of non-silent concealment in six-second windows that still cut two video rungs.

The endpoint now accounts for non-silent concealment and discarded speech in
each decoder's six-second window. At 120 ms of accumulated damage a fresh event
can cut video; smaller events only hold growth and secondary producers briefly.
This threshold measures missing/discarded sound, not ping or playout delay.
Group peers use separate windows; a healthy peer cannot dilute another's damage.
Missing/partial legacy diagnostics retain the existing conservative fallback.
RTP loss, real interruption and sustained buffer pressure retain their guards.
Incoming catch-up is kept separate from outgoing peer impairment.

The native counters already travel in encrypted RTCP. This adds local JSON
diagnostics, with no wire format, C ABI, relay labels or relay scheduling change.

## Verification

- 461 targeted Flutter tests passed; analysis of nine Dart files passed.
- Native recovery framing, production shim and complete call-planes smoke passed.
- Hook and production libraries retain their previous export sets (135/101).
- Red regressions show the previous policy cutting video for small measured
  damage, and the missing-age compatibility guard accepting a real impairment.
- Replay, stale reports, counter rollback, decoder replacement and gaps have
  native tests. Known small damage preserves recovery credit.

## Measured result and remaining problem

The 360-second capture used three isolated SDK processes, six media directions,
a neutral 1024 kbit/s FIFO relay and three encrypted 512 KiB files. The measured
stimulus, codecs, source caps, clocks and qualification gates were unchanged.
All 2,112 synthetic audio markers and all three files arrived. This does not
prove intelligibility of live speech or device speaker/headphone volume.

Small audio events caused no remaining video rung cuts. Final-minute decoded
rates were 1.85–5.46 FPS (previous capture: 1.37–1.92). The overall capture still
failed: all six paths ended at 80×60, five missed the final motion gate, and the
original strict 200 ms acoustic gate saw a maximum of 210.16 ms. The user has
deferred that latency target; the gate/result have not been rewritten.

Of the 13 remaining rung cuts, 12 had a fresh persistent video network loss
witness, and one had a video RTP enqueue drop. The native encoder's frame pixel
cap also remained low after four oversize events. These are the next video
constraints to investigate; this cycle does not establish their root cause or
claim that video quality is fixed.

The capture precedes a final compatibility guard for missing optional receive
packet-age diagnostics. All 339 measured decisions per worker already required
incoming audio; the added expectation OR term preserves that value. The final
guard is regression-tested, but this is not a full capture of final source.

See `group-capture.json`, `checks.json`, and `native-build-proof.json` for hashes,
measurements and logs. All owned workers/helpers exited, node stop returned zero
on all four nodes, and no sockets remained; cleanup proofs are included.
