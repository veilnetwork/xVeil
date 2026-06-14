# xVeil

A decentralized, censorship-resistant **messenger** and overlay-network client,
built on [veil](https://github.com/veilnetwork/veil) (the network) and
[hidden-volume](https://github.com/veilnetwork/hidden-volume) (deniable storage).

Cross-platform Flutter: **Android · iOS · Windows · Linux · macOS**.

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
- Master vault (one password → several spaces); RU/EN; veil-branded icons

The app still builds/runs/tests on **in-memory fakes** behind clean ports (no native
stack needed); the real stack activates via env (`XVEIL_VEIL_CLI`/`XVEIL_VEIL_CONFIG`,
`XVEIL_NODE_MODE=embedded`). See [`doc/REAL-MODE.md`](doc/REAL-MODE.md) and
[`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md). ~52 unit/widget tests + env-gated live
tests under `test/native/`.

## Develop

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
  domain/      Identity, Contact, Conversation, Message
  data/        ports + fakes: storage/ node/ transport/
  state/       Riverpod: providers, AppController, MessagingService
  features/    splash · onboarding · lock · home · chat · network · settings
  routing/     go_router + AppPhase gating
  l10n/        app_en.arb · app_ru.arb
third_party/   veil + hidden-volume (git submodules)
doc/           ARCHITECTURE.md · SECURITY-NOTES.md
```
