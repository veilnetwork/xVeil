# Call fallback lifetime and physical video qualification

SDK fix: `9bf194c3`. The native media engine and hidden-volume are unchanged.

## Confirmed defect and fix

Closing a call stopped its private-route workers but did not own the generic
fallback openers and circuits created for its isolated producers. Dropping a
`DataCircuit` handle does not remove its origin-table row or send a teardown.
An opener could also finish after the channel closed. These allocations could
continue consuming circuit capacity until normal expiration.

Each isolated producer now owns its opener cancellation handles and circuit
lifetime guards. Candidates acquire a guard before awaiting confirmation.
Pool entries and in-flight selections share the guard; replacing an entry
does not retire a still-used selection. Closing the channel aborts openers,
closes feeds, removes origin state and sends the ordinary circuit teardown.
Weak registry references avoid keeping retired guards alive. A concurrent
late registration is retired immediately.

File-stream pools retain their existing shared receive-grace policy. Media
guards do not leave that policy's delayed cleanup tasks holding their services
after close. There are no new relay-visible roles, priorities or wire fields.

## Verification

| Check | Result |
|---|---|
| Real established fallback, then public channel close | Origin and first-hop relay slots disappear within the two-second deadline |
| Shared file hub after that close | Exact test bytes received through its real reliable stream |
| Last hop blackholed during fallback confirmation | Stop cancels the opener and releases allocated slots without waiting for the ten-second confirmation timeout |
| Guard against post-close warm | No new tracked opener after stop |
| Full embedded FFI suite | 375 passed; 11 existing ignored tests |
| Strict Clippy, all FFI targets | Passed |
| Header and generated ABI contracts | Unchanged |
| Android and macOS production-feature SDKs and QA frontends | Built; installed Android APK verified by its complete SHA-256 |

The established-circuit test failed semantically on the preceding production
implementation. The cancellation test also failed when stop-side ownership
release was temporarily disabled; the candidate was restored afterwards.
Tests keep the runtimes running while checking cleanup, so node teardown and
TTL cannot mask a leak.

The first full-suite attempt exposed a race in the new cancellation fixture:
starting a media pump warms its primary route before a later network cut.
The fixture now constructs the real hub/routes without pumps and explicitly
warms only after cutting the last hop. The two-second cleanup deadline remains.

## Physical Mac / Android call

Both QA profiles were preserved. The phone's active connection was Wi-Fi;
P2P remained denied for the test contact. This call used relay transport and
does **not** qualify the anonymous fallback fix; the native network tests above
exercise that path.

| Measurement | Result |
|---|---:|
| Incoming call observed | 808 ms |
| Answer to five audio RTP packets on both devices | 1,701 ms |
| Cameras enabled to five decoded frames on both devices | 10,434 ms |
| First observed five-second window with at least 20 decoded FPS, desktop / Android | 38,204 / 39,229 ms after camera enable |
| Final sampled decoded FPS, desktop / Android | 29.92 / 30.31 |
| Registered audio interruptions, desktop / Android | 0 / 0 |
| Maximum sampled audio jitter buffer during video, desktop / Android | 121 / 131 ms |

The [cautious RTT probe](../video-rtt-probes-2026-10-25/README.md) was exercised:
native cadence reached 1.25 FPS while the policy allowed a probe on both
devices. Subsequent fractional steps were observed on the desktop. This proves
branch execution, not faster startup. RTT reports reached approximately 805 ms;
growth remained restricted for part of the startup despite small audio buffers.
Slow full-quality recovery remains open. This is one combined-build run, with
no matched physical before/after comparison.

[physical-summary.json](physical-summary.json) and
[physical-video-trace.csv](physical-video-trace.csv) contain only aggregate or
numeric relative-time observations. No IDs, addresses, credentials, capture
labels, absolute native timestamps, audio or images are included. Speech
intelligibility and loudness were not assessed.

Both QA apps were closed. A separate check verified zero owned Mac processes,
no QA process on Android, exact restoration of microphone/camera grants, removal
of the owned ADB forward and archival of the QA Mac profile. Main installations
and system power/volume settings were not changed.

The production-feature native builds preceded a comment correction in the
retirement helper and a `cfg(test)` fixture synchronization change; executable
production behavior was unchanged by those edits. The subsequent local A/B/C
build uses the exact committed SDK source.

## A/B/C anonymous-call checks

A/B are separate processes of one identity; C is another identity. Three local
relays and real containers/SDK/media are used without a separate C–B session.
C rings both online devices; only the selected answerer stays in the call.
Both actual audio RTP counters must exceed five and continue increasing over
the following five seconds. Hangup must reach the other endpoint.

| Build/run | Online A/B: answerer | Answer observed by C | Duplex audio after acceptance | B answers with A offline: duplex audio |
|---|---|---:|---:|---:|
| Baseline, this cycle | B | 3,744 ms | 5,775 ms | 439 ms |
| Candidate, first | A | 1,660 ms | 3,289 ms | 4,234 ms |
| Candidate, second | B | 3,731 ms | 13,951 ms | 14,349 ms |

All three runs passed the functional checks and process cleanup: five owned
groups/nine PIDs checked per run, zero remaining, stand directories removed.
The last run confirms that **cold-start latency remains unresolved**. Circuit
cleanup alone does not establish a faster start, and these differing runs are
not a latency distribution or a controlled attribution experiment.

[summary.json](summary.json) contains aggregate results and software hashes.

## Remaining qualification

Stable cold three-device startup, simultaneous-answer races, long reconnects, the full
multi-device matrix, Windows 10, Android background operation and live speech
remain separate work. The circuit leak is not established as the sole cause of
the earlier cold-start delays. A failed local qualification attempt ran out of
host temporary space before the application started; it is not a product-test
result. Its processes were cleaned up before retrying. Older owned QA binaries
and APKs were archived to the external filesystem with hashes verified and
original references preserved; user profiles and application data were retained.
