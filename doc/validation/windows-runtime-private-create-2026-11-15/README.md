# Windows runtime directory creation

Production managed storage remains disabled. This cycle fixes a Windows runtime
boundary used by both ordinary and managed-storage boot; it does not qualify
Windows 10 camera capture or incoming-call notifications.

## Reproduced boundary failure

The isolated Windows 11 application created its runtime below a temporary base.
Its directory and diagnostic `soak.key` each inherited two untrusted allow rules,
including replacement/write rights. The control key was not read by another
account in this test; remote exploitation is not claimed. The existing Windows
branch skipped permission checks and assumed profile ancestry was sufficient.

A separate Flutter-free AOT probe reproduced the mechanism through the real
`claimRuntimeDirUnder` and `RuntimeDirLease.acquire` functions. PowerShell created
independent disposable ACL fixtures below application data: stable bases with
inheritable read access, and unsafe bases with inheritable modification access.
All eight original cases failed before the fix: positive cases inherited shared
access, and negative cases accepted unsafe bases or ancestors.

## Correction

- Create every Windows runtime/provisioning child atomically with the existing
  explicit-owner, protected-DACL native helper. An occupied name is never adopted.
- Resolve the base once and operate on the canonical path. Verify its existing
  ancestry before creating missing parents. Require stable ancestry and private,
  current-user-owned runtime children; no permissive fallback or post-secret ACL
  tightening is used.
- Preserve nonempty operator-selected bases with stable read-only sharing. Keep
  their data, ACLs and occupied children unchanged.
- Verify Windows privacy in `restrictRuntimeDir` instead of returning immediately.
  An already shared runtime directory is refused rather than silently tightened.
- Use application-data ancestry for the ordinary Windows default. Windows uses
  authenticated loopback TCP and does not need the short POSIX Temp socket path.
  Explicit overrides remain supported when they satisfy the actual ACL policy.

The first candidate exposed a fresh-process collision edge: an occupied child
was reported as an I/O failure. The Win32 package lazily resolves `GetLastError`;
resolve it before `CreateDirectoryW` so the first symbol lookup cannot overwrite
the error being inspected. The occupied-name regression then passed without
adopting or changing that directory.

`path` 1.9.1 is now a direct dependency for platform-aware normalization; its
already pinned version and artifact digest did not change.

## Verification

The final [Windows fixture](../../../scripts/test-windows-runtime-directories.ps1)
checks the selected executable SHA-256 and invokes the
[committed probe](../../../test/native/probes/windows_runtime_directory_probe.dart)
in separate processes. Nine cases pass, with no timing thresholds:

1. Claim and lease below stable nonempty read-shared bases.
2. Refusal of unsafe bases for both entrypoints.
3. Claim and lease with missing nested parents.
4. Refusal before creating nested paths below unsafe ancestry.
5. Refusal of an already shared runtime, retaining its original ACL.

Positive cases check immediate child ownership/privacy, inherited privacy of a
synthetic capability, occupied-child preservation, parent-data preservation and
lease release. The original eight failures and final nine successes are counted
separately; the ninth case was added during validation.

The Windows driver checked source manifests before and after build/execution,
used an isolated Dart CLI output, and verified the copied Veil, hidden-volume and
ordinary SQLite DLL digests. The regular `lib/main.dart` Windows debug app was
then rebuilt with the same native provenance and the actual new runtime default.
An independent native ACL observer found zero untrusted allow rules on the
runtime directory and diagnostic key while locked, and also on the node's
control-channel sidecars and device secret after a real node boot.

Host verification: 77 checks in seven serial Flutter suites, zero skips; analysis
of the four changed Dart implementation/probe files is clean. These cover runtime
permissions, ownership, leases, heartbeat/sweep, provisioning and endpoint plans.
The Windows native probe additionally verifies the DACL behavior; POSIX mode
checks alone are not credited as Windows security coverage.

Raw paths, SIDs, VM service endpoints, control tokens, synthetic credentials and
recovery certificates remain outside the repository. No push or release was made.

The owned app process was stopped after locking. The five owned scheduled tasks
were removed after verifying process exit. Synthetic exported certificates were
removed only after exact path/name and digest checks; the obsolete rollback
bundle was removed, retaining the current QA bundle for further qualification.
