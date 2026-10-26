# RTT-paced video recovery

## Change

After congestion drain, healthy cruise probes previously waited a fixed three
seconds. The model now uses twice the validated RTT, bounded to 950–3000 ms.
Missing or invalid RTT keeps three seconds. A later RTT increase or loss of RTT
extends a pending deadline. Cruise FPS growth is bounded to 25% per probe.

Causal decoder acknowledgements, fresh feedback from every expected peer,
route and membership resets, audio guards, congestion drain and its initial
six-second retry remain enforced. No relay classification or priority changes.

## Verification

231 focused tests passed. Regression tests first failed against the previous
fixed interval and deadline handling, then passed with the correction. Focused
static analysis and whitespace checks passed.

A preceding physical Wi-Fi relay baseline reached 29.5 decoded FPS in both
directions in its final window, but recovered slowly after an audio impairment.
This motivated the change; it does not measure the new implementation.

The candidate physical attempt did not reach incoming ringing within its
60-second deadline and never started media. It is excluded from passing media
evidence. The stand used frozen native libraries for a controlled frontend
comparison, not the forthcoming release SDK. Live speech, loudness, cellular
quality and a physical recovery speedup are not qualified by this cycle.

Both owned app instances were stopped, the owned ADB forward removed, the
Mac QA profile archived and temporary camera/microphone grants restored.
Public evidence excludes identities, addresses, keys, raw traces and clocks.
