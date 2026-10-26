# Anonymous stream queued writes

Local work only; no release, push, relay deployment or main-app installation.

## Confirmed inefficiency and correction

The Flutter SDK observes native write progress in 2 KiB pieces. Anonymous
streams pass those pieces directly to the in-process Rust driver, rather than
through the ordinary SDK's IPC data window. The driver's application queue has
eight slots, but previously it admitted only one command before polling cells
again. Already queued writes could therefore each produce a small padded tail.
With the observed 1982-byte MSS, one 2048-byte write produces payloads of 1982
and 66 bytes.

The driver now admits at most eight ready commands per turn. It uses try_recv,
does not wait for a batch, stops at FIN or disconnection, and checks the existing
4 MiB send-buffer high-water mark before each additional command. It leaves the
next command queued at the batch limit. The command-channel bound, SDK progress
granularity, carrier pacing, congestion control and receive window are unchanged.
No relay priority, traffic classification, authentication exception or mailbox
fallback was added.

A deterministic real-driver regression pauses the first DATA admission, queues
eight more short writes, and resumes the carrier. Before correction, nine writes
used eighteen DATA cells with repeated 66-byte tails. Afterwards they use eleven
cells, preserving every byte and FIN. The isolated first write must reach the
carrier before later writes exist, guarding against added batching latency.
A second case verifies byte identity and FIN across 65 writes and multiple
queue batches. All 150 veil-onion-stream tests passed, including existing
ACK fairness, reset, local backpressure, partial handoff and retransmission tests.
The optimized FFI library built successfully with warnings denied. External
target mount identity was checked before and throughout Rust builds/tests.

## Cold native comparison

Two independent macOS QA processes, B and C from the preceding three-device
stand, retained their latest encrypted profiles and physical keys. A was offline.
Each phase cold-launched both nodes; profiles were never restored backwards.
Both contacts' P2P policies were temporarily denied and restored after each
transfer. Every run sent a fresh random file of 3 MiB plus a 251-byte tail,
verified that the recipient did not already cache it, and checked the complete
download byte-for-byte and with SHA-256. Endpoint diagnostics used existing
debug flags in private QA bundles. Production source gained no test hook.

The preceding stand had used an unoptimized development Rust library. A release
library of the same source revision was built before evaluating this change.
The release baseline and candidate used matching build features and the same
Dart bundle. This is a public-network experiment, not a fixed-path simulator.

| Native build | Complete verified download | Source manifest to completion of application writes | Connection timeouts |
| --- | ---: | ---: | ---: |
| Development baseline | 45.220 s | 41.665 s | 0 |
| Release baseline, run 1 | 22.060 s | 19.327 s | 0 |
| Release candidate, run 1 | 13.188 s | 5.447 s | 0 |
| Release baseline, run 2 | 71.497 s | 12.263 s | 2 |
| Release candidate, run 2 | 48.194 s | 30.693 s | 0 |

Application-write completion means queued/admitted writes, not final remote
receipt. Only the complete-download column includes the final size/hash check.
The deterministic reduction in padded cells is established. These few variable
network samples do not establish a universal latency improvement: candidate
run 2's data phase was slower than both optimized baseline data phases.

## Remaining delivery problem

Baseline run 2 hit the existing 25-second connection deadline twice. The source
accepted streams but did not receive the content request before cancellation.
The third stream delivered the file intact. Separately, candidate run 2 showed
multi-second sender RTT estimates and local carrier backpressure during DATA.
Those observations separate connection establishment from bulk pacing and
prevent treating this correction as a complete fix for slow or one-way delivery.
The cause of the handshake stalls and RTT inflation remains unproven. Earlier
publisher-slot refusals are also not yet causally connected to either delay;
the admission limit remains unchanged.

The [next cycle](../cold-stream-reply-identity-2026-10-26/README.md) confirms and
corrects a cold-start reply-route identity lookup gap, and adds anonymous ingress
diagnostics. Attribution of the original observed handshake stalls remains open.

All owned app process groups were verified exited after the transfers. Latest
encrypted profiles and raw diagnostics were archived privately; public evidence
contains no identities, addresses, tickets, payloads or raw event timestamps.
This cycle does not qualify Windows 10, cellular service, live audio quality,
video, interrupted-download recovery or the full multi-device campaign.
