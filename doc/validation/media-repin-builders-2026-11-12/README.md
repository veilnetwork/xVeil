# Media rebuild and release builder qualification

Seven media targets were rebuilt from SDK `83a54e35` through the application
checkout `d00e921b`. Their native source digest is
`59d214afb4b205ed17a28c50ada8a18587d270077466d1be8a1c587ffd8dafe2`.
The source digest remains valid after the subsequent Rust build-profile fix:
that change does not modify native media sources.

| Build | Result |
| --- | --- |
| [Linux/Android workflow](https://github.com/veilnetwork/xVeil/actions/runs/43123485733) | Linux x64/arm64 and Android arm/arm64/x64 succeeded |
| [Windows workflow](https://github.com/veilnetwork/xVeil/actions/runs/43123489500) | Windows x64/arm64 succeeded |
| Release publication jobs | Both skipped: dispatch explicitly disabled publication |
| Local macOS media | Built from the same native source digest; arm64, 107 media exports and the application's symbol gate checked |

All fourteen downloaded artifact archives (seven binaries and seven provenance
records) matched GitHub's archive digests. Each binary matched its recorded SHA,
current native source digest and intended architecture. No known developer home
path was present. All seven binaries pass the application's required-symbol
check after the PE reader correction below. These are build and artifact checks,
not seven platform runtime qualifications. The verified set is published as the
immutable [`engine-2026.11.12` prerelease](https://github.com/veilnetwork/xVeil/releases/tag/engine-2026.11.12).
All fourteen release assets matched a download round trip and a separate public,
unauthenticated download. The latest application release stayed unchanged.
Android, Linux and Windows release jobs now pin this new set.

## Darwin host proc-macro failure

Two actual automatic macOS release-builder attempts failed in the PacketTunnel
Rust phase before producing an application. Rust reported E0463 for `time_macros`
or `zeroize_derive`. The retained latter library passed codesign verification,
but the native loader rejected its misaligned LINKEDIT string pool.

An isolated derive fixture reproduced the failure with the release profile,
source-path remapping and macOS 12 deployment target. The same fixture succeeds
when stripping is disabled for host build dependencies. SDK `acdf3e0d` therefore
sets `profile.release.build-override.strip = "none"`. These compiler inputs are
not shipped. The ordinary target release stripping policy remains `debuginfo`,
and application packaging still removes native debug information separately.
Cargo documents this separation in its [profile overrides reference](https://doc.rust-lang.org/cargo/reference/profiles.html#overrides).

The checked-in native regression test failed before this change and passed
after it, with no skips. It uses an isolated, locked dependency fixture with a
known triggering layout; it does not update production dependencies. Earlier
small fixtures that passed the old profile were not counted as reproductions.

A subsequent full build, including native producers from an empty Cargo cache,
found the same malformed host macro in hidden-volume before compiling its FFI.
Its profile also needs an explicit host `strip = "none"`. Storage commit
`3b8c302` adds that setting; the same isolated profile probe failed before it and
passed after it. The probe now accepts a workspace path so CI exercises both
profiles. No production dependency versions or storage format changed.

That full ordinary build subsequently completed in 596.38 seconds, including
native producers, CLI, optional wrappers, Flutter AOT, packaging and signature
verification. Its 126 artifact members (128,746,351 scanned bytes) contained zero
home paths or home source URIs; the separate known-private-data scan was clean.
However, the final SDK dylib was still rejected by dyld for misaligned LINKEDIT.
It was quarantined and is **not a usable candidate**. This extends the problem
from host macros to final Rust Mach-O outputs.

The macOS release plan now disables Rust's strip step for the target too; Apple
packaging still removes debug records before signing. The SDK's Darwin release
script and storage's Darwin publication workflow use the same approach. A new
gate loads bundled native libraries in an isolated process, both before export
and from the copied artifact before replacing any previous output. It starts no
application, recording or playback. The old gate accepted an unloadable fixture;
three native loader/export-preservation tests now pass, plus the eleven existing
build-orchestration checks. The full repeat on application `35de3e11` completed
in 488.69 seconds. All five bundled libraries (SDK, storage, media, whisper and
translation) loaded successfully, including the copied artifact. Its signature
passed; 126 members / 128,821,471 scanned bytes had zero home paths or source
home URIs. A separate known-private-data scan covered 108 unique physical files
with zero findings. The development media cache was then updated to the verified
current-source binary. No app window, container, recording or playback was opened.
This qualifies the builder; the later dependency fixes below still require final
release builds.

## ARM64 PE symbol-reader correction

The ARM64 DLL contains the required exports. On the validation host, x64 GNU
objdump cannot read it; LLVM objdump can, but prints an ordinal/RVA/name table
instead of GNU's name-pointer table. The checker accepted LLVM's successful
output and then parsed only GNU's format, incorrectly reporting no exports.

The fallback now reads rows only inside LLVM's export table. Imports and ordinary
symbols still cannot satisfy the export gate. Three format checks pass; the LLVM
case failed on the old script. The corrected gate also passed on all seven actual
CI binaries, including both Windows architectures.

The CI-built x64 Windows DLL also loaded on the available Windows 11 host with
all 107 required Dart lookups resolved. No application or audio was started by
this probe. Its temporary files were removed and the previous SDK, storage and
media DLL hashes remained unchanged. This does not qualify Windows 10 or speech
audibility.

## Dependency audit caught by source CI

SDK source CI reached its advisory gate and stopped on five Hickory advisories
and one rustix unsoundness warning. Formatting, clippy and preceding native
checks had passed; this was not treated as an infrastructure failure.

| Component | Validation | Change |
| --- | --- | --- |
| Hickory 0.26.1 | DNS bootstrap uses the resolver. The [wire-decoder allocation advisory](https://github.com/rustsec/advisory-db/blob/main/crates/hickory-proto/RUSTSEC-2026-0491.md) is relevant to parsing DNS responses; the other text-parser findings are not asserted to be reachable in this client. | Resolver, proto and net updated together to 0.26.2; proto requires prefix-trie 0.8.4. |
| rustix 1.1.4 | The [zero-length xattr buffer advisory](https://github.com/rustsec/advisory-db/blob/main/crates/rustix/RUSTSEC-2026-0486.md) is confirmed upstream. Exploitation through the application's working paths was not established. A compatible patch is available and removes the SDK audit blocker. | 1.1.6 in SDK and storage runtime locks; SDK fuzz lock updated too. |

An intermediate resolver/proto-only update failed compilation because net was
still 0.26.1. That combination was rejected. The coherent three-package 0.26.2
family passed 141 bootstrap tests (one ignored). Storage passed 753 workspace
tests (five ignored). Unrelated Windows binding and randomness dependency edges
were retained and Cargo accepted the resulting locked graphs.

SDK main, fuzz and compiler-fixture audits pass with `--deny warnings`; there are
zero vulnerabilities and zero warnings under the existing policy. No advisory
exceptions were added. Storage reports zero vulnerabilities and its pre-existing
maintenance-only basic-toml warning; that warning is not called a vulnerability.
The advisory database revision was
`fd6f39814c4d3c359fdbe223d0280dec4933f78f` (1,458 entries).

The compiler fixture now has a standalone workspace/source target and a CI
metadata-plus-audit gate. Its final fixture still reproduces E0463 under the old
release profile and passes under the corrected SDK and storage profiles. The
existing hygiene-workflow parser self-test passes with 30 steps. Standalone
vendored Quinn/tun2proxy lockfiles do not select the production dependency graph
and were not upgraded. An ignored local storage-fuzz lock was refreshed locally;
it is not presented as a tracked release defect.

## Standalone release staging

The SDK release script could build into `CARGO_TARGET_DIR` and then stage older
files from the conventional `target/` directory. A native regression builds four
tiny real Rust executables into an external directory containing spaces, leaving
stale files in the conventional location. The old script stages `stale`; the
corrected script stages runnable `fresh` binaries with valid ad-hoc signatures.

Both SDK and storage local releasers now follow the actual Cargo output path.
The storage local path also uses locked resolution and the Darwin
unstripped-link / Apple-strip / re-sign sequence already used by its publication
workflow. No CLI options or storage format changed. The staging regression is
included in the macOS native CI job.

## Privacy and remaining work

The first full Android packaging attempt built all three APKs but the artifact
privacy gate refused them before export. No failing APK was attached to a
release. Failure diagnostics now report only fixed component/ABI categories and
counts; protected strings and artifact-controlled filenames are never reflected.
Eleven scanner checks and twelve build-orchestration checks pass locally. Manual
builds can select a single platform; publication additionally requires a successful
complete scan and the full platform selection.

A real Android NDK/CMake fixture isolates a source-path mechanism in the speech
dependency: debug-enabled OpenMP embeds source labels in runtime data that
survive `llvm-strip`. Prefix remapping alone leaves two home paths in each C/C++
fixture. The actual previous workflow flags fail this test; explicit release
configuration with `-g0` yields zero after stripping. Both variants retain
`__kmpc_fork_call`, so OpenMP parallel execution has not been disabled. The speech
build uses these corrected flags and runs the fixture before compilation.
Full candidate APK qualification and attribution of any remaining categories
are still pending.

The build-only application workflow at `8d34ef73` caught another real Windows
ARM64 producer failure before any application tag: ring invokes GNU-driver
clang directly for assembly, bypassing the target's clang-cl selection. That
driver rejects the `/clang:` path-remapping option. The Windows environment now
passes macro/debug prefix maps through the frontend interface accepted by both
drivers. Path hiding is retained rather than disabled.

A real cross-host ARM64 COFF assembly fixture failed with the old flags and
passes with the new flags; its embedded `__FILE__` is remapped. The existing
narrow/wide C++ macro checks also pass on the available Windows host: four
compiler tests, zero skips. The build-entrypoint checks pass (21 tests). Full
ARM64 application packaging is being repeated; the fixture alone is not claimed
to qualify the complete bundle.

The repeated ARM64 job passed the earlier compiler failure but was cancelled at
its 60-minute job limit. Its last visible child output was locked package setup;
this does not establish which later operation stalled. The neutral builder now
flushes step labels and reports fixed phase labels, elapsed time and package-alias
counts without printing source paths. The job limit and artifact gates remain
unchanged while the build is repeated with this instrumentation.

The next versions are Veil 0.11.50, hidden-volume 2.7.1 and xVeil 0.13.97+116.
The version manifests and locked graphs pass metadata/version checks; the storage
format remains generation 3.

The ordinary Mac builder completed again with the patched dependencies in
455.34 seconds. All 2,920 tracked inputs in its captured source workspace matched
application `b039e6b4` and the clean dependency checkouts. The driver started at an
earlier application commit; the separate source comparison, rather than that
entry-time label, establishes what the child compiled. The later `2895fa33`
change affects test ACL reads only. The candidate reports 0.13.97+116, has a valid
signature and loads all five bundled native libraries. Its known-private-data
scan covers 108 physical files with zero findings. It is a local builder
qualification, not a final tagged release artifact.

The first application source CI exposed six failing Flutter checks and Windows
packaging-test failures. The release dry run now displays the child workspace's
actual commands and signing checks without executing them. The node chooser
uses safe system insets; an unused translation was removed; the certificate test
selects its specific expandable section instead of assuming there is only one.
The 28 affected Flutter tests pass locally.

Windows ACL application and verification now use explicit .NET descriptors and
the required access/owner sections, avoiding PowerShell provider processing that
failed on the restricted CI token. The actual Windows checks retain a protected
descriptor, the current owner and exactly one access rule. Five workspace tests
and twelve build tests pass on the available Windows 11 host. The repeated
GitHub Windows packaging job also passes; full source CI is still in progress.

The full reachable histories of the application, SDK and storage repositories
were scanned again before the feature-branch CI pushes: zero known private-data
findings, zero oversized objects skipped. Existing sanitized history publication
and restored branch protections were independently recorded previously. This
does not claim that GitHub's old object retention or local unreachable objects
have been garbage-collected.

Remaining release work includes qualifying the automatic application builders and completing source
CI and artifact checks. The original Windows 10 audio/video/avatar complaint is
still distinct from the available Windows 11 qualification. No new human
listening or Windows GUI confirmation is claimed here.
