# xVeil

A decentralized, censorship-resistant **messenger** and overlay-network client,
built on [veil](https://github.com/veilnetwork/veil) (the network) and
[hidden-volume](https://github.com/veilnetwork/hidden-volume) (deniable storage).

Cross-platform Flutter: **Android · iOS · Windows · Linux · macOS**.

> Built for people in censored and authoritarian environments. Two rules drive
> the design: the fewest possible actions for the user, and no central source of
> data. See [`doc/SECURITY-NOTES.md`](doc/SECURITY-NOTES.md).

## Status

Milestone 1 — **foundation + minimal chat** — is in place and runs on all desktop
targets today:

- First-run onboarding (create identity → recovery phrase → storage choice → password)
- Lock screen + `AppPhase`-gated navigation
- Messenger: chat list + 1:1 conversation
- Network + Settings tabs (live node status; proxy/VPN and node management stubbed)
- Full RU/EN localization

Everything runs against **in-memory fakes** behind clean ports, so the app builds and
runs without the native Rust stack. Wiring the real `veil` node + `hidden-volume`
storage is the next milestone — it only re-points three providers. See
[`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md).

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
