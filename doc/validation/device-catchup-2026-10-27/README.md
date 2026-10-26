# Device catch-up merge budget — 2026-10-27

The previous absent plain-message frame on Android was traced to normal
multi-device routing: C sent it to B, another device of identity X, and
received a delivery ACK in about half a second. A was waiting for B's device
mirror. This narrows that observation to own-device replication; it does not
qualify Windows 10 delivery or rule out other routing failures.

Device-history replies used a 3,500-byte row budget predating durable snapshot
fragmentation. The app now selects a bounded **32 KiB row budget** through the
existing `sendGroupSnapshot` adapter. Actual wire chunks remain **1,800 bytes**,
with the same durable outbox, limits, authorization and reassembly. Hosts
without fragmentation retain the conservative default. Rows are measured in
UTF-8 bytes; an individually oversized row remains intact for the snapshot
transport to fragment.

The regression transfers 100 Unicode-bearing device events, verifies bounded
row bytes and complete convergence, and requires at least four times fewer
merges than the conservative transport. Forcing the old budget compiled but
failed the behavioral assertion: 100 merges versus at most 25. The group,
device-sync, backpressure and snapshot suites passed 353 tests with three
existing skips; static analysis passed.

## Physical scope and results

All three isolated QA applications used base `16db2613` plus this change and
the same Veil `1d36980d` native artifacts. Existing encrypted profiles were
retained. A was Android on Wi-Fi; A/B shared identity X, C used identity Y.
There were no private timing overlays, native test hooks or reduced identity
difficulty. Native libraries were reused, with no Rust build or server change.

| Phase | Online devices | Observation |
| --- | --- | --- |
| Cold C → X | A, B, C | B had the text at the first 408 ms observation; A/B/C had the same single logical record by 36,806 ms. |
| C sends 100 texts | A, C; B offline | Sending took 4,998 ms; A held 16 unique records at the 125,070 ms observation limit. **Failed delivery limit.** |
| B reconnects | A, B, C | After another 122,816 ms, counts were A=34, B=62, C=100. **Not converged.** |

No duplicates were observed. A later order sample, taken while delivery was
still progressing, had A=34/B=63/C=100 and increasing fixture order on each
device. The extra B record belongs to this later observation. Neither that
partial order check nor the improved cold-text observation establishes an
end-to-end performance improvement: the profiles and inherited queues were
advancing, and the hundred-message boundary still failed. Permanent loss is
not established either. The five-minute C-offline transition was not run.

The larger catch-up batch removes a demonstrated source of excess merge work,
but does not fix the observed per-message processing delay. The next target is
the journal work joined by each individual incoming message, including repeated
admission-cache invalidations and overlapping background readers. No release
qualification is claimed.

All owned macOS process groups exited; the Android QA process was stopped,
permissions restored and its ADB forward removed. Main app data, power policy,
relay scheduling and mailbox policy were unchanged. The public
[aggregate evidence](summary.json) contains role/count/timing fields only.
