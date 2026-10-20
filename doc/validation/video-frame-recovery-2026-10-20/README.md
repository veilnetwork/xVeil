# Video source resolution recovery experiments (not enabled)

Neither recovery candidate is enabled. Production sources were restored to
Veil `6d3e3ab8` after the comparative captures failed to establish an overall
quality improvement. `candidate-not-enabled.patch` retains the final candidate
and its regressions; apply it from the Veil submodule to reproduce the build.

## Observed cause

The preceding three-process, 360-second group capture ended at 80×60 on all
six decoded paths. Each source had four oversized frames. Its additional source
pixel cap could only decrease until the effective allocation reached 60 kbit/s.
One source requested 117 kbit/s but the encoder still received about 28 kbit/s,
so successful small frames could never restore its resolution. See `before.json`.

## Candidate

The candidate probes 25% more area after ten seconds of comfortably sized
encoded frames (at least eight frames, each no more than 75% of the frame byte
budget). A new oversize or near-budget frame resets recovery. Repeated/stale
timestamps and a gap of three seconds cannot earn a probe. The cap never asks
for more pixels than a previously observed input image; the source adapter also
retains its capture/sink bounds.

The candidate preserves bitrate and FPS requests, audio policy, relay scheduling,
VP8 reference chain and SDK frame lifetime are unchanged. During recovery in
the 30–60 kbit/s hysteresis band the guard retains a rate-derived byte envelope
instead of leaving a pixel cap with no path to recover it. The existing release
at an effective allocation of 60 kbit/s remains.

## Tests and scope

The old no-recovery behavior fails the timed regression (captured with a no-op
timestamp parameter so the old behavior compiles against the new test). The
candidate budget smoke passes, including oversize handling, replay/stalls, limited
headroom and a second recovery following another oversize.

An initial periodic probe prototype reached 120×90 but reduced final-minute FPS
to 1.36–2.09 and increased the peak acoustic delay to 260.13 ms. It repeatedly
retried resolutions whose resize keyframe had already exceeded the budget.
That version was rejected; its capture, binary hashes and cleanup are retained
in `prototype-rejected.json` and the prototype proof files.

The revised candidate remembers the smallest resolution that produced an oversize
frame and its encoded cost. It can recover below that size, but cannot retry
that failed resolution until the measured byte budget funds the failed frame
with 25% margin. A timed regression proves that small delta frames cannot cause
repeated failed probes, while an actual allocation increase to 40 kbit/s can
unlock that resolution before the previous 60 kbit/s release threshold.

The real VP8 smoke proves the callback path recovers a source pixel cap at an
unchanged 8 kbit/s on both direct and group engines. Its former immediate
assertion that a larger *requested* bitrate releases the cap was corrected:
the actual encoder allocation can still be low after the longer low-rate run.
The allocation-based release remains explicitly covered by the budget smoke.

No C ABI, codec wire format, relay priority or application setting was added.
Synthetic PCM/VP8 results do not establish live speech intelligibility or
physical camera/screen presentation.

## Final candidate capture

The same 360-second workload used three isolated processes, six media paths,
a neutral 1024 kbit/s FIFO relay and three concurrent encrypted 512 KiB files.
All 2,112 audio markers and all files arrived, but the capture still failed the
original acoustic gate: maximum 260.20 ms. That target is deferred by the user;
the gate was not changed. All six paths passed the existing final motion gate,
but ended at 80×60 and 1.00–2.53 decoded FPS. There was no demonstrated overall
improvement over the prior 1.85–5.46 FPS / 210.16 ms capture.

The final candidate stopped periodic retries of known unfunded resolutions.
That local correctness property is established; improved call quality is not.
See `qualified-not-enabled.json` and `native-build-proof.json`. The complete
call-planes smoke passed after that capture, including audio progress with
video queues stalled. Both candidate captures have independent cleanup proofs;
all owned workers/helpers exited and no fixture sockets remained.

## Next constraint to measure

The existing frame budget uses a theoretical `rate / 20` byte hint and a
single-packet floor, anticipating fragments waiting for the SDK's 200 ms local
freshness deadline. The actual native field trial requests
`factor:4.0,max_delay:25ms`; pinned WebRTC raises its adjusted pacing rate when
needed to drain a queued frame toward that delay target. Completed-frame queue
age (measured from the first fragment) was only 0–4 ms in the final capture.
That does not prove the 200 ms deadline never expires: incomplete frames and
downstream admission need separate attribution. It does mean the theoretical
byte envelope alone is insufficient evidence that an encoded image is unsafe.

The next experiment should correlate actual first-to-marker timing, frame
admission/expiry and decoded progress, instead of attempting another blind
pixel recovery or changing the acoustic target. `pacing-evidence.json` records
the relevant source hashes and locations. The relay remains opaque and neutral.
