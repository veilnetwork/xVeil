# Installing xVeil / Установка xVeil

[English](#english) · [Русский](#русский)

## English

Builds are published on the [Releases page](https://github.com/veilnetwork/xVeil/releases).
Every artifact there is produced by CI from a tagged commit on a clean
checkout, not from anyone's laptop.

### What is published

| Platform | File | Notes |
|---|---|---|
| Android | `app-arm64-v8a-release.apk` | almost every phone made since 2016 |
| Android | `app-armeabi-v7a-release.apk` | older 32-bit devices |
| Android | `app-x86_64-release.apk` | emulators |
| Windows | `xveil-windows-x64.zip` | unzip, run `xveil.exe` |
| Linux | `xveil-linux-x64.tar.gz` | unpack, run `bundle/xveil` |

The APKs are split per architecture so the download is ~30 MB instead of ~90.
Pick the one matching your phone; `arm64-v8a` is the right answer unless the
device is genuinely old.

Speech recognition downloads its model (~57 MB) the first time you use it,
which is why the app itself is small.

### Android

Install the APK directly. Some vendor shells (MIUI in particular) refuse
installs from `adb` while allowing the same file from the on-device file
manager — copy it to the phone and open it there if `adb install` is blocked.

### Windows

**Unsigned.** SmartScreen shows "Windows protected your PC" on first run:
*More info* → *Run anyway*. Authenticode signing costs money and the project
does not have a certificate yet, so this warning is expected rather than a sign
of a bad download. Verify the file against the release page if in doubt.

### Linux

Built on Ubuntu 24.04, so it needs that glibc or newer. It will not start on
Debian 12 or Ubuntu 22.04 — build from source there instead
(see [BUILDING.md](BUILDING.md)).

### macOS and iOS — build it yourself

**Nothing is published for Apple platforms, and the reason is not laziness.**
Both require an Apple Developer account, and without one there is nothing
useful to hand out:

- macOS: Gatekeeper refuses an unsigned application downloaded from the
  internet. A build signed only ad-hoc runs on the machine that made it.
- iOS: an application cannot be installed on a device at all without a
  provisioning profile, which needs an account.

So on Apple platforms you build it yourself. Both paths are documented in
[BUILDING.md](BUILDING.md); the shape of them:

**macOS**, without a developer account:

```sh
scripts/build-native.sh --release
scripts/build-macos-adhoc.sh release
```

This signs ad-hoc against the `NoVpn` entitlements and drops the packet-tunnel
extension, so the result has no VPN — which costs nothing today, because the
macOS VPN has never worked without that entitlement anyway. The result is
`build/macos/Build/Products/Release/xveil.app`.

If someone hands you such a build rather than making it yourself, macOS will
quarantine it:

```sh
xattr -dr com.apple.quarantine /Applications/xveil.app
```

Understand what that command does before running it: it removes the check that
would otherwise stop an unidentified application. Only do it for a build whose
origin you trust.

**iOS** needs Xcode and an Apple ID:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
scripts/build-mobile.sh ios
(cd ios && pod install)
flutter build ios --release
```

Open `ios/Runner.xcworkspace` in Xcode to pick a signing team. A **free** Apple
ID works for installing on your own device, with one catch worth knowing before
you start: the provisioning profile expires after **7 days** and the app stops
launching until you rebuild. A paid account raises that to a year.

### Before it can do anything

The app needs to reach the network. It ships with bootstrap seeds, and if those
are unreachable a fresh install will start, look healthy, and connect to
nobody — that state is the network's, not the build's. A peer can also be added
by hand from a `veil:bootstrap?…` link: **Network → Peers → Add peer**.

---

## Русский

Сборки лежат на [странице релизов](https://github.com/veilnetwork/xVeil/releases).
Каждый артефакт собран в CI из помеченного тегом коммита на чистом клоне, а не
на чьём-то ноутбуке.

### Что публикуется

| Платформа | Файл | Примечание |
|---|---|---|
| Android | `app-arm64-v8a-release.apk` | почти все телефоны с 2016 года |
| Android | `app-armeabi-v7a-release.apk` | старые 32-битные |
| Android | `app-x86_64-release.apk` | эмуляторы |
| Windows | `xveil-windows-x64.zip` | распаковать, запустить `xveil.exe` |
| Linux | `xveil-linux-x64.tar.gz` | распаковать, запустить `bundle/xveil` |

APK разделены по архитектурам, поэтому файл весит ~30 МБ, а не ~90. Берите тот,
что подходит вашему телефону; `arm64-v8a` — верный ответ, если устройство не
совсем старое.

Модель распознавания речи (~57 МБ) докачивается при первом использовании —
поэтому само приложение небольшое.

### Android

APK ставится напрямую. Некоторые оболочки (заметнее всего MIUI) запрещают
установку через `adb`, но разрешают тот же файл из файлового менеджера на
телефоне — если `adb install` блокируется, скопируйте файл на устройство и
откройте его там.

### Windows

**Без подписи.** При первом запуске SmartScreen скажет «Windows protected your
PC»: *Подробнее* → *Выполнить в любом случае*. Подпись Authenticode стоит
денег, сертификата у проекта пока нет — то есть предупреждение ожидаемо и не
означает испорченной загрузки. Сомневаетесь — сверьте файл со страницей релиза.

### Linux

Собрано на Ubuntu 24.04, поэтому требует такой же glibc или новее. На Debian 12
и Ubuntu 22.04 не запустится — там собирайте из исходников
(см. [BUILDING.md](BUILDING.md)).

### macOS и iOS — собирать самому

**Для платформ Apple ничего не публикуется, и причина не в лени.** Обе требуют
учётной записи Apple Developer, а без неё раздавать просто нечего:

- macOS: Gatekeeper не запустит неподписанное приложение, скачанное из
  интернета. Сборка с ad-hoc подписью работает на той машине, где сделана.
- iOS: приложение вообще нельзя поставить на устройство без provisioning
  profile, а он требует учётной записи.

Поэтому на платформах Apple вы собираете сами. Оба пути описаны в
[BUILDING.md](BUILDING.md); коротко:

**macOS**, без учётной записи разработчика:

```sh
scripts/build-native.sh --release
scripts/build-macos-adhoc.sh release
```

Подпись ad-hoc против entitlements `NoVpn`, расширение packet-tunnel
выбрасывается — то есть без VPN. Сегодня это ничего не стоит: macOS-VPN и так
никогда не работал именно из-за отсутствия этого entitlement. Результат:
`build/macos/Build/Products/Release/xveil.app`.

Если такую сборку вам передали, а не вы её сделали, macOS поставит карантин:

```sh
xattr -dr com.apple.quarantine /Applications/xveil.app
```

Понимайте, что делает эта команда, прежде чем её запускать: она снимает
проверку, которая иначе не даст запустить неопознанное приложение. Делайте так
только для сборки, чьему происхождению доверяете.

**iOS** требует Xcode и Apple ID:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
scripts/build-mobile.sh ios
(cd ios && pod install)
flutter build ios --release
```

Откройте `ios/Runner.xcworkspace` в Xcode и выберите команду для подписи.
**Бесплатного** Apple ID достаточно, чтобы поставить приложение на своё
устройство, но с оговоркой, которую лучше знать заранее: profile истекает через
**7 дней**, и приложение перестанет запускаться, пока не пересоберёте. Платная
учётная запись поднимает срок до года.

### Чтобы приложение заработало

Ему нужно достучаться до сети. В сборку зашиты бутстрап-сиды; если они
недоступны, свежая установка запустится, будет выглядеть исправной и ни с кем
не соединится — это состояние сети, а не сборки. Пир можно добавить и вручную
по ссылке `veil:bootstrap?…`: **Сеть → Пиры → Добавить пир**.
