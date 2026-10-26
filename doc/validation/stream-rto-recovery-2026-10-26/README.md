# Stream RTO recovery after first-SACK delivery

Local SDK correction `1d36980d`; no release, push or relay deployment.

## Confirmed timer defect

The preceding sealed stand showed a sender retaining a 10-second RTO while
its smoothed RTT was about 300 ms. The receiver eventually aborted one stream
after 20 seconds without new readable payload, although later segments were
already held out of order. Its resumed file completed intact. Those symptoms
motivated this investigation; they do not prove a single cause for all delay.

The engine correctly preserves an original's first SACK timing so cumulative
retirement cannot mistake a long head-repair/local-queue wait for a new RTT.
It previously allowed such timing only to increase RTO. Consequently even
new originals sent after a previous RTO, freshly received and cumulatively
retired after its recovery, could never release the earlier exponential
backoff if they had first arrived out of order.

A behavioral regression recovers an old timed-out flight, then sends a new
flight whose head needs fast repair while its original tail is SACKed. Before
correction, fresh ten-millisecond delivery evidence left an older 80-ms backoff
instead of returning to the test's 40-ms minimum. The same regression passes
after correction, with both RACK and SACK-count recovery and sequence wrap.

## Correction and guards

Each actual DATA timeout records its time and protected sequence frontier.
Deferred first-SACK timing can release that backoff only when:

- the original was first handed off after the latest timeout;
- the cumulative ACK has covered that timeout's entire protected flight;
- the recorded first receipt is younger than the configured maximum RTO;
- the segment has never been retransmitted and is being retired once.

Otherwise the existing conservative handling remains. Any slower original
receipt in the same retirement still contributes its previous protective RTO
floor. Ordinary original cumulative-ACK samples retain their existing role.
The added local summary counter records qualifying first-SACK refreshes.

Minimum/maximum RTO, retransmission limits, pacing, congestion-window policy,
wire format and relay scheduling are unchanged. There is no media/content hint
or mailbox change.

## Validation

All 152 veil-onion-stream tests passed, including 90 library and 62 integration
tests, without skips. New guards cover a later RTO invalidating earlier timing,
expiry during a long local repair wait, replayed SACKs, and partial cumulative
progress that has not yet retired the protected flight. Existing slow-original,
local-handoff, reordering, repeated-loss, cancellation and BBR tests also passed.
All 325 enabled FFI library tests passed (two existing skips). Clippy with all
targets passed for onion-stream and FFI. Rust warnings were denied and the
external target mount monitored throughout builds/tests.

The matching optimized CLI/FFI were frozen and checked against the committed
SDK source. The production media library comes from the unchanged C++ tree
qualified with the audio-device factory correction. Raw traces, identifiers,
payloads and absolute clocks remain private.

## Sealed stand result

The three-process stand used A/B as identity X and C as identity Y. C rang both
online devices; B answered and A stopped ringing. The concurrent anonymous file
of 3,145,979 bytes completed its size/SHA-256 qualification in 340,815 ms. The
elapsed value includes the fixture's final audio-observation join (up to five
seconds); it is not a pure socket-transfer timing.

Both endpoints used one content stream. Neither reported the receiver's
20-second payload-idle failure, and no application-level stream restart was
needed. The sender's existing periodic summary observed 29 qualifying first-
SACK RTO updates; the largest sampled sender RTO was 5,640 ms. These are sampled
diagnostics, not a bound on every intermediate timer value.

Audio RTP reception advanced on both active endpoints in every five-second
observation window. Hangup converged. After A stopped, a second C-to-B call
connected, exchanged audio packets and hung up normally. The fixture exited
zero, source hashes stayed unchanged during the run, and all owned runner/
worker groups and runtime commands were verified absent after cleanup.

The preceding diagnostic run completed the same-sized file in 471,186 ms and
used two content streams after a payload-idle timeout. These independent fresh
stands are not a repeated fixed-route benchmark. The regression proves the
timer defect and the new counter proves that correction was exercised live;
the single timing comparison does not establish a general speed increase.

File delivery during a call remains slow. The endpoint's DATA rate limits were
not changed. Windows execution, physical speech/loudness, cellular delivery,
video quality and the complete multi-device campaign remain unqualified by
this run. Installed apps/profiles and production relay services were untouched.
