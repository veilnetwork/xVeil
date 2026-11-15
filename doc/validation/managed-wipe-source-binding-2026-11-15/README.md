# Whole-profile wipe uses the router's exact source binding

Managed-storage defaults remain **OFF**. This closes an orchestration-boundary
check exposed while qualifying the
[custom-source compaction path](../custom-source-compaction-binding-2026-11-15/README.md).
It is not an attribution of a reported user corruption or a claim that the new
storage modes are ready for default activation.

## Confirmed gap

`ManagedProfileWipe` previously required its retained preference source and
router to belong to the same directory, but did not compare their container
leaves. Two valid container paths in that directory could therefore be composed
into one wipe owner. The native erasure actor honors the explicit preference
source path: directory equality alone does not establish that it is the source
bound to the router. A mismatched composition could target the wrong sibling
file and leave the router's hidden container behind.

Normal main already constructs its preference source and router from the same
configured path. The gap is a missing boundary invariant, not evidence that
normal bootstrap currently supplies inconsistent paths. The router's opaque
injected factory remains a caller-owned capability; this check verifies its
explicit source binding rather than claiming to inspect the factory.

The wipe constructor now validates the preference source's absolute profile-local
path against the router's immutable source leaf before admitting a wipe owner.
Mismatch becomes the existing bounded `ManagedProfileWipeFailure`. It cannot
start resource retirement, preference release, OS-record reads, native intent
publication or deletion. Existing directory identity/ownership, preference-source
identity and storage-retirement checks remain necessary. Recovery scopes,
filesystem durability and cryptographic authorization are unchanged.

## Evidence

The new native integration fixture uses an actual hidden container, its same-key
byte-copy neighbor, and independent encrypted/plain managed identities. It
composes real preference-file ownership, router ownership, the native erasure
worker and fresh-profile handoff. OS-secret and platform-resource ports are
explicit in-memory fixtures, not physical Keystore/Keychain or Android services.

Before the change, both mismatched bindings incorrectly constructed a wipe owner;
the two correctly bound controls already completed successfully. After the change,
all four pass: default and Unicode/percent/hash/question-mark source names reject
a different same-directory router binding before side effects. File inventory,
catalog, OS-read and resource-admission assertions remain intact. Correctly bound
full wipes remove the selected container and both managed identities, preserve
the neighbor byte-for-byte and admit a fresh empty profile.

Final sequential regression qualification: **106 passed, zero skipped**, six
suites covering the new binding controls, full-profile lifecycle, guards, cold
recovery, auxiliary erasure and application requests. Full application/new-test
static analysis reports no issues. The selected native library
is unchanged and verified against its prior qualified hash; no Rust rebuild or
native source edit is part of this cycle.

All checks run in background processes with `TMPDIR=/private/tmp/`; no application
window is launched or activated, and no input is injected. Private paths,
credentials, identities and raw artifacts stay outside the repository. No user
container is opened or modified. No push or release.

Native Windows source-directory durability, physical OEM/platform checks,
packaged custom-source post-compaction cold readback, the complete destructive/
credential/model matrix, native pins and release AOT remain open activation gates.
