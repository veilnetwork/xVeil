# Packaged macOS call-network retirement

## Scope

This follows the [native ownership checks](../macos-call-activity-retirement-2026-11-15/README.md)
with a real Flutter method-channel round trip in a separately named QA app.
It closes the packaged-runner gap for call-network activity retirement only.
It does not qualify managed storage, camera/audio capture or a messenger call.

## Build correction

The first full Debug build failed while compiling a dependency of the embedded
PacketTunnel node: rustc reported that it could not find a host proc-macro crate.
The dylib existed and had the correct architecture. Loading it directly exposed
a malformed Mach-O LINKEDIT string pool. The build used disabled debug info;
stripping the host dylib left it unusable by the compiler.

The Debug branch of `scripts/build-packet-tunnel-macos.sh` now sets
`CARGO_PROFILE_DEV_STRIP=none`, matching the existing release-path policy.
The full build then succeeded, including the Rust static archive, plugins and
PacketTunnel extension. This is an observed Debug build failure and repair;
it is not evidence of a release-media defect.

## Packaged checks

The entry point is [macos_call_network_probe.dart](../../../test/native/macos_call_network_probe.dart).
It runs after the first Flutter frame using the production runner and actual
`xveil/call_network` channel. No channel handler or plugin-registration stub is
substituted. It opens no container, starts no node and captures no media.

Three fresh processes each passed all 13 assertions, reporting exactly one
bounded result and exiting successfully:

- Acquire an activity through the original Dart facade and observe native state.
- Retire and verify through the composed background-service actions; observe
  inactive state and refusal of both old-facade and raw native acquisition.
- Reject a foreign retirement token.
- Release admission, publish a fresh facade and acquire a new activity.
- Deliver a late release from the old facade without ending the fresh activity.
- Release the fresh activity and observe inactive state.
- Repeat the old admission-release receipt without replacing the fresh facade.

The platform assertion is included in the 13 checks. State observations use the
runner's real activity inventory, rather than a Dart-only owner count. They do
not independently measure App Nap or hardware power state.

## Build and provenance

The isolated copy retained the real app sources, assets, generated plugin
registration, CocoaPods integration and embedded PacketTunnel target. Only the
QA bundle/product identifiers and Flutter entry point changed. It was built for
arm64 with the Debug configuration and then signed ad hoc.

The first ad-hoc launch was killed before the probe could report because its
unprovisioned host carried the restricted Network Extension entitlement. The
harness was corrected to follow the existing debug policy in
`scripts/bundle-macos-dylibs.sh`: omit that entitlement from the unprovisioned
host while retaining the extension's own entitlements. Production signing and
entitlements were not changed. That initial launch is not a passing run or a
new application finding.

The consumed copies of 899 app/build input files matched the worktree, with
only the recorded QA metadata substitutions. The SDK inventory covered 990
source/manifest files and matched before and after qualification. A dedicated
external Cargo target was used with a live filesystem/free-space watchdog.
The copied PacketTunnel archive matched the selected target archive by SHA-256.
The final host/extension executable hashes were recorded privately and the
complete bundle passed strict, deep signature verification before and after
the runs. No developer signing identity was used.

An additional 31 checks passed across the network activity/retirement,
background-service, microphone-lifetime and Apple tunnel-build suites. Dart
analysis of the probe passed. The source inventory and four previously pinned
native-library hashes remained unchanged around those suites. All QA app
processes exited; no installed application or user container was replaced.

## Limits

This is an unprovisioned Debug runner, not release-sandbox qualification. The
extension was compiled, embedded and signed, but not activated. Plugin
registration executed during startup; individual plugin functions, runtime FFI
libraries, microphone/camera resources and network delivery were not exercised.

Independent native media-resource observations, cold application recovery and
packaged storage migration/maintenance remain open. Managed storage stays
disabled. There is no push, installation or release in this cycle.
