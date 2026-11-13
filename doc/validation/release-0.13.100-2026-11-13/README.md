# Release 0.13.100 qualification

Published application: **0.13.100+119**, source `9cdac2672798635332450c32e0d25f45197f3842`.
Verified at 2026-11-13T03:20:37.065952+00:00.

[Release](https://github.com/veilnetwork/xVeil/releases/tag/v0.13.100),
[source CI](https://github.com/veilnetwork/xVeil/actions/runs/43345663353),
[tagged build](https://github.com/veilnetwork/xVeil/actions/runs/43348103623).

## Change and limits

A pending network notification for one online identity no longer delays later
handovers of other identity nodes. Each node retains its own serialized, bounded
retry queue; platform observations are shared. Retired nodes do not overlap their
admitted native notification when re-added.

[Regression evidence](../network-handover-fanout-2026-11-13/README.md): two
assertion-red tests on the released provider, 24 network tests and **358 related
tests passed, zero skipped**. Full analysis passed. This removes a confirmed
application barrier; it does not establish the cause of the original
single-identity NETCALL-01 report. No new hardware handover qualification is
claimed. Other limits in [0.13.99](../release-0.13.99-2026-11-13/README.md) remain.

## Release checks

- All six source-CI jobs and all ten tagged release jobs passed. Source tests:
  **8539 passed, 584 skipped**; skipped cases are
  recorded separately. The tag names the exact qualified source.
- All **17 public asset digests** match GitHub. Six APKs retain the trusted
  previous Android signer, with version 0.13.100 and ABI version codes
  **1119 / 2119 / 4119**. The three normal APKs match the independently
  qualified tagged Actions artifact. Diagnostic snapshots have structured
  export enabled and no raw debug-log sink.
- Packaged native media matches the unchanged immutable
  `engine-2026.11.12.2` pins, including the verified Android stripping transform.
  **15 archives** and all **3141 payload members** passed
  source-home-URI and known-private-data checks; archive metadata was checked
  separately. Android packages contain no signing keys.
- Pending Git objects and author metadata passed the private-data audit before
  publication. Public reports contain no operator addresses, account names,
  transport IDs or raw diagnostic records.
- Veil **0.11.51** and hidden-volume **2.7.2** were already published and verified
  before this app tag; their remote tags match the pinned sources. No dependency
  source, native engine, container format or call timeout changed.
- **Six production and three standard testnet seeds** already run the exact
  published Veil binary. All nine have active services and sessions, unchanged
  configurations, zero automatic restarts and successful DHT commands. No seed
  replacement or restart was needed for this application-only change.
