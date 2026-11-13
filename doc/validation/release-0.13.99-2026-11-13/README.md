# Release 0.13.99 qualification

Publication started on 2026-11-12 UTC; independent verification completed at
2026-11-13T00:54:51+00:00. Application build number: **118**.

| Component | Source commit | Qualification | Published package |
| --- | --- | --- | --- |
| xVeil 0.13.99 | `d942015f6197` | [source CI](https://github.com/veilnetwork/xVeil/actions/runs/43314602221) | [release](https://github.com/veilnetwork/xVeil/releases/tag/v0.13.99) |
| veil 0.11.51 | `952e0c292eb8` | [source CI](https://github.com/veilnetwork/veil/actions/runs/43302623904) | [release](https://github.com/veilnetwork/veil/releases/tag/v0.11.51) |
| hidden-volume 2.7.2 | `072b402de743` | [source CI](https://github.com/veilnetwork/hidden-volume/actions/runs/43308195274) | [release](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.7.2) |

Tagged release workflows: [xVeil](https://github.com/veilnetwork/xVeil/actions/runs/43325910542), [veil](https://github.com/veilnetwork/veil/actions/runs/43319827908), [hidden-volume](https://github.com/veilnetwork/hidden-volume/actions/runs/43311291351). Both dependencies were published and
independently verified before the application tag was pushed. The seven native
media targets use the verified immutable
[`engine-2026.11.12.2` set](https://github.com/veilnetwork/xVeil/releases/tag/engine-2026.11.12.2).
The container format is unchanged.

## What changed

Public communities accept signed link joins without manual approval. Discovery
uses the active transport device and retains independent-identity quorum.
Compaction repairs master-to-child references in the encrypted replacement before
atomic publication. Delivery status and device-group/recovery state preserve
their durable publication boundaries. Camera switches retain ownership and state;
Windows negotiates supported capture formats and reports failures honestly.

## Checks

- Mandatory source CI: Veil **6/6 jobs**, hidden-volume **24/24**, xVeil **6/6**.
  Veil's workspace series passed **7243 tests**, with **48 skipped**. Its selected
  feature series passed **387 / 13 / 202**; their filters/skips are kept separate
  in the linked logs. Application source CI and tagged checks each passed
  **8530**, with **584 skipped**. Gated tests are not counted as passes.
- All **17 application assets** matched their published digests. Six APKs
  retained the trusted previous release signer; versions are 0.13.99 with ABI
  codes **1118 / 2118 / 4118**. The three normal APKs also match the independently
  qualified Actions artifact byte for byte. Packaged media matches the verified
  pins; Android's documented stripping transform is checked against real APKs.
- Dependency checksum signatures, architectures and native version/load checks
  passed. The Veil update manifest matches the expected issuer, source epoch,
  binary digest, minimum version and download URL. Storage's **12 binary files**
  match its signed checksum list.
- Available desktop Actions packages were independently checked before app
  publication: **10 artifact archives**, **9 packaged media pins**,
  **345 payload files**, no source-home URIs or known private
  data. Final checks covered **15 application archives**, their metadata and all
  payloads, plus six speech libraries/OpenMP interfaces. No Android signing keys were
  bundled. Reachable Git history and subsequent objects/commit metadata passed
  the known-private-data audit; new commits use the project pseudonym and email.
- The final local macOS builder used the exact application/dependency sources.
  The signature and all **five** native-library loads passed; **108 physical
  files** passed the separate known-private-data scan. These checks start no
  application, recording or playback. They are not Windows 10 hardware checks.
- **Six production and three standard testnet seeds** were updated sequentially
  with backups. All nine have the expected version/binary, unchanged config,
  active services/sessions, zero automatic restarts and successful DHT commands.
  Hostnames, addresses, transport IDs and raw logs are kept out of this report.

## Gates that stopped earlier candidates

The full app gate caught two obsolete manual-join translations. They were removed
from every language and generated localization; **32** focused tests and analysis
passed, then full source CI was repeated. The earlier disposal fix joins admitted
publication work rather than an idle tail; active durable writes still drain.

Dependency test corrections preserve production locking: Darwin process-crash
fixtures isolate fork/exec lock inheritance, Windows respects mandatory byte-range
locks while a prepared owner is alive, and abort still compares original bytes.
The camera-format fixture owns COM on a dedicated thread; its guard is unchanged.
The public API snapshot was updated. The accidental external `half` version edit
was reverted; locked metadata and external dependency records were rechecked.
Failed, cancelled and explicitly skipped jobs are not recast as successful gates.

## Known limits

Ongoing-call network handover, the affected Windows 10 camera scenario,
camera-switch mirroring on the affected phones and the reported loss of both
compaction passwords are not declared fixed by this release.
Large-history latency remains in the backlog. Own-device synchronization requires
an online source; relay mailbox support is not added. Full power-loss/multi-device
qualification and unknown-publisher Android discovery/join remain incomplete.
Legacy group-transfer bytes already deleted by old senders cannot be recovered.
