# Rejected circuit builds release origin state — 23 October 2026

Source correction: Veil **`471618ef`**, parent **`7e15b372`**.

## Reproduced defect

Both `NodeServices::open_data_circuit` and `build_onion_circuit_once` allocate an
origin-table entry before handing a `CircuitBuild` to the first-hop session.
When local admission returned `Full`, `Closed` or `Missing`, the original code
retained that entry. The data path removed its return sink twice but never
removed its origin entry. No build had been admitted to the transport.

The regression uses real offline node services, a signed relay-directory entry
and a real session outbox. It first admits one data path and retains its origin
and return receiver. It then fills, closes or unregisters the outbox and checks
the **actual admission error**, attempts **257 rejected builds** (the real
256-entry origin cap plus one), restores admission and immediately tries again.
There is no expiry advance, wait for GC or increased resource limit.

On the parent, all three new tests fail with a filled outbox:

| Build kind | Origin entries before → after rejected builds | New build after draining |
| --- | --- | --- |
| Data | 1 → 256 | Rejected |
| Permanent onion service | 1 → 256 | Rejected |
| Ephemeral reply | 1 → 256 | Admitted through existing reply eviction; stale state remains |

The reply case is a retained-state defect; the observed table starvation in
this fixture applies to the persistent data/service cases. It must not be
reported as the same recovery failure for all three kinds.

## Correction

If the first-hop queue rejects the build, its exact newly allocated origin entry
is removed. The data path also closes the newly allocated return sink once.
An unadmitted build has no remote path to tear down, so rollback does not enqueue
another frame into the unavailable outbox. The normal `close_data_circuit` and
`retire_data_circuit` policies for admitted/shared paths are unchanged.

Both rejection diagnostics now name `Full`, `Closed` or `Missing` instead of
labeling every refusal as an absent live session. These new diagnostic strings
contain no node address, cookie, key, payload or file path. A separate warning
now names an actually full data-origin table with only its cap and sampled
length; previously this branch returned the generic `NoRelays` without that
reason. Existing logging elsewhere is outside this correction's privacy scope.

## Verification

All **nine cases** pass: three build kinds × three real local admission errors.
After each 257-attempt burst, the origin count stays **1 → 1**; after recovery
it becomes **2**, exactly one new `CircuitBuild` is admitted, and the original
origin entry and return receiver remain intact. Return-sink counts stay constant
after rejection and increase only for an admitted data build.

- **23 runtime-library tests selected by the `circuit` filter** pass, including
  normal admission, path ownership, retirement and scheduled reply teardown.
- **5 origin-table tests** pass, including capacity, GC and reply lifetime rules.
- **61 anonymous-stream tests** pass, including retry backoff, warm-up reuse,
  receiver binding, local backpressure and route recovery.
- All-target runtime Clippy with warnings denied and rustfmt pass.
- Production macOS/Android SDK builds pass. Their **199 C export names** match
  the compatible baseline; current-source and frozen-library hashes agree.

[summary.json](summary.json) records numeric observations and verification scope.
Raw fixture/runtime logs and build paths stay outside the repository.

## Remaining scope

This proves a local resource leak and recovery failure, including its correction.
It does **not** establish that table exhaustion caused the previous physical
stand's five `NoRelays` failures. That data-build failure path previously lacked
a specific capacity diagnostic. The observed repeated route construction and
manifest-first-byte timeout still need separate investigation.

No stand app, phone installation, relay update, physical call/file recheck,
Windows qualification, release or push was performed in this cycle. The last
physical file results remain tied to the preceding SDK commit documented in
[the cellular stand report](../cellular-provider-2026-10-22/README.md).
