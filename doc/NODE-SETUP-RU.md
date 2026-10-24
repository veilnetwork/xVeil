# Свой узел Veil: от установки до проверки

Это руководство для владельца Linux-сервера (Debian/Ubuntu с systemd).
Команды управления сверены с текущим `veil-cli` в репозитории. Для macOS и
Windows также есть [общая инструкция установки CLI](../third_party/veil/docs/ru/install.md).
Отдельный маршрут для Windows приведён в конце этого документа.
Команды с `203.0.113.10` — пример: замените адрес своим публичным IP или DNS-именем.

## 1. Что вы запускаете

| Вопрос | Ответ |
| --- | --- |
| Кто создаёт личность? | Ваше устройство локально генерирует ключи и подбирает доказательство работы. Сервер, присваивающий личности, не нужен. |
| Что такое майнинг? | Перебор числового параметра до выполнения условия хеша. Это защита от массового создания адресов; монеты при этом не добываются. Адрес выводится из публичного ключевого материала. |
| Что делает серверный узел? | В режиме `core` участвует в маршрутизации и инфраструктуре сети. Может быть точкой входа и передавать зашифрованный трафик. Это не файловый сервер вашей переписки. |
| А мессенджер? | xVeil сам поднимает клиентский узел (`leaf`). Серверный `core` не заменяет приложение и не получает доступ к его переписке. |
| Нужен TURN? | Для транспорта Veil отдельный WebRTC TURN не требуется. Роль bootstrap сама по себе не означает, что на сервере установлен TURN. |
| Nostr/BitTorrent обязательны? | Это способы обнаружения первых узлов. Если уже передали рабочие адреса и ключи узлов, подключение возможно без поиска через эти службы. Изолированный сегмент общается только с достижимыми участниками. |

Наличие одного своего узла не гарантирует доступность любого собеседника.
Нужны работающие сетевые пути между их сегментами. Несколько независимых точек
входа уменьшают зависимость от отказа одной машины.

## 2. Подготовка

Нужен сервер с доступным входящим портом, SSH и возможностью запускать службу.
Если сервер за NAT, настройте проброс порта; DNS-запись сама по себе NAT не обходит.
Для примера ниже нужны входящие TCP/9000 и UDP/8443 в firewall сервера **и**
в правилах облачного провайдера. SSH оставьте доступным.

QUIC/UDP помогает избежать блокировки всего потока потерянным TCP-пакетом,
но может блокироваться провайдером. TCP оставляем запасным путём. Эти два
публичных транспорта не маскируют факт использования собственного протокола.
Если нужна маскировка, настройте obfs4 по [справочнику транспортов](../third_party/veil/docs/en/config-reference.md)
и распространите соответствующее приглашение; не считайте обычный TCP обфускацией.

## 3. Установить бинарник

От обычного пользователя скачайте установщик официального проекта, прочитайте
его и запустите. Он скачивает релиз и проверяет контрольные суммы:

```sh
curl --proto '=https' --tlsv1.2 -sSfL \
  https://raw.githubusercontent.com/veilnetwork/veil/main/scripts/install.sh \
  -o /tmp/veil-install.sh
less /tmp/veil-install.sh
sudo sh /tmp/veil-install.sh --prefix /usr/local --no-modify-path --yes
/usr/local/bin/veil-cli --version
```

