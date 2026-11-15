# Windows preference creation and cold read

This follows the [Windows worker bootstrap qualification](../managed-storage-windows-bootstrap-2026-11-15/README.md).
It closes a second native Windows preference failure. It does not qualify
Windows identity onboarding, encryption modes or the Windows 10 call/video
complaints. Managed storage remains disabled in production defaults.

## Confirmed defect

A real AOT CLI bundle invoked `ManagedProfilePreferencesFile` on Windows 11,
without application controllers, a Flutter engine or mocked filesystem I/O.
The profile parent was current-user owned and stable, with inherited read
access for other accounts, which is allowed for a profile ancestor.

The old writer reported success for the first preference write. The temporary
and final file inherited the parent's read grants: `file_private=false`.
The very next worker read rejected that file as unsafe, returning
`ManagedWorkerFailure(invalid)`. The completed native build exited zero; the
actual round-trip executable exited one on the reproduced failure. This was a
payload-write defect, separate from the prior empty-cache DLL lookup failure.

The common synchronous and asynchronous preference writers skipped all Windows
permission work. The managed reader correctly required private leaves; removing
that reader check would hide the failure and retain the disclosure.

## Final correction

Both writers now reserve a new empty temporary file with an explicit protected
Windows DACL, granting access only to the current user and the existing trusted
SYSTEM/Administrators authorities. `CREATE_NEW` refuses an existing entry; the
DACL and non-inheritable handle are supplied in `SECURITY_ATTRIBUTES` at file
creation, as specified by [CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
Ownership and privacy are checked through the existing handle-bound native
facts before payload writing and after publication. An unsupported or refused
operation returns failure; there is no permissive fallback.

A stale temporary is removed only after confirming it is a stable regular
leaf owned by the current user. The next payload uses a fresh private object.
The containing directory's permissions are unchanged. Existing directory/file
entries cannot be silently adopted by the private-file creator.

An intermediate candidate that merely tightened the DACL of the existing
empty temporary was rejected by a new deterministic check. A reader opened on
a stale inherited-read temporary could see the next payload through its old
handle, even when the overall write subsequently returned failure. Changing
permissions does not revoke that handle. That candidate is not part of the
final implementation.

The final check holds such a reader across a write. On this host Windows denies
deletion while the handle is open, so the write truthfully returns false before
modifying its bytes. The reader still sees only the stale synthetic contents.
After closing the reader, a retry succeeds. No timer or scheduling threshold
is used to establish this boundary.

## Independent regression fixture

[`test-windows-profile-preferences.ps1`](../../../scripts/test-windows-profile-preferences.ps1)
uses the OS ACL API, independently of the application helper, to create a
GUID-named disposable profile below application-data ancestry. It explicitly
sets the current owner and read-only inheritable Everyone grants. A temporary
directory whose ancestors permit replacement is correctly refused by managed
admission; the fixture does not weaken that policy to accommodate Temp ACLs.

The helper verifies the selected probe executable's SHA-256 and runs the
[`profile_preferences_roundtrip_probe.dart`](../../../test/native/probes/profile_preferences_roundtrip_probe.dart)
entrypoint in two separate processes:

- Exercise: first write/read, worker close/reopen, stale-reader isolation,
  successful replacement after reader release, and both common sync/async
  writers with private files and exact synthetic contents.
- Cold verify: a new process reads the replacement through a fresh worker and
  confirms that its leaf is still private.

Both phases confirm that the read-shared parent is the same object and retains
its original policy. Further native negatives refuse an existing directory or
file; a successful empty reservation is private immediately and an attempted
second reservation neither replaces it nor changes its length.

A private `bin/` entrypoint forwarded to the committed probe for `dart build
cli`, retaining ordinary SQLite native assets. With a reviewed probe bundle:

```powershell
.\scripts\test-windows-profile-preferences.ps1 `
  -ProbeExecutable <reviewed-bundle>\bin\qa_storage_preferences_probe.exe `
  -Sha256 <reviewed-executable-sha256>
```

The final actual Windows run passed both phases. The source manifest verified
3,035 effective inputs before/after the build and execution, including the
changed implementation and regression sources. Selected bundle libraries
matched the already qualified fresh Veil build, published hidden-volume 2.7.2,
and sqlite3 3.5.2's pinned ordinary Windows SQLite asset. Their hashes are in
the preceding bootstrap report. This cycle did not rebuild or alter Rust.

## Checks, cleanup and remaining scope

The final serial Flutter run passed **58 checks across six suites, no skips**:
preference store, owned-file routing, preference lifetime, Windows and POSIX
filesystem policy, and the Flutter-free headless import boundary. Analysis of
the two changed implementation files and the native probe found no issues.
The actual Windows AOT probe supplies platform evidence that these macOS-hosted
regressions alone cannot provide.

The temporary ACL fixtures were removed by the helper. Owned probe processes
and the one scheduled task were checked terminal, then the task and obsolete
probe output bundle were removed. No application instance, real container or
clipboard was used during this cycle. Private logs and OS account identifiers
are excluded from this report. No push or release was performed.

Still unqualified: normal Windows UI identity creation/open/switch/lock and
all three identity-mode payload lifecycles, Android packaging, application
release AOT, and production activation. Previously existing broad-permission
preference files are still subject to managed admission; activation must
explicitly qualify their migration rather than weaken the reader's policy.
The private storage-only application bundle from the preceding cycle predates
this change and must be rebuilt for the next UI qualification.
