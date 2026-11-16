# macOS storage ABI packaging gate

## Confirmed gap

The final macOS packaging gate checked that bundled native libraries loaded,
but did not compare hidden-volume with the application's generated Dart
bindings. A loadable library missing the current storage constructor passed
that gate, although the Dart runtime would refuse it before storage use.
This is a packaging validation defect, not evidence of container corruption.

Before the change, the new negative test failed because the old gate accepted
a loadable fixture without the required FFI contract.

## Change

The gate now checks the actual bundled hidden-volume handle against the
current binding source: UniFFI contract version, every bound export and all
generated method checksums. Metadata must be literal and cover the complete
bound-method inventory. The reusable checker calls only argument-free version
and checksum functions; it never opens a container or creates an identity.

The existing publication path applies this check again to the copied candidate
before replacing the previous artifact. An incompatible candidate therefore
cannot replace that artifact. Loading stays in a separate process.

## Verification

- Four metadata checks pass, including omitted and nonliteral checksum rejection.
- Eight Darwin-loader checks pass: a matching synthetic contract is accepted;
  missing constructor/checksum, wrong version/checksum and unloadable components
  are rejected. Failed copied-candidate checks preserve the previous artifact.
- The related build suite has 12 passing cases and one skipped case.
- A retained, previously qualified native storage component passes all 50 method
  checksums. Its recorded bundled hash matches and its bytes remain unchanged.
- An existing installed component loads but lacks exports required by the new
  bindings, and is rejected. Its bytes remain unchanged. This does not imply
  that the installed application's own older bindings are incompatible.

The small compiled contract fixtures prove validation behavior, not storage
functionality. The real-library controls complement those fixtures. No graphical
application was launched, no window was activated and no user container was
opened for these checks.

## Limits

This integration covers final macOS packaging. It does not qualify all platforms
or finish release preparation. ABI compatibility does not prove implementation
provenance; source digests, native hashes, signatures and artifact privacy remain
separate checks. Matching dependency releases and final application packages are
still required before publication.
