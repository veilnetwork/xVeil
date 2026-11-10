# Release preparation: Veil 0.11.49 / xVeil 0.13.96+115

Publication is pending. Dependency order: Veil, then xVeil. Hidden-volume
remains at the published 2.7.0; no empty release is planned for it.

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

All seven engine artifacts were built without publication, checked against the
native source digest, binary SHA, architecture and provenance. The Windows
source fix is shared by both engine types. The six other builds retain the same
native source digest, even where Windows-only code is excluded by compilation.

## Publication gates

The first complete application CI run reported 8,074 passing tests, one failure
and 501 skips. The failure was an obsolete always-visible certificate expectation
after the requested expandable-details UI change. The reuse test now first checks
that the certificate is folded, opens its details and checks the same certificate
and unchanged mint count. All 11 focused recovery-step tests pass. The failed full
run is not a passing gate; final-commit CI must run again. No product fallback or
backup requirement was weakened to satisfy that test.

Source CI must pass for the final release commits. Published binary signatures,
checksums, native dependency provenance, architecture and privacy scans must pass
before deployment. Production/testnet seed updates require backups, unchanged
configuration and independent readiness checks.

Detailed identities, endpoint names, local paths, credentials, raw logs and crash
dumps stay outside Git. New reachable source objects are scanned for protected
developer information. Test processes and forwarding were stopped after physical
qualification; the real Windows application remained running.

## Limits retained

Network-handover audio pauses and provider transport restrictions remain under
investigation. Full long-offline/revoke/split-brain/device-scale coverage is not
claimed. Old orphaned group transport fragments remain a documented limitation.
Previously deferred complaints are not declared fixed without reproduction.
