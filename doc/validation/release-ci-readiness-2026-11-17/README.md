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

## Versioned release candidates

The complete hidden-volume run `44123443650` subsequently passed all 24 jobs.
Its first attempt had two macOS jobs cancelled before any steps: GitHub reported
that no hosted runner was acquired and noted arm64 capacity constraints. The
retry is qualified; the original cancellations are not passes.

Candidate versions are Veil **0.11.53** (`6f54938c`), hidden-volume **2.8.0**
(`16871fe`, followed by the model review `8f8fc35`) and xVeil **0.13.102+121**.
hidden-volume's minor bump follows its
public-API addition policy. Matching in-repository constraints, locked metadata,
format documentation and the API snapshot pass. The format remains generation 3.
The 53 Veil manifests and the 53/46 owned entries in the main/fuzz locks change
only package versions; normalized lock comparison preserves every other field.

Final dependency source CI runs are Veil `44129668207` and hidden-volume
`44130909593`. The prior Veil run passed hygiene before the final-version run
superseded it. A new application run must use the versioned pointers; the older
`44126361318` run is superseded rather than counted as a complete qualification.
Final tags, dependency releases, application packages and seed deployment are
not created by this preparation.

The 2.8 metadata run `44129254979` rejected the threat-model currency marker in
Linux stable/beta and all-features tests. The three completed logs name only
that failing case: the documents still claimed v2.7.x. Both models were reviewed
for persisted padding, known-key proof and worker-local prepared ownership,
then updated. They now state that None does not obscure file growth, visible
host catalogs are outside single-container deniability, and the known-key proof
still uses an exclusive read/write open without a freshness guarantee.
All seven existing documentation agreement tests pass on the actual Rust core;
144 source/config/model inputs retain their hashes during the mount-monitored
run. No guard was weakened. The old run was superseded after the failure was
identified. `16871fe..8f8fc35` changes exactly the two model documents, so the
application source CI `44130170796` on xVeil `3cd2473e` retains identical runtime
SDK/HV inputs; tagged artifact checks still run on the final pointer.

The application version smoke passes 43 selected tests and the analyzer remains
clean. All seven published engine binaries and producer records also verify
against the versioned checkout's unchanged native source digest. These checks
do not replace the final source CI and tagged artifact gates.

The final hidden-volume source run `44130909593` passes all **24 jobs** after
retrying four macOS jobs which never acquired a hosted runner. Their original
cancellations are not counted as passes. A separate ordinary macOS ARM64 AOT
package now passes source/native/ABI/signature/privacy checks without opening
the application; [qualification and limits](../macos-release-candidate-2026-11-17/README.md).

## Storage tag and artifact pipeline

After the complete 24-job source gate, hidden-volume main was fast-forwarded
to the tested `8f8fc35103a2457f53a2bfb042b3fa39ff70b6a6`. The unsigned annotated
tag `v2.8.0` names that exact commit; its tagger uses the project pseudonym and
the allowed zeroil email. No protection setting or existing tag was changed.
The release (`44137568737`), tagged CI (`44137568992`) and Flutter native-build
(`44137568864`) workflows started. This records a pushed tag and started builds,
not verified published assets.

Before tagging, the refreshed audit over all reachable refs, paths, commit/tag
metadata and text objects passed in all three repositories with the private
literal/regex rules. Git binary objects are excluded from that text audit and
require separate artifact checks, as performed for the private macOS package.
Unreachable objects and reflogs are not garbage-collected, following the owner's
explicit instruction to defer that cleanup.

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

## Full native-enabled Linux run: remaining fixture failures

Application run `44130170796` completes with five successful jobs and one failed
test job. The analyzer, real optimized native preparation, build support,
Windows audio helper and macOS packaging pass. The native-enabled Flutter
suite reports 116 failed cases across 29 files; these are not 116 independent
product defects. The following fixture causes were identified:

- Sixteen subprocess launch sites forced macOS `/private/tmp/` on Linux.
  Writers validate their temporary root before opening any storage, so missing
  roots terminate them before their crash gates. Lease helpers then report a
  broken command pipe. Subprocesses now retain `/private/tmp/` on macOS and use
  the host system temporary directory elsewhere. Prefix/path safety checks,
  process-group ownership and real SIGKILL boundaries remain unchanged.
