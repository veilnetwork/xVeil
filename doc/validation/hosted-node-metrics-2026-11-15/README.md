# Hosted-node diagnostics and network-status remount

Managed-storage defaults remain **disabled**. This follows the
[hosted compaction qualification](../managed-compaction-access-root-2026-11-15/README.md).
Two failures from its packaged runs are now reproduced, fixed and rechecked.

## Confirmed failures

| Failure | Credited reproduction | Change |
|---|---|---|
| Hosted child apply-config fails with address-in-use | Actual normal-main QA app; real default hosted boot while the old metrics port is held | Give every hosted node an OS-assigned loopback metrics port |
| Returning home after maintenance causes a build-time parent notification | Packaged full Flutter stack; cached-controller remount widget test with the same stack | Follow the controller lifecycle inputs directly in the node-status stream |

### Diagnostic port ownership

Asking for the debug hook also asks for native metrics. Every hosted node had
inherited the single-node diagnostic port, so its QUIC listener could start and
apply-config could still fail when the metrics listener bound. Changing the QA
QUIC port did not help because that was not the conflicting service. This was a
debug/opt-in diagnostic failure, not evidence of container corruption or a
production listener defect.

The hosted default boot now requests port zero. The pure metrics composer
renders that as an OS-assigned **loopback** listener rather than omitting metrics.
Positive explicit ports and existing metrics tables retain their behavior;
null/negative requests remain no-ops. The single-node default is unchanged.
The existing debug gate still excludes this endpoint from ordinary release
builds; diagnostics were not removed to make hosted startup pass.

The native test uses synthetic storage adapters with the real default hosted
boot and the selected SDK. Its fixture holds the old diagnostic port throughout.
On the old code a live hosted stack is missing despite successful QUIC listener
starts. With the fix both native stacks connect, expose distinct non-demo node
IDs and start two distinct OS-assigned metrics endpoints. Teardown joins the
session and verifies that its QUIC ports can be rebound before removing the
fixture. This is actual node startup, not native container-durability coverage.

### Status subscription during remount

The home route disappears while maintenance replaces the nodes. Its always-alive
status stream can retain a paused, cached controller dependency. Subscribing
again flushes that dependency during the banner's build and schedules the
provider scope's refresh from inside a child build. The retained full stack and
the widget regression agree on this path; it was not a messaging-service
construction failure.

The stream now follows the actual stack/boot-state inputs directly, then reads
the shared, injectable controller owner. It still emits the current snapshot
before the live status stream. Error states and the network banner remain
visible. The regression hides the banner, replaces its controller while absent,
and remounts it; it proves both absence of the original exception and observation
of the new error status. Locked/ending admission controls remain in the suite.

Flutter errors also retain their full stack in the existing local diagnostic
log, as zone/platform errors already do. The anonymized error-export allowlist,
frame limit and text exclusion are unchanged.

## Final packaged qualification

The normal-main macOS QA bundle was rebuilt from verified current product inputs
and selected native libraries. Only its isolated bundle metadata was changed;
no installed user app/profile was replaced. The rebuilt Dart kernel, package
signature and mapped SDK, hidden-volume and SQLite libraries were checked. The
same pinned SQLite raw input/current reconstruction procedure is retained from
the previous qualification; the superseded transformed hash is not asserted.

Through the ordinary settings UI, all-owner collection authenticated the
independent encrypted roots, required explicit plaintext link-update consent,
and collected both known hidden passwords. Native compaction published, reopened
the selected hidden child on a **real** native stack, preserved its actual node
ID and read back the exact note digest. After locking and stopping the process,
a cold launch reopened both hosted children: the original encrypted child's ID
matched its original baseline, and the hidden child's actual ID and note matched
their pre-compaction baseline. Neither oracle accepts the debug loopback ID.

Final compaction and cold-run logs contain zero uncaught errors and zero
address-in-use failures; the retained cold log has no dropped entries. These
results supersede the earlier demo-ID comparisons rather than validating them
retroactively. No speed improvement or relay/call recovery is inferred here.

| Terminal run | Passed | Skipped |
|---|---:|---:|
| Final network/lifecycle/settings/diagnostic regression set, 16 suites | 160 | 0 |
| Opted-in real hosted-node startup regression | 1 | 0 |

The focused composer and remount regressions fail on their respective old code.
Static analysis of the full application and changed tests reports no issues.
Owned QA apps were locked and stopped, launcher exits consumed, and remaining
processes/listener closure checked. No push or release.

## Remaining scope

This closes the observed diagnostic-port and status-remount failures. Identity
creation's earlier locked-storage startup reads were not repeated here and stay
open. Physical Android/OEM, complete platform destructive/recovery qualification,
Windows source-directory durability, custom source-name journal binding,
all-target native pin updates, release AOT and activation remain separate gates.
