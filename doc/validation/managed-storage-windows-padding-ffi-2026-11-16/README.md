# Windows native constructor and persisted padding

Status: current hidden-volume Windows x64 DLL rebuilt and qualified through a
standalone Dart AOT process probe. The previous QA DLL lacks the new constructor;
current bindings reject it before writing data. This qualifies the component,
not the full graphical Windows release or activation of managed storage.

## Why a rebuild was needed

Read-only inspection of the retained Windows QA libraries checks the actual
previous input digest, successful LoadLibrary and missing exports for both
`spacehandle_create_with_padding` and its checksum. Five matching copies give
the same result. The tracked source manifest also differs at the FFI constructor
implementation. A clean Dart checkout cannot validate those older DLL bytes.

A fresh private Windows directory receives an archive of all 384 tracked
hidden-volume files, including Cargo.lock. The archive and every source file
are verified on the Windows host. Cargo builds the release MSVC x64 library
with locked/offline dependencies, three jobs, a dedicated target directory,
source/home prefix maps and a disk/process watchdog. No Rust dependency version,
source implementation, production DLL or dependency pin is changed here.

The initial compilation used a new target. A corrected process observer then
uses that same owned target and unchanged inputs to capture actual Cargo exit
code 0. The final DLL loads and exports the constructor with checksum 7392,
matching the current Dart table. Tracked inputs are checked again after build
and execution. This is source/output provenance, not a hermetic or bitwise
reproducibility claim about the complete Windows toolchain.

The selected DLL is copied to its own artifact directory, downloaded, and its
hash is matched to the compiled/loaded/probed file. The actual DLL passes the
existing artifact privacy scan without binary-string rewriting. The private
standalone probe executable is not a distribution application artifact.

## Current Dart AOT probe

[managed_creation_padding_probe.dart](../../../test/native/managed_creation_padding_probe.dart)
is compiled as a standalone Windows executable. It uses the ordinary current
hidden-volume facade, actual FFI checksum verification and an explicit library
selection. The two pure-Dart dependency packages use the current lockfile's
ffi/meta versions: twelve source/license/manifest files are transferred and
verified. No Flutter GUI, network node, fake FFI answer or changed padding
implementation is involved.

The probe accepts only an absolute disposable directory with the expected name
and synthetic marker. Creation refuses existing payloads; reopening requires
regular files. It never deletes a fixture directory. All fake passwords are
scrubbed in finally blocks. The parent observes real child exit codes and owns
subsequent teardown.

The final executable runs these cases:

| Case | Evidence |
| --- | --- |
| Prior DLL negative control | ABI verification fails in a separate process; no container file is created |
| Explicit no-padding creation | Exact values committed/read in three separate encrypted files representing keybox, content and maintenance |
| Cold no-padding reopen | Another process reads each original value, commits/reads a second value and keeps growth bounded without a session-only padding override |
| Ordinary hidden default | Constructor is called with padding omitted; creation and a separate-process read/write retain the original default grid |

Every cold case also checks that a wrong password raises AuthFailed and leaves
the complete file image unchanged. The ABI control cannot pass as an empty
positive fixture; each positive role must return its explicit result.

## Observed file sizes

| Role | After first commit | After cold reopen and second commit | Growth |
| --- | ---: | ---: | ---: |
| Keybox | 36,864 B | 57,344 B | 20,480 B |
| Content | 36,864 B | 57,344 B | 20,480 B |
| Maintenance | 36,864 B | 57,344 B | 20,480 B |
| Hidden/default control | 1,052,672 B | 2,101,248 B | 1,048,576 B |

The default quantizes the slot grid, so file size is a multiple of 1 MiB plus
one 4-KiB header chunk; an exact file-size multiple is not the format contract.
The default control protects the requested distinction: the existing hidden
path still pads, while an explicitly enumerable encrypted store can persist
no-padding. These are small native fixtures, not long-run growth, throughput,
managed keybox recovery or application-level accounting measurements.

All four roles pass in the final AOT source version, with real separate create
and reopen processes. The prior smaller probe run is retained as intermediate
evidence, not added to the final case count. Focused analysis is clean.

## Excluded stand failures

Setup issues are not product defects or passing qualification: an oversized
encoded SSH command was rejected before execution; Windows refused a proxy
Cargo symlink from the service process; Start-Process lost its exit-code
observation despite Cargo completing; the probe setup initially removed path
separators in a verifier. Each was inspected after authoritative termination.
The final drivers use transferred/hash-checked scripts, actual installed
Cargo/rustc executables, retained process handles and numeric separator values.
No global execution policy, compiler security rule or storage check was relaxed.

## Audit, cleanup and remaining scope

The final audit checks the recorded source manifests, compiled/probed DLL
identity, constructor checksum, negative ABI control, positive role results,
separate PIDs, current probe source digest, privacy result and process/cleanup
observations. Native/Dart inputs are rechecked after execution.

Owned Windows supervisors and child processes exit; marked fake fixtures,
redundant executable and target intermediates are removed after verification,
freeing about 553 MiB. One exact native artifact and final AOT probe remain
privately for subsequent integration. Existing app installations, original SDK
libraries and the old controls are untouched. No Mac window or real phone is
used, and no push, release or production-default change occurs.

Actual current Windows Flutter release packaging, ordinary application
lifecycle/UI and OS-vault qualification, other architectures and other platform
activation gates remain open. These passes must not be substituted for those
checks, or for physical Windows 10 reproduction of unrelated media complaints.