- The beneath-open and sovereign identity fixtures opened the native library
  directly without registering the application loader's handle. On Linux the
  raw load is local; sender/default embedded-node calls cannot resolve it from
  the process image. Both suites now preload through the production loader;
  no production fallback or ABI guard is weakened.
- The roster erasure fixture required reading an absent OS record. Cleanup
  correctly probes presence before reading, so this expectation fails on the
  current Mac as well. The fixture now observes both presence checks and
  deletion through its injected OS port, while retaining all actual child
  removal, lock, key-zeroization and cold-recovery assertions. Both old
  assertions fail on the unmodified fixture.

Five selected native/crash files complete 23 cases. After correcting a test
import error, the two FFI suites complete another 25 cases, without skips.
All use fresh qualified SDK/HV binaries, `TMPDIR=/private/tmp/`, and no GUI.
The compilation-failed first aggregate is not a green full run.
The analyzer remains clean. A new full Linux CI is required for these changes.

The hidden-volume `v2.8.0` release pipeline completes all eight jobs, including
signing and crate publication. All 14 downloaded assets match GitHub digests;
the 12 binaries match the signed checksum manifest. Cosign verifies the exact
tagged release-workflow identity, the host CLI reports 2.8.0, both Darwin FFI
signatures verify, and local literal/regex checks pass, including the decoded
signing certificate. The separate tagged CI has macOS runner-capacity
cancellations, which are not passes. The mobile iOS job instead reports an
unsupported macOS 14 configuration before any step. A workflow-only follow-up
selects macOS 15 for that independent build; the published tag is unchanged.

## Verified dependency publication and isolated seed rollout

Veil source CI `44129668207` completes all six jobs on exact source `6f54938c`.
The immutable `v0.11.53` release run `44143181448` completes all eight jobs.
All 43 downloaded public assets match their GitHub digests; seven installer
manifest signatures authenticate the checksums and architectures of 28
binaries. The published GNU x64 update manifest verifies its expected issuer,
version, minimum version, source epoch, URL and binary digest. A corrupted
signature is independently rejected. Host CLI version and literal/regex
privacy checks pass, including UTF-16 strings. Veil is published before xVeil.

The separate testnet build `44143183166` proves the same immutable source,
isolated network features, static x64 ELF and artifact digest. Three testnet
seeds update sequentially with binary/state backups. Independent post-update
reads verify exact binaries, unchanged configurations, healthy live sessions,
zero automatic restarts and successful DHT commands. Production rollout uses
the independently verified public binary. All six production seeds subsequently
update sequentially and the independent nine-node final verification passes:
exact binary digests, unchanged configurations, healthy live sessions, zero
automatic restarts and successful DHT commands.

One production SSH transfer exceeds its deadline before replacing the binary.
A read-only observation confirms the old version is still active. The exact
owned unfinished transfer process is retired and its opened partial file is
removed, with the original binary/configuration rechecked. An HTTPS download
of the same immutable public asset completes; its locally authenticated SHA
remains mandatory before validation, backup, installation or restart. No
signature or readiness gate is relaxed. Subsequent production nodes use this
transfer path. State/binary backups remain available for rollback.

hidden-volume's macOS 15 mobile follow-up `44142298546` completes all six jobs,
including iOS, four Android ABIs and Kotlin bindings. The workflow-only change
is fast-forwarded to its main branch; the published `v2.8.0` tag and xVeil's
storage dependency remain unchanged. The downloaded native storage binary also
passes three actual managed-padding/reopen cases with the application's current
bindings. The tagged storage CI retry still has separately tracked macOS jobs.

Application source CI `44142441570` uses `2d41293d`, including all fixture fixes.
Native preparation succeeds and the complete Flutter suite is running. Its
macOS packaging job is cancelled before any step: annotations explicitly name
hosted arm64 capacity, not a test failure. A single-job retry is refused while
the aggregate remains active; retry only the cancelled/failed jobs after its
terminal result. This documentation follow-up changes no tested runtime input.

