# Security notes

xVeil is used by people for whom a privacy failure can mean prison or worse. These
constraints are not optional polish — treat a violation as a release blocker.

## Where data lives

- **Secrets, messages, contacts, identity, node config → the hidden-volume container
  only.** Never the OS keychain, never plaintext files, never logs.
- **`shared_preferences` is for non-sensitive UI state ONLY** (theme, locale, and the
  boolean "has the user completed onboarding"). The onboarded flag reveals only that
  the app was set up — which the app's mere presence already implies — and never which
  spaces or data exist. Putting anything sensitive here is a bug.

## Deniability

- Default storage is a **hidden space**: an adversary with the device + one password
  cannot prove other spaces (or any specific data) exist. Plain storage is an explicit,
  warned opt-in for low-risk users only.
- The lock screen must not distinguish "wrong password" from "no such space" — the
  hidden-volume `AuthFailed` error deliberately conflates them. Do not leak the difference.
- A "master space" that unlocks child spaces is app-layer. **Never anchor / reference a
  decoy or hidden space from a discoverable location.**

## Anonymity & metadata

- Prefer the network's anonymous / onion send paths for sensitive flows; surface the
  trade-offs in plain language, not jargon.
- No central server, no phone number, no analytics, no crash telemetry that leaves the
  device without explicit, informed, opt-in consent.

## Recovery keys

- The 24-word phrase is shown once for backup and then lives only inside the container.
  Never persist it elsewhere, never copy it to the clipboard without a clear warning,
  never include it in any export that is not itself encrypted.

## Current status

The present milestone runs on **in-memory fakes** — nothing is persisted or transmitted
yet. The constraints above are written now so the native adapters are built to them, not
retrofitted.
