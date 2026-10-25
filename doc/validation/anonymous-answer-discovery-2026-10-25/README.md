# Anonymous answer delivery: cold DHT lookup attribution

SDK: `54dff306` (base `325e36e0` plus explicit endpoint diagnostics).

## Change and scope

DHT candidate lookups can now log a bounded per-replica outcome and elapsed
lookup duration when the existing `VEIL_RT_TRACE` switch is explicitly enabled.
The trace distinguishes a valid value, an empty reply, a closed receiver and a
timeout. Query selection, deadlines, candidate validation, pending-query
cancellation and device authorization are unchanged. Trace volume is bounded
by the ordinary replica cap per lookup. These raw endpoint traces contain
short target/peer identifiers and must stay private; the app's support report
exports typed diagnostic metrics and does not include these raw log strings.

The native startup fixture now observes the caller concurrently with the
accept request. It records when the caller first reports the answer, then waits
for both operations. It no longer makes the accept API or the answerer's
media-statistics call a prerequisite for observing the caller. Poll intervals
still limit measurement precision; private signal event times provide the
finer attribution below.

## Confirmed delay before the media handshake

Three independent native workers: A/B share an identity, C has another.
C calls A/B; B answers and A stops ringing. No explicit C–B session is added.
The repeated call runs after A stops. The sealed relay island and canonical
fixture identities match the preceding production-SDK qualification.

In the diagnostic baseline:

| First call event | Time since accept invocation |
|---|---:|
| B enqueues its answer | 33 ms |
| B starts audio | 109 ms |
| B finishes family delegation/route lookup | 3,536–3,538 ms |
| C receives the answer | 3,554 ms |
| C starts audio | 3,621 ms |

The answer's independently logged age is 3,520 ms; the two endpoint timestamps
are 3,521 ms apart after aligning their time zones. Thus the observed initial
delay is in answer delivery. Audio initialization takes approximately 0.1 s
in this fixture.

Lookup traces identify the waiting condition: address slots 0–3 return valid
records in 1–4 ms. Slot 4 has both fast values and silent replicas in the first
refresh. Slots 5–7 have no returned value and all selected replicas reach the
3,500-ms deadline. The resolver awaits every configured slot. The recursive
protocol supplies positive values but has no aggregate terminal negative result
for these missing walks, so an unused slot consumes the full lookup deadline.
The later refresh receives the identity document in 3–4 ms. Other/background
lookups overlap; raw trace order alone does not identify every request's
invocation time.

This cycle establishes the missing-slot wait. It does not remove that delay.
The resolver must continue comparing signed replica evidence and enforcing the
latest device/revocation floor; an early return on the first cached or remote
value is not qualified by these results.

## Verification and limitations

Eight runtime unit tests passed, including the stale-local/stale-first-replica
freshness regression and cancellation cleanup regression. The diagnostic native
library and relay CLI built successfully while the external Rust target stayed
mounted. Diagnostic builds use the local-island feature set
`node-embedded,allow-empty-seeds,test-low-difficulty,packet-tunnel`.
The previous production-feature SDK run independently reproduced the same
approximately 3.7-s first-answer observation.

The baseline real-codec anonymous calls passed with growing `audio_rx_pkts` in
both directions, correct sibling cancellation and remote hangup. The updated
fixture's independent observation is recorded in [summary.json](summary.json).

| Updated fixture scenario | Caller observed answer | Five audio RTP packets on both |
|---|---:|---:|
| C calls A/B; both online; B answers | 3,672 ms | 4,085 ms |
| Repeated call after A stops; B answers | 405 ms | 408 ms |

The observation loop uses a 400-ms polling interval. In particular, the
405-ms warm observation is quantized by polling and does not establish a
405-ms signalling delay. Both endpoints' packet counters kept growing for a
further five seconds in each call, sibling cancellation and hangup passed,
and all owned process groups exited.

These are local process tests. A physical phone, live speech, loudness, camera
motion and the mobile-network video ramp were not qualified in this cycle.
The phone was absent from both ADB and the USB device tree during inspection.

## Storage interruption and cleanup

One attempt of the updated fixture was explicitly aborted after a worker kernel
copy failed with `ENOSPC`. The wrapper returned zero after interruption; that
exit is excluded from qualification. All of its owned process groups were
terminated and verified gone, and its private runtime directory was archived.

The host had accumulated 78 GiB of generated `build/test_cache` kernels.
Removed 749 old generated kernel files after checking open handles, retaining
the newest 24 eligible files and all current/open files; reclaimed 75.11 GiB.
Two unused prepared artifacts were copied to the mounted external disk with
SHA-256 verification and original cache paths retained as symlinks. Source,
profiles and user data were preserved. The fixture was then rerun.

Private logs, identities, addresses, keys, absolute timestamps, media and local
profile paths are excluded from the checked-in summary. Cleanup checks cover
whole owned process groups as well as the recorded worker/relay PIDs.
