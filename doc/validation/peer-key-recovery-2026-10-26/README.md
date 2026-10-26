# Restored peer key recovery

Local correction after xVeil 0.13.93 / Veil 0.11.46; not published.

## Finding and scope

The user reported Android-to-Windows text delivery, missing calls and failure
in the reverse direction. User logs and a Windows stand were unavailable.
On retained macOS/Android QA profiles, the current verified SDK reproduced a
related, broader failure: neither text direction nor either call offer arrived
within the 12-second observation windows. This does not establish that every
symptom in the Windows report has the same cause.

Packets reached the receiver and decrypted, but existing chains used a previous
sender ratchet key. The current verified cache named the same instance with a
different key. Historical chain standing remained current, yet exact current
key evidence was absent. The SDK handed plaintext up as Claimed; the app
correctly rejected privileged text and call offers. Both devices' published
current keys agreed with their local keys. No decryption-key exception or
weakened application provenance check is appropriate.

## Correction

Before consuming a held chain, detect that current unexpired certificates name
its sender instance but no held root's key. Request the existing bounded repair
protocol instead of consuming/acknowledging data the application cannot accept.
Direct sessions use their existing response; relay paths use their existing
signed repair envelope. The sender then makes a fresh agreement against current
certificates. A currently authenticated prologue still has to satisfy existing
freshness and replay admission. Missing certificates alone do not authorize a
reset, and a warm cache retaining both valid rotations keeps its working chain.
No message format, mailbox policy or relay media priority was changed.

## Validation

- The restored-session/rotation regression failed on the previous code at the
  behavioral assertion; it passes after correction. It also verifies unchanged
  receive state on refusal, successful fresh authenticated retry and continued
  use when both rotations remain verified.
- Direct and relay dispatcher regressions assert a repair response, no app
  delivery, no delivery ACK and unchanged stored receive state.
- Complete `veil-e2e` and `veil-dispatcher` library suites: 137 + 284 tests passed,
  including replay, expiry, forged-device, crossed-root and persistence cases.
- The same retained physical profiles recovered with only the Mac SDK patched;
  Android remained on the current published SDK. Text delivery took 1155/1329
  ms and call ringing 311/742 ms. No duplicates were observed.
- After stopping and restarting both apps, text delivery took 1143/1389 ms and
  ringing 445/2003 ms. Calls were accepted in both directions, remained active
  for ten seconds and received audio packets at both endpoints. The first
  recovery produced one repair request and one accepted sender reset; the next
  restart produced neither. See the anonymous aggregate results beside this file.

The stand used Wi-Fi with contact P2P denied to exercise relay signaling. Live
speech quality, Windows execution, cellular conditions, device linking and file
resume were not qualified in this run. The Mac frontend's call/authentication
paths were unchanged from the frozen QA frontend; Android used current local
Dart sources. The candidate native binary had no test-only key classification
instrumentation. All owned app/capture processes exited, temporary permissions
and policies were restored, and temporary private source overlays were removed.
Production apps and relay services were unchanged.

## Separate Android build finding

With Cargo skipped, Gradle's copy task previously preferred a stale library in
a shared Cargo target over the explicitly staged input. A real Gradle copy-task
probe used two distinct harmless byte fixtures: compilation was skipped in both
runs; before correction the stale target replaced the staged fixture, and after
correction the staged fixture was preserved. Fixtures were restored and never
executed or installed. The installed QA APK was then checked against the exact
selected native artifact. This is a verified developer/prebuilt build defect,
not evidence that the published CI artifact suffered that replacement.

Raw logs, identifiers, key material, profiles and absolute native clocks remain
outside the repository. Only aggregate timings, counters and booleans are kept.
