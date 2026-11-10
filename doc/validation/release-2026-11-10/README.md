# Release validation: Veil 0.11.49 / xVeil 0.13.96+115

Published [Veil 0.11.49](https://github.com/veilnetwork/veil/releases/tag/v0.11.49),
then [xVeil 0.13.96+115](https://github.com/veilnetwork/xVeil/releases/tag/v0.13.96).
Hidden-volume remains at the published 2.7.0; no empty release was made.

## Completed qualification

- [Windows sound and COM lifetime](../windows-audio-output-2026-11-10/README.md):
  live speech confirmed in both directions; real-DLL COM red/green control;
  repeated call, device-switch and lock/unlock cycles. The exact tested Windows
  media binary is retained for the engine asset set.
- [Biometric entry](../quick-unlock-independent-methods-2026-11-10.md): startup
  settings regression tests and physical pattern-free entry on Android, including
  force-stop/restart with the same test identity. No main container was changed.
- [Report 32](../report32-2026-11-09/README.md): applicable findings validated and
  fixed; rejected or design-dependent claims retain their recorded verdicts.
- [Large-history qualification](../history-mid-crash-100000-2026-11-10/README.md):
  exact 100,001-row recovery after a crash during catch-up, including offline
  storage inspection and final cold reopen. This is not the whole device matrix.

All seven engine artifacts were checked before publication against the
native source digest, binary SHA, architecture and provenance. The Windows
source fix is shared by both engine types. The six other builds retain the same
native source digest, even where Windows-only code is excluded by compilation.

## Publication gates

The first complete application CI run reported 8,074 passing tests, one failure
and 501 skips. The failure was an obsolete always-visible certificate expectation
after the requested expandable-details UI change. The reuse test now first checks
that the certificate is folded, opens its details and checks the same certificate
and unchanged mint count. All 11 focused recovery-step tests pass. The failed full
run was not used as a passing gate; the final-commit CI passed separately. No
product fallback or backup requirement was weakened to satisfy that test.

Final-commit source CI passed. Published binary signatures, checksums, native
dependency provenance, architecture and privacy scans were independently verified.
Production/testnet updates retained backups and unchanged configuration;
independent readiness checks passed for all nine services.

Core CI also caught an incomplete version-bump preparation: the separate fuzz
lockfile still named the previous versions of 46 internal packages. Its locked
metadata check failed, so no release tag was pushed. Those entries are now
synchronized with the workspace; third-party dependency versions did not change.
The same full `cargo metadata --locked --offline` check then passed locally.
The final core CI passed with the locked-file check retained.

Detailed identities, endpoint names, local paths, credentials, raw logs and crash
dumps stay outside Git. New reachable source objects are scanned for protected
developer information. Test processes and forwarding were stopped after physical
qualification; the real Windows application remained running.

## Limits retained

Network-handover audio pauses and provider transport restrictions remain under
investigation. Full long-offline/revoke/split-brain/device-scale coverage is not
claimed. Old orphaned group transport fragments remain a documented limitation.
Previously deferred complaints are not declared fixed without reproduction.

## Publication and rollout verified

- Final source CI: [Veil](https://github.com/veilnetwork/veil/actions/runs/42824635461)
  and [xVeil](https://github.com/veilnetwork/xVeil/actions/runs/42824753520).
  The application source suite passed 8,075 tests; 501 checks were skipped
  and are not counted as passed.
- Veil: seven signed checksum manifests and 28 executable hashes/architectures,
  plus the native macOS CLI version smoke and artifact privacy scan, verified.
- xVeil: all 15 published asset digests, embedded media engines, six Android APK
  signatures/versions, enabled anonymous diagnostic variants and privacy scan,
  verified. Android version codes are 1115 / 2115 / 4115 for arm / arm64 / x64.
- Seven engines share the checked native-source digest. The Windows x64 asset is
  byte-identical to the library qualified with live speech and COM controls.
- Six production and three testnet services run 0.11.49. Backups, unchanged
  configuration, process binary identity and readiness were checked. Independent
  verification passed for all nine, including DHT access and zero automatic
  restarts. Testnet features and immutable source provenance were checked before
  deploying its separate static binary.

The owner requested release before another reporter recheck of the locked-screen
incoming-call complaint. That complaint is not marked fixed or confirmed by the
incomplete new window observation. Previously completed call-screen qualification
keeps its original scope; reporter feedback after updating is still required.
Raw operator reports and host details remain outside version control.
