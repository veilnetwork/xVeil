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

The helper temporarily replaces the scanner package with a simulator-compatible
stub, builds the ARM64 simulator native slices, and restores the production
dependency graph when it exits. Device and simulator `veilclient-ffi` slices
share one staging path, so rerun `scripts/build-mobile.sh ios` before the next
physical-device build.

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

Optional on-device voice transcription: build the whisper wrapper with
`native/whisper/build_veil_whisper_linux.sh` (uses a whisper.cpp checkout at
`WHISPER_SRC`, building its static CPU libs when missing) and place the ggml
model (`ggml-base-q5_1.bin`) next to the produced `.so` in
`native/whisper/linux/`; the app CMake bundles both into the bundle's `lib/`
automatically. A model in the XDG data dir
(`~/.local/share/network.veil.xveil/`) or via `XVEIL_WHISPER_MODEL` works too.

### Windows

The hidden-volume Windows plugin has automatic DLL bundling. The veil DLL still
requires a manual staging step in the xVeil Windows runner. Run these commands
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

Keep the two DLLs beside `xveil.exe` when redistributing the directory. Windows
application packaging is less automated than macOS, Android, iOS, and Linux;
verify a fresh extracted bundle on a clean Windows machine before distribution.

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

Скрипт временно заменяет пакет сканера совместимой с симулятором заглушкой,
собирает ARM64 simulator slices и восстанавливает production-граф зависимостей
при завершении. Device- и simulator-варианты `veilclient-ffi` используют один
путь staging, поэтому перед следующей сборкой для физического устройства снова
выполните `scripts/build-mobile.sh ios`.

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

Опциональная локальная транскрипция голосовых: соберите whisper-обёртку
скриптом `native/whisper/build_veil_whisper_linux.sh` (использует чекаут
whisper.cpp в `WHISPER_SRC`, при отсутствии сам собирает статические
CPU-библиотеки) и положите ggml-модель (`ggml-base-q5_1.bin`) рядом с
полученной `.so` в `native/whisper/linux/` — CMake приложения сам добавит
обе в `lib/` бандла. Модель также ищется в XDG-каталоге данных
(`~/.local/share/network.veil.xveil/`) и через `XVEIL_WHISPER_MODEL`.

### Windows

Windows-плагин hidden-volume умеет автоматически добавлять DLL. Для veil DLL в
Windows runner xVeil пока нужен ручной шаг staging. Выполните в Developer
PowerShell:

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

При распространении оставляйте обе DLL рядом с `xveil.exe`. Упаковка Windows-
версии автоматизирована слабее, чем macOS, Android, iOS и Linux, поэтому перед
публикацией проверьте свежераспакованный каталог на чистой Windows-машине.

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
