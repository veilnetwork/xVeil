# Release 0.13.101 qualification

Published application **0.13.101+120**, source `73e83f0beb22f7bcaab3232ad85dde6e10558208`.
Veil **0.11.52**, source `19dc8f3ee9fcaafa981e609f5e03dd6341b5bc6a`, was published and verified first.
hidden-volume remains **2.7.2**. Verified at 2026-11-13T10:16:27.641453+00:00.

[Application release](https://github.com/veilnetwork/xVeil/releases/tag/v0.13.101),
[Veil release](https://github.com/veilnetwork/veil/releases/tag/v0.11.52),
[application source CI](https://github.com/veilnetwork/xVeil/actions/runs/43370333014),
[application tagged build](https://github.com/veilnetwork/xVeil/actions/runs/43384484813),
[Veil source CI](https://github.com/veilnetwork/veil/actions/runs/43370323898),
[Veil tagged build](https://github.com/veilnetwork/veil/actions/runs/43381615748).

## Change and limits

Flutter endpoint binds now wait for local IPC on a worker isolate. Native errors,
app-handle ownership and cleanup are preserved; native bind still awaits its
reply. This removes a confirmed event-loop blocker. The native ABI, network
protocol, container format and call timeouts do not change.

[Bind regression evidence](../sdk-bind-worker-2026-11-13/README.md): 12 baseline
assertion failures, 12 candidate cases, 81 SDK tests with six separate skips,
358 related application tests, 12 host AOT cases and one real local IPC/media
test passed. [Receiver crash qualification](../message-ack-crash-2026-11-13/README.md)
adds three selected native cases, including stopping the receiver after an
observed durable delivery acknowledgement. This is partial matrix coverage.

The original mobile NETCALL-01 interruption remains open. No new hardware
handover improvement or full multi-device qualification is claimed. Other
[0.13.100 limits](../release-0.13.100-2026-11-13/README.md) remain.

## Release checks

- All source and tagged workflow jobs passed for both changed projects.
  The first Veil source CI rejected an intentional UTF-8 test literal under the
  existing source policy. The fixture now uses equivalent Unicode escapes;
  all 12 controlled cases and the unchanged policy passed before fresh CI.
  Two tagged application attempts were canceled by the local verifier after
  all three Android 14 installation cases passed. Its cleanup ownership checks
  expected a private executable path or the main emulator launch arguments
  after that process had exited. Both captures were independently rechecked:
  native SHA, cold starts, shutdown, closed ports and removed images passed.
  The corrected guard distinguishes exited zombie entries from live processes,
  verifies live SDK helper executables and has six separate classification
  checks. Local cleanup failures after completed product cases no longer
  cancel CI. Canceled jobs were rerun on the unchanged immutable tag; the final
  result below does not count cancellation as a passed job.
  Application source tests: **8539 passed,
  585 skipped**. Tagged tests:
  **8539 passed, 585 skipped**.
- All **17 application assets** match public digests. Six APKs retain the trusted
  Android signer, version 0.13.101 and ABI codes **1120 / 2120 / 4120**.
  Three normal APKs match independent tagged Actions artifacts.
  The exact tagged arm64 APK also passed Android 14 / API 34 clean installation
  and upgrade from 0.13.99, all 12 extracted-library SHA checks and two cold
  Flutter/AOT mapping checks. Its public digest matches the tested bytes.
  The affected HyperOS handset is still unqualified.
- **15 archives** and **3141 payload members** passed
  private-identifier and source-home-URI checks, with archive metadata checked
  separately. Diagnostic exports remain structured; signing keys are absent.
- Packaged media matches unchanged `engine-2026.11.12.2` pins, including the
  verified Android stripping transform. No empty storage or media release was made.
- Veil: seven installer-manifest signatures, 28 binary checksums/architectures,
  a native macOS version smoke and the signed update manifest passed. Pending
  Git objects and author metadata passed privacy checks before publication.
- All **six production and three testnet seeds** were updated sequentially with
  backups and rollback preparation. Exact binary digests, active services,
  unchanged configurations, live sessions, zero automatic restarts and nine
  successful DHT commands were verified after deployment. Testnet uses a
  separately built, source-verified isolated-network binary.

Operator endpoints, account names, private paths, raw logs and correlation data
are retained outside the repository and are absent from this report.
