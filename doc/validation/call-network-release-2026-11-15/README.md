# Retryable call network resource release

## Confirmed defects

Three Dart behavior tests failed on the previous implementation: a failed
release could not be retried after its owner left, a still-active reply was
ignored, and cleanup was skipped after an acquire reply was lost despite an
actual modeled native grant. Five existing ownership/queue tests passed.

Code inspection found the matching native defect: Android discarded both
WifiLock references even when release threw, without checking that the locks
were no longer held. This is a resource-failure path, not attribution of a
reported voice pause, network handover delay or battery observation.

## Change

Dart tracks desired call owners separately from unconfirmed platform cleanup.
Failed or rejected acquisition can require cleanup even without a desired owner.
Release stays non-throwing for ordinary media teardown; only an inactive reply
clears cleanup debt. A retry reaches the port again. A newer live owner prevents
an old owner's late release from deactivating its resource.

Android retains each concrete native lock until release and its isHeld readback
confirm absence. A failure on one lock does not skip the other. Partial or
uncertain sets are not overwritten by a replacement acquisition. Known native
owners are retained independently of Activity references. Retired owners can
retry cleanup when a later engine/channel interaction occurs; active owners are
excluded from that sweep.

The Activity binds each manager to its Flutter engine. Engine cleanup and
Activity destruction retire that manager permanently; stale channel callbacks
cannot acquire or release the successor's locks. Native factories retain only
application context and native locks, not the destroyed Activity. Existing API
level mode selection is preserved. The macOS port's inactive-result convention
matches the Dart protocol and its implementation is unchanged.

## Validation

- 449 checks passed across 28 serial Flutter suites, including direct/group
  media, application teardown, capture resources, screen locks and native
  profile-wipe fixtures. The eight network ownership cases passed again after
  a test-only brace cleanup. Analysis of both changed Dart files is clean.
- The actual production Kotlin owner passed 12 host scenarios through injectable
  native lock ports: one/two locks, partial acquisition, lost grant reply,
  release refusal, false completion, unavailable observations, retry, retired
  ownership, successor isolation and retired-owner cleanup sweeps.
- Three private-copy mutants failed behaviorally: forgetting a lock on release
  failure, omitting release readback, and permitting retired reacquisition.
  All mutant sources compiled; compilation failure was not counted as rejection.
- All 17 actual application Kotlin sources and current SDK Android sources and
  resources compiled into an isolated debug APK. Source hashes matched around
  compilation. The harness has no Flutter app assets and was not installed;
  APK compilation does not qualify runtime behavior.
- Source inventories and four pinned native-library hashes matched around the
  Flutter suites. No native media engine or release artifact was rebuilt.

## Remaining boundary

The lock-port tests model OS facts, not physical Wi-Fi power behavior. The native
inventory is process-local and is not an erasure receipt. Composing its native
admission/verification with whole-profile retirement, independent media
observations, cold application recovery and packaged qualification remains open.
Neither the Dart owner set nor the native isActive presentation query proves
absence of all resources. Managed storage remains disabled. There is no push or
release in this cycle.
