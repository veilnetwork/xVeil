# Private HVS commit-stage probe

This is stand tooling, not a production diagnostic feature. `install.py` copies
`probe.rs` and timing-only marks into a **clean, detached, linked worktree** of
HVS at the exact supported commit. It refuses the primary checkout, the app
source tree, dirty inputs and unknown source anchors. All anchors are validated
before any source file is written. Guards remain active under `python -O`.

Build that private worktree in its own external Cargo target under the normal
mount/watchdog/provenance rules. Verify all source hashes, native byte SHA and
all existing UniFFI checksums. The dylib contains `xv_hv_commit_probe_begin`;
name and mark it **PRIVATE_PROBE**, `mustNeverShip: true`. Never copy it into
an APK, normal SDK, release, engine pin, or deployed node. The app's dependency
checkout and pins must remain unchanged.

Enable only the desired stand process:

```sh
XVEIL_PRIVATE_HV_COMMIT_PROFILE=B
```

This requires the existing stand worker label `B`. Value `1` enables the
control test without a device label. The normal library has none of this code.
The installer does not change durability, padding, churn, operations or results.
The copied module observes durations/counts only, without keys, IDs, namespaces,
paths or data. It emits a begin marker once per process and at most 25,000
completed-commit rows; the analyzer rejects a capped file.

`SyncGuard` times the existing `File::sync_all`. That includes scheduler,
filesystem and device waiting; it is not a physical-disk-only measurement.
`CommitProbe` splits the native core body into disjoint phases; `sync_ns` is
contained in those phases, so **do not add it to their sum**. `publish` includes
the Superblock writes and their sync. FFI decode, surrounding Dart work,
parameter cleanup and formatting/writing the probe row are outside this body.
The probe adds overhead and cannot establish an application speedup.

```sh
python3 test/support/hv_commit_probe/install.py /absolute/private/worktree
python3 test/support/hv_commit_probe/analyze.py /private/stand/B.log
python3 -m unittest discover -s test/support/hv_commit_probe -p 'test_*.py'
python3 -O -m unittest discover -s test/support/hv_commit_probe -p 'test_*.py'
```

Read the selected device log, not a merged multi-device stream. Session numbers
are only begin-marker order, not identities. Use the stand's boot/crash/teardown
ledger to select the recovery process. Rows cover **observed completed native
calls**; a SIGKILL can prevent the unfinished call from emitting a row. Never
claim complete RPC/worker attribution from equal counts alone. Keep VM worker
traces and their independent validator when RPC attribution is required.

The analyzer re-exports fixed numeric aggregates only. It rejects unknown or
duplicate fields, malformed integers/outcomes, phase gaps, sync totals exceeding
the body, missing begin markers, caps and empty captures. It does not authenticate
arbitrary log text; use only the controlled stand capture and verified binary.
Close all owned app processes and check listeners/runtime cleanup. `cargo clean`
only the owned target after retaining the separately verified private dylib.
