Deployment-specific network material bundled into the app build.

`obfs4_psk.b64` — the deployment-wide obfs4 pre-shared (anti-probe) key for the
production veil network. It is **gitignored** (a network secret, like the
testnet PSK / ansible inventory). The embedded node reads it on Android (where
there is no `XVEIL_OBFS4_PSK` env var) to dial the production seed nodes baked
into `builtin_seeds()`. Drop your deployment's PSK here before `flutter build`.
A build without it degrades gracefully (no PSK -> fakes / no obfs4 bootstrap).
