# Release CI qualification, 2026-11-17

## Failures observed in the first full runs

The initial runs were xVeil `44107446328`, Veil `44107452525` and hidden-volume
`44107458443`. They failed; skipped/cancelled downstream work is not qualified.

xVeil reported 499 failed groups across 76 files. Most require the native SDK
or storage library, which the checks job never built. Four group-service tests
also failed at native availability; child storage processes could exit before
their command pipe became usable. These are not 499 independent product bugs.
Separate source/widget/camera failures require their own fixes below.

## Dependency corrections

- Veil `78b87401` updates libz-sys to 1.1.33 for RUSTSEC-2026-0544. The graph
  reaches zlib through RocksDB; no application-specific exploit was reproduced.
  The chrono RUSTSEC-2026-0543 exception covers an unmaintained dependency with
  no patched release, following existing maintenance policy. Actual security
  vulnerabilities are not ignored.
- Veil `2e9f5c49` updates vendored quinn-proto to 0.11.19 and quinn-udp to
  0.5.16 for RUSTSEC-2026-0523, -0524 and -0538. Verified registry archives
  were merged with the existing expiration, pacing, receive timestamp and
  Apple batching changes. The Windows dependency pin is preserved.
  Three old protocol regression cases fail assertions; the truncated-datagram
  nonblocking case also fails on the old implementation. Existing packet
  capacity guards mean the worst upstream OOM claim is not reproduced here.
- The final Quinn checks pass **336 protocol tests**, **3 UDP tests**, and
  **21 wrapper tests with 3 ignored**. The wrapper uses both local path forks;
  an earlier probe selecting a registry UDP dependency is not qualified.
  The second UDP payload control now uses a bounded blocking receive because
  send completion does not guarantee both loopback datagrams are queued. It
  is not a second independent baseline reproduction of the spin.
- Workspace audit reports zero vulnerabilities and zero warnings against a
  clean RustSec database commit `233155b4025b854c68a4b199c0e32d7fd53291a2`.
  A separate gate inventories all four local registry path overrides, because
  the workspace lock alone does not cover those registry bases. Current bases
  pass; old bases fail with the three Quinn advisories. Six driver tests and
  provenance checks pass. This inventory is advisory-only, not a replacement
  build dependency graph or a claim that fork bytes equal registry bytes.
- hidden-volume `616a172` corrects the public API snapshot and extractor
  omission of factory constructors; 18 extractor checks pass. `586eabb` adds
  async explicit-padding creation through the shared implementation, retaining
  the legacy default. **35 unit and 3 padding checks pass**, including cold
  reopen. Builds use a separate external target with mount monitoring.

Veil run `44123443333` passed workspace/vendor auditing but rejected the
independent fuzz lock at its locked metadata gate: its two path-package version
entries were still old. Veil `f4c7895b` updates only those two entries. Locked
offline metadata resolves exactly the two current local forks, and a separate
fuzz-lock audit reports zero vulnerabilities/warnings. No runtime source or
production dependency graph changes in this follow-up.

New full dependency runs: Veil `44126741124`, hidden-volume `44123443650`.
Application source CI `44126361318` tests xVeil `5b06427c`; the later fuzz-only
pointer update does not change application or SDK runtime inputs. Completion
of these jobs must be checked before qualification is claimed.

## Application and test preparation

- The chat loading scaffold now exposes RootedBackButton, including entry with
  an empty navigation stack. The existing route invariant failed on the base.
  Two additional widget cases exercise the actual cold chat during loading and
  identity-read failure. Removing the leading produces two assertion failures;
  the restored implementation returns to home in both cases.
- An internal compaction error was split across lines, so the UI prose guard
  misclassified it. Its internal error tag is now explicit; no untranslated
  user-facing sentence was added or silently exempted.
- Resend source coverage follows the owned retry helper. The secure-screen
  fixture sends the actual session-bound frame envelope. The Windows builder
  fixture creates a source-current producer record, and separately verifies
  refusal of an unverified DLL; production provenance admission is retained.
- Group screen coverage follows camera retirement through its drain helper
  and checks the post-drain epoch/engine predicate before screen creation.
- The Android camera denial test injects permission admission, matching the
  existing group-controller boundary. Network ownership tests inject the
  platform activity port, so Linux does not silently substitute its unsupported
  platform response for Android behavior. Production permission defaults remain.
- The wipe phrase test observes destructive-operation admission, including a
  near-match refusal, independently of model/filesystem timing. The existing
  real wipe/report tests remain. Every folder-panel fixture installs mock
  preferences before its first read; preference persistence runs outside the
  widget clock, avoiding an unanswered prior host-plugin operation.
- Both CI and release checks build fresh optimized SDK/HV libraries in separate
  targets, load them and check required entrypoints before exporting their
  absolute paths to Flutter. No prebuilt library or presence-only admission
  substitutes for this preparation. These test libraries have no compiled-in
  seeds and permit explicitly configured low-difficulty fixtures; they are not
  published application libraries. Two helper-driver tests cover successful
  load plus build, absent-output and missing-entrypoint failures.

Full Linux execution of the revised preparation and all Flutter tests is still
required. Small fixture/control checks do not qualify Linux runtime behavior.
The final selected Flutter run passes **425 tests, zero skips**, covering the
changed UI, direct/group camera and screen paths, contact feedback, wipe and
folder panel. The analyzer reports no issues. The two native-preparation driver
tests pass; workflow YAML, tool pins, documentation checks and diff whitespace
checks pass separately. Interrupted stuck fixture runs and the temporary
missing-import compilation error are not counted as product regressions or
qualification passes.
No GUI activation, user input, phone installation or seed changes were made.
The original camera, contact and handover complaints retain their own status.
