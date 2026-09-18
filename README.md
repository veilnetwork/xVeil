# xVeil

A decentralized, censorship-resistant **messenger** and overlay-network client,
built on [veil](https://github.com/veilnetwork/veil) (the network) and
[hidden-volume](https://github.com/veilnetwork/hidden-volume) (deniable storage).

Cross-platform Flutter: **Android · iOS · Windows · Linux · macOS**.

**Getting the app:** builds for Android, Windows and Linux are on the
[Releases page](https://github.com/veilnetwork/xVeil/releases);
[`INSTALL.md`](INSTALL.md) says which file to take and what each platform will
complain about. Nothing is published for macOS or iOS — both need an Apple
Developer account before there is anything worth handing out — so there you
build it yourself, from [`BUILDING.md`](BUILDING.md), which now starts from a
clean machine.

> Built for people in censored and authoritarian environments. Two rules drive
> the design: the fewest possible actions for the user, and no central source of
> data. See [`doc/SECURITY-NOTES.md`](doc/SECURITY-NOTES.md).

## Status

**Real P2P chat works end to end.** Verified between two app instances over the live
veil overlay, including:

- Onboarding, lock screen + `AppPhase`-gated navigation, "start over" recovery
- **Deniable storage** on a real `hidden-volume` container (desktop)
- A real **veil node** — spawned (`veil-cli`) *or* run **in-process** via FFI
  (`node-embedded`, the iOS/sandbox path; RocksDB stripped for a slim mobile build)
- Real overlay **transport**; contact exchange via bootstrap invites (QR + paste)
- **Consent gate** — request → accept before anyone can message you
- Master vault (one password → several identities); EN/RU/ES; veil-branded icons

Beyond one-to-one chat, the app also carries:

- **Spaces** — communities with a signed control log: roles, moderation with
  appeals, protected and restricted channels, a public feed with posts,
  comments and reactions, retention policy, and a policy audit
- **Group chats** and **calls** — one-to-one and group, with a device picker,
  a call log and an in-app overlay
- **Cloud storage** — folders, notes, shared documents and attachments, with
  capability links that can be revoked
- **Backup and multi-device** — a sealed or plain archive that carries the
  identity, contacts, groups, Spaces and the cloud tree; device linking,
  verification and revocation
- **Node operation** from inside the app — config, managed nodes, a fleet
  updater and network diagnostics

The app still builds/runs/tests on **in-memory fakes** behind clean ports (no native
stack needed); the real stack activates via env (`XVEIL_VEIL_CLI`/`XVEIL_VEIL_CONFIG`,
`XVEIL_NODE_MODE=embedded`). See [`doc/REAL-MODE.md`](doc/REAL-MODE.md) and
[`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md). The automated suite covers the
application, protocol, storage, media, and recovery layers; hardware-dependent
live checks remain explicitly env-gated under `test/native/`.

## Develop

For complete native build instructions in English and Russian, including
macOS, Android, iOS, Linux, Windows, release signing, and production network
material, see [`BUILDING.md`](BUILDING.md).

```sh
git clone --recurse-submodules git@github.com:veilnetwork/xVeil.git
cd xVeil
flutter pub get
flutter run -d macos      # or windows / linux / a device
```

If you cloned without `--recurse-submodules`:

```sh
git submodule update --init --depth 1
```

Checks:

```sh
flutter analyze
flutter test
```

## Layout

```
lib/
  core/        value types (NodeId)
  crypto/      key handling
  domain/      Identity, Contact, Conversation, Message, groups, Spaces, cloud
  data/        ports + fakes: storage/ node/ transport/
  state/       Riverpod: providers, AppController, MessagingService
  features/    bootstrap · calls · chat · common · contacts · groups · help
               home · identity · lock · network · onboarding · preparing
               settings · spaces · splash · storage
  routing/     go_router + AppPhase gating
  headless/    the app without a UI, for tests and diagnostics
  desktop/     desktop-only entry points
  theme/       colour and typography
  l10n/        app_en.arb · app_ru.arb · app_es.arb
third_party/   veil + hidden-volume (git submodules)
doc/           design notes and plans (23 documents; ARCHITECTURE.md and
               SECURITY-NOTES.md are the two to start from)
```

## Community

- **News:** [@xVeilNet](https://t.me/xVeilNet) — releases and project updates.
- **Discussion:** [@chat_veilnet](https://t.me/chat_veilnet) — bug reports,
  questions, suggestions.

## Support the project

Donations in crypto:

- **Ethereum:** `0x5238294aFb8F4e36D7ea091827909E0311879B1A`
- **Bitcoin:** `bc1qam33yx29et9krqc8jnnu80qvds8jz32wrwr3ph`
