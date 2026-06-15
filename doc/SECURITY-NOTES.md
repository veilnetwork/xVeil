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

## File transfer

- Files are stored **deniably**, the same as messages: chunked into the hidden-volume
  append-log (namespace `fileChunks`), never written as plaintext files on disk. They
  inherit the container's deniability — an adversary with the device + one password
  cannot prove a stored file exists.
- The **receive path treats every inbound frame as hostile by default** — chunks arrive
  from a (possibly compromised) accepted peer. It is hardened along independent axes,
  each with a regression test:
  - **Consent** — file frames from a non-accepted / blocked peer are dropped (same gate
    as chat messages).
  - **Sender identity** — a chunk is bound to the transfer's originator; a *different*
    accepted peer cannot contribute to (or hijack) someone else's in-flight transfer by
    guessing its id.
  - **Structural validity** — the reassembler rejects out-of-range / duplicate indices
    and a `total` that shifts mid-transfer, so a peer cannot fake completion or trigger a
    missing-slot crash.
  - **Memory** — bounded on two axes so a hostile peer cannot exhaust memory:
    `kMaxIncomingFileBytes` per transfer (declared size refused up front, real bytes
    enforced mid-stream) and `kMaxConcurrentIncomingFiles` simultaneous transfers. These
    are **local safety bounds, not protocol values** — tune them freely; the two sides
    need not agree.
  - **Fault isolation** — a malformed datagram (bad JSON, wrong types, bad base64) is
    dropped and can never throw out of the inbound stream listener to disrupt delivery
    for other peers.
- **Anonymity caveat:** file transfers currently use the same direct `app.send` path as
  chat, not an onion path. Large transfers have correspondingly larger metadata/timing
  surface — revisit before treating file transfer as a high-risk-safe flow.

## Node identity lives inside the container (no plaintext config)

The veil **node identity** (Ed25519 private key, node_id, PoW nonce) is provisioned
**in-process** (`veil_config_init`) and stored **inside the unlocked deniable container**
(`Storage.saveNodeConfig`) — never in a plaintext `config.toml`. At unlock the node boots
deferred-init and the real config is applied **in memory** (`veil_node_start_deferred` →
`veil_node_apply_config`, `persist:false`); a fixed throwaway stub identity satisfies the
boot schema until then. So the only persistent identity material on disk is the encrypted
container. Verified end-to-end (two-instance chat, no config.toml). See
[`MULTI-IDENTITY-DESIGN.md`](MULTI-IDENTITY-DESIGN.md).

Residual (not the headline leak): deferred-init briefly writes a **throwaway ephemeral
stub** identity to veil's own temp dir (scrubbed on graceful shutdown; reveals nothing
about the real identity). Eliminating stub-to-disk is a veil follow-up.

## Current status

The real adapters are live: data persists to a deniable `hidden-volume` container, and
messages transmit over the veil overlay (a real node, embedded in-process or via
`veil-cli`). A **consent gate** stops strangers messaging unsolicited. The constraints
above are enforced by these adapters, not retrofitted.

Known gaps to close before any real-user release:
- Desktop dev runs **unsandboxed** (macOS DEBUG entitlement) to reach local node
  sockets/dylibs; the release build must keep the sandbox, bundle the dylibs, add the
  network (client/server) entitlements, and keep storage inside the container.
- The 24-word recovery phrase is still a local placeholder; restoring an existing
  identity from a real veil master-phrase is not wired yet (needs the veil-side FFI).
- iOS background is short scheduled windows (BGProcessingTask), not a 24/7 relay —
  offline delivery must lean on mailbox/rendezvous + push, not a persistent on-device node.
- Large-file anonymity over the direct send path is unaddressed (file transfer UI + backend
  are done; the path is the same direct `app.send` as chat).
