# Enable the requested storage defaults in source

Status: ordinary source builds now use the three-mode profile router without a
QA opt-in. New identities default to independently owned encrypted storage;
hidden and explicitly unencrypted storage remain user choices. This is an
unreleased source change. No installed application, profile, native release,
published package or production server is changed.

## One startup policy

`managedStorageEnabled` in `lib/core/storage_features.dart` defaults to true.
Preference admission, native/profile bootstrap, early provider admission and
bootstrap-error refusal all use that same policy. The explicit compile-time
`XVEIL_MANAGED_STORAGE=false` override remains available for isolated legacy
regression controls; no runtime error automatically selects it.

The router retains the original factory for an existing hidden container.
Enabling it does not copy or compact that container, enumerate unknown hidden
spaces, convert their protection, or create a public hidden-identity directory.
The visible catalog can enumerate only the independently owned encrypted and
plaintext identities. Encryption/ratchet/network admission remains independent
of the selected local storage protection. Plaintext still carries its explicit
local-secret exposure warning and is never an unlock-error fallback.

## Evidence

Two ordinary-startup regressions fail on the previous source without the QA
flag: debug startup admits the fake storage boundary, and preference startup
bypasses an existing managed-erasure obligation. Both pass after the startup
policy changes. These are default-policy controls; they are not a claim that
published legacy-only profiles already contained managed identities.

The final frozen-source run passes **164 tests across 22 suites, zero skips**:
startup/refusal/erasure, real preference ownership, onboarding, protection
choices and scoped quick entry, actual managed facades, master creation and
selection, router ownership/retirement, cold selection, persisted padding and
selected-root native reference recovery. The run uses the exact signed native
libraries from the [qualified macOS package](../managed-storage-macos-aot-2026-11-16/README.md),
with their packaged hashes checked before and after. All 1,899 Dart/test inputs (the tracked set plus the new policy file) are
checked across the run; this is not the earlier full native/package input
manifest.
The complete current Dart-to-native checksum table also matches that storage
library.

A broader run initially found an unrelated stale test expectation: an opening
facade retired by selection was expected to return success. The same failure is
reproduced with the previous startup sources restored. The fixture now attaches
its failure observer before retirement and requires refusal, one actual resource
close, deferred replacement and refusal of a later stale reopen. Product
retirement/ownership guards are unchanged. Its corrected case passes in the
164-test run; three existing direct retirement controls pass separately.

An additional widget execution compiled with the explicit legacy opt-out passes.
Two standalone product/AOT executables, compiled from the actual policy and
protection modules, confirm default `managed=true` and explicit legacy
`managed=false`, respectively. Both retain encrypted new-identity policy and
verify `dart.vm.product=true`; dependency files confirm the intended source
modules. These are policy probes, not ordinary graphical AOT app executions.
Changed-source analysis is clean.

An initial library-selection precheck compared an unsigned/pre-packaging AOT
digest to the signed package and refused before tests. The qualified run instead
uses the actual post-packaging provenance, including both native hashes. It is
not a binary regression or a bypassed signature/provenance check.

## Release work still required

The earlier Android/macOS/Windows QA builds explicitly enabled the router; this
source change does not retroactively make those builds a test of absent build
definitions. The small AOT probes above establish that narrower policy property.
Before publication:

- Release the matching hidden-volume native API/assets and preserve dependency
  release order. The published 2.7.2 binaries lack required new entry points;
  a matching version string alone is not provenance or ABI proof.
- Build and check the ordinary final app packages with the new default and
  matching native artifacts, including artifact privacy and runtime loading.
- Repeat scoped packaged startup/cold-open/maintenance checks for fresh visible
  identities and retained hidden data. Existing platform qualifications keep
  their documented scope.

The owned test processes exit; the two temporary AOT probe executables are
removed after digest checks. The user's original Mac app remains untouched.
No graphical app activation, input automation, push, tag or release occurs.
