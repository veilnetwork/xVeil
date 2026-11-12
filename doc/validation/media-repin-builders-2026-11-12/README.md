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
not seven platform runtime qualifications. Application engine pins have not yet
been changed and no application release was published by these runs.

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
Full automatic macOS application qualification with this fix is pending.

## ARM64 PE symbol-reader correction

The ARM64 DLL contains the required exports. On the validation host, x64 GNU
objdump cannot read it; LLVM objdump can, but prints an ordinal/RVA/name table
instead of GNU's name-pointer table. The checker accepted LLVM's successful
output and then parsed only GNU's format, incorrectly reporting no exports.

The fallback now reads rows only inside LLVM's export table. Imports and ordinary
symbols still cannot satisfy the export gate. Three format checks pass; the LLVM
case failed on the old script. The corrected gate also passed on all seven actual
CI binaries, including both Windows architectures.

## Privacy and remaining work

The full reachable histories of the application, SDK and storage repositories
were scanned again before the feature-branch CI pushes: zero known private-data
findings, zero oversized objects skipped. Existing sanitized history publication
and restored branch protections were independently recorded previously. This
does not claim that GitHub's old object retention or local unreachable objects
have been garbage-collected.

Remaining release work includes publishing and pinning the verified immutable
media set, qualifying the automatic application builders, and completing source
CI and artifact checks. The original Windows 10 audio/video/avatar complaint is
still distinct from the available Windows 11 qualification. No new human
listening or Windows GUI confirmation is claimed here.
