# Windows reference recovery across process termination

Status: the four process-death cases skipped in the
[source-barrier round](../windows-source-recovery-barrier-2026-11-16/README.md)
now pass on Windows. Production managed-storage defaults remain OFF.

## Actual crash boundaries

The existing native reference-repair suite now accepts an explicit absolute
`XVEIL_REFERENCE_WRITER_EXE`. This is an owned standalone AOT writer, not a batch
launcher. Its ready marker must name the exact direct child PID and requested
phase. The parent proves the writer still holds exclusive profile/catalog
ownership before terminating it. Prepared cases also prove the original hidden
source is still locked. Dart terminates the owned process directly on Windows;
the POSIX path retains SIGKILL.

All four boundaries were exercised on both hosts:

| Boundary | Writer state when stopped | Cold recovery result |
| --- | --- | --- |
| `prepared` | Async preparation has written both private journals; source not published | Retain original source/references |
| `published` | Async source replacement complete; external references still pending | Apply replacement keys |
| `worker-prepared` | Synchronous prepared owner, before publication | Retain original source/references |
| `worker-published` | Synchronous prepared owner, after publication | Apply replacement keys |

The fixture includes two hidden spaces, an encrypted master, a plaintext master
and an independently owned plaintext sibling. Every recovery checks the exact
labels, order, anonymous flags, original/replacement keys and both hidden-space
payloads. Prepared cases compare the entire original source byte image. Both
private journals must be removed only after successful repair. Added controls
verify the encrypted master's keybox bytes and a real sibling setting remain
unchanged through termination and recovery.

The writer's fixture admission uses the canonical temporary parent and basename,
which works with Windows separators and does not accept a similarly named
directory elsewhere. A configured executable must be absolute and present.
Unconfigured Windows runs still explicitly skip the four cases; those skips are
not evidence of passing qualification.

## Packaging and evidence

The independent writer must include native assets. An initial `dart compile exe`
probe lacked the SQLite native-asset bundle and exited before its checkpoint.
Its bounded `ManagedSqliteFailure(open, null)` was diagnosed from private child
output. That setup failure is not a product regression or a completed crash test.
The successful writer was built with:

```powershell
dart build cli --target=test/native/managed_legacy_reference_writer.dart --output="$writerBuild"
$env:XVEIL_REFERENCE_WRITER_EXE = "$writerBuild/bundle/bin/managed_legacy_reference_writer.exe"
flutter test --no-pub --concurrency=1 test/native/managed_legacy_reference_repair_test.dart
```

Use an isolated output directory, the matching hidden-volume DLL and Veil DLL in
the bundle's `lib` directory, and an admitted private temporary-data directory.
Building the executable alone or using a writable shared temporary ancestor
does not qualify this setup.

- **Windows: 18 native tests passed, zero skips**, including all four actual
  process terminations. The runner used a restricted primary token with
  administrative membership and privileges disabled, not an elevated-only test.
- **macOS: 18 native tests passed, zero skips**, including the existing direct
  Dart-writer SIGKILL route and the new keybox/sibling assertions.
- The actual writer executable, bundled SQLite/Veil/hidden-volume libraries and
  all 874 recorded source/asset inputs were verified. Source digests were checked
  before and after the Windows run; the writer executable was checked again
  afterwards. No native library or dependency pin changed in this round.
- Analysis of both changed fixture files found no issues. Temporary diagnostic
  printing used to inspect the failed standalone build was removed before the
  qualified run and is not in the committed test.
- The owned Windows task and private test data were removed after the run;
  no owned test processes remained. Obsolete standalone builds were removed,
  the qualified CLI bundle was retained, and the SDK's original libraries were
  restored with byte-level checks. No foreground application was launched.

## Remaining scope

These are real process terminations with real stores, not hardware power loss,
GUI startup recovery or physical Android/OEM qualification. Packaged application
cold recovery, native ratchet/ACK crash coverage, destructive/model/credential
inventory, release AOT and all-target native packaging remain separate gates.
The three production storage modes are not enabled by this qualification.


## Follow-up with the qualified Release package

The complete 18-case suite is repeated with the actual Release core and
hidden-volume DLLs from the
[current Windows package](../windows-release-aot-storage-package-2026-11-16/README.md).
This is regression qualification of those newly packaged bytes, not the first
qualification of the four boundaries above and not another product fix.

The writer is rebuilt as a complete native-asset CLI bundle from the frozen
application sources. The ordinary test suite runs through a stand-only wrapper
that explicitly loads the qualified core DLL. No production fixture assertions
or ACL policy are relaxed. The restricted primary token has administrative
membership and privileges disabled, an explicit current-user owner and a
private default DACL. It runs on a separate noninteractive window station; no
user-facing application or input automation is launched.

**18 passed, zero skips**, including all four writer terminations. The ready
marker names the actual child PID before termination; private journals, hidden
payloads, encrypted keybox and sibling data retain the checks described above.
The seven CLI bundle files are hashed, including the executable, SQLite asset
and qualified native dependencies. All 4,256 frozen source/test inputs and all
45 application-package files still match after the test. The source closure
includes the original suite/writer; the small stand wrapper is separate.

An initial elevated SSH launch is excluded: its default file owner was the
administrators group, so the current-user ownership checks correctly refused
fixture creation before the crash tests. A subsequent executable-only writer
did not reach the four checkpoints and is also excluded; the successful run
uses the documented full `dart build cli` bundle. This preparation issue does
not establish a storage or recovery defect.

The actual launcher, writer and test processes have exited; synthetic fixtures
are absent. The successful CLI bundle is retained. Failed standalone builds,
two obsolete wrappers, duplicated native inputs and the regenerated test cache
are removed after ownership/hash checks, approximately 154.5 MiB. The real
application/profile and published packages are unchanged. This adds no GUI
cold-recovery or hardware power-loss claim and does not enable production
managed storage, publish native pins, push or release.
