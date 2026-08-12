# Changelog

All notable changes to xVeil are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versioning follows [SemVer](https://semver.org/). The app is pre-1.0: minor
bumps may change behaviour a user notices.

Each release pins the two projects it is built on. Those pins are part of the
release: an app version means nothing without knowing which network and which
storage it was built against.

## [0.9.2] — unreleased

Built on [veil v0.4.2](https://github.com/veilnetwork/veil/releases/tag/v0.4.2)
and [hidden-volume v1.2.3](https://github.com/veilnetwork/hidden-volume/releases/tag/v1.2.3).

All three call engines are now built and pinned (`ENGINE_RUN` for android,
linux and windows), so the release workflow no longer stops on a missing
engine. What remains before publishing is in the release checklist at the
bottom of this entry.

### Security

- **Declining the shared seed nodes now holds from the first packet.** Someone
  who turns that off at onboarding was still contacting all four production
  seed hosts once per start, on every launch, on the app and on the headless
  daemon alike.

  The setting was correct everywhere it could be seen. It reaches the node
  config the app composes, which carries `builtin_seed_policy = "never"` — but
  that is the SECOND config the node reads. The deniable boot starts the node
  from a stub built inside the veil library, and `veil_node_start_deferred`
  takes no config at all, so nothing on this side could reach it. That stub
  carried veil's default policy, whose condition is "no peers configured" —
  exactly what a stub is — so the node spliced in its compiled-in seed list and
  opened connectors to it, seconds before the answer arrived.

  Fixed in veil: the stub now boots refusing the compiled-in seeds, so a
  deferred boot reaches nothing and the network arrives with the config that
  was asked about. Nothing changes for someone who KEEPS the seeds — applying
  the real config is a full reload, and veil re-runs its bootstrap against it.
  This app cannot observe the stub at runtime, so the guard against it coming
  back with a submodule bump reads the veil source directly
  (`test/bundled_seeds_match_builtin_test.dart`).

- **A shipped build no longer runs on the in-memory fake store.** When the
  hidden-volume library failed to load, the app carried on: every non-empty
  password opened the SAME unencrypted space and nothing survived the process.
  The FATAL banner announcing it goes through `devLog`, which is compiled out
  of a product build — so the degradation was silent exactly where it mattered,
  and a user would have written down a recovery phrase for a container that did
  not exist. Release and profile builds now refuse to start.
- **Folder sync can no longer write outside the folder you chose.** Mirror
  paths are built from cloud item names, any linked device can create an item,
  and the path was plain string concatenation — so a name like
  `../../.ssh/authorized_keys` landed atomically on whatever it hit.
- **The local API is exclusive and bounded.** `shared: true` is SO_REUSEPORT:
  another process of the same user could bind the port and receive a share of
  the requests, bearer token included. The token is also checked before the
  body is read, and the body is capped.
- **SSH host keys are confirmed before credentials are sent.** Trust-on-first-
  use was decided inside the connection that then authenticated and ran the
  provisioning script, so a man-in-the-middle on first contact collected the
  password, the script and the obfs4 PSK — and had its key saved as trusted.
- **Provisioning stages secrets privately.** The PSK, the systemd unit and a
  TLS private key were written to fixed `/tmp` names under the login umask and
  then handed to `sudo install`; cleanup ran only on success.
- **A corrupt roster is never silently rewritten.** `loadRoster` answered null
  both for "no roster" and "a roster I could not parse", so adding one identity
  to a damaged master dropped the SpaceKeys of every other identity — keys that
  exist nowhere else.
- **Content manifests are checked for geometry, not just self-consistency.** A
  manifest hashes to its own id, which its author computed; nothing verified
  that the numbers agreed. One declaring 2 MiB in 256 KiB pieces with a single
  hash was accepted and reported complete after 256 KiB.
- **BLAKE3 hashes past one chunk.** It was single-chunk behind a debug assert,
  so a release build returned a wrong digest for longer inputs — reachable,
  because a peer's node id is derived from their public key and the hybrid
  post-quantum key is 1825 bytes.
- **The error report stops naming people.** It carried IP addresses, hostnames,
  URLs, e-mail addresses, paths and short tokens — and the active profile's
  name, when the existence of a second profile is the fact worth hiding.

### Added

- **Messages translate on the device, by button.** No text leaves the machine
  and nothing is sent to a service: the engine is CTranslate2 running an
  OPUS-MT model, and the result is kept in the ENCRYPTED store so a second look
  costs nothing and the translation never lands in plaintext. Translation
  appears only when a model for that direction is actually installed — an
  affordance that cannot work is not shown.
- **Language models install from a file, and can be passed on.** A direction
  travels as one `.veiltranslate`; the speech model travels as one
  `.veilaudio`. Either can be picked from disk or received in a chat, where it
  becomes an install card rather than an anonymous download. Settings can write
  an installed direction back out as a file, so a person whose connection
  cannot fetch 79 MB — or who has none — can get one from someone who has it.
- **A model is installed whole or not at all, and is verified before it is.**
  A language pair is five files; four of them plus a missing tokeniser is not
  a partial model but one that would translate into nonsense the moment the
  fifth arrived from a different pair. Every file's size and SHA-256 are
  checked against the manifest before anything becomes visible, the container
  carries no paths, and nothing is compressed — so a file from a stranger
  cannot write outside where it belongs or expand into anything.

  For the SPEECH model the check is stronger, because the right hash is known:
  a bundle is compared against what this build expects, not merely against its
  own claim about itself. For a translation model there is no such pin, so
  every install card says plainly that a model decides what the app claims
  another person wrote, and that its hashes prove integrity and not
  provenance.

- **Link a new device without minting a phrase it will never own.** A second
  device joining an existing device group no longer walks the create-identity
  wizard first.
- **Attach a file to a note** by reference, with a dangling attachment shown as
  visibly unavailable rather than as raw text.
- **A community's action log**, rendered to what each member may see; anything
  they may not is an explicit unavailable row rather than a gap.

### Fixed

- **The released APK carries the call engine.** v0.9.1 shipped without
  `libveil_media.so`: voice messages, video notes, calls and speech-to-text all
  threw at first use. The build now refuses to start without it and reads the
  finished APK to confirm it arrived.
- Android ships **arm64-v8a only**. armeabi-v7a and x86_64 were published
  through v0.9.1 and can never carry the call engine.
- Onboarding no longer dead-ends on a failed container creation; folder sync no
  longer wedges a pair as busy forever; API-token ids no longer throw about one
  creation in 585.

### Release checklist

1. ~~Tag veil and hidden-volume, and repoint the pins at those tags.~~ Done:
   v0.4.2 and v1.2.3.
2. ~~Run the `webrtc-linux` workflow (job `engine-android`), pin its run id in
   `release.yml`.~~ Done: run 31609030118, artifact
   `libveil_media-android-arm64`, 87/87 symbols. The same run repins linux,
   which was pointing at a run whose overall conclusion was `failure`.
3. ~~Run `webrtc-windows`, fix what the never-compiled port gets wrong, pin its
   run id.~~ Done: run 30665287484, artifact `libveil_media-win-x64`.
4. Tag xVeil; then DOWNLOAD the published artifacts and open them before
   announcing anything — that is what v0.9.1 skipped.

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

Android ships one APK, `arm64-v8a`, signed with the project release key. Speech
recognition downloads its model on first use, which keeps the download near
30 MB.
