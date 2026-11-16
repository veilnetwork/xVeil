# Windows Release/AOT storage package qualification

This records a separate Windows x64 QA package of the application at
`748401b7`, with managed storage explicitly enabled for the QA build. The
production flag remains disabled. The package has its own executable/product,
application-data namespace and Windows notification registration. No installed
user application, container or physical phone was opened or replaced.

## Artifact evidence

- **4,255** staged source/test inputs match their recorded hashes before and
  after compilation. Three Windows files differ only in QA branding. Native
  component source closures are checked separately; the subsequent six-file
  Dart notification update leaves all native sources unchanged.
- The actual Flutter SDK is pinned to 3.44.0 and framework revision
  `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`. Locked offline dependency setup
  succeeds. Package/SDK roots are neutral aliases, not home-directory paths.
- `lib/main.dart` is built with `--release`, testnet and managed storage enabled.
  No debug hook or release-log define is enabled. The actual `data/app.so` is an
  ELF64 x86-64 AOT snapshot; it is not a debug kernel renamed as AOT.
- Veil and Whisper are fresh Release components, with hashes matching their
  source-qualified producer results. The media DLL matches its release digest,
  published provenance and the current media source digest. The hidden-volume
  DLL matches the earlier [Windows native/AOT qualification](../managed-storage-windows-padding-ffi-2026-11-16/README.md).
  Its new persisted-padding constructor is present in the actual package and
  reports the expected generated-binding checksum, **7392**.
- The unmodified Windows VPN staging script builds the Release helper and
  includes the official locked Wintun DLL and license. Required Visual C++
  runtime files are copied from the reviewed compiler's x64 redistributable,
  individually checked by PE machine and SHA, as in the release workflow.
- The final architecture/dependency check passes over **24 PE binaries**.
  Actual loader checks load/free **21 DLLs**, including core, storage, media,
  speech and VPN. The unused Java bridge does not load without a JVM and is
  recorded separately; no other packaged PE imports it. It is not credited as
  a successful loader check.
- All **45** archive member hashes match the qualified Windows directory after
  download. AOT/home-path checks and the primary CI artifact privacy scanner
  pass over the complete package.

The older shell substring scan reports one apparent match in the core DLL.
It is independently attributed to the boundary between two adjacent 16-byte
compiler fragments of existing public configuration-field strings. The short
operator literal spans that boundary; it is not an account/path stored in the
artifact. The primary CI scanner already distinguishes such matches inside
identifier runs. No artifact byte, configuration field, private pattern list or
scanner policy was changed to obtain the clean result. Raw matches and operator
patterns remain private.

## Preparation corrections

The earlier retained core DLL was Debug, so it was not reused as Release
proof. Native build preparation first encountered the Windows tracker path
limit and then inherited GNU C++ options under the MSVC driver. A shorter owned
Cargo target and the repository builder's scoped clang-cl/remap policy resolved
those setup errors; failed attempts are excluded.

The standalone Python installation is isolated and does not import adjacent
scripts automatically. Only the explicitly verified helper directory was added
for the AOT-root helper; no global Python settings were changed. Python's build
orchestrator also needed case-normalized environment keys: retaining both `Path`
and `PATH` selected an account Cargo shim in a child PowerShell. The corrected
stand explicitly witnesses the resolved real Cargo executable before staging.

The first completed compiler output lacked the release workflow's separate CRT
copy step. It failed the package guard, was not declared usable, and was then
completed with the same reviewed redist selection. No feature or check was
removed to make packaging pass.

## Scope and limits

No application GUI, tray registration, microphone/camera capture, input
injection or focus operation was performed. These are compilation, artifact and
loader checks. They do not prove ordinary Windows onboarding, cold UI unlock,
biometric entry, a displayed toast, network handshake or camera transmission.
Previous debug UI/native storage qualifications retain their original scope.

The following [notification startup correction](../windows-incoming-call-toast-2026-11-16/README.md)
was found after this baseline package froze. It is tested separately and is not
retroactively claimed to be inside the `748401b7` AOT snapshot. No release,
production-default activation, push or tag is performed by this qualification.

## Updated package with the startup correction

A second source-frozen build at `eaf17f77` includes the guarded-notification
startup fix and its new fixture: **4,256 inputs** verified before/after. It
passes the same architecture/runtime, 21-DLL loader and home-path checks. The
new archive has the same 45 members; comparison with the baseline finds only
`data/app.so` changed. Its actual ELF64 AOT digest differs, while every native
component retains its independently qualified bytes.

All member digests match after download. The primary CI privacy scanner checks
both retained archives, **90 members**, and reports no forbidden data. The
unchanged core retains the separately attributed compiler-fragment substring
false positive described above. Both archives remain private QA artifacts.

The packaged Release core/storage DLLs also pass the separate
[headless sovereign-pair checks](../windows-native-sovereign-pair-2026-11-16/README.md).
That functional check uses JIT services and synthetic stores; it does not turn
this package qualification into an ordinary AOT UI/biometric/camera test.
