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
| Windows | `xveil-windows-x64.zip` | unzip, run `xveil.exe` |
| Linux | `xveil-linux-x64.tar.gz` | unpack, run `bundle/xveil` |

Android is `arm64-v8a` only. Builds for `armeabi-v7a` and `x86_64` were
published through v0.9.1 and are not any more: the call media engine is built
for arm64 alone, so those APKs started and then could not record a voice
message, play a video note, take a call or transcribe anything. An APK that
looks like the app and quietly cannot do half of it is worse than no APK.

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

**Unpack it somewhere OneDrive does not sync — not the Desktop, not Documents.**
Those folders are redirected into OneDrive on most Windows installs, and with
Files On-Demand a file is a placeholder until something opens it: Explorer shows
the name and the size, and the bytes are not on the disk. Windows cannot load a
DLL that is a placeholder, and the app cannot read its bundled configuration
from one. The first three reports of v0.10.0 were all this, wearing three
different masks — *"the system cannot find hidden_volume_plugin.dll"* for a file
sitting right there, then a node that would not start. `C:\Users\<you>\Apps\xveil`
or anywhere off the synced tree is fine.

If you would rather keep it where it is: right-click the extracted folder →
*Always keep on this device*, and wait until every file shows a green tick
rather than the blue sync arrows.

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

Open `ios/Runner.xcworkspace` in Xcode to pick a signing team.

Two things are worth knowing before you start, because they cost a day if you
find them halfway. First, `scripts/build-mobile.sh ios` builds the call engine
from a from-source WebRTC checkout — hours and tens of gigabytes, with no
prebuilt to download for Apple platforms — and the build fails at link time
without it. Second, the app and its packet-tunnel extension both request the
Network Extension entitlement in every configuration, and unlike macOS there is
no `NoVpn` variant to fall back on, so the signing team you pick has to be one
that can provision that capability. Without provisioning profiles the only
thing you can produce is `flutter build ios --no-codesign`, which compiles but
cannot be installed on a device. `BUILDING.md` covers both in detail.

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
| Windows | `xveil-windows-x64.zip` | распаковать, запустить `xveil.exe` |
| Linux | `xveil-linux-x64.tar.gz` | распаковать, запустить `bundle/xveil` |

Android — только `arm64-v8a`. Сборки под `armeabi-v7a` и `x86_64` публиковались
по v0.9.1 включительно и больше не публикуются: движок звонков собирается лишь
под arm64, поэтому те APK запускались, но не могли ни записать голосовое, ни
проиграть кружочек, ни принять звонок, ни распознать речь. APK, который выглядит
как приложение и молча не умеет половины, хуже, чем его отсутствие.

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

**Распаковывайте туда, где нет синхронизации OneDrive — не на Рабочий стол и не
в Документы.** На большинстве установок Windows эти папки перенаправлены в
OneDrive, а при включённой подгрузке по требованию файл до первого обращения
остаётся заполнителем: имя и размер в проводнике видны, а байтов на диске нет.
Windows не может загрузить библиотеку-заполнитель, а приложение не может
прочитать из неё свою настройку. Первые три отчёта о v0.10.0 оказались именно
этим в трёх разных обличьях — «система не обнаружила hidden_volume_plugin.dll»
про файл, лежащий на месте, а затем узел, который не стартует. Подойдёт
`C:\Users\<вы>\Apps\xveil` или любое место вне синхронизируемого дерева.

Если переносить не хочется: правой кнопкой по распакованной папке → «Всегда
сохранять на этом устройстве», и дождитесь, чтобы у всех файлов была зелёная
галочка, а не синие стрелки синхронизации.

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

Две вещи, которые лучше знать заранее, — иначе они стоят дня, когда
обнаруживаются на середине. Во-первых, `scripts/build-mobile.sh ios` собирает
движок звонков из исходного чекаута WebRTC: часы и десятки гигабайт, готового
прибилта для платформ Apple нет нигде, а без него падает линковка. Во-вторых,
приложение и его расширение packet-tunnel просят право Network Extension во
всех конфигурациях, и, в отличие от macOS, варианта `NoVpn` здесь нет — значит,
выбранная команда должна уметь провизионить эту возможность. Без
provisioning-профилей собрать можно только `flutter build ios --no-codesign`:
оно компилируется, но на устройство не ставится. Подробности — в `BUILDING.md`.

### Чтобы приложение заработало

Ему нужно достучаться до сети. В сборку зашиты бутстрап-сиды; если они
недоступны, свежая установка запустится, будет выглядеть исправной и ни с кем
не соединится — это состояние сети, а не сборки. Пир можно добавить и вручную
по ссылке `veil:bootstrap?…`: **Сеть → Пиры → Добавить пир**.
