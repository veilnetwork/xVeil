# Independent preview reads and anonymous desktop evidence

Base: `825b9672`. The original Windows 10 report remains open. This round
confirms an application preview defect, not the cause of the user's camera
capture or outgoing-video failure.

## Confirmed mechanism

The frame timer read the remote decoded frame and the local self-preview inside
one try/catch. If the first getter threw, the local getter was never invoked,
even when it had a valid new frame. Repeated errors could leave self-preview
waiting or frozen. Native camera capture/encoding runs separately and is not
stopped by this timer; this finding alone does not explain absent outgoing RTP.

A controlled test runs the actual media controller and frame timer with a fake
engine. Three manually driven ticks produce three remote reads but **zero**
local reads on the baseline when only the remote getter throws. The inverse
control (local getter throws, remote remains usable) passes on the baseline.
There are no elapsed-time thresholds, real media devices or application windows.
The initial primary checkout needed its local package metadata refreshed after
integration; that compiler refusal is not counted as a baseline reproduction.
The credited red is the subsequent local-read assertion (expected 3, actual 0).

The two reads now have independent failure boundaries. Both directions are
attempted on each applicable tick; after a getter recovers, both notifiers can
receive its frame without replacing the engine or restarting the call.

## Diagnostics

Opt-in desktop `videoPreview` evidence is sampled by the existing one-second
media poll and retained separately from the busy event ring:

| Field | Meaning |
|---|---|
| `enabled` | Camera expected by current video/camera intent and no active/starting screen share |
| `state` | Frame-pump timer is active |
| `localPreviewFrames` | Non-null local frames pulled by the current pump |
| `localPreviewReadErrors` | Local preview read/update exceptions in this pump |
| `remotePreviewReadErrors` | Remote preview read/update exceptions in this pump |
| `localPreviewAgeMs` | Monotonic age of the last pulled local frame; absent before the first frame |

Frame/error counts are bounded to one billion and age to ten minutes. Counts
restart with the pump; zero is not proof of a device or transport failure.
Preview includes screen frames when screen sharing, so `enabled` distinguishes
the camera intent. No source timestamp, device label, exception string, ID,
pixel buffer or image is exported. Android native texture paths are not reported
as if they were desktop Dart previews. Ordinary diagnostic-off builds retain
none of this evidence.

Combined with existing camera-start/capturing and video-transmit counters,
the report can distinguish a running empty preview from getter failures or a
working preview followed by a later encoding/delivery problem. It cannot prove
pixels were painted or media was delivered to a peer, nor identify a driver
failure by itself.

## Checks and scope

- **113 passed, no skips**, with `XVEIL_DIAGNOSTICS=true`: controller startup,
  permissions, device switching, capture end/retry, independent reads and
  diagnostic retention/ranges/privacy. The controller regression also drives
  the real stats callback and checks its directional counters.
- **188 passed, no skips**, across 13 related suites with diagnostics at the
  ordinary disabled default: camera intent/retirement, receive activity, route
  operations, microphone state, preview widgets and video playback.
- Changed-source analyzer is clean. A Python artifact control compiles the
  production journal to AOT both enabled and disabled; its expected numeric
  preview evidence and existing private canaries pass.

No GUI stand, camera/microphone capture, Windows session interaction, USB
interaction, relay change, media-engine rebuild, push or release occurs.
Source graphs could not resolve this path in the bounded query; the mechanism
and checks above come from current source and the executable controller tests.
