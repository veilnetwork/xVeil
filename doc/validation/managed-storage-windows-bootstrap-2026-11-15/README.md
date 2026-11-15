# Packaged Windows managed-storage bootstrap

Managed storage remains opt-in QA (`XVEIL_MANAGED_STORAGE=true`). Production
activation, Android qualification and full Windows identity-mode qualification
remain incomplete. This cycle fixes early Windows worker startup; it does not
establish a cause for the separate Windows 10 camera/incoming-call complaints.

## Confirmed failure and correction

A separately named Windows debug build of ordinary `lib/main.dart` displayed
`StartupFailedApp` before onboarding. Its local journal recorded
`ManagedWorkerFailure(invalid)` during `ManagedProfilePreferencesFile.open`.
The wrapper classification alone did not identify the cause. Read-only VM
inspection and the private development log localized it to the first worker's
filesystem admission, before node preload.

`processLibFor` fell back to `DynamicLibrary.process()` on Windows when the
isolate-local preload cache was empty. DLL exports are not exports of the
executable. The preference worker starts before main's node preload; even a
later preload in the parent does not populate the worker's Dart handle cache.
The native ACL/ABI lookup therefore failed closed despite the correct DLL being
present beside the application.

Windows now independently opens explicit existing bundle candidates, using the
same candidate policy as the ordinary loader and remembering the resulting
handle per isolate. The existing ABI gate still verifies that handle. The
Linux system-soname fallback remains Linux-only: Windows does not introduce a
bare-name search that could load a DLL from the working directory.

## Regression and actual application evidence

The Flutter-free AOT executable in
[`packaged_library_worker_probe.dart`](../../../test/native/probes/packaged_library_worker_probe.dart)
was compiled on Windows with the reviewed Veil DLL beside it and launched from
an unrelated directory. Before the fix it exited 255 on `fresh worker cannot
resolve ABI`. After the fix both a fresh worker before parent preload and a
second worker after parent preload resolved the ABI symbol. The process image
itself did not export that symbol, so this is not a vacuous global-scope test.

The reusable
[`test-windows-worker-loader.ps1`](../../../scripts/test-windows-worker-loader.ps1)
requires the reviewed DLL's SHA-256, compiles the probe, checks both workers,
then moves the only packaged DLL into the working directory. That negative
control must refuse it. The script passed on the final fixture and source;
its temporary executable, DLL copy and package map were removed.

Example invocation from a developer PowerShell with the selected Dart SDK:

```powershell
.\scripts\test-windows-worker-loader.ps1 `
  -VeilLibrary <reviewed-build>\veilclient_ffi.dll `
  -Sha256 <reviewed-build-sha256> `
  -Dart <selected-sdk>\bin\dart.exe
```

The actual packaged application then reached normal onboarding. After process
death a new process reopened the existing coordination role and again reached
the welcome screen. Its complete 13-line in-memory startup log had zero dropped
lines and no error/exception entries. This checks native startup and cold role
reopen, not identity persistence or a preference-payload round trip.

Certificate export was attempted through the real native dialog. The private
UI helper did not find its filename control; no certificate was saved and the
attempt is **not** credited as export qualification or classified as an app
failure. No clipboard action was used. The volatile synthetic onboarding session
was discarded before the cold restart.

## Build and library provenance

The host was **Windows 11**, not Windows 10. The app was a normal debug/JIT
build; only the standalone loader probe was AOT. Private application metadata,
profile and notification namespace were used. No real container was opened.

The private Flutter 3.44.0 / Dart 3.12.0 toolchain matched the official archive
manifest. Native Veil was built from SDK commit
`5d9884a6e476d263f918cafd2aa575bdfa65c229` with the locked graph and
`node-embedded,testnet-seeds`, preserving normal TLS defaults. The final build
verified 3,033 effective inputs; only three generated non-Windows machine-path
files were excluded after pub get. Build identity changes were limited to the
reviewed QA executable metadata, compile-time flags and application changes.

Actual loaded module hashes were checked, rather than inferring provenance
from the source checkout:

| Module | SHA-256 / basis |
|---|---|
| Veil DLL | `c964d025311c15bb2e61d94cbd6d689a1aba1a7bd8f863029678513481a0c268`, matched this fresh native build |
| hidden-volume DLL | `ba6f41472172916e207d2a6d6ca5d7e6224dfcb12e6563b2bcf10a6406c426ff`, published v2.7.2 |
| Ordinary SQLite DLL | `2bf39f2aadafdc59a90b260f582a8fccebc5b89eb94175fdbaa9148c1e1f084d`, matched sqlite3 3.5.2's platform asset hash |

No media engine was included in this storage-only debug stand. A pre-existing
engine pin failed the current native-source digest check and was not accepted.
Neither a release bundle nor calls, camera or human audio were qualified.

## Windows notification isolation

Renaming a QA executable and its data directory alone does not isolate toast
history or the COM notification activator. `NotificationService` previously
always used production notification metadata. An optional compile-time
`XVEIL_WINDOWS_NOTIFICATION_NAMESPACE` now changes the app name, AUMID and
stable UUIDv5 activator GUID together. Empty retains the exact production
values; malformed values refuse initialization rather than falling back to
production. These identifiers are build metadata, never identity-derived.

The compiled-QA initialization test failed against the old fixed production
settings and passed after the change. Default and QA compile-time cases verify
what the service actually passes to the plugin; independent UUID computation
checks the expected QA activator GUID. This establishes build isolation, not
physical display/delivery of an incoming-call toast.

## Checks and limits

- Final serial Flutter run: **96 passed, 2 skipped**, 13 suites. The two skipped
  host ABI cases lacked a library in that test invocation's lookup path and
  are not counted as passed. The Windows packaged probe exercised the actual
  reviewed DLL independently.
- Analysis of both changed Dart implementation files and both new Dart test/
  probe files: no issues. Earlier compiled-QA notification checks also passed.
- Native security policy, filesystem ownership checks, ABI validation and
  production storage defaults were retained.

The stand is closed after qualification, with process exit, scheduled-task
removal and tunnel shutdown verified privately. Private endpoints, OS account
names, runtime tokens and synthetic recovery material are excluded from this
report. The original Windows 10 video and incoming-alert reports remain
unattributed; whether the call is visible inside that user's app is unknown.
No push or release is part of this cycle.
