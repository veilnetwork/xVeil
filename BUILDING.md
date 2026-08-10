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

Flutter has no official linux-arm64 tarball; on an ARM machine clone the SDK
instead (`git clone -b stable https://github.com/flutter/flutter.git`) — the
tool then fetches an arm64 Dart SDK and works.

**Then, for every host:**

```sh
git clone --recurse-submodules https://github.com/veilnetwork/xVeil.git
cd xVeil
./prepare.py            # or: ./prepare.py android|ios|linux|windows|macos
flutter doctor -v       # should report no blocking issues for your target
./builder.py
```

**Signing, for Apple platforms only.** An iOS build needs a team selected in
`ios/Runner.xcworkspace` (Xcode → Runner → Signing & Capabilities). A free
Apple ID is enough to run on your own device, with a 7-day profile expiry. For
macOS without a developer account, use `scripts/build-macos-adhoc.sh` as
described in the macOS section below — the normal build fails at signing,
debug included.

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

Debug build:

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

That signs ad-hoc against `{Debug,Release}NoVpn.entitlements` and drops the
tunnel extension, so the result has no VPN — which costs nothing today, since
the macOS VPN has never worked for exactly this reason. It cannot be
notarised either: on another Mac the recipient must run
`xattr -dr com.apple.quarantine /Applications/xveil.app`. For real
distribution, get a Developer ID and use the normal build.

Outputs:

- debug: `build/macos/Build/Products/Debug/xveil.app`;
- release: `build/macos/Build/Products/Release/xveil.app`.

The bundling step is mandatory. It copies both Rust libraries into
`Contents/Frameworks`, verifies that `veilclient-ffi` contains the embedded-node
API, and re-signs the application with the original Flutter entitlements. If
available, it also bundles the optional call-media and Whisper libraries.
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

Build and stage the physical-device native libraries:

```sh
scripts/build-mobile.sh ios
(cd ios && pod install)
flutter build ios --release
```

Open `ios/Runner.xcworkspace` in Xcode first if a development team, bundle
identifier, provisioning profile, or signing certificate must be selected. For
an unsigned CI compile check, use:

```sh
flutter build ios --release --no-codesign
```

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
`apt install libmpv-dev`; deployed systems need `libmpv2`:

```sh
scripts/build-native.sh --release
flutter build linux --release
```

Output: `build/linux/<architecture>/release/bundle/`.

For a debug build, omit `--release` from the native script and use
`flutter build linux --debug`; the native and Flutter profiles must match.

On-device voice transcription: build the whisper wrapper with
`native/whisper/build_veil_whisper_linux.sh` (uses a whisper.cpp checkout at
`WHISPER_SRC`, building its static CPU libs when missing) and leave the
produced `.so` in `native/whisper/linux/`; the app CMake bundles it into the
bundle's `lib/`.

The ggml model is **not** bundled — it is 57 MiB, it does not compress, and
most people never transcribe anything, so the app downloads it on demand and
keeps it once for the whole app (in the support directory, shared by every
profile), verifying a pinned size and SHA-256. Nothing needs staging for that
to work.

