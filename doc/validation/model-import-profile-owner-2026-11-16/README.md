# Delayed model imports retain their original profile owner

Status: confirmed application lifetime defect, fixed locally. It affects the
shared model-import path, not only one storage backend. Managed-storage defaults
remain OFF; this is one part of the credential/model activation inventory.

## Reproduction and change

The chat model card staged a received file before constructing its installation
targets. Those targets also resolved model controllers lazily, after asynchronous
manifest inspection. A profile wipe could finish and install a fresh model-work
owner during either wait. The old action would then use a new controller and
recreate installed model data after the wipe had reported completion.

A deterministic test holds the actual bundle's first filesystem read, completes
the real application wipe, then releases the read. With the old code the delayed
import succeeds and installs the model in the directory the wipe removed. This
is a filesystem publication after wipe, not merely a stale progress indicator.

The chat card now captures one target set before its first await and retains it
through staging, provenance decisions and manual-picker retries. Each target set
binds the original profile model-work owner. Dispatch must acquire a task from
that owner before resolving a controller; a retired owner refuses instead of
adopting fresh providers. Actual accepted installation remains joined by that
owner. Its error result is retained locally, so reporting refusal does not read
disposed or replacement providers.

Provider disposal permanently retires its model-work owner. Ref-based targets
also carry a build-generation witness: `Ref.mounted` alone does not identify the
provider build that created an action. Widget targets capture the original
context's mounted witness; container targets retain their original work owner.
Neither mechanism changes manifest validation, provenance approval, model hash
checks or the storage-mode choice.

## Settings picker follow-up

The same lifetime boundary also existed before controller dispatch in Settings.
Both model tiles captured a controller, then awaited the system file picker.
Riverpod can reuse that controller object after a wipe rebuilds its providers;
capturing the object did not preserve the original authority. A late translation
selection recreated installed files after the actual application wipe completed.
A late speech selection inspected the bundle and changed the fresh controller's
state. The speech fixture uses a real translation bundle and verifies refusal of
stale dispatch; it does not substitute a new pinned speech-model hash.

The translation export picker had the opposite effect: after wiping and creating
a replacement pair, the old pending export wrote the replacement's files to the
old destination. Three unchanged-code checks failed on these exact outcomes.

Both import tiles now capture their existing installation targets before opening
the picker. Exports retain the original model-work owner and acquire a task only
after the destination is chosen, so an unattended dialog cannot block erasure.
Accepted export work remains joined through file writing and sharing, and a
retired operation cannot report success or open a share sheet after its write.
Selected source files and destinations are never treated as erasure scratch.

Five widget regressions invoke the actual callbacks in the real I/O zone: both
imports across completed wipe, both imports after widget removal, and export
across wipe/replacement. The wipe path is the real `AppController` method with
controlled storage/OS/network adapters; model controllers, owner retirement,
bundle parsing and filesystem publication are real. Positive controls start new
actions after wipe, install the exact original translation bytes, then export and
independently reinstall the exact replacement bytes. **68 checks in seven serial
suites pass, zero skips**, including existing tile/controller and model-work/wipe
coverage. This is host qualification, not a physical Android picker/share test.
Initial test attempts stalled on fake-async I/O, and one export finder selected
the icon instead of its button; those fixture failures are not product evidence.
Final fixture preparation, completers and file operations run in the real I/O
zone. No system file dialog or application window was opened.

## Qualification

- The gated bundle-read test failed on unchanged product code, then passed with
  the fix. The old action is refused and the installed-model directory stays
  absent. An explicit new action after wipe installs the same real bundle and
  every model file has its exact expected contents: fresh use is not disabled.
- Five lifecycle cases cover replacement work owners through both factories,
  a disposed provider build, disposed container and removed widget. Both speech
  and translation dispatch refuse without resolving a replacement controller.
- **61 tests across seven serial suites pass, zero skips**: import lifetime,
  wipe/model-work composition, manifest/provenance installation, chat rendering,
  task ownership, bounded staging and received-name path handling.
- **54 further tests across three serial suites pass, zero skips**: actual
  managed-profile wipe, native application storage binding and profile-scoped
  models. These regression suites use real stores and controlled OS/resource
  adapters; they are not physical Keychain/Keystore or OEM qualification.
- Analysis of all changed product/test files reports no issues. No native
  library, ABI, dependency pin or network protocol changed.

The first new fixture omitted the bundle's `openRead` delegation; a second setup
attempt lacked the explicit quick-entry OS adapter. Neither failure is credited
as a product reproduction. The qualified wipe fixtures use the existing in-memory
retirement secret store rather than Android's unimplemented test method channel
or the developer's OS credentials. A candidate using only `Ref.mounted` also
failed its disposed-provider check; the build-generation witness closes it.

## Boundaries

The new native regression run does not replace packaged UI or physical platform
qualification. This fixes installation authority after wipe; it does not claim a
new durable inventory for system-temporary staging files, hardware model engines
or every optional application writer. The initial inspection is read-only; after
retirement it cannot gain installation authority from the next profile lifetime.
Existing application cold-erasure recovery is already wired through
`ColdProfileErasureRecovery` (see the
[cold recovery report](../cold-profile-recovery-2026-11-15/README.md)); it should
not be listed as an unimplemented refusal shell.

An updated isolated macOS QA package is prepared separately from the real app.
No application window is launched or activated without an agreed test time.
Packaged custom-source compaction cold readback and the remaining activation/
platform gates remain separate. No push or release.
