# Shared unfinished group-header reads — 2026-10-27

UI, sync and media readers could issue the same encrypted group-header read
concurrently. Segment reads already shared an unfinished operation, but header
reads did not: they also reached those segment reads at different times.

GroupService now shares only the unfinished raw-header future. Every caller
still decodes and validates its own bundle. A settled read returns to storage;
no final bundle, membership verdict or key authorization is cached. A new save
invalidates the preceding shared read. Timeout reads while a write remains in
flight are unshared. Purge and shutdown clear the relevant pending reads too.

A held-read test compiled on base `0aa9f141` and observed **12** physical header
reads for 12 concurrent callers where one was expected. It passes with this
change, observes distinct decoded bundles, and verifies that a later read sees
deletion. A second test checks failure propagation and recovery on the next
read. The broader group/device/snapshot/backpressure/provenance suites passed
387 tests with three existing skips. Analysis passed without issues.

## Physical investigation

The retained stand had A Android on Wi-Fi and B macOS sharing identity X, with
C macOS as identity Y. Veil `1d36980d`, media artifacts and identity difficulty
were unchanged. No Rust build, server change, release or push was performed.
Android was observed awake, with the QA activity resumed and power saving off.

An extended normal-code recovery on base `0aa9f141` added no messages. The
previous 100-message fixture advanced from A=52/B=100/C=100 to
A=91/B=100/C=100 in 609,217 ms. The missing rows were predominantly absent from
A's folded device journal as well, rather than waiting solely for chat apply.

Private QA source copies then measured awaited stages. No timing code was
added to the repository or native libraries. A 20-message C-to-X burst took
810 ms to submit; after 307,391 ms B/C held all 20 and A held none. A had
mean group-apply time 7,651.6 ms, mean group-load time 2,002.5 ms and a maximum
dequeued-frame wait of 279,907.7 ms. These are wall-clock stages; concurrent
group reads overlap, so their cumulative time must not be summed as CPU time.

With this change, recovery of those same retained fixtures, without new load,
reached all 100 inherited and all 20 recent messages on A/B/C after 249,812 ms,
without duplicates. This is **not a controlled before/after latency comparison**:
the earlier run had already advanced the older backlog, and the frame mix
differs. Mean group apply remained 7,618.3 ms. The header-read correction is
qualified by its I/O-count test; no claim that it resolves physical latency is
made.

The private timing source was subsequently removed from both QA source copies
and normal kernels rebuilt. After restarting all three normal QA apps, the
first check, 650 ms after starting observations, found all 100 inherited and
20 recent messages on every device, with identical logical IDs and no
duplicates. Timing source was absent from the kernels and the private timing
endpoint returned 404 on every role. This verifies persistence, not new-message
latency. The [anonymous evidence](summary.json) records the checks.

All started apps were closed after each stand run. The final audit found no
processes in the five recorded macOS groups, no owned app executable or QA
Android process, restored QA permissions and no owned ADB forward. Main app
data and system power settings were unchanged.

## Remaining work

Slow catch-up remains open. In the omitted-manifest device-delta path,
`_restoreOmittedManifest` loads the whole journal to recover its manifest;
the serialized merge then loads it again. The next investigation should retain
one coherent loaded view inside the group mutation gate, preserving hash,
membership and missing-segment checks. This has not been changed here.

This does not qualify Windows, calls, revocation, long offline periods, or the
full multi-device matrix. Raw logs, message markers, device identifiers and
private paths are excluded from this report.
