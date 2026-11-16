# Managed-storage macOS release/AOT qualification

Status: ordinary-entry ARM64 release compilation, packaging and selected native
runtime checks pass. This is an isolated testnet QA artifact, not a published
release, installed application, graphical runtime qualification or activation of
the new production default. No application window was opened or activated.

## What was built

The normal `lib/main.dart` entrypoint was compiled with
`XVEIL_MANAGED_STORAGE=true` in Xcode's Release configuration. Actual build-log
defines verify the managed/testnet selection and absence of the debug hook;
the native feature manifest independently verifies `testnet-seeds`. The produced
`App.framework` has the native Dart VM/isolate snapshot instruction symbols and
no JIT kernel blob. All 3,045 product inputs were checked against the committed
worktree before and after compilation. The only tracked-source substitutions
were the two existing QA bundle-name/identifier overrides.

The release PacketTunnel archive was built from those same Veil sources in the
checkout's dedicated external Cargo cache, with a live filesystem-mount and
free-space watchdog. Its bytes matched the archive supplied to Xcode. The
standalone SDK dylib came from that release build; the storage dylib was the
previously qualified release build with the persisted-padding constructor. Both
exact input and packaged hashes were retained privately.

Packaging used the existing neutral package-root and compiler-prefix helpers,
the pinned SQLite reconstruction and the ordinary release debug-record remover.
That remover verifies unchanged exported symbols for each processed Mach-O.
Frameworks, native libraries and the app were ad-hoc signed and passed deep,
strict signature verification. As with the existing ad-hoc path, the QA bundle
does not retain the provisioned VPN extension; its archive compilation above
does not qualify a working VPN.

The complete final app passed the existing artifact path scanner: **125 files,
zero source-home URIs and zero current-builder home-path occurrences**. A fresh
process loaded the required bundled native libraries without launching Flutter,
audio capture or an application window. Private symbols and build logs are not
distribution artifacts. This path check is not a universal secret scan.

## Runtime checks of the packaged libraries

Four existing serial host suites use the exact signed native libraries from the
release QA bundle, with hashes checked before and after the run:

- Managed identity file publication, reopen, refusal and ownership controls.
- Native persisted-padding creation for the storage modes.
- Ordinary three-node mixed-mode all-online startup, real peer traffic and ACKs,
  view changes, owned reclamation, lock and cold reopen.
- Two real peers, observed delivery ACK, process-group SIGKILL and a fresh
  process restoring stored ratchet roots/floors and continuing messaging in each
  of the hidden, encrypted and unencrypted modes.

**15 tests pass, zero skips.** These run through the Flutter test host with
release native libraries; they are not a claim that the graphical Dart AOT app
was executed. Existing controls and adapter boundaries remain those of the
[mixed-node report](../mixed-native-session-2026-11-16/README.md) and
[ratchet crash report](../native-ratchet-first-root-2026-11-16/README.md).
Owned apps/build/test processes are gone; only the user's original app remains.
Six dead native-runtime directories were deleted only after matching this run's
creation interval and an already removed synthetic crash-fixture endpoint root.

## Excluded attempts and remaining work

The first private command omitted the native testnet override, so it was stopped
and excluded. A raw build also initially retained compiler/linker source paths:
the shortened QA command had omitted normal packaging steps. Applying the
existing prefix maps, neutral package roots and debug-record removal produced
the clean result above. These setup failures are not credited as product defects
or as qualified release artifacts. No binary-string patching was used.

The earlier signed debug QA artifact was retained unchanged, and its generated
debug configuration was restored. Packaged custom-source compaction cold
readback still awaits an agreed graphical test slot. Physical Android/OEM and
actual OS-vault qualification, other target/architecture packaging and remaining
supported-operation/platform checks are separate. Production managed storage
remains disabled; the requested encrypted default has not yet been activated.
No push, tag, installation or release was performed.
