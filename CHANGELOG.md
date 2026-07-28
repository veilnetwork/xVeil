# Changelog

All notable changes to xVeil are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versioning follows [SemVer](https://semver.org/). The app is pre-1.0: minor
bumps may change behaviour a user notices.

Each release pins the two projects it is built on. Those pins are part of the
release: an app version means nothing without knowing which network and which
storage it was built against.

## [0.9.1] — 2026-07-28

Built on [veil v0.4.1](https://github.com/veilnetwork/veil/releases/tag/v0.4.1)
and [hidden-volume v1.2.2](https://github.com/veilnetwork/hidden-volume/releases/tag/v1.2.2).

### Fixed

- **A deployed server is added to the peer list.** Deployment over SSH ended
  with a saved node id and a snackbar; the node was installed, running and
  reachable while staying invisible to the app. A node id cannot be dialled —
  reaching a peer needs transport, public key and nonce — so the script now
  asks the node for its own bootstrap entry and the app adds it.
- **A node deployed without an advertise host is reachable.** `listen add`
  binds `0.0.0.0` and only advertises when the operator filled in a public
  host, so such a node handed out an invite telling peers to dial `0.0.0.0`: a
  peer entry that saves and can never connect. The address the deployment
  reached the machine on is substituted; a host the node advertised for itself
  is left alone.
- **An oproxy exit deployed with the node joins the proxy catalog** instead of
  being installed and never offered.
- **The deploy button is reachable on a phone with gesture navigation.** The
  screen used a flat bottom padding and put its own primary control under the
  system bar.
- **The cloud folder name is visible again.** Seven icon-only actions plus a
  back button left the title about one character wide.
- Errors shown after a deployment or a manual peer add are redacted before they
  reach the screen. They previously carried the raw exception, which quotes
  hostnames, key paths and node ids — into a snackbar, which is the thing
  people photograph when asking for help.

### Added

- **Add a peer by hand**: Network → Peers → *Add peer*. Paste a
  `veil:bootstrap?…` link; the sheet prefills from the clipboard and shows what
  the link resolved to before acting on it. An identity-only link is refused
  with the reason, because it parses cleanly and would add nothing.
- **Plain `ws://` listeners** in the deploy screen. veil's websocket transport
  always served both `ws` and `wss`; only `wss` was offered.
- **INSTALL.md** — which artifact to take per platform, what each platform will
  complain about, and why nothing is published for macOS and iOS.
- **BUILDING.md now starts from a clean machine**: Xcode (the IDE, not just the
  command-line tools), Flutter, Rust, CocoaPods, the Android and Windows
  toolchains, the Debian package list, and the disk budget to expect.

### Changed

- **The cloud root has one named menu** instead of seven unlabelled icons.
  Every entry carries its name; sorting shares the menu and states its current
  value with a checkmark.
- **"Keep on this device" moved into cloud settings.** It is a choice made
  once and it was standing above the file list on every visit.
- **The space setting "P2P availability" is now "Copy redistribution".** It
  never controlled peer-to-peer connections: it sets how many members
  redistribute the space's content so it stays reachable while the owner is
  offline, and the recipients are members the ACL already allows to distribute
  content. The old name invited the conclusion that a channel could see your
  address.
- `libayatana-appindicator3-dev` is in the Linux package list. Without it the
  build stops with a message naming a pkg-config module and no package.

### Removed

- **Lua extensions** from the network screen. The row was a chevron leading to
  a "coming later" notice, which reads as a feature that exists and is switched
  off. The strings stay in the translation files.

## [0.9.0] — 2026-07-28

First release. Built on veil v0.4.1 and hidden-volume v1.2.2.

Android, Windows and Linux artifacts, all produced by CI from the tagged commit
on a clean checkout. macOS and iOS are absent: without an Apple Developer
account the result is something nobody can install — see
[INSTALL.md](INSTALL.md).

Android APKs are split per ABI and signed with the project release key. Speech
recognition downloads its model on first use, which keeps the download near
30 MB.
