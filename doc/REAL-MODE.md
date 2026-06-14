# Running xVeil in real mode (real veil overlay)

By default the app runs on an in-memory loopback (no node, no network) so the
UI works without the native stack. **Real mode** runs an actual veil node and
routes messages over the overlay. It is opt-in via env vars, so the default
startup is never affected.

## One-time

```sh
scripts/build-native.sh          # build veil-cli + both FFI dylibs
flutter build macos --debug      # build the app
```

## Two nodes, correctly peered

`send` routes by node id over a **session**, and veil's directional dedup
requires the session to form lower-node-id=listener ← higher-node-id=dialer.
So **each** node needs its own listener and the two must **mutually**
`bootstrap join` each other's invite (otherwise the link drops with EOF and
every send hits `route.discovery.miss`).

`scripts/dev-real-pair.sh` encodes exactly this — it mines two identities
(first run only), gives each a listener, enables the app IPC socket, mutually
bootstraps them, and starts both nodes under `.dev-nodes/`.

## Two app instances on one machine

```sh
scripts/run-real-instance.sh .dev-nodes/a/config.toml /tmp/xveil-a.store
scripts/run-real-instance.sh .dev-nodes/b/config.toml /tmp/xveil-b.store
```

`XVEIL_STORE_PATH` gives each instance its own container (they share the app
bundle, hence shared `shared_preferences`, but storage stays separate).

In each window: finish onboarding (any password) → **+** (add contact) shows
**this** instance's invite; paste the **other** instance's invite → send. The
peer's app auto-creates the conversation from the inbound node id.

## Env vars

| var | meaning |
|-----|---------|
| `XVEIL_VEIL_CLI` | path to `veil-cli` (enables real mode with `XVEIL_VEIL_CONFIG`) |
| `XVEIL_VEIL_CONFIG` | node config.toml (listener + ipc enabled) |
| `VEIL_FFI_DYLIB` | `libveilclient_ffi` (veil_flutter loader honours this) |
| `XVEIL_HV_DYLIB` | `libhidden_volume_ffi` (real deniable storage) |
| `XVEIL_STORE_PATH` | container file path (per-instance) |

Real cross-**device** chat works the same way once each device runs its own
node with a reachable listener and the two exchange invites.
