# xVeil headless daemon

The headless host runs the real deniable store, embedded veil node, messaging
engine and `/v1` automation API in a standalone Dart AOT executable. It does
not start or link a Flutter engine. Build the bundle on the target operating
system:

```sh
scripts/build-headless.sh
```

The bundle is self-contained under `build/headless/bundle/`: the executable is
in `bin/`, native libraries in `lib/`. For development, `VEIL_FFI_DYLIB` and
`XVEIL_HV_DYLIB` may override their locations.

## Provisioning

Create the public, non-secret config and a protected API credential:

```sh
build/headless/bundle/bin/xveil init-config /etc/xveil/headless.json
umask 077
build/headless/bundle/bin/xveil generate-token > /etc/xveil/api.token
```

Edit the JSON paths, ports and bootstrap peers. Passwords, identity phrases and
API tokens are deliberately rejected from JSON and literal CLI arguments. Use
protected files (or a service manager's credential facility):

```sh
build/headless/bundle/bin/xveil run \
  --config /etc/xveil/headless.json \
  --create \
  --password-file /run/credentials/xveil/store-password \
  --identity-phrase-file /run/credentials/xveil/identity-phrase \
  --api-token-file /run/credentials/xveil/api-token
```

`--identity-phrase-file` and `--create` are first-run options. The phrase is
consumed to provision the identity and is never stored. Subsequent starts need
only the store password; issued API tokens are loaded from the deniable store.
An existing GUI identity store is format-compatible, but two processes must
never open the same container concurrently (the native exclusive lock rejects
that safely). A bot should normally use its own identity/store.

Environment overrides for public configuration are `XVEIL_CONFIG`,
`XVEIL_STORE`, `XVEIL_RUNTIME_DIR`, `XVEIL_BLOB_DIR`, `XVEIL_LISTEN_PORT`,
`XVEIL_API_PORT`, `XVEIL_ANONYMOUS`, `XVEIL_OBFS4_PSK_FILE`. Secret file paths
may be supplied as `XVEIL_PASSWORD_FILE`, `XVEIL_IDENTITY_PHRASE_FILE`, and
`XVEIL_API_TOKEN_FILE`; secret values themselves have no environment option.

## systemd service

Provision the identity once with `--create`, then remove the phrase credential
from the steady-state service. A minimal hardened unit for a dedicated `xveil`
user is:

```ini
[Unit]
Description=xVeil headless daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xveil
Group=xveil
StateDirectory=xveil
RuntimeDirectory=xveil
UMask=0077
LoadCredential=store-password:/etc/xveil/store-password
LoadCredential=api-token:/etc/xveil/api-token
ExecStart=/opt/xveil/bin/xveil run --config /etc/xveil/headless.json --password-file %d/store-password --api-token-file %d/api-token
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/xveil /run/xveil
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
```

Keep `/opt/xveil/bin` and `/opt/xveil/lib` together: the executable resolves
the bundled FFI libraries from the sibling `lib/` directory. SIGINT/SIGTERM
first closes the API, messaging engine, embedded node and encrypted store, then
explicitly terminates the standalone process so residual native worker threads
cannot hold service shutdown open.

## API and privacy boundary

The daemon serves the same authenticated API, WebSocket event feed and
loopback webhook implementation as the GUI. HTTP always binds only
`127.0.0.1`; expose it remotely only through a separately authenticated tunnel.
Calls return HTTP 501 because the headless host has no audio/video media engine.
Messaging, contacts, files, groups, OpenAPI, scoped tokens, WebSocket events
and loopback webhooks use the normal production code paths. Group list/create
and message read/post are available at `/v1/groups` and
`/v1/groups/messages`; incoming group messages also appear in the WebSocket
and webhook feed as `group_message` events. The daemon uses the same signed
group log and epoch-E2EE service as the GUI, not an API-only shadow store.

SIGINT or SIGTERM stops the API, mailbox and node, closes the encrypted store,
and removes the identity-free runtime socket directory.
