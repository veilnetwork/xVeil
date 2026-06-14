# xVeil architecture

xVeil is a cross-platform (Android · iOS · Windows · Linux · macOS) Flutter client
for the [veil](https://github.com/veilnetwork/veil) overlay network. It is
**messenger-first**: a Telegram-grade chat experience whose primary differentiator
is decentralization and deniability. Proxy/VPN routing and node management are
secondary surfaces; cloud file storage is a future "killer feature".

It is built for people in censored / authoritarian environments. The two design
rules that follow from that — minimal user actions, and no central source of data —
shape every decision below.

## Ports & adapters

Every external dependency sits behind a **port** (a Dart `abstract interface`), and
each port has an **in-memory fake**. This lets the entire app build, run, and be
tested without the native Rust stack — and makes the native swap a one-file change
in `lib/state/providers.dart`.

| Port | File | Real adapter (later) | Fake (today) |
|------|------|----------------------|--------------|
| `Storage` | `lib/data/storage/` | `hidden-volume` (deniable container) | `InMemoryStorage` |
| `NodeController` | `lib/data/node/` | spawn `veil-cli node run` over IPC | `FakeNodeController` |
| `VeilTransport` | `lib/data/transport/` | `veil_flutter` `VeilClient`/`AppHandle` | `LoopbackTransport` (echoes) |

```
UI (features/*)  ──►  Riverpod state (state/*)  ──►  Ports (data/*)  ──►  fake | native
                         AppController                Storage
                         MessagingService             NodeController
                                                      VeilTransport
```

## Key decisions

1. **Node runtime — hybrid.** The veil FFI is a *client*; it never starts a node.
   We start the node by spawning `veil-cli node run` and connecting the FFI client to
   its IPC socket (works on desktop + Android now). An embedded `veil_node_run` FFI
   entrypoint comes later (needed for iOS and clean mobile background). The
   `NodeController` port hides which strategy is in use.
2. **Storage — hidden-volume.** Default is a deniable hidden space; plain storage is an
   explicit, warned opt-in. A "master space" that unlocks several child spaces is an
   app-layer construct (the library only does 1 password → 1 space).
3. **Fakes-first / chat-first.** The first milestone proves the hardest seam — the
   transport — with a loopback fake, so the messenger UX is real before the native
   stack lands.

## State & navigation

- **Riverpod** for DI and state. `AppController` exposes an `AppPhase`
  (`bootstrapping → onboarding | locked → ready`).
- **go_router** gates navigation on `AppPhase` via a redirect bridged from Riverpod.
- **MessagingService** is the single seam where `VeilTransport` meets `Storage`:
  inbound payloads are persisted then surfaced; `sendText` persists then transmits.

## Roadmap (next)

- Real native wiring: build `libveilclient_ffi` + `hidden-volume-ffi` dylibs, swap the
  three providers, add desktop CMake/podspec build glue for veil_flutter.
- Identity restore / backup import; 24-word BIP-39 via veil_flutter.
- Username claiming (rarity-proportional PoW; needs a veil-side FFI).
- Bootstrap/QR invites, multi-device pairing, mailbox offline delivery, push.
- Proxy/VPN (oproxy/ogate) and SSH node provisioning.
- Lua extension VM (app-level sandbox).
- Cloud file storage across one/several identities.

See `doc/SECURITY-NOTES.md` for the threat-model constraints these features inherit.