The aggregate subsequently terminates with the full Linux suite green:
**11151 tests passed, 251 skipped**. Those skips are not passes. Retrying only
the failed/cancelled jobs obtains the macOS runner, and the final source run
`44142441570` passes all six jobs. The original capacity cancellation is not
qualified. Its tested head remains `2d41293d`; subsequent root changes affect
only the qualification Markdown files, with unchanged runtime/build inputs.
Application tagging and its independent mandatory release checks follow this
source gate; a successful source run alone does not publish application assets.

The unsigned annotated application tag `v0.13.102` names the exact
`7a322d5c315835cac77a6065bc9c027a6de25318` source, with the project pseudonym
and allowed email. Its independent mandatory release run `44151584778`
passes analysis, native preparation, **11151 Flutter tests with 251 skipped**,
media provenance regressions and the AOT/privacy driver checks. Android,
Linux and Windows packaging has started; the node-connect helper passes.
Neither these source checks nor the pushed tag qualify unpublished packages.
Downloaded package digests, signatures, embedded native bytes, privacy and
Android 14 clean-install/update checks remain pending.

Veil's tagged mobile run `44143181484` subsequently completes with eleven
successful jobs and one separately skipped guard. hidden-volume's tagged CI
`44137568992` also completes all 24 jobs after the previously noted retry.
The already published Veil release receives a short Russian introduction;
its complete original changelog is retained, identifier checks pass and the
published body is read back and compared. No artifact or tag is changed.

The exact final-main run `44151579927`, on the same `7a322d5c` source as the
release tag, now also passes all six jobs; its full Linux suite again reports
**11151 passed and 251 skipped**. Packaging continues in the tag workflow.

Android 14 qualification begins in an owned ARM64 headless emulator with a
separate loopback-only ADB server restricted against physical USB devices.
The official previous stable **0.13.101** APK installs successfully and its
installed APK digest matches the independently verified download. Loading its
actual installed storage library passes contract version 30 but correctly
fails the new binding inventory: one of the 50 current methods is missing.
This is a real negative ABI control, not a successful 0.13.102 installation.
The same emulator waits for the source/signature/media-verified normal tagged
APK before attempting update and fresh-install cases. No camera, microphone,
host window or physical phone is used. Those new-package cases and final
emulator cleanup are still pending.

The waiting guest also qualifies an actual storage-version transition:
the installed previous APK's library creates two hidden spaces, and the exact
tagged 2.8.0 Android component reads their payloads, appends distinct new rows
and retains all four payloads after process reopen. Read-only opens preserve
the container digest; wrong passwords are refused. This component check does
not substitute for the new application APK or its installation.
[Operations, provenance and limits](../android-storage-version-transition-2026-11-17/README.md).

All nine desktop archives are now available from the same tagged Actions run:
normal/debug Linux x64 and ARM64, Linux x64 musl, and normal/debug Windows x64
and ARM64. Independent downloads match the Actions archive digests. Checks of
decompressed payloads and archive metadata pass the local literal/regex policy,
including UTF-16 strings and source-home URIs. Packaged media bytes match the
current source-verified engine pins. The four diagnostic snapshots contain the
enabled-report markers and omit the raw log filename; normal snapshots omit
the enabled marker. Native architectures and the normal SDK/storage exports
also pass. These observations do not qualify the still-building Android APKs
or establish that future published assets have identical bytes.

The actual packaged Linux x64 SDK and storage libraries also load on a Linux
x64 host with **glibc 2.39**. All 50 storage checksum calls, contract version 30
and the SDK contract hash match. No application or node is started, no container
is opened and no service is changed. The owned temporary directory is removed
before the probe exits. This control does not establish runtime compatibility
with every older glibc or qualify Windows 10 camera behavior. Windows archive
checks on the Mac are explicitly static, not Windows execution.

An initial extra-desktop checker invocation precedes one unfinished download
and fails for missing input metadata. It is not a package failure or a pass.
After all five transfers complete, the full checker passes all five extra
archives without relaxing a guard. The complete release and Android install
qualification remain pending.