For a build that must install without a network, put the model next to the
`.so` and set `XVEIL_BUNDLE_WHISPER_MODEL=1` — the same opt-in Android and
macOS use. `XVEIL_WHISPER_MODEL` still points at a model anywhere, and
`XVEIL_WHISPER_MODEL_URL` changes where the download comes from (the default
is the canonical whisper.cpp distribution, fetched over plain HTTPS from the
person's own address — worth knowing in this app).

### Windows

The hidden-volume Windows plugin has automatic DLL bundling. The veil client
DLL still requires a manual staging step. The system-VPN engine is different:
the Windows CMake build invokes `scripts/stage-windows-vpn.ps1`, builds
`veil-vpn-helper`, and stages both `veil_vpn_helper.dll` and the official
signed `wintun.dll` selected from the locked Cargo package. Run these commands
from a Developer PowerShell:

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

### On-device translation

Message translation runs locally on CTranslate2 with an OPUS-MT model. Upstream
CTranslate2 does not support Android or iOS — the request has been open since
2024 — so the engine is built from the fork at
`https://github.com/veilnetwork/CTranslate2`, whose `mobile/` scripts add
nothing but the right flags. No C++ was changed to make it build; see
`mobile/README.md` there for which defaults are wrong for a phone and why.

Prerequisites, both out-of-repo checkouts beside this one:

- `CTranslate2` (the fork) — `mobile/build-android.sh`, `mobile/build-ios.sh`,
  and for the host a static build with `BUILD_SHARED_LIBS=OFF`.
- `sentencepiece` — the tokeniser. Cross-compiling it needs
  `SPM_PROTOC_EXECUTABLE` pointing at a protoc that runs on the BUILD machine;
  without it the build makes a protoc for the target and tries to run it here,
  which fails as an unexplained "Error 126". iOS additionally needs
  `native/translate/cmake/ios_shim.cmake` injected with
  `CMAKE_PROJECT_INCLUDE_BEFORE`.

Then build the wrapper — one library holding the engine, the tokeniser and a
small C ABI, so a translation feature arrives as one file rather than a set
that can turn up incomplete:

```bash
native/translate/build_veil_translate_macos.sh     # libveil_translate.dylib
native/translate/build_veil_translate_android.sh   # jniLibs/arm64-v8a/, + libomp.so
native/translate/build_veil_translate_ios.sh       # libveil_translate.a
```

Each verifies what it produced — architecture, exported entry points, and for
iOS the PLATFORM, because a macOS archive is arm64 too and fails only on a
device. The Android script also runs its selftest ON a connected phone when
one is attached and `VEIL_TRANSLATE_TEST_MODEL` names a model directory.

**Linux and Windows are not built yet.** The engine itself is supported
upstream on both; only the wrapper script is missing. Translation is simply
absent there — the provider returns null and no affordance appears.

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

Официального архива Flutter под linux-arm64 не существует: на ARM-машине
клонируйте SDK (`git clone -b stable https://github.com/flutter/flutter.git`) —
инструмент подтянет arm64-сборку Dart SDK и заработает.

**Дальше — одинаково для всех хостов:**

```sh
git clone --recurse-submodules https://github.com/veilnetwork/xVeil.git
cd xVeil
./prepare.py            # или: ./prepare.py android|ios|linux|windows|macos
flutter doctor -v       # для вашей цели не должно остаться блокирующих пунктов
./builder.py
```

**Подпись — только для платформ Apple.** Сборке под iOS нужна выбранная команда
в `ios/Runner.xcworkspace` (Xcode → Runner → Signing & Capabilities).
Бесплатного Apple ID достаточно, чтобы запустить на своём устройстве, но
profile истекает через 7 дней. Для macOS без учётной записи разработчика
используйте `scripts/build-macos-adhoc.sh`, как описано ниже в разделе macOS:
обычная сборка падает на подписи, включая debug.

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

Debug-сборка:

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

Скрипт подписывает ad-hoc по `{Debug,Release}NoVpn.entitlements` и выбрасывает
расширение туннеля, поэтому VPN в результате нет — сегодня это ничего не
стоит, потому что macOS-VPN ровно по этой причине никогда и не работал.
Нотаризовать такую сборку тоже нельзя: на чужом маке получателю придётся
выполнить `xattr -dr com.apple.quarantine /Applications/xveil.app`. Для
настоящей раздачи нужен Developer ID и обычная сборка.

Результаты:

- debug: `build/macos/Build/Products/Debug/xveil.app`;
- release: `build/macos/Build/Products/Release/xveil.app`.

Шаг bundling обязателен. Он копирует обе Rust-библиотеки в
`Contents/Frameworks`, проверяет наличие API встроенного узла и повторно
подписывает приложение с исходными Flutter entitlements. При наличии также
добавляются необязательные библиотеки звонков и Whisper.
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

Соберите и подготовьте нативные библиотеки для физического устройства:

```sh
scripts/build-mobile.sh ios
(cd ios && pod install)
flutter build ios --release
```

Если нужно выбрать Development Team, Bundle ID, provisioning profile или
сертификат, предварительно откройте `ios/Runner.xcworkspace` в Xcode. Для
неподписанной проверки компиляции в CI используйте:

```sh
flutter build ios --release --no-codesign
```

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
`apt install libmpv-dev`; на машинах пользователей нужен `libmpv2`:

```sh
scripts/build-native.sh --release
flutter build linux --release
```

Результат: `build/linux/<architecture>/release/bundle/`.

Для debug-сборки уберите `--release` у нативного скрипта и используйте
`flutter build linux --debug`. Профили Rust- и Flutter-сборки должны совпадать.

Локальная транскрипция голосовых: соберите whisper-обёртку скриптом
`native/whisper/build_veil_whisper_linux.sh` (использует чекаут whisper.cpp в
`WHISPER_SRC`, при отсутствии сам собирает статические CPU-библиотеки) и
оставьте полученную `.so` в `native/whisper/linux/` — CMake приложения сам
добавит её в `lib/` бандла.

Ggml-модель **не вшивается**: она весит 57 МиБ, не сжимается, а расшифровкой
пользуются немногие — поэтому приложение скачивает её по требованию и хранит
один раз на всё приложение (в каталоге поддержки, общем для всех профилей),
сверяя закреплённые размер и SHA-256. Готовить для этого ничего не нужно.

Для сборки, которая должна ставиться без сети, положите модель рядом с `.so`
и задайте `XVEIL_BUNDLE_WHISPER_MODEL=1` — тот же флаг, что у Android и
macOS. `XVEIL_WHISPER_MODEL` по-прежнему указывает на модель в любом месте, а
`XVEIL_WHISPER_MODEL_URL` меняет адрес загрузки (по умолчанию — канонический
whisper.cpp, обычным HTTPS с адреса самого человека, что в этом приложении
стоит учитывать).

### Windows

Windows-плагин hidden-volume умеет автоматически добавлять DLL. Для клиентской
veil DLL пока нужен ручной шаг staging. System VPN собирается иначе: Windows
CMake вызывает `scripts/stage-windows-vpn.ps1`, собирает `veil-vpn-helper` и
автоматически кладёт рядом с приложением `veil_vpn_helper.dll` и официальный
подписанный `wintun.dll` из зафиксированной Cargo-зависимости. Выполните в
Developer PowerShell:

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

### Перевод на устройстве

Перевод сообщений работает локально на CTranslate2 с моделью OPUS-MT. Апстрим
CTranslate2 не поддерживает Android и iOS — запрос висит с 2024 года, — поэтому
движок собирается из форка `https://github.com/veilnetwork/CTranslate2`, чьи
скрипты в `mobile/` не добавляют ничего, кроме верных флагов. Ни строки C++ ради
сборки менять не пришлось; какие умолчания неверны для телефона и почему —
в `mobile/README.md` там же.

Что нужно рядом, двумя отдельными чекаутами:

- `CTranslate2` (форк) — `mobile/build-android.sh`, `mobile/build-ios.sh`, а для
  хоста статическая сборка с `BUILD_SHARED_LIBS=OFF`.
- `sentencepiece` — токенизатор. Кросс-сборке нужен `SPM_PROTOC_EXECUTABLE` с
  путём к protoc, который запускается на СБОРОЧНОЙ машине; без него сборка
  делает protoc под целевую платформу и пытается запустить его здесь, падая
  необъяснимой «Error 126». Для iOS дополнительно нужен
  `native/translate/cmake/ios_shim.cmake`, подставленный через
  `CMAKE_PROJECT_INCLUDE_BEFORE`.

Затем соберите обёртку — одну библиотеку с движком, токенизатором и небольшим
C ABI, чтобы перевод приезжал одним файлом, а не набором, который может
оказаться неполным:

```bash
native/translate/build_veil_translate_macos.sh     # libveil_translate.dylib
native/translate/build_veil_translate_android.sh   # jniLibs/arm64-v8a/, + libomp.so
native/translate/build_veil_translate_ios.sh       # libveil_translate.a
```

Каждый проверяет то, что произвёл: архитектуру, экспортируемые точки входа, а
для iOS ещё и ПЛАТФОРМУ — потому что macOS-архив тоже arm64 и падает только на
устройстве. Андроидный скрипт вдобавок гоняет самопроверку НА подключённом
телефоне, если он подключён и `VEIL_TRANSLATE_TEST_MODEL` указывает на каталог
модели.

**Linux и Windows пока не собраны.** Сам движок апстрим поддерживает на обеих;
не хватает только скрипта обёртки. Перевод там просто отсутствует — провайдер
возвращает null, и интерфейс не появляется.

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
