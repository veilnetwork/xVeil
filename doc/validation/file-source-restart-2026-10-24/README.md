# File source restart and requester ownership — 24 October 2026

Follow-up: [first-receipt RTO correction and a completed interrupted transfer](../file-rto-first-receipt-2026-10-24/README.md).
The comparison below retains the results of these earlier runs.

**Requester-proof recovery is corrected; physical file performance remains open.**
Native SDK `cc52c17b` is unchanged across the comparison runs. This correction
is in the common Dart messaging layer.

## Confirmed defect

The source preserves its accepted contact through a restart, but its in-memory
physical-device → identity map starts empty. An anonymous file stream arrives
under the requester's device address. That claim alone cannot restore ownership,
so an accepted contact's restarted source can reject its stream as unknown.
The retry path previously repeated stream opens without re-establishing the
authenticated relationship.

On the cellular phone, stopping the owned source app for ten seconds during a
32 MiB transfer reproduced seven matching `DENIED` log entries and seven
EOF-before-manifest errors after restart. The source's identity and accepted
contact were retained. The transfer eventually made further progress, but did
not finish within its 240-second test limit. This is a recovery delay, not proof
that the old version could never recover through another authenticated exchange.

## Correction and deterministic regression

Before a **retry**, the receiver now sends the existing authenticated content
reoffer request to an accepted contact. The ordinary verified-message path can
learn device ownership again, while the reply refreshes the existing manifest.
No device ownership is inferred from an anonymous stream claim. Contact consent,
blocking, source access checks, envelope format and mailbox policy are unchanged.
Reoffer failure remains best effort, with the existing request-time bound; it
does not prevent the stream retry. Normal first opens receive no extra request.

The regression recreates the source service over its existing storage after
priming a different physical requester address. Its ownership map must be empty.
The old code times out; the corrected code completes the 600,000-byte file on its
second anonymous open, restores the verified relationship and matches all bytes.
The combined stream-transfer, credit and contact-device-policy suites pass
**83 tests**, and Dart analysis passes. No test-only behavior was added to the
production path.

## Physical results

The Poco used mobile data with Wi-Fi off. Both owned contact P2P overrides were
denied, and recorded file opens were anonymous. SDK hashes, installed QA APK
and loaded Mac library were verified; the corrected Dart frontends were rebuilt
from the current source snapshot. No call or audio output was started.

| Scenario, 32 MiB | Actual result |
| --- | --- |
| Poco → Mac, no interruption | Completed in **135.880 s**, SHA-256 matches. |
| Mac → Poco, first run | Hit the **180 s** cap at **23.25 MiB**; it was still progressing, with no payload-idle failure before cancellation. |
| Mac → Poco, repeat with a 600 s diagnostic allowance | Completed in **162.734 s**, SHA-256 matches; this sample also meets the original 180 s gate. |
| Source restart before the fix | Source stopped after **4.25 MiB**; same identity ready after **15.250 s**. Seven access denials / manifest EOFs retained; **14.25 MiB** at the 240 s cap. |
| Source restart with the fix | Source stopped after **4 MiB**; same identity ready after **15.056 s**. No matching access denial or manifest EOF. Resume requests at **4 MiB** and **18.5 MiB**; **30.25 MiB** at the 600 s cap. |

The corrected physical run observed the reoffer exchange and a newly learned
authenticated device proof after restart. Before harness cancellation, the two
observed pull failures were payload-idle events, including the intentional interruption. The receiver's
history retained one offer row for this content after the reoffers.

**The interrupted corrected file did not complete and has no final integrity
qualification.** A longer diagnostic allowance does not pass the 180/240-second
timing gates. Different routes, rates and observation durations prevent claiming
a physical throughput improvement from the larger partial file. Successful
ordinary transfers do not prove intermittent stalls have disappeared.

## Remaining work

The access-denial loop is addressed. Slow contiguous progress, payload-idle
recovery and variable throughput still require investigation. Near the end of
the corrected run, a sampled sender had 212,910 bytes queued, 25,024 bytes in
flight, a free peer window close to 8 MiB, a model of 67,228 B/s and a 4,316-ms
retransmission timeout. The latter is **not ping or one-way delivery latency**.
These samples do not identify the bottleneck or prove physical packet loss.
Sender recovery/SACK state and rate sampling under endpoint credit windows are
the next areas to examine before changing limits.

This cycle does not qualify Windows, audio/video, long offline periods, the full
A/B/C matrix or all crash stages. The overall defect work remains unfinished.

## Cleanup and privacy

All owned stand apps and log captures exited. Independent checks confirmed
process absence, removal of the ADB forward, restoration of the diagnostic
property, unchanged profile selection and the original phone APK's exact hash.
The installed Mac app was untouched. Builds used the monitored external volume;
Mac launches and Flutter tests used `/private/tmp/`.

Committed [evidence](summary.json) contains only relative timings, byte counts,
booleans, code hashes and commit references. Raw logs, node/device identifiers,
addresses, ports, paths, credentials, APKs and payloads remain private. The
original untracked October 17 matrix is preserved.
