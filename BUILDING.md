# Building xVeil / Сборка xVeil

- [English](#english)
- [Русский](#русский)

## English

### Build model

xVeil is a Flutter application with two Rust native dependencies:

- `veilclient-ffi` provides the veil overlay client and the embedded node;
- `hidden-volume-ffi` provides deniable encrypted storage.

A plain Flutter build may be useful for UI development, but a production-capable
build must contain both native libraries. Run all commands below from the xVeil
repository root unless a command explicitly changes directory.

### The short way

Two entry points cover every target from a Windows, Linux or macOS host:

```sh
./prepare.py [target]     # bring a clean machine to the point of building
./builder.py [target]     # native libraries + the app itself
```

`target` defaults to this machine's own system and may be `android`, `linux`,
`windows`, `macos` or `ios`. Add `--debug` for a debug build, `--dry-run` to
print the plan and execute nothing — which also works for a target this host
cannot build, so a Windows plan can be reviewed from a Mac.

`prepare.py` installs Rust and the cross-compilation targets, cargo-ndk, the
Android command-line tools and NDK, the Linux system packages, CocoaPods, the
git submodules the native libraries live in, and the Dart packages. It stops
and tells you the exact command for anything that wants a license agreement or
tens of gigabytes — Flutter itself, Xcode, Visual Studio — because starting
those unattended because someone typed a word is worse than asking. Running it
twice is safe: the second run reports what is already satisfied.

`builder.py` calls the scripts documented below rather than replacing them, so
the per-platform sections stay the reference for what actually happens, and
anything unusual (staging a single DLL, a signing workaround) can still be run
by hand.

### From a clean machine

`prepare.py` deliberately stops at anything that needs a licence agreement or
tens of gigabytes. This section is what to do when it stops. Do these once,
then let `prepare.py` finish the rest.

**Disk.** Budget ~100 GB if you intend to iterate: Rust debug trees are the
dominant cost (veil alone reaches ~22 GB), and each platform you switch to adds
its own. A single build needs far less, but you will run `cargo clean` often.

**macOS host — Xcode.** The command-line tools are not enough for macOS or iOS
builds; the full IDE is required.

```sh
xcode-select --install                       # command-line tools
# then install Xcode itself from the App Store (~10 GB), and:
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

`xcode-select -s` matters: with only the command-line tools selected, Flutter
reports Xcode as missing even though it is installed.

**macOS host — the rest.**

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask flutter          # or download the SDK and add bin/ to PATH
brew install cocoapods
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

**Android, on any host.** Android Studio is the easy route because it installs
the SDK, the NDK and a JDK together. Without it, install JDK 17 and the
command-line tools, then let `prepare.py android` fetch the SDK packages. Point
`ANDROID_HOME` at the SDK (`~/Library/Android/sdk` on macOS,
`~/Android/Sdk` on Linux) before running it.

**Windows host.** Visual Studio with the *Desktop development with C++*
workload — the Build Tools alone are not enough for `flutter build windows`.
Git for Windows provides the bash that `builder.py` needs for the whisper
wrapper.

**Linux host.** Everything is a package; `prepare.py` installs the list for
apt, dnf, pacman or zypper. On a Debian-family system that is:

```sh
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev libayatana-appindicator3-dev \
  unzip curl git
```

That list is exactly what `prepare.py` installs. **`libmpv-dev` is not in it**
and is needed for in-chat video, so install it separately:

```sh
sudo apt-get install -y libmpv-dev
```

Flutter has no official linux-arm64 tarball; on an ARM machine clone the SDK
instead (`git clone -b stable https://github.com/flutter/flutter.git`) — the
tool then fetches an arm64 Dart SDK and works. Note that a linux-arm64 host
runs into a harder problem later: the prebuilt call engine is published for
linux-**x64** only, and the Linux build refuses to configure without it. See
[Call media engine](#call-media-engine-webrtc).

**Then, for every host:**

```sh
git clone --recurse-submodules https://github.com/veilnetwork/xVeil.git
cd xVeil
./prepare.py            # or: ./prepare.py android|ios|linux|windows|macos
flutter doctor -v       # should report no blocking issues for your target
./builder.py
```

**Signing, for Apple platforms only.** Both Apple targets ship a packet-tunnel
network extension, and both the app and the extension request
`com.apple.developer.networking.networkextension` — a restricted entitlement
that needs a provisioning profile, which needs an Apple Developer account. That
one fact shapes every Apple build, so read the macOS and iOS sections below
before starting: macOS has a documented way around it and **iOS does not**.
Neither Apple target is published by CI, by design — without a signing identity
the artifact would be something nobody can run — so on Apple platforms you
build locally, for yourself.

### Requirements

Common requirements:

- Git with submodule support;
- Flutter stable. Flutter 3.44.0 with Dart 3.12.0 is the currently verified
  toolchain; `pubspec.yaml` requires Dart 3.12 or newer;
- Rust stable. Rust 1.97.0 is the currently verified toolchain;
- the platform toolchain reported by `flutter doctor -v`.

Additional platform requirements:

- macOS/iOS: current Xcode command-line tools and CocoaPods;
- Android: Android SDK, Android NDK, JDK 17, `cargo-ndk`, and the four Android
  Rust targets;
- Linux: the Flutter Linux desktop prerequisites, including CMake, Ninja, GTK
  development packages, and the system libmpv development package
  (`libmpv-dev` on Debian/Ubuntu); end-user systems need the matching libmpv
  runtime (`libmpv2` on Debian/Ubuntu);
- Windows: Visual Studio with the Desktop development with C++ workload and
  Windows SDK.

Check out and prepare the source tree:

```sh
git clone --recurse-submodules git@github.com:veilnetwork/xVeil.git
cd xVeil
git submodule update --init --recursive
flutter doctor -v
flutter pub get
```

Do not replace the recorded submodule revisions with arbitrary branches: xVeil
is tested against the exact `third_party/veil` and `third_party/hidden-volume`
commits stored by the parent repository.

### Production network material

Production seed addresses are compiled into release builds, but the deployment
obfs4 pre-shared key is intentionally not stored in Git. Before producing a
distributable build, place the deployment key at:

```text
assets/prod/obfs4_psk.b64
```

Keep this file private and never commit it. A build without it can compile, but
the embedded node cannot bootstrap through production obfs4 seeds and may fall
back to a non-live development posture.

### macOS

**The short way, and the one to reach for first:**

```sh
./builder.py macos             # --debug for a debug build
```

`builder.py` picks the right path for the machine it is on. It looks for
provisioning profiles in `~/Library/MobileDevice/Provisioning Profiles`; if
there are none it takes the ad-hoc route described below automatically, and
says so as it goes. It then builds the native libraries, builds the optional
whisper wrapper, bundles the dylibs, and finally checks the ARTIFACT — that
both required dylibs are in `Contents/Frameworks`, naming each optional one
that is absent and the feature that goes with it. That last check is the
reason to prefer it: a bundle can be built successfully and still be missing
the library a feature needs.

Note that the profile check is a heuristic — it asks whether that directory has
anything in it, not whether any profile matches this app. A machine holding
unrelated profiles from some other project will take the signed path and fail
at signing; force the ad-hoc script by hand if that happens.

**What you get, and what you can do with it.** A local build is fine to run on
the machine that made it. It is not something to hand out: without a Developer
ID it cannot be notarised, so on any other Mac Gatekeeper refuses it until the
recipient runs `xattr -dr com.apple.quarantine /Applications/xveil.app` — a
command that removes the check that would otherwise stop an unidentified
application, and not one to ask people to run casually. macOS is deliberately
not a published artifact for exactly this reason. For real distribution, get a
Developer ID and use the normal signed build.

**By hand**, if you want the individual steps — debug build:

```sh
scripts/build-native.sh
flutter build macos --debug
scripts/bundle-macos-dylibs.sh debug
```

Release build:

```sh
scripts/build-native.sh --release
flutter build macos --release
scripts/bundle-macos-dylibs.sh release
```

**Without an Apple Developer account both commands above fail** — debug
included, not just release. The app and the PacketTunnel extension request
`com.apple.developer.networking.networkextension`, a restricted entitlement
that needs a provisioning profile, and no profile can be minted without an
account. Everything compiles and then signing fails. Use instead:

```sh
scripts/build-native.sh          # --release for a release build
scripts/build-macos-adhoc.sh debug     # or: release
```

That signs ad-hoc against `{Debug,Release}NoVpn.entitlements` and deletes the
built `PlugIns/PacketTunnel.appex` from the bundle, so the result has no VPN —
which costs nothing today, since the macOS VPN has never worked for exactly
this reason. The order matters and the script handles it: the bundling step it
calls re-signs with the ORIGINAL entitlements, which puts the restricted VPN
key back, so the script strips the extension and re-signs with the NoVpn
entitlements afterwards, then fails outright if `codesign` still reports the
`networkextension` key. Keeping that key on an ad-hoc signature does not
produce a warning — the process is killed at launch.

Outputs:

- debug: `build/macos/Build/Products/Debug/xveil.app`;
- release: `build/macos/Build/Products/Release/xveil.app`.

The bundling step is mandatory. It copies both Rust libraries into
`Contents/Frameworks`, verifies that `veilclient-ffi` contains the embedded-node
API, and re-signs the application with the original Flutter entitlements. If
present it also bundles the three optional libraries — call media, Whisper and
translation — and reports each one it did not find, because "this build has no
translation" is a thing to learn here rather than from a button that does
nothing. See the sections on those three below; none of them is built by a
plain macOS build.
The helper uses an ad-hoc signature for local execution. A distributable macOS
artifact must be signed with the project's Developer ID certificate and
notarized after the bundling step.

### Android

Install the native targets once:

```sh
cargo install cargo-ndk --locked
rustup target add aarch64-linux-android armv7-linux-androideabi \
  x86_64-linux-android i686-linux-android
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/<installed-version>"
```

Use the actual NDK path reported by Android Studio or your SDK installation.
On Linux and Windows the path will be different.

Prepare the hidden-volume libraries, then build the application:

```sh
scripts/build-mobile.sh android
(cd third_party/hidden-volume && ./scripts/build-android.sh)
flutter build apk --debug
```

Release APK or Android App Bundle:

```sh
(cd third_party/hidden-volume && ./scripts/build-android.sh)
flutter build apk --release
# or
flutter build appbundle --release
```

The veil Gradle plugin builds and packages `veilclient-ffi` for all four ABIs
automatically. The hidden-volume script stages its four `.so` files into the
Flutter plugin before Gradle runs.

Release signing is read from the gitignored `android/key.properties`:

```properties
storePassword=<keystore password>
keyPassword=<key password>
keyAlias=<key alias>
storeFile=<absolute path to the keystore>
```

Without this file, `flutter build ... --release` deliberately falls back to the
debug key and prints a warning. Such an artifact is suitable for local testing
only and must not be distributed.

Typical outputs:

- `build/app/outputs/flutter-apk/app-debug.apk`;
- `build/app/outputs/flutter-apk/app-release.apk`;
- `build/app/outputs/bundle/release/app-release.aab`.

### iOS device

iOS builds require macOS and Xcode. Install the Rust targets once:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

**There is one iOS build shape, and it includes the VPN.** The Runner target
depends on the `PacketTunnel` app extension and embeds it, `veilclient-ffi` is
always built with the `packet-tunnel` cargo feature, and
`ios/Runner/Runner.entitlements` requests
`com.apple.developer.networking.networkextension` in every configuration.
Unlike macOS there is **no** `NoVpn` entitlements file for iOS and no script
that strips the extension, so there is no "iOS without the VPN capability"
variant to choose. The only thing you can build without that entitlement is an
**unsigned** app, which cannot be installed on a device — see below.

Before the first build, stage the native libraries. This step is not optional
and it is the expensive one:

```sh
scripts/build-mobile.sh ios
(cd ios && pod install)
flutter build ios --release
```

`scripts/build-mobile.sh ios` builds `veilclient-ffi` for the device slice and
then calls `veil_media/ios/build_veil_media_ios.sh`, which **builds the call
engine from a from-source WebRTC checkout**. It expects one at `WEBRTC_ROOT`
(default `~/Projects/veilnetwork/webrtc-checkout`) with `depot_tools` beside
it, and exits immediately if `gn`, `autoninja` or the checkout's bundled clang
is missing. On a machine that has never built WebRTC this is hours and tens of
gigabytes, and there is no prebuilt iOS engine published anywhere to download
instead — see [Call media engine](#call-media-engine-webrtc). Skipping the step
does not degrade gracefully: the staged archives are gitignored, and both the
`veil_media` pod and the PacketTunnel target `-force_load` them, so the link
fails on a missing path.

Open `ios/Runner.xcworkspace` in Xcode first to select a development team
(Xcode → Runner → Signing & Capabilities); the project pins no
`DEVELOPMENT_TEAM`. Because the Network Extension capability is what must be
provisioned, a team that cannot carry that entitlement cannot sign this app —
the same wall `scripts/build-macos-adhoc.sh` documents on the macOS side, where
the answer was to drop the entitlement. That answer does not exist here.

Without provisioning profiles the only path is an unsigned build, which is what
`./builder.py ios` falls back to on such a machine:

```sh
flutter build ios --release --no-codesign
```

That compiles and links everything, including the extension, and produces a
bundle that **cannot be installed on a device**. It is a compile check, not a
build you can run.

Output: `build/ios/iphoneos/Runner.app`.

### iOS Simulator

On Apple Silicon use the repository helper:

```sh
scripts/build-ios-simulator.sh
```

Output: `build/ios/iphonesimulator/Runner.app`.

The helper builds the production dependency graph, including `mobile_scanner 7`
and its Apple Vision implementation; dependency overrides are rejected so a
simulator-only scanner cannot accidentally enter a verified build. It also
checks that the resulting Runner contains an ARM64 slice. Device and simulator
`veilclient-ffi` slices share one staging path, so rerun
`scripts/build-mobile.sh ios` before the next physical-device build.

### Linux

The Linux CMake integration bundles both native `.so` files into the Flutter
application automatically. In-chat video uses the distribution's libmpv rather
than bundling a second codec stack. On Debian/Ubuntu, prepare the build host with
`apt install libmpv-dev`; deployed systems need `libmpv2`.

**A clean checkout cannot complete this build.** The prebuilt call engine
`libveil_media.so` is gitignored, and `veil_media/linux/CMakeLists.txt` raises a
CMake `FATAL_ERROR` when it is absent rather than producing a bundle that
throws at the first voice message. Stage it first — see
[Call media engine](#call-media-engine-webrtc) for where to get one — then:

```sh
scripts/build-native.sh --release
flutter build linux --release
```

Output: `build/linux/<architecture>/release/bundle/`.

For a debug build, omit `--release` from the native script and use
`flutter build linux --debug`; the native and Flutter profiles must match.

On-device voice transcription is optional and built separately; see
[On-device speech-to-text](#on-device-speech-to-text-whispercpp) below.

### Windows

The hidden-volume Windows plugin has automatic DLL bundling. The veil client
DLL still requires a manual staging step. The system-VPN engine is different:
the Windows CMake build invokes `scripts/stage-windows-vpn.ps1`, builds
`veil-vpn-helper`, and stages both `veil_vpn_helper.dll` and the official
signed `wintun.dll` selected from the locked Cargo package.

As on Linux, a clean checkout cannot finish this build: `veil_media.dll` is a
gitignored prebuilt and `veil_media/windows/CMakeLists.txt` raises a CMake
`FATAL_ERROR` without it. Stage it first — see
[Call media engine](#call-media-engine-webrtc).

Run these commands from a Developer PowerShell:

```powershell
cargo build --manifest-path third_party\hidden-volume\Cargo.toml `
  -p hidden-volume-ffi --release
New-Item -ItemType Directory -Force `
  third_party\hidden-volume\experimental\flutter_plugin\hidden_volume\windows\lib
Copy-Item third_party\hidden-volume\target\release\hidden_volume_ffi.dll `
  third_party\hidden-volume\experimental\flutter_plugin\hidden_volume\windows\lib\

cargo build --manifest-path third_party\veil\Cargo.toml `
  -p veilclient-ffi --release --features node-embedded,production-seeds
flutter build windows --release
Copy-Item third_party\veil\target\release\veilclient_ffi.dll `
  build\windows\x64\runner\Release\
```

Output: `build\windows\x64\runner\Release\`.

Keep `veilclient_ffi.dll`, `veil_vpn_helper.dll`, `wintun.dll`, and the
hidden-volume DLL beside `xveil.exe` when redistributing the directory. Keep
`WINTUN-LICENSE.txt` in the same distribution. The VPN requests UAC only when
the user starts it; the elevated copy is the same `xveil.exe`, owns ActiveStore
routes for the tunnel lifetime, and exits after rollback. Verify a fresh
extracted bundle and the VPN start/stop rollback on a clean Windows machine
before distribution.

### Call media engine (WebRTC)

Voice messages, video notes, in-chat video, calls and speech-to-text all load
one native library — `libveil_media` — and **this repository does not build
it**. It is a prebuilt, produced from a from-source WebRTC checkout: hours of
compilation and tens of gigabytes on disk (~33 GB for the checkout alone),
which is why neither `builder.py` nor the release job attempts it.

It is gitignored on every platform, so **a fresh clone has none**, and what
happens next is not the same everywhere:

| Platform | A clean checkout, with no engine |
|---|---|
| Linux | `flutter build linux` **stops at CMake configure** — `veil_media/linux/CMakeLists.txt` raises `FATAL_ERROR` |
| Windows | `flutter build windows` **stops at CMake configure** — the same `FATAL_ERROR` in `veil_media/windows/CMakeLists.txt` |
| iOS | the CocoaPods link **fails** — `veil_media.podspec` `-force_load`s four archives that are not there. `builder.py ios` refuses earlier, with a clearer message |
| Android | a **debug** APK builds and installs, and throws `library libveil_media.so not found` at the first voice message. `builder.py` refuses a **release** build |
| macOS | the build **succeeds** without it. `scripts/bundle-macos-dylibs.sh` prints that it is bundling without calls-media |

So on Linux, Windows and iOS the engine is effectively required to produce any
build at all; only macOS degrades quietly, and only Android lets a debug build
through.

**Where the prebuilts come from.** Two workflows in `.github/workflows/` build
the engine and upload it as a run artifact — `webrtc-linux.yml` (producing
`libveil_media-linux-x64` and `libveil_media-android-arm64`) and
`webrtc-windows.yml` (producing `libveil_media-win-x64`). Both pin the WebRTC
revision itself in `WEBRTC_PIN`. `release.yml` then pins the *run id* it
downloads each artifact from, and checks the result against the symbols the
Dart layer looks up before building anything with it.

For a local build on those three targets, the cheapest route is the same
download, given an authenticated `gh`:

```sh
# linux-x64 — the id is the ENGINE_RUN pinned in .github/workflows/release.yml
gh run download <ENGINE_RUN> -n libveil_media-linux-x64 \
  -D third_party/veil/flutter/veil_media/linux
bash scripts/check-media-symbols.sh \
  third_party/veil/flutter/veil_media/linux/libveil_media.so
```

The same shape works for `libveil_media-android-arm64` into
`android/app/src/main/jniLibs/arm64-v8a` and `libveil_media-win-x64` into
`third_party/veil/flutter/veil_media/windows`. Run
`scripts/check-media-symbols.sh` afterwards either way: a stale engine links
and then fails at `dlsym` on the first call, which is a much worse place to
find out.

**When the pinned run has expired.** GitHub deletes run artifacts after its
retention window, so a pin that worked last month can start returning 404 —
this is expected, not a broken repository. There is no way to recover the
artifact from an expired run. Re-run the workflow that produces it
(`webrtc-linux` or `webrtc-windows`) from the Actions tab, take the new run id,
and update `ENGINE_RUN` in `release.yml`. The runs pinned there today are from
late July and August 2026, so they lapse in the autumn.

**Apple platforms have no published artifact at all.** Neither workflow builds
a macOS or iOS engine, so there is nothing to download and the only route is
from source, against a WebRTC checkout:

```sh
# macOS
WEBRTC_SRC=~/Projects/veilnetwork/webrtc-checkout/src WEBRTC_OUT=out/mac-arm64 \
  third_party/veil/flutter/veil_media/macos/build_veil_media_dylib.sh

# iOS — invoked for you by scripts/build-mobile.sh ios, see the iOS section
WEBRTC_ROOT=~/Projects/veilnetwork/webrtc-checkout \
  third_party/veil/flutter/veil_media/ios/build_veil_media_ios.sh [--sim]
```

Both need `WEBRTC_ROOT`/`WEBRTC_SRC` to name a checkout that has already been
built with `gn`/`ninja`, plus `depot_tools` beside it — the iOS script uses
`$WEBRTC_ROOT/depot_tools/gn` and the WebRTC checkout's own bundled clang, and
exits immediately if either is missing. Producing that checkout is the hours
and tens of gigabytes described above; this repository does not automate it.
`webrtc-linux.yml` is the most complete worked example of the `fetch`/`gclient
sync`/`gn gen` sequence, and `third_party/veil/flutter/veil_media/BUILD-INTEGRATION.md`
records the codec-stripped GN args.

### On-device speech-to-text (whisper.cpp)

Voice transcription runs locally on whisper.cpp, wrapped in a small library
called `veil_whisper`. It is **optional on every platform**: absent, the
Transcribe affordance stays hidden and nothing else changes. It is a build
artifact, gitignored, so a fresh clone has none.

One prerequisite, shared by all four scripts: a whisper.cpp checkout, upstream
rather than a fork.

```sh
git clone https://github.com/ggml-org/whisper.cpp
```

**The revision is pinned and the pin is enforced.** `native/whisper/whisper_pin.sh`
holds `WHISPER_PIN`, every build script sources it, and a checkout at any other
commit — or one that is not a git checkout at all — makes the script exit
before it builds anything. That is deliberate: it refuses rather than checking
out over your working tree. Either move the checkout to the pin, or say
explicitly that you are building from something else:

```sh
git -C "$WHISPER_SRC" fetch origin && git -C "$WHISPER_SRC" checkout <WHISPER_PIN>
WHISPER_ALLOW_UNPINNED=1 native/whisper/build_veil_whisper_<platform>.sh   # or this
```

`WHISPER_SRC` points at the checkout and its default is not the same on every
platform, so it is worth setting explicitly. `WHISPER_BUILD_DIR` overrides where
the whisper.cpp build tree goes.

```sh
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_macos.sh    # native/whisper/Frameworks/libveil_whisper.dylib
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_linux.sh    # native/whisper/linux/libveil_whisper.so
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_android.sh  # android/app/src/main/jniLibs/arm64-v8a/
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_windows.sh  # native/whisper/windows/veil_whisper.dll
```

The Linux and Windows scripts configure and build whisper.cpp's static CPU
libraries themselves when they are missing; the macOS and Android scripts
expect them already built, and each script's header comment gives the exact
cmake line it wants. The Windows one is bash, not PowerShell — run it under Git
Bash with the MSVC environment already set, which is what `builder.py` does.
Android additionally needs `ANDROID_NDK_HOME`.

`./builder.py <target>` runs the right script for the target as an optional
step, so a failure here does not stop the app from building.

The ggml model is **not** bundled — it is 57 MiB, it does not compress, and
most people never transcribe anything, so the app downloads it on demand and
keeps it once for the whole app (in the support directory, shared by every
profile), verifying a pinned size and SHA-256. Nothing needs staging for that
to work.

For a build that must install without a network, put the model next to the
built library and set `XVEIL_BUNDLE_WHISPER_MODEL=1` — the opt-in Linux,
Android and macOS share. `XVEIL_WHISPER_MODEL` still points at a model
anywhere, and `XVEIL_WHISPER_MODEL_URL` changes where the download comes from
(the default is the canonical whisper.cpp distribution, fetched over plain
HTTPS from the person's own address — worth knowing in this app).

### On-device translation

Message translation runs locally on CTranslate2 with an OPUS-MT model. Upstream
CTranslate2 does not support Android or iOS — the request has been open since
2024 — so the engine is built from the fork at
`https://github.com/veilnetwork/CTranslate2`, whose `mobile/` scripts add
nothing but the right flags. No C++ was changed to make it build; see
`mobile/README.md` there for which defaults are wrong for a phone and why.

Translation is **optional** on every platform. Without the wrapper library the
provider returns null and no translation affordance appears; nothing else in
the app changes and no build fails.

Prerequisites, both out-of-repo checkouts beside this one:

- `CTranslate2` (the fork, `https://github.com/veilnetwork/CTranslate2`) —
  `mobile/build-android.sh`, `mobile/build-ios.sh`, and for the host a static
  build with `BUILD_SHARED_LIBS=OFF`.
- `sentencepiece` (upstream, `https://github.com/google/sentencepiece`) — the
  tokeniser. Cross-compiling it needs `SPM_PROTOC_EXECUTABLE` pointing at a
  protoc that runs on the BUILD machine; without it the build makes a protoc
  for the target and tries to run it here, which fails as an unexplained
  "Error 126". iOS additionally needs `native/translate/cmake/ios_shim.cmake`
  injected with `CMAKE_PROJECT_INCLUDE_BEFORE`.

Every script finds those checkouts through the same four variables, so a tree
laid out differently needs no edits:

| Variable | Default | What it points at |
|---|---|---|
| `CT2_SRC` | `~/Projects/veilnetwork/CTranslate2` (`~/CTranslate2` on Windows) | the fork's checkout |
| `SPM_SRC` | `~/Projects/veilnetwork/sentencepiece` (`~/sentencepiece` on Windows) | the SentencePiece checkout |
| `CT2_BUILD` | `$CT2_SRC/build-<platform>` | where CTranslate2 was built |
| `SPM_BUILD` | `$SPM_SRC/build-<platform>` | where SentencePiece was built |

Each script names the exact build directory and cmake flags it expects in its
own header comment; those headers are the reference, because they are what the
script actually checks for. `VEIL_TRANSLATE_TEST_MODEL` points at a converted
model directory — set it and the script proves the library translates instead
of only proving it linked.

Then build the wrapper — one library holding the engine, the tokeniser and a
small C ABI, so a translation feature arrives as one file rather than a set
that can turn up incomplete:

```bash
native/translate/build_veil_translate_macos.sh          # native/translate/Frameworks/libveil_translate.dylib
native/translate/build_veil_translate_android.sh        # android/app/src/main/jniLibs/arm64-v8a/ (+ libomp.so)
native/translate/build_veil_translate_ios.sh            # libveil_translate.a       (device)
native/translate/build_veil_translate_ios.sh --simulator # libveil_translate-sim.a  (Simulator)
native/translate/build_veil_translate_linux.sh          # native/translate/linux/libveil_translate.so
```

On Windows the script is PowerShell and wants a Developer PowerShell, because
it drives `cl.exe`, `link.exe` and `dumpbin.exe` directly:

```powershell
native\translate\build_veil_translate_windows.ps1       # native\translate\windows\veil_translate.dll
```

Each verifies what it produced — architecture, exported entry points, and for
iOS the PLATFORM, because a macOS archive is arm64 too and fails only on a
device. The Android script also runs its selftest ON a connected phone when
one is attached and `VEIL_TRANSLATE_TEST_MODEL` names a model directory.

The iOS script builds its own prerequisites when they are missing, including
the SentencePiece cross build — that invocation lives in the script rather than
in the SentencePiece checkout, which is pristine upstream and cannot carry a
reference to a shim file in this repo.

**The Simulator is a separate build, not a second architecture.** An arm64
device slice and an arm64 Simulator slice are the same instruction set and
different platforms in the Mach-O load commands (2 = iOS, 7 = iOS Simulator).
The linker refuses to mix them and `lipo` cannot fuse them, so there are two
archives and each is checked against the platform it claims — a check that only
asks "is this iOS" passes on the wrong one. One consequence worth knowing: the
arm64 Simulator did not exist before iOS 14, so the toolchain raises a 13.0
request to 14.0 and the verifier expects that floor rather than the number it
asked for.

Each platform's wrapper lands where that platform's packaging already looks,
and nothing has to be staged by hand: `linux/CMakeLists.txt` installs
`native/translate/linux/libveil_translate.so` into the bundle's `lib/` when it
exists, `builder.py`'s Windows target copies
`native/translate/windows/veil_translate.dll` next to the runner, the Android
script writes straight into the APK's `jniLibs`, and
`scripts/bundle-macos-dylibs.sh` copies the dylib into `Contents/Frameworks`.
Each of those is guarded by "if it exists", so a platform whose wrapper has not
been built produces a working app with no translation rather than a failure.

The iOS link is done through a GENERATED xcconfig, and the reason is that it
had to TOLERATE THE ARCHIVE BEING ABSENT. The obvious move — an `-force_load`
entry in the Runner target's OTHER_LDFLAGS, the way PacketTunnel links
libveilclient_ffi.a — breaks the build outright for anyone who has not produced
the prebuilt, and translation is optional where veilclient is mandatory. So the
build script writes `ios/Flutter/TranslateLink.xcconfig` and Runner's Debug and
Release configs pull it in with `#include?`, the optional form Xcode skips in
silence when the file is not there. The `-force_load` itself is not optional —
nothing in the app's own code calls these symbols, Dart resolves them out of
the process image, and a plain link drops every one of them.

The file selects the archive by SDK, and only the SDKs whose archive is
actually on disk get any flags:

```
VEIL_TRANSLATE_LDFLAGS =                                  // base: nothing
VEIL_TRANSLATE_ARCHIVE[sdk=iphoneos*]        = …/libveil_translate.a
VEIL_TRANSLATE_ARCHIVE[sdk=iphonesimulator*] = …/libveil_translate-sim.a
OTHER_LDFLAGS = $(inherited) $(VEIL_TRANSLATE_LDFLAGS)
```

Building only one of the two is therefore harmless: the other SDK falls through
to the empty base and links a working app with no translation. Naming an
archive that is not there would be worse than saying nothing, because
`-force_load` on a missing path is a hard link error — the half-built tree
would break the build it was supposed to leave alone. The file is rewritten
from what is on disk on every run, so building one archive never un-links the
other.

Confirm the result in the PRODUCT rather than the build log, because every way
this has gone wrong so far was invisible from the exit code:

```bash
scripts/check-ios-translate-link.sh --simulator   # build/ios/iphonesimulator/Runner.app
scripts/check-ios-translate-link.sh --device      # build/ios/iphoneos/Runner.app
```

It reads the export trie — the table `dlsym` consults, not the static symbol
table a release build strips — and reports which platform the bundle it opened
was built for, since a stale device app sits in its own directory after a
Simulator build and would otherwise answer for it.

Models are **not** bundled and none are published yet. Convert a pair with
`native/translate/convert-model.sh <from> <to>` (needs a Python environment
with `ctranslate2`, `transformers` and `torch`; ~870 MB of wheels, host-side
only). It prints the catalogue entry — real sizes and SHA-256 read back from
the files it just wrote. A person installs a converted pair from Settings, or
receives one in a chat as a `.veiltranslate`.

### Verification

Fast Flutter checks:

```sh
flutter analyze
flutter test
```

On macOS, run the Flutter suite against the freshly built native libraries with:

```sh
scripts/build-native.sh
VEIL_FFI_DYLIB="$PWD/third_party/veil/target/debug/libveilclient_ffi.dylib" \
XVEIL_HV_DYLIB="$PWD/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib" \
flutter test
```

Native smoke checks:

```sh
cargo test --manifest-path third_party/veil/Cargo.toml \
  -p veilclient-ffi --features node-embedded
cargo test --manifest-path third_party/hidden-volume/Cargo.toml --workspace
```

If a Finder-launched macOS build opens a fake store, rerun
`scripts/bundle-macos-dylibs.sh` with the matching profile. If iOS reports a
wrong-architecture linker error, rebuild the correct device or simulator slice.
If Android cannot find a linker or target, verify `ANDROID_NDK_HOME`,
`cargo-ndk`, and all four Rust targets.

---

## Русский

### Схема сборки

xVeil — Flutter-приложение с двумя нативными зависимостями на Rust:

- `veilclient-ffi` предоставляет клиент overlay-сети veil и встроенный узел;
- `hidden-volume-ffi` предоставляет отрицаемое зашифрованное хранилище.

Обычная Flutter-сборка подходит для работы над интерфейсом, но полноценная
сборка должна содержать обе нативные библиотеки. Если явно не указано обратное,
все команды ниже выполняются из корня репозитория xVeil.

### Коротко

Две точки входа покрывают все цели с хоста Windows, Linux или macOS:

```sh
./prepare.py [target]     # довести чистую машину до состояния «можно собирать»
./builder.py [target]     # нативные библиотеки и само приложение
```

`target` по умолчанию — система самой машины; допустимы `android`, `linux`,
`windows`, `macos`, `ios`. `--debug` даёт отладочную сборку, `--dry-run`
печатает план и ничего не выполняет — в том числе для цели, которую этот хост
собрать не может, так что план для Windows можно посмотреть с мака.

`prepare.py` ставит Rust и кросс-цели, cargo-ndk, командные инструменты
Android и NDK, системные пакеты Linux, CocoaPods, git-подмодули с нативными
библиотеками и пакеты Dart. Для того, что требует принятия лицензии или
десятков гигабайт — сам Flutter, Xcode, Visual Studio — он останавливается и
называет точную команду: запускать такое без спроса, потому что человек ввёл
одно слово, хуже, чем спросить. Повторный запуск безопасен: скрипт сообщает,
что уже сделано.

`builder.py` вызывает скрипты, описанные ниже, а не заменяет их — поэтому
разделы по платформам остаются источником правды о происходящем, а всё
нестандартное (выкладка одной DLL, обход подписи) по-прежнему можно выполнить
руками.

### С нуля

`prepare.py` намеренно останавливается на всём, что требует согласия с
лицензией или десятков гигабайт. Этот раздел — что делать, когда он
остановился. Один раз выполняете это, дальше `prepare.py` доделывает остальное.

**Диск.** Закладывайте ~100 ГБ, если собираетесь работать итеративно: основная
статья — debug-деревья Rust (один veil дорастает до ~22 ГБ), и каждая новая
платформа добавляет своё. Разовая сборка требует заметно меньше, но `cargo
clean` придётся звать часто.

**macOS — Xcode.** Одних command-line tools для сборок под macOS и iOS
недостаточно, нужен полный Xcode.

```sh
xcode-select --install                       # command-line tools
# затем сам Xcode из App Store (~10 ГБ), и:
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

`xcode-select -s` здесь существен: если выбраны только command-line tools,
Flutter сообщает, что Xcode отсутствует, хотя он установлен.

**macOS — остальное.**

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask flutter          # либо скачать SDK и добавить bin/ в PATH
brew install cocoapods
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

**Android, на любом хосте.** Проще всего через Android Studio — он ставит SDK,
NDK и JDK разом. Без него: поставьте JDK 17 и command-line tools, а пакеты SDK
докачает `prepare.py android`. Перед запуском укажите `ANDROID_HOME` на SDK
(`~/Library/Android/sdk` на macOS, `~/Android/Sdk` на Linux).

**Windows.** Visual Studio с нагрузкой *Desktop development with C++* — одних
Build Tools для `flutter build windows` не хватает. Git for Windows даёт bash,
который нужен `builder.py` для обёртки whisper.

**Linux.** Здесь всё ставится пакетами; `prepare.py` знает списки для apt, dnf,
pacman и zypper. Для семейства Debian это:

```sh
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libstdc++-12-dev libayatana-appindicator3-dev \
  unzip curl git
```

Этот список — ровно то, что ставит `prepare.py`. **`libmpv-dev` в него не
входит**, а он нужен для видео в чате, поэтому поставьте его отдельно:

```sh
sudo apt-get install -y libmpv-dev
```

Официального архива Flutter под linux-arm64 не существует: на ARM-машине
клонируйте SDK (`git clone -b stable https://github.com/flutter/flutter.git`) —
инструмент подтянет arm64-сборку Dart SDK и заработает. Учтите, что дальше
linux-arm64 упирается в более серьёзную проблему: прибилт движка звонков
публикуется только под linux-**x64**, а без него Linux-сборка не проходит
configure. См. «Движок звонков».

**Дальше — одинаково для всех хостов:**

```sh
git clone --recurse-submodules https://github.com/veilnetwork/xVeil.git
cd xVeil
./prepare.py            # или: ./prepare.py android|ios|linux|windows|macos
flutter doctor -v       # для вашей цели не должно остаться блокирующих пунктов
./builder.py
```

**Подпись — только для платформ Apple.** Обе Apple-цели содержат расширение
packet-tunnel, и приложение вместе с расширением просят
`com.apple.developer.networking.networkextension` — ограниченное право, которому
нужен provisioning-профиль, а профилю нужна учётная запись Apple Developer. Из
этого следует всё остальное, поэтому сначала прочитайте разделы macOS и iOS
ниже: для macOS обход описан, а для iOS **его нет**. Ни одна из Apple-целей не
публикуется через CI намеренно — без подписи артефакт всё равно никто не сможет
запустить, — так что на платформах Apple вы собираете локально и для себя.

### Требования

Общие требования:

- Git с поддержкой submodule;
- стабильный Flutter. Сейчас проверена связка Flutter 3.44.0 и Dart 3.12.0;
  `pubspec.yaml` требует Dart 3.12 или новее;
- стабильный Rust. Сейчас проверен Rust 1.97.0;
- платформенный toolchain, который проверяет `flutter doctor -v`.

Дополнительные требования:

- macOS/iOS: актуальные Xcode Command Line Tools и CocoaPods;
- Android: Android SDK, Android NDK, JDK 17, `cargo-ndk` и четыре Android target
  для Rust;
- Linux: зависимости Flutter Desktop для Linux, включая CMake, Ninja,
  заголовочные файлы GTK и системный пакет разработки libmpv (`libmpv-dev` в
  Debian/Ubuntu); на компьютере пользователя нужен runtime-пакет libmpv
  (`libmpv2` в Debian/Ubuntu);
- Windows: Visual Studio с workload «Desktop development with C++» и Windows
  SDK.

Клонирование и подготовка:

```sh
git clone --recurse-submodules git@github.com:veilnetwork/xVeil.git
cd xVeil
git submodule update --init --recursive
flutter doctor -v
flutter pub get
```

Не заменяйте зафиксированные ревизии submodule произвольными ветками: xVeil
тестируется с конкретными коммитами `third_party/veil` и
`third_party/hidden-volume`, записанными в родительском репозитории.

### Материалы production-сети

Адреса production seed-узлов встраиваются в release-сборки, но общий obfs4 PSK
конкретного развёртывания намеренно не хранится в Git. Перед сборкой дистрибутива
поместите ключ сюда:

```text
assets/prod/obfs4_psk.b64
```

Не коммитьте и не публикуйте этот файл. Сборка без него завершится, но
встроенный узел не сможет подключиться к production seed-узлам через obfs4 и
может перейти в режим разработки, непригодный для production-сети.

### macOS

**Коротко — и начинать стоит с этого:**

```sh
./builder.py macos             # --debug для отладочной сборки
```

`builder.py` сам выбирает путь под машину, на которой запущен. Он смотрит
provisioning-профили в `~/Library/MobileDevice/Provisioning Profiles`; если их
нет — молча уходит на ad-hoc-путь, описанный ниже, и сообщает об этом. Дальше
он собирает нативные библиотеки, необязательную обёртку whisper, укладывает
dylib'ы и в конце проверяет РЕЗУЛЬТАТ: что обе обязательные библиотеки лежат в
`Contents/Frameworks`, называя каждую отсутствующую необязательную вместе с
функцией, которая с ней пропала. Ради этой проверки его и стоит предпочесть:
бандл может собраться успешно и всё равно остаться без библиотеки, которой
нужна функция.

Проверка профилей — эвристика: спрашивается, есть ли хоть что-то в том
каталоге, а не подходит ли профиль этому приложению. Машина с чужими профилями
от другого проекта уйдёт на путь с подписью и упадёт на ней — тогда запускайте
ad-hoc-скрипт руками.

**Что получается и что с этим можно делать.** Локальная сборка годится для
запуска на той машине, где сделана. Раздавать её нельзя: без Developer ID её
не нотаризовать, поэтому на чужом маке Gatekeeper откажется её открывать, пока
получатель не выполнит `xattr -dr com.apple.quarantine /Applications/xveil.app`
— команду, которая снимает проверку, не дающую запустить неопознанное
приложение, и просить о ней походя не стоит. Именно поэтому macOS намеренно не
публикуется. Для настоящей раздачи нужен Developer ID и обычная подписанная
сборка.

**Руками**, если нужны отдельные шаги. Debug-сборка:

```sh
scripts/build-native.sh
flutter build macos --debug
scripts/bundle-macos-dylibs.sh debug
```

Release-сборка:

```sh
scripts/build-native.sh --release
flutter build macos --release
scripts/bundle-macos-dylibs.sh release
```

**Без аккаунта Apple Developer обе команды выше падают** — и debug тоже, не
только release. Приложение и расширение PacketTunnel просят
`com.apple.developer.networking.networkextension`, а это ограниченное право:
ему нужен provisioning-профиль, который без аккаунта не выпустить. Всё
компилируется и падает на подписи. Вместо этого:

```sh
scripts/build-native.sh          # --release для релизной сборки
scripts/build-macos-adhoc.sh debug     # или: release
```

Скрипт подписывает ad-hoc по `{Debug,Release}NoVpn.entitlements` и удаляет из
бандла уже собранный `PlugIns/PacketTunnel.appex`, поэтому VPN в результате
нет — сегодня это ничего не стоит, потому что macOS-VPN ровно по этой причине
никогда и не работал. Порядок здесь важен, и скрипт его соблюдает: вызываемый
им шаг bundling переподписывает ИСХОДНЫМИ entitlements и тем самым возвращает
ограниченное право VPN обратно, поэтому расширение выбрасывается и подпись
переделывается по NoVpn уже после него, а затем скрипт падает, если `codesign`
всё ещё показывает `networkextension`. Оставленное при ad-hoc подписи, это
право не даёт предупреждения — процесс убивают при запуске.

Результаты:

- debug: `build/macos/Build/Products/Debug/xveil.app`;
- release: `build/macos/Build/Products/Release/xveil.app`.

Шаг bundling обязателен. Он копирует обе Rust-библиотеки в
`Contents/Frameworks`, проверяет наличие API встроенного узла и повторно
подписывает приложение с исходными Flutter entitlements. При наличии
добавляются и три необязательные библиотеки — звонки, Whisper и перевод, — а
про каждую ненайденную он сообщает: «в этой сборке нет перевода» лучше узнать
здесь, чем от кнопки, которая ничего не делает. Ни одна из трёх обычной
сборкой macOS не собирается — см. разделы про них ниже.
Скрипт использует ad-hoc подпись для локального запуска. Дистрибутив macOS нужно
после bundling подписать сертификатом Developer ID проекта и нотариализовать.

### Android

Один раз установите необходимые target:

```sh
cargo install cargo-ndk --locked
rustup target add aarch64-linux-android armv7-linux-androideabi \
  x86_64-linux-android i686-linux-android
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/<installed-version>"
```

Используйте реальный путь к NDK из Android Studio или вашего Android SDK. В
Linux и Windows путь будет отличаться.

Подготовьте библиотеки hidden-volume и соберите приложение:

```sh
scripts/build-mobile.sh android
(cd third_party/hidden-volume && ./scripts/build-android.sh)
flutter build apk --debug
```

Release APK или Android App Bundle:

```sh
(cd third_party/hidden-volume && ./scripts/build-android.sh)
flutter build apk --release
# или
flutter build appbundle --release
```

Gradle-плагин veil автоматически собирает и упаковывает `veilclient-ffi` для
всех четырёх ABI. Скрипт hidden-volume заранее помещает четыре `.so` в Flutter-
плагин.

Параметры release-подписи читаются из игнорируемого Git файла
`android/key.properties`:

```properties
storePassword=<пароль хранилища>
keyPassword=<пароль ключа>
keyAlias=<алиас ключа>
storeFile=<абсолютный путь к keystore>
```

Без этого файла `flutter build ... --release` намеренно использует debug-ключ и
показывает предупреждение. Такой артефакт предназначен только для локальной
проверки и не должен распространяться.

Основные результаты:

- `build/app/outputs/flutter-apk/app-debug.apk`;
- `build/app/outputs/flutter-apk/app-release.apk`;
- `build/app/outputs/bundle/release/app-release.aab`.

### Физическое устройство iOS

Для iOS необходимы macOS и Xcode. Один раз установите Rust target:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

**Вариант сборки под iOS ровно один, и он с VPN.** Цель Runner зависит от
расширения `PacketTunnel` и встраивает его, `veilclient-ffi` всегда собирается
с cargo-фичей `packet-tunnel`, а `ios/Runner/Runner.entitlements` просит
`com.apple.developer.networking.networkextension` во всех конфигурациях. В
отличие от macOS, для iOS **нет** файла entitlements `NoVpn` и нет скрипта,
выбрасывающего расширение, — то есть выбрать «iOS без VPN» негде. Без этого
права собирается только **неподписанное** приложение, которое нельзя поставить
на устройство (см. ниже).

Перед первой сборкой выложите нативные библиотеки. Шаг обязательный, и он же
самый дорогой:

```sh
scripts/build-mobile.sh ios
(cd ios && pod install)
flutter build ios --release
```

`scripts/build-mobile.sh ios` собирает `veilclient-ffi` под срез устройства, а
затем вызывает `veil_media/ios/build_veil_media_ios.sh`, который **собирает
движок звонков из исходного чекаута WebRTC**. Он ждёт чекаут в `WEBRTC_ROOT`
(по умолчанию `~/Projects/veilnetwork/webrtc-checkout`) с `depot_tools` рядом и
завершается сразу, если нет `gn`, `autoninja` или clang из самого чекаута. На
машине, где WebRTC никогда не собирали, это часы и десятки гигабайт, и скачать
готовый iOS-движок неоткуда — см. «Движок звонков». Пропустить шаг не выйдет:
архивы в gitignore, а и pod `veil_media`, и цель PacketTunnel делают по ним
`-force_load`, так что линковка падает на отсутствующем пути.

Откройте `ios/Runner.xcworkspace` в Xcode и выберите Development Team (в
проекте `DEVELOPMENT_TEAM` не задан). Провизионить нужно именно возможность
Network Extension, поэтому команда, которая не может нести это право, подписать
приложение не сможет — та же стена, что описана в
`scripts/build-macos-adhoc.sh` для macOS, где выходом было убрать право. Здесь
такого выхода нет.

Без provisioning-профилей остаётся только неподписанная сборка — на такой
машине `./builder.py ios` сам уходит на неё:

```sh
flutter build ios --release --no-codesign
```

Она компилирует и линкует всё, включая расширение, и даёт бандл, который
**нельзя поставить на устройство**. Это проверка компиляции, а не сборка,
которую можно запустить.

Результат: `build/ios/iphoneos/Runner.app`.

### Симулятор iOS

На Apple Silicon используйте скрипт проекта:

```sh
scripts/build-ios-simulator.sh
```

Результат: `build/ios/iphonesimulator/Runner.app`.

Скрипт собирает production-граф зависимостей, включая `mobile_scanner 7` и его
реализацию на Apple Vision; dependency overrides запрещены, чтобы в проверенную
сборку случайно не попал simulator-only сканер. Также проверяется наличие ARM64
slice в готовом Runner. Device- и simulator-варианты `veilclient-ffi` используют
один путь staging, поэтому перед следующей сборкой для физического устройства
снова выполните `scripts/build-mobile.sh ios`.

### Linux

Linux-интеграция CMake автоматически добавляет обе нативные `.so` в Flutter-
приложение. Для видео в чате используется системный libmpv вместо ещё одного
встроенного набора кодеков. В Debian/Ubuntu установите на машине сборки
`apt install libmpv-dev`; на машинах пользователей нужен `libmpv2`.

**Чистый чекаут эту сборку не доведёт до конца.** Прибилт движка звонков
`libveil_media.so` лежит в gitignore, и `veil_media/linux/CMakeLists.txt`
выдаёт `FATAL_ERROR` при его отсутствии — вместо бандла, который падал бы на
первом голосовом. Сначала выложите движок (см. «Движок звонков» ниже), потом:

```sh
scripts/build-native.sh --release
flutter build linux --release
```

Результат: `build/linux/<architecture>/release/bundle/`.

Для debug-сборки уберите `--release` у нативного скрипта и используйте
`flutter build linux --debug`. Профили Rust- и Flutter-сборки должны совпадать.

Локальная транскрипция голосовых необязательна и собирается отдельно — см.
«Распознавание речи на устройстве» ниже.

### Windows

Windows-плагин hidden-volume умеет автоматически добавлять DLL. Для клиентской
veil DLL пока нужен ручной шаг staging. System VPN собирается иначе: Windows
CMake вызывает `scripts/stage-windows-vpn.ps1`, собирает `veil-vpn-helper` и
автоматически кладёт рядом с приложением `veil_vpn_helper.dll` и официальный
подписанный `wintun.dll` из зафиксированной Cargo-зависимости.

Как и на Linux, чистый чекаут эту сборку не закончит: `veil_media.dll` —
прибилт в gitignore, и `veil_media/windows/CMakeLists.txt` без него выдаёт
`FATAL_ERROR`. Сначала выложите движок — см. «Движок звонков» ниже.

Выполните в Developer PowerShell:

```powershell
cargo build --manifest-path third_party\hidden-volume\Cargo.toml `
  -p hidden-volume-ffi --release
New-Item -ItemType Directory -Force `
  third_party\hidden-volume\experimental\flutter_plugin\hidden_volume\windows\lib
Copy-Item third_party\hidden-volume\target\release\hidden_volume_ffi.dll `
  third_party\hidden-volume\experimental\flutter_plugin\hidden_volume\windows\lib\

cargo build --manifest-path third_party\veil\Cargo.toml `
  -p veilclient-ffi --release --features node-embedded,production-seeds
flutter build windows --release
Copy-Item third_party\veil\target\release\veilclient_ffi.dll `
  build\windows\x64\runner\Release\
```

Результат: `build\windows\x64\runner\Release\`.

При распространении оставляйте рядом с `xveil.exe` `veilclient_ffi.dll`,
`veil_vpn_helper.dll`, `wintun.dll` и DLL hidden-volume, а также включайте
`WINTUN-LICENSE.txt`. VPN запрашивает UAC только при включении: elevated-копия —
это тот же `xveil.exe`, она владеет маршрутами ActiveStore до остановки и
завершается после rollback. Перед публикацией проверьте свежераспакованный
каталог и полный start/stop rollback VPN на чистой Windows-машине.

### Движок звонков (WebRTC)

Голосовые, видеозаметки, видео в чате, звонки и распознавание речи грузят одну
нативную библиотеку — `libveil_media`, — и **этот репозиторий её не собирает**.
Это прибилт, который делается из исходного чекаута WebRTC: часы компиляции и
десятки гигабайт на диске (~33 ГБ на один чекаут), поэтому за него не берутся
ни `builder.py`, ни релизная джоба.

Он в gitignore на всех платформах, то есть **в свежем клоне его нет**, и
дальше платформы ведут себя по-разному:

| Платформа | Чистый чекаут без движка |
|---|---|
| Linux | `flutter build linux` **останавливается на configure** — `FATAL_ERROR` в `veil_media/linux/CMakeLists.txt` |
| Windows | `flutter build windows` **останавливается на configure** — тот же `FATAL_ERROR` |
| iOS | **падает линковка** CocoaPods: `veil_media.podspec` делает `-force_load` четырёх архивов, которых нет |
| Android | **debug**-APK собирается и ставится, а на первом голосовом бросает `library libveil_media.so not found`. `builder.py` отказывает в **release** |
| macOS | сборка **проходит**; `scripts/bundle-macos-dylibs.sh` сообщает, что собрал без медиа звонков |

**Откуда берутся прибилты.** Их собирают воркфлоу `webrtc-linux.yml`
(артефакты `libveil_media-linux-x64` и `libveil_media-android-arm64`) и
`webrtc-windows.yml` (`libveil_media-win-x64`); ревизия самого WebRTC там
закреплена в `WEBRTC_PIN`. `release.yml` закрепляет уже *id прогона*, из
которого качает, и проверяет скачанное по символам, которые ищет Dart.

Локально проще всего скачать то же самое, если `gh` авторизован:

```sh
gh run download <ENGINE_RUN> -n libveil_media-linux-x64 \
  -D third_party/veil/flutter/veil_media/linux
bash scripts/check-media-symbols.sh \
  third_party/veil/flutter/veil_media/linux/libveil_media.so
```

`<ENGINE_RUN>` — это значение из `.github/workflows/release.yml`. Так же
качаются `libveil_media-android-arm64` в
`android/app/src/main/jniLibs/arm64-v8a` и `libveil_media-win-x64` в
`third_party/veil/flutter/veil_media/windows`. Проверку символов делайте в
любом случае: устаревший движок линкуется молча и падает на `dlsym` при первом
звонке.

**Если закреплённый прогон истёк.** GitHub удаляет артефакты прогонов по
истечении срока хранения, поэтому пин, работавший месяц назад, начинает
отдавать 404 — это ожидаемо, а не поломка репозитория. Вернуть артефакт
истёкшего прогона нельзя: перезапустите нужный воркфлоу (`webrtc-linux` или
`webrtc-windows`) со вкладки Actions и пропишите новый id в `ENGINE_RUN`.
Сейчас там закреплены прогоны за конец июля и август 2026 — значит, истекут
осенью.

**Для платформ Apple артефактов нет вообще.** Ни один воркфлоу не собирает
движок под macOS или iOS, качать нечего, и единственный путь — из исходников,
против чекаута WebRTC:

```sh
# macOS
WEBRTC_SRC=~/Projects/veilnetwork/webrtc-checkout/src WEBRTC_OUT=out/mac-arm64 \
  third_party/veil/flutter/veil_media/macos/build_veil_media_dylib.sh

# iOS — вызывается из scripts/build-mobile.sh ios, см. раздел про iOS
WEBRTC_ROOT=~/Projects/veilnetwork/webrtc-checkout \
  third_party/veil/flutter/veil_media/ios/build_veil_media_ios.sh [--sim]
```

Обоим нужен уже собранный чекаут и `depot_tools` рядом с ним; iOS-скрипт берёт
`$WEBRTC_ROOT/depot_tools/gn` и клang из самого чекаута и завершается сразу,
если чего-то из этого нет. Наиболее полный рабочий пример последовательности
`fetch`/`gclient sync`/`gn gen` — в `webrtc-linux.yml`, а GN-аргументы с
урезанными кодеками записаны в
`third_party/veil/flutter/veil_media/BUILD-INTEGRATION.md`.

### Распознавание речи на устройстве (whisper.cpp)

Расшифровка голосовых работает локально на whisper.cpp через небольшую обёртку
`veil_whisper`. Она **необязательна на всех платформах**: без неё кнопка
расшифровки просто не появляется. Это артефакт сборки, он в gitignore, и в
свежем клоне его нет.

Нужен один чекаут — апстрим, не форк:

```sh
git clone https://github.com/ggml-org/whisper.cpp
```

**Ревизия закреплена, и пин проверяется.** В `native/whisper/whisper_pin.sh`
лежит `WHISPER_PIN`, его подключают все четыре скрипта, и чекаут на другом
коммите (или вовсе не git-чекаут) останавливает скрипт до начала сборки. Это
сделано намеренно: он отказывается работать, а не переключает вам рабочее
дерево. Либо переведите чекаут на пин, либо скажите явно, что собираете из
другого:

```sh
git -C "$WHISPER_SRC" fetch origin && git -C "$WHISPER_SRC" checkout <WHISPER_PIN>
WHISPER_ALLOW_UNPINNED=1 native/whisper/build_veil_whisper_<платформа>.sh
```

`WHISPER_SRC` указывает на чекаут, и умолчание у него на разных платформах
разное — задавайте явно. `WHISPER_BUILD_DIR` меняет каталог сборки whisper.cpp.

```sh
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_macos.sh    # native/whisper/Frameworks/libveil_whisper.dylib
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_linux.sh    # native/whisper/linux/libveil_whisper.so
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_android.sh  # android/app/src/main/jniLibs/arm64-v8a/
WHISPER_SRC=~/whisper.cpp native/whisper/build_veil_whisper_windows.sh  # native/whisper/windows/veil_whisper.dll
```

Скрипты для Linux и Windows при отсутствии статических CPU-библиотек
whisper.cpp конфигурируют и собирают их сами; macOS- и Android-скрипты ждут их
готовыми, и точную строку cmake каждый называет в своей шапке. Windows-скрипт —
на bash, а не на PowerShell: запускать из Git Bash с уже настроенным окружением
MSVC, как это делает `builder.py`. Android дополнительно требует
`ANDROID_NDK_HOME`.

`./builder.py <цель>` запускает нужный скрипт как необязательный шаг, поэтому
неудача здесь не останавливает сборку приложения.

Ggml-модель **не вшивается**: она весит 57 МиБ, не сжимается, а расшифровкой
пользуются немногие — поэтому приложение скачивает её по требованию и хранит
один раз на всё приложение (в каталоге поддержки, общем для всех профилей),
сверяя закреплённые размер и SHA-256. Готовить для этого ничего не нужно.

Для сборки, которая должна ставиться без сети, положите модель рядом с
собранной библиотекой и задайте `XVEIL_BUNDLE_WHISPER_MODEL=1` — тот же флаг,
что у Linux, Android и macOS. `XVEIL_WHISPER_MODEL` по-прежнему указывает на
модель в любом месте, а `XVEIL_WHISPER_MODEL_URL` меняет адрес загрузки (по
умолчанию — канонический whisper.cpp, обычным HTTPS с адреса самого человека,
что в этом приложении стоит учитывать).

### Перевод на устройстве

Перевод сообщений работает локально на CTranslate2 с моделью OPUS-MT. Апстрим
CTranslate2 не поддерживает Android и iOS — запрос висит с 2024 года, — поэтому
движок собирается из форка `https://github.com/veilnetwork/CTranslate2`, чьи
скрипты в `mobile/` не добавляют ничего, кроме верных флагов. Ни строки C++ ради
сборки менять не пришлось; какие умолчания неверны для телефона и почему —
в `mobile/README.md` там же.

Перевод **необязателен на всех платформах**: без библиотеки-обёртки провайдер
возвращает null, интерфейс перевода не появляется, больше в приложении ничего
не меняется и ни одна сборка не падает.

Что нужно рядом, двумя отдельными чекаутами:

- `CTranslate2` (форк, `https://github.com/veilnetwork/CTranslate2`) —
  `mobile/build-android.sh`, `mobile/build-ios.sh`, а для хоста статическая
  сборка с `BUILD_SHARED_LIBS=OFF`.
- `sentencepiece` (апстрим, `https://github.com/google/sentencepiece`) —
  токенизатор. Кросс-сборке нужен `SPM_PROTOC_EXECUTABLE` с
  путём к protoc, который запускается на СБОРОЧНОЙ машине; без него сборка
  делает protoc под целевую платформу и пытается запустить его здесь, падая
  необъяснимой «Error 126». Для iOS дополнительно нужен
  `native/translate/cmake/ios_shim.cmake`, подставленный через
  `CMAKE_PROJECT_INCLUDE_BEFORE`.

Затем соберите обёртку — одну библиотеку с движком, токенизатором и небольшим
C ABI, чтобы перевод приезжал одним файлом, а не набором, который может
оказаться неполным:

```bash
native/translate/build_veil_translate_macos.sh          # native/translate/Frameworks/libveil_translate.dylib
native/translate/build_veil_translate_android.sh        # android/app/src/main/jniLibs/arm64-v8a/ (+ libomp.so)
native/translate/build_veil_translate_ios.sh            # libveil_translate.a      (устройство)
native/translate/build_veil_translate_ios.sh --simulator # libveil_translate-sim.a (Симулятор)
native/translate/build_veil_translate_linux.sh          # native/translate/linux/libveil_translate.so
```

Под Windows скрипт — на PowerShell, и запускать его нужно из Developer
PowerShell, потому что он напрямую вызывает `cl.exe`, `link.exe` и
`dumpbin.exe`:

```powershell
native\translate\build_veil_translate_windows.ps1       # native\translate\windows\veil_translate.dll
```

Каждый проверяет то, что произвёл: архитектуру, экспортируемые точки входа, а
для iOS ещё и ПЛАТФОРМУ — потому что macOS-архив тоже arm64 и падает только на
устройстве. Андроидный скрипт вдобавок гоняет самопроверку НА подключённом
телефоне, если он подключён и `VEIL_TRANSLATE_TEST_MODEL` указывает на каталог
модели.

Все скрипты ищут чекауты через одни и те же переменные — `CT2_SRC`, `SPM_SRC`,
`CT2_BUILD`, `SPM_BUILD`, — так что дерево с другой раскладкой правок не
требует. Точный каталог сборки и флаги cmake каждый скрипт называет в своей
шапке; она и есть источник правды, потому что скрипт проверяет именно их.

Собранная обёртка попадает туда, куда упаковка этой платформы уже смотрит, и
руками ничего раскладывать не нужно: `linux/CMakeLists.txt` кладёт
`native/translate/linux/libveil_translate.so` в `lib/` бандла, Windows-цель
`builder.py` копирует `veil_translate.dll` рядом с runner, андроидный скрипт
пишет прямо в `jniLibs` APK, а `scripts/bundle-macos-dylibs.sh` копирует dylib
в `Contents/Frameworks`. Каждая из этих выкладок обёрнута в проверку «если файл
есть», поэтому платформа без собранной обёртки даёт рабочее приложение без
перевода, а не сломанную сборку.

Линковка под iOS сделана и работает: скрипт пишет
`ios/Flutter/TranslateLink.xcconfig`, а конфигурации Runner подключают его
формой `#include?`, которую Xcode молча пропускает при отсутствии файла.
Подробности — в английском разделе выше.

Модели **не** входят в сборку, и ни одна пока не опубликована. Пара
конвертируется скриптом `native/translate/convert-model.sh <from> <to>` (нужно
питон-окружение с `ctranslate2`, `transformers` и `torch`; около 870 МБ колёс,
только на хосте). Он печатает запись каталога — настоящие размеры и SHA-256,
прочитанные из только что записанных файлов. Сконвертированную пару человек
ставит из настроек или получает в переписке файлом `.veiltranslate`.

### Проверка

Быстрые Flutter-проверки:

```sh
flutter analyze
flutter test
```

На macOS полный Flutter-набор с только что собранными нативными библиотеками
запускается так:

```sh
scripts/build-native.sh
VEIL_FFI_DYLIB="$PWD/third_party/veil/target/debug/libveilclient_ffi.dylib" \
XVEIL_HV_DYLIB="$PWD/third_party/hidden-volume/target/debug/libhidden_volume_ffi.dylib" \
flutter test
```

Быстрые нативные проверки:

```sh
cargo test --manifest-path third_party/veil/Cargo.toml \
  -p veilclient-ffi --features node-embedded
cargo test --manifest-path third_party/hidden-volume/Cargo.toml --workspace
```

Если приложение macOS, запущенное через Finder, открыло fake-хранилище,
повторите `scripts/bundle-macos-dylibs.sh` с соответствующим профилем. При iOS
linker error с неверной архитектурой пересоберите device- или simulator-slice.
Если Android не находит linker или target, проверьте `ANDROID_NDK_HOME`,
`cargo-ndk` и наличие всех четырёх Rust target.