Для закрепления конкретного релиза добавьте `--version X.Y.Z`, взяв номер из
[официальных релизов](https://github.com/veilnetwork/veil/releases).
Не копируйте номера версий из старых обсуждений. Сверьте опубликованную SHA-256,
если устанавливаете архив вручную. Сборка Rust на сервере не обязательна.

## 4. Создать данные и ключ узла

```sh
sudo useradd --system --home-dir /var/lib/veil --no-create-home \
  --shell /usr/sbin/nologin veil
sudo install -d -m 0700 -o veil -g veil /var/lib/veil
sudo -u veil /usr/local/bin/veil-cli \
  config init /var/lib/veil/node.toml --difficulty 24
sudo chmod 0600 /var/lib/veil/node.toml
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml \
  config set identity.role core
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml \
  config set global.admin_socket unix:///var/lib/veil/admin.sock
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml \
  config set global.bootstrap true
```

Если пользователь `veil` уже есть, пропустите `useradd`. Если конфиг уже есть,
сначала сохраните его и изучите: **не запускайте `config init --force` для обновления**.
Это может заменить ключи и адрес узла. У `config init` путь передаётся отдельным аргументом: глобальный `-c`
в проверенной версии не выбирает место создания нового файла.
Сложность относится к первоначальному
подбору; не обещайте фиксированное время генерации на любом процессоре.

`global.bootstrap=true` разрешает узлу объявлять себя точкой входа через
настроенные механизмы обнаружения. Сам по себе этот флаг не открывает firewall.

## 5. Открыть публичные входы

На новом конфиге сначала посмотрите существующие listener'ы:

```sh
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml listen list
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml \
  listen add tcp://0.0.0.0:9000 --advertise tcp://203.0.113.10:9000
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml \
  listen add quic://0.0.0.0:8443 --advertise quic://203.0.113.10:8443
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml config validate
```

Не добавляйте повторно уже существующий вход на тот же порт. `0.0.0.0` — адрес
прослушивания, его нельзя раздавать клиентам как адрес сервера. Для клиентов
нужен внешний адрес в `--advertise`. При использовании UFW:

```sh
sudo ufw allow 9000/tcp
sudo ufw allow 8443/udp
```

Не включайте UFW вслепую, если правила SSH ещё не настроены. Admin socket
остаётся локальным: административный TCP-порт наружу не публикуется.

## 6. Постоянная служба

Создайте `/etc/systemd/system/veil.service`:

```ini
[Unit]
Description=Veil core node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=veil
Group=veil
WorkingDirectory=/var/lib/veil
ExecStart=/usr/local/bin/veil-cli -c /var/lib/veil/node.toml node run --foreground
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/veil
LimitCORE=0
LimitNOFILE=65536
LimitMEMLOCK=268435456

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now veil.service
sudo systemctl status veil.service --no-pager
sudo journalctl -u veil.service -n 60 --no-pager
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node show
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node health
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node listens
```

В пользовательском конфиге пути сохранения состояния должны быть внутри
`/var/lib/veil`, иначе ограничения службы запретят запись. Справочник persistence
и настройка подписи конфига: [Operations](../third_party/veil/docs/ru/OPERATIONS.md).
Служба должна запускаться от того же пользователя, что владеет данными.

## 7. Подключить xVeil и другие узлы

Получите публичное приглашение:

```sh
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml bootstrap invite --qr
```

Приглашение использует **первый** listener; проверьте адрес через
`bootstrap decode 'veil:bootstrap?...'` перед отправкой. Оно должно содержать
доступный внешний адрес, а не `0.0.0.0` или loopback. В xVeil откройте
«Сеть» и добавьте точку входа через приглашение/QR. Для второго CLI-узла:

```sh
veil-cli -c /path/to/second-node.toml bootstrap join 'veil:bootstrap?...'
# Если второй узел уже работает, перечитайте его конфиг:
veil-cli -c /path/to/second-node.toml node reload
```

Строку `veil:bootstrap?...` можно передать пользователям: в ней публичные
данные подключения, а не приватный ключ. Целиком `node.toml` не отправляйте.
Чтобы добавить несколько своих серверов, повторите `bootstrap join` с каждым
приглашением; это список точек входа, не объединение серверных личностей.

Если хотите сегмент только со своими узлами, добавьте их адреса вручную и
отдельно отключите посторонние источники bootstrap/объявления в конфиге.
`global.bootstrap=false` выключает собственную публикацию, но не всю внешнюю
разведку. Один этот флаг не обеспечивает изоляцию. Полный перечень источников
и политик смотрите в [справочнике](../third_party/veil/docs/en/config-reference.md).

## 8. Проверить полезную работу

```sh
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml sessions list
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node bootstrap-status
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node dht routing
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node bandwidth
```

Проверьте с внешней сети, например с телефона на мобильном интернете:
подключение к вашему узлу, сообщения в обоих направлениях, файл с проверкой
полного получения, звонок. Число соседей само по себе не доказывает доставку
до конкретного контакта. Пустой DHT на новом узле тоже не означает поломку.

| Симптом | Что проверить |
| --- | --- |
| Нет подключений | Служба, listener, внешний адрес, firewall/cloud rules, провайдер; UDP проверяйте подключением QUIC, а не только TCP-сканером. |
| `Broken pipe` в admin-команде | Состояние демона и его журнал, одинаковую версию CLI/демона, владельца сокета. Запускайте admin-команду от `veil`. Это не свидетельство потери файла собеседника. |
| Работает только одно направление | Сохранение авторизации устройств после рестарта, маршруты обеих сторон, версии клиентов. Снимите обезличенные отчёты с обоих устройств сразу после ошибки. |
| Файл остановился | Доступен ли источник, существует ли у него содержимое, восстанавливается ли передача после reconnect. Узел-реле не является гарантированным постоянным хранилищем вложения. |
| Android перестал принимать | Включён ли фоновый узел **в xVeil**, есть ли его постоянное уведомление, разрешён ли фон/автозапуск у производителя. Force-stop Android прекращает работу приложения независимо от этих разрешений. |

## 9. Резервная копия и обновление

У серверного CLI приватный ключ хранится в `node.toml`. Защитите конфиг и
каталог состояния резервной копией на зашифрованном носителе. Не публикуйте их
и не кладите в git. Для согласованной копии остановите службу, скопируйте данные
с правами/владельцем, затем запустите. Клонировать работающий узел с теми же
ключами на два сервера не нужно: каждому серверу создайте отдельный ключ.

У **личности xVeil** другие средства восстановления: экспортируемый сертификат
и его код. Сохраните оба в доступном вам безопасном месте, желательно раздельно.
Пароль приложения открывает локальный контейнер; он не заменяет сертификат.
Экспорт сертификата не является копией всей истории переписки.

Обновляйте бинарник из релиза с проверкой контрольной суммы, сохранив старый
бинарник для отката. Остановите службу перед заменой, сохраните конфиг и данные,
запустите и проверьте `node show`, `node health` и внешний клиент. Не генерируйте
новую личность при каждом обновлении. Если узел не стартовал, верните прежний
бинарник и проверьте журнал; не удаляйте данные как первый шаг диагностики.

## 10. Узел на Windows 10

Ниже — самостоятельный серверный узел, а не контейнер xVeil. Нужны права
администратора. На рабочем компьютере сначала согласуйте установку службы и
входящие подключения с администратором вашей организации.

Откройте **PowerShell от имени администратора**. Скачайте и просмотрите установщик:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/veilnetwork/veil/main/scripts/install.ps1 `
  -OutFile "$env:TEMP\veil-install.ps1"
notepad "$env:TEMP\veil-install.ps1"
& "$env:TEMP\veil-install.ps1" -BinDir "$env:ProgramFiles\Veil" -NoModifyPath
```

Если политика выполнения запрещает скрипт, используйте разрешённый в вашей
среде способ установки готового архива из Releases. Не отключайте корпоративные
защиты. Важно: исполняемый файл службы должен лежать в защищённом каталоге,
например `Program Files`, а не в папке, которую может менять обычный пользователь.

Создайте каталог данных и разрешите доступ только SYSTEM и администраторам.
SID в команде не зависит от языка Windows:

```powershell
$exe = "$env:ProgramFiles\Veil\veil-cli.exe"
$data = "$env:ProgramData\Veil"
$cfg = "$data\node.toml"
New-Item -ItemType Directory -Force $data
icacls $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'
& $exe --version
& $exe config init $cfg --difficulty 24
& $exe -c $cfg config set identity.role core
& $exe -c $cfg config set global.bootstrap true
& $exe -c $cfg config set global.admin_socket 'tcp://127.0.0.1:0?runtime_dir=C:/ProgramData/Veil/admin'
& $exe -c $cfg listen list
& $exe -c $cfg listen add tcp://0.0.0.0:9000 --advertise tcp://203.0.113.10:9000
& $exe -c $cfg listen add quic://0.0.0.0:8443 --advertise quic://203.0.113.10:8443
& $exe -c $cfg config validate
```

Как и на Linux, замените внешний адрес и не создавайте повторные listener'ы.
Если `node.toml` уже существует, пропустите `config init` и сначала изучите его.
При другом системном диске исправьте `C:/ProgramData/Veil/admin`. Пути persistence
в конфиге задавайте абсолютными, внутри каталога данных: у Windows-службы другой
рабочий каталог, чем у вашего PowerShell.

Откройте порты в Windows Firewall и на маршрутизаторе/у провайдера:

```powershell
New-NetFirewallRule -DisplayName 'Veil TCP 9000' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 9000
New-NetFirewallRule -DisplayName 'Veil QUIC 8443' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 8443
```

Сначала проверьте обычный запуск:

```powershell
& $exe -c $cfg node run --foreground
# Во втором PowerShell администратора, с теми же $exe и $cfg:
& $exe -c $cfg node show
& $exe -c $cfg bootstrap invite --qr
```

После проверки остановите foreground-узел через Ctrl+C. Установите службу:

```powershell
& $exe service install --config $cfg
Start-Service VeilNode
Get-Service VeilNode
& $exe -c $cfg node health
& $exe -c $cfg sessions list
```

Служба называется `VeilNode`. Если она не стартует, проверьте
`C:\ProgramData\Veil\veil-service.log`, путь к бинарнику и конфигу, права SYSTEM
и абсолютные пути состояния. Admin TCP доступен только локально; файлы токена
в `admin` не публикуйте. Для обновления остановите `VeilNode`, сохраните бинарник,
конфиг и данные, замените только бинарник, запустите службу и повторите проверку.
Команды сверены с интерфейсом CLI; запуск службы именно на Windows 10 в этом
цикле не проверялся.
