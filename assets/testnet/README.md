Deployment-specific network material for the **testnet**, bundled into the app
build exactly like `assets/prod/`.

The testnet runs on the same hosts as production, on a different port, under a
different obfs4 pre-shared key and with its own node identities. The PSK is what
actually keeps the two apart: a node holding one cannot complete an obfs4
handshake with a node holding the other, so a development build cannot reach
production even by accident.

It exists so a change to a RELAY can be proven against a relay that runs it.
Before it, proving one live meant deploying to production or believing a unit
test — and the mailbox slice endpoint is exactly the kind of change no unit test
can finish the argument about.

`seeds.json` — the testnet seed descriptors. Public, committed: they mirror
veil's `builtin_seeds()` under `--features testnet-seeds`, and
`test/bundled_seeds_match_builtin_test.dart` checks the two lists against each
other in both directions.

`obfs4_psk.b64` — the testnet PSK. **Gitignored**, like production's. A build
without it degrades gracefully (no PSK → no obfs4 bootstrap), which on the
testnet looks like an app that connects to nothing.

Which directory a build reads is decided by `lib/data/node/network_flavor.dart`:
debug builds read this one, release builds read `assets/prod/`, and
`XVEIL_NETWORK` overrides both. The same variable picks veil's cargo feature in
`scripts/build-native.sh`, because the node splices its compiled-in seed list in
by itself — an app that bundled these descriptors while linking a
production-seeded native would dial production anyway.
