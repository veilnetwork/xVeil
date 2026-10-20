# Remeasure startup after a relative RTT warning — 2026-10-20

## Measured cause

The preceding Camera2 check captured Mac policy observation 8: RTT 200 ms
against a 16 ms baseline, actual receiver/peer buffers 56/65 ms, with no recorded
loss, interruption or buffer pressure. The relative RTT rail was exceeded,
so `networkBad` permanently retired fast startup even after the RTT recovered.
That run's Mac video recovered slowly (17.27 outgoing FPS in seconds 120–150).
The trace proves the decision; it does not identify the network excursion's
cause or attribute it to the larger phone capture.

## Change

A relative RTT warning can reset the healthy startup period without permanently
retiring startup when all expected audio directions have measured, healthy
playout and video is progressing. Source pressure, buffer growth/pressure,
missing measurements or real media loss cannot take this exception. The existing
absolute RTT failure rail remains 400 ms; its literal was extracted to a named
constant without changing the value.

During the warning there is no growth. A cold measured floor must earn a new
three-observation healthy period and a distinct peer confirmation before its
first bounded step. A warning during an already pending native ramp still
resets ramp credit and requires twelve healthy observations. Actual impairments
continue to retire fast startup. The code never re-enables a startup shortcut
that was already retired by an earlier failure.

Existing audio priority, bitrate/FPS step bounds, native ACKs, source admission,
route epochs, network/wire format and relay scheduling are unchanged.
`relative_rtt_warning` is local diagnostics only.

## Verification

The new regression reproduces 16 → 200 → 16 ms RTT with 60 ms measured buffers.
The old source fails after three newly healthy samples (expected rung 3, got 4).
The change passes and verifies the warning spends no growth or old healthy
credit. Six negative cases retain slow recovery: absolute RTT 400 ms, loss,
full audio buffer, missing peer measurement, source pressure and an unmeasured
legacy peer. Another regression verifies the twelve-sample debt when a native
ramp was already pending.

The selected **430 Flutter tests** passed, covering adapter, call service,
direct source pressure/recovery and group source/media. Targeted analysis found
no issues; diff checks and macOS/Android profile builds 12630 passed. Native
SDK/media inputs remain pinned to the preceding verified stand.

The phone disappeared from ADB before installation; this cycle did not replace
its ordinary APK or start a physical phone call. These tests and builds do not
claim physical validation of the new branch. Broader transport contention
verification is recorded separately; the full audio/video/screen/data goal
remains active. Own edits are committed unsigned without push/release.
