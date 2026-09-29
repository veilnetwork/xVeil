# xVeil architecture

xVeil is a cross-platform (Android · iOS · Windows · Linux · macOS) Flutter client
for the [veil](https://github.com/veilnetwork/veil) overlay network. It is
**messenger-first**: a Telegram-grade chat experience whose primary differentiator
is decentralization and deniability. Proxy/VPN routing and node management are
secondary surfaces. Cloud file storage is shipped, not planned — its own screens,
folder sync, a trash with undo, and per-folder ACLs.

It is built for people in censored / authoritarian environments. The two design
rules that follow from that — minimal user actions, and no central source of data —
shape every decision below.

## Ports & adapters

Every external dependency sits behind a **port** (a Dart `abstract interface`) with
**both a real adapter and an in-memory fake**. The fakes let the whole app build/run/test
without the native Rust stack; selecting real vs fake is a provider choice in
`lib/state/providers.dart` (+ `main()` bootstrap). All three real adapters are
implemented and verified end-to-end.

| Port | File | Real adapter | Fake (dev/tests) |
|------|------|--------------|------------------|
| `Storage` | `lib/data/storage/` | `HiddenVolumeStorage` over `hidden_volume` (deniable container; `HvKvLogStore`) | `HiddenVolumeStorage` over `FakeKvLogStore` |
| `NodeController` | `lib/data/node/` | `EmbeddedNodeController` (node in-process via FFI) **or** `SubprocessNodeController` (`veil-cli node run`) | `FakeNodeController` |
| `VeilTransport` | `lib/data/transport/` | `VeilFlutterTransport` (`veil_flutter` `VeilClient`/`AppHandle`, `xveil/inbox` endpoint) | `LoopbackTransport` (echoes) |

`RealVeilStack` (`lib/data/veil_stack.dart`) composes the real node + transport + this
device's bootstrap invite; `main()` activates it when `XVEIL_VEIL_CLI`/`XVEIL_VEIL_CONFIG`
are set (`XVEIL_NODE_MODE=embedded` picks the in-process node), else the app stays on fakes.

```
UI (features/*)  ──►  Riverpod state (state/*)  ──►  Ports (data/*)  ──►  fake | native
                         AppController                Storage
                         MessagingService             NodeController
                                                      VeilTransport
```

## Key decisions

1. **Node runtime — embedded or subprocess (both done).** The veil client FFI only
   *connects* to a running node. xVeil starts one two ways behind `NodeController`:
   `SubprocessNodeController` spawns `veil-cli node run` (desktop/Android); the
   **embedded** path runs the node IN-PROCESS via a new `veil_node_start/stop` FFI
   (`node-embedded` feature in `veilclient-ffi`) — required for iOS and sandboxed
   desktop (no subprocess), and verified end-to-end. The embedded build drops RocksDB
   (in-memory DHT) so mobile stays slim.
2. **Storage — hidden-volume.** Default is a deniable hidden space; plain storage is an
   explicit, warned opt-in. A **master vault** (`MasterVault`) that unlocks several
   child spaces with one password is an app-layer construct (the library does 1
   password → 1 space). `loadConversations` derives from a contacts index + the message
   log (hidden-volume has no KV key enumeration).
3. **Consent gate.** Strangers can't message unsolicited: a typed `WireEnvelope`
   carries request/accept/message; a relationship is `pending → accepted` before free
   messaging (`MessagingService`; `ContactStatus`). Messages from non-accepted/blocked
   peers are dropped.
4. **Fakes-first.** The fakes keep the whole app build/run/test-able without the native
   stack; the real stack is verified by env-gated tests under `test/native/`.

## State & navigation

- **Riverpod** for DI and state. `AppController` exposes an `AppPhase`
  (`bootstrapping → onboarding | locked → ready`).
- **go_router** gates navigation on `AppPhase` via a redirect bridged from Riverpod.
- **MessagingService** is the single seam where `VeilTransport` meets `Storage`:
  inbound payloads are persisted then surfaced; `sendText` persists then transmits.

## Status

**Done & verified:** native storage (deniable container on desktop); node lifecycle
(subprocess **and** embedded in-process FFI); pure-Dart BLAKE3 → `app_id`/`node_id`;
real transport (`send`/`messages`); **two-node real chat**; bootstrap-invite contact
exchange (QR + paste); `RealVeilStack` composition; consent gate (request/accept);
`MasterVault`; recovery-phrase input; app icons; lock-screen "start over" recovery.
Test harness: ~5,700 tests in 566 files. Live cases in `test/native/` and
`test/e2e/` skip under a plain `flutter test` when their native libraries are
missing; the multi-device harness also needs a `veil-cli` from the same build.
`.github/workflows/nightly.yml` builds these artifacts and schedules the
locally runnable live cases, while the push CI covers the regular Dart suite.

**Shipped since this section was written** — each was roadmap here, each is wired into
the app rather than merely present as a file:

- Veil FFI follow-ups: `veil_config_init` and `apply_config` (deferred mode) are bound
  and called from `RealVeilStack`; iOS dylib bundling is `scripts/build-mobile.sh ios`, TCP-loopback IPC is in `embedded_node.dart`.
- Identity restore/import, via `veil_config_init_from_phrase`.
- Username claiming — rarity-proportional PoW through `veil_flutter`
  (`claimNickname`/`resolveNickname`), UI in `features/settings/nickname_screen.dart`.
- Multi-device pairing (`device_link_invite`), mailbox offline delivery
  (`mailbox_service` + `mailbox_orchestrator`).
- File / image / video transfer (`messaging_file_transfer`).
- Audio / video calls (`call_service`, `group_call_service`).
- Built-in S3-style object storage across identities (`cloud_*`).
- Proxy/VPN (oproxy/ogate), SSH node provisioning.

**Not built:**
- Remote push. Notifications are local-only (`flutter_local_notifications`): the
  notification layer displays what the caller hands it and holds no policy, and there
  is no FCM/APNs registration anywhere in `lib/`. A sleeping device stays asleep until
  it wakes and drains its mailbox on its own.
- The Lua extension VM. The ARB strings are kept (`networkExtTitle`) and the row was
  taken out of the network screen, because a chevron leading to a "coming later"
  snackbar reads as a feature that exists and is merely switched off.

See `doc/SECURITY-NOTES.md` for the threat-model constraints these features inherit.
