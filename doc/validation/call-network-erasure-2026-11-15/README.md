# Call network resources in profile erasure

## Confirmed defects

A corrected pre-fix production-composer fixture removed its actual synthetic
legacy file while a modeled native call-network resource remained held. An
unrelated microphone fixture was explicitly inactive in this reproduction.
A second behavioral reproduction showed that a null platform release reply was
collapsed to false, losing the pending cleanup. Both are fixed; neither is
attributed to a reported mobile audio interruption.

## Ownership and ordering

Each call controller retains its original call-network coordinator before
permission or startup awaits. The direct controller previously looked up the
current global object on acquire/release; it now follows the existing group
controller binding. Old coordinators stay sealed after a new profile is admitted.

The production background composer captures microphone/network lifetimes at
construction. Retirement seals both synchronously before joining accepted daemon
commands. Network retirement then joins its own accepted queue and requires a
native resource owner, even with an empty desired-owner cache. Failed and null
ordinary replies remain unknown; a missing supported-platform retirement port
refuses instead of guessing absence.

Native Android admission requires both an open daemon gate and an open network
gate. Beginning retirement requires a sealed daemon and binds an opaque token
to that daemon generation. It releases all retained native lock holders and
verifies none remain. Verification and final release recheck the same binding
and resource inventory. Wrong tokens, another daemon generation, unverified
release and remaining holders refuse. Exact retries of lost successful release
are idempotent. Live engines are not destroyed by the sweep; admission opens
only for the subsequent daemon/profile generation.

The background owner verifies daemon, microphone and network resources at the
existing erasure barriers. Native network/microphone admission releases before
daemon admission. Both Dart publication preconditions are checked before either
fresh facade is installed, after the daemon release succeeds. Old facades never
regain authority. This resource proof does not authorize deleting a profile;
the existing erasure worker and request bindings remain required.

## Validation

- 472 checks passed across 31 serial Flutter suites: call-network ownership
  and retirement, direct/group media, background/microphone lifetimes,
  screen locks, capture resources and native profile-wipe/guard fixtures.
  The current host ran the null-reply case; other unsupported native hosts
  explicitly skip that platform-port check.
- New actor tests cover accepted/reentrant work, permanent sealing, missing or
  invalid native proof, resource refusal/retry, lost release replies, foreign
  publication and null ordinary replies. Background tests verify synchronous
  sealing during an outstanding daemon call and reentrant retirement ownership.
- A production-composer native fixture preserves actual synthetic payloads, six
  OS-key fixture records and absence of an erasure intent on network refusal.
  A second fixture introduces a held resource after native preparation and
  preserves payloads/keys before deletion; resolving it permits retry.
- Omitting the composer's network recheck made the second fixture fail at its
  actual payload-preservation assertion. Production code was restored before
  the final broad suite.
- The production Kotlin owner passed its 12 host scenarios; the new native
  retirement gate passed token, generation, admission, observed-resource,
  unverified-release and lost-success checks. Six compiled private-copy mutants
  failed behaviorally, including three new retirement-gate mutants.
- All 19 actual application Kotlin files and current SDK Android sources and
  resources compiled into an isolated debug APK with verified source hashes.
  This harness has no Flutter app assets and was not installed.
- Analysis of all seven affected Dart files reported no issues. Source
  inventories and four pinned native-library hashes matched around host runs.
  No native media engine was rebuilt.

## Limits

Projection/audio/camera runtime behavior is not established by these host tests.
Native lock ports and OS keys in erasure fixtures are modeled; native profile
workers and filesystem deletion are real on synthetic data. Native Android
compilation is a build check, not physical Wi-Fi power qualification.

The macOS native retirement port subsequently received
[host qualification](../macos-call-activity-retirement-2026-11-15/README.md).
A supported platform with a missing port still refuses. The no-resource port is
limited to platforms with no native call-activity adapter.
Independent Camera2/AAudio/projection observations, cold application recovery
and packaged migration/maintenance remain open. Managed storage stays disabled.
No push, device installation or release is part of this cycle.
