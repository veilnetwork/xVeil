Deployment-specific network material bundled into the app build.

`obfs4_psk.b64` — the deployment-wide obfs4 pre-shared (anti-probe) key for the
production veil network. It is **gitignored** (a network secret, like the
testnet PSK / ansible inventory). The embedded node reads it on Android (where
there is no `XVEIL_OBFS4_PSK` env var) to dial production obfs4 peers it
discovers or is configured to use. Drop your deployment's PSK here before
`flutter build`.
A build without it has no shared obfs4 bootstrap key; it must be configured
for another reachable transport or network. The release APK gate verifies
that configured network assets are present unchanged, and omitted assets do
not survive from a cached build. The gate does not require a PSK for a
deployment that intentionally supplies none.
