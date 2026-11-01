# Узел Veil на Debian с nginx, без Docker

Схема: `xVeil → wss://node.example.org:9443/veil → nginx → ws://127.0.0.1:9080/veil → Veil`.
Команды рассчитаны на Debian с systemd и отдельный домен. Замените
`node.example.org` своим доменом **во всех командах и файлах**. Нужны SSH с sudo,
DNS A/AAAA на ваш сервер и доступные снаружи TCP-порты 80 и 9443. Если IPv6 на
сервере не работает, не публикуйте AAAA. За NAT нужен проброс этих портов.

Узел создаёт свои ключи локально. Он маршрутизирует зашифрованный трафик и может
быть точкой входа в сеть; это не аккаунт-сервер и не хранилище открытой переписки.
Личность в xVeil также создаётся локально, отдельно от серверного узла.
Подробности: [общее руководство](NODE-SETUP-RU.md#1-что-вы-запускаете).

Здесь nginx завершает HTTPS/WebSocket. Обычный `proxy_pass http://…` нельзя
направить на сырой TCP-, obfs4- или QUIC-порт Veil. Для этой инструкции выбран
именно WebSocket listener. Дополнительный прямой QUIC можно настроить отдельно;
через этот HTTP-блок nginx он не проходит. WSS работает поверх TCP, поэтому
потеря пакета может задерживать следующие данные; один этот вход не гарантирует
лучшего качества звонков при любом провайдере.

В примере используется внешний TCP-порт **9443**. При проверке найден дефект
парсера стандартных портов WS/WSS в прежнем CLI: даже явно указанный `:443`
мог дать «missing port». Исправление подготовлено в коде; до его выпуска схема
с 9443 работает без этой правки. После обновления можно согласованно заменить
9443 на 443 в nginx, firewall и advertised URI.

## 1. Установите зависимости и CLI

```sh
sudo apt update
sudo apt install ca-certificates curl nginx certbot less nano
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/veilnetwork/veil/main/scripts/install.sh \
  -o /tmp/veil-install.sh
less /tmp/veil-install.sh
sudo sh /tmp/veil-install.sh --prefix /usr/local --no-modify-path --no-quickstart --yes
/usr/local/bin/veil-cli --version
```

Установщик скачивает готовый релиз и проверяет контрольные суммы; компилятор
Rust не нужен. Для фиксированной версии используйте его `--version X.Y.Z`,
взяв номер из [релизов Veil](https://github.com/veilnetwork/veil/releases).
Если nginx уже обслуживает сайты, сохраните его конфиги и используйте свободный
домен; не заменяйте существующие `server`-блоки.

## 2. Подготовьте ключи и конфигурацию

На новой установке:

```sh
sudo useradd --system --home-dir /var/lib/veil --no-create-home --shell /usr/sbin/nologin veil
sudo install -d -m 0700 -o veil -g veil /var/lib/veil
sudo -u veil /usr/local/bin/veil-cli config init /var/lib/veil/node.toml --difficulty 24
sudo chmod 0600 /var/lib/veil/node.toml
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml config set identity.role core
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml config set global.admin_socket unix:///var/lib/veil/admin.sock
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml config set global.bootstrap true
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml listen list
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml \
  listen add ws://127.0.0.1:9080/veil --advertise wss://node.example.org:9443/veil
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml config validate
```

Подбор доказательства работы при создании ключей может занять время. Если
пользователь `veil` или конфиг уже существуют, не создавайте их повторно:
сначала сделайте резервную копию. Не используйте `config init --force` для
обновления — это может заменить личность узла.

Проверьте `listen list`: в этой схеме нужен указанный локальный WS listener.
Не добавляйте его повторно. Если конфиг уже содержит другие listener'ы, решите,
нужны ли они; публичное приглашение по умолчанию берёт первый. Admin socket и
порт 9080 не публикуйте в Интернет. Внутренний `ws://127.0.0.1` не требует
TLS-ключей Veil: сертификат HTTPS хранится у nginx.

## 3. Настройте HTTP для получения сертификата

```sh
sudo install -d -m 0755 /var/www/veil-acme/.well-known/acme-challenge
sudo nano /etc/nginx/sites-available/veil
```

В nano сохраните файл: Ctrl+O, Enter, затем выйдите Ctrl+X.

Содержимое `/etc/nginx/sites-available/veil` на этом шаге:

```nginx
server {
    listen 80;
    server_name node.example.org;
    location /.well-known/acme-challenge/ {
        root /var/www/veil-acme;
    }
    location / { return 404; }
}
```

```sh
sudo ln -s /etc/nginx/sites-available/veil /etc/nginx/sites-enabled/veil
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
sudo certbot certonly --webroot -w /var/www/veil-acme -d node.example.org
```

Если ссылка уже есть, повторять `ln -s` не нужно. У certbot укажите свою почту
для уведомлений о сертификате. Для проверки домена DNS должен вести на этот
сервер, а порт 80 — быть доступен из Интернета. Правила облачного firewall
отдельны от firewall самой ОС. Если используете UFW, сначала сохраните доступ
SSH, затем разрешите `80/tcp` и `9443/tcp`; вслепую включать UFW не нужно.

## 4. Добавьте HTTPS и WebSocket

Замените содержимое файла nginx следующим (домен в путях сертификата тоже свой):

```nginx
server {
    listen 80;
    server_name node.example.org;
    location /.well-known/acme-challenge/ { root /var/www/veil-acme; }
    location / { return 301 https://$host:9443$request_uri; }
}

server {
    listen 9443 ssl;
    server_name node.example.org;
    ssl_certificate /etc/letsencrypt/live/node.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/node.example.org/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /veil {
        proxy_pass http://127.0.0.1:9080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        access_log off;
    }
    location / { return 404; }
}
```

Путь `/veil` сохраняется до backend: в `proxy_pass` нет завершающего `/`.
Заголовки Upgrade и Connection нужны для WebSocket, длительный read timeout
не даёт стандартным 60 секундам nginx обрывать тихое соединение.
Не добавляйте HTTP Basic Auth или браузерную проверку на этот путь: клиент
Veil не проходит форму входа. Аутентификация узлов выполняется самим Veil.
nginx видит адрес подключения и TLS-метаданные; сертификат HTTPS не заменяет
криптографическую личность Veil.

```sh
sudo nginx -t
sudo systemctl reload nginx
sudo install -d /etc/letsencrypt/renewal-hooks/deploy
sudo nano /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

Скрипт обновления:

```sh
#!/bin/sh
set -eu
/usr/sbin/nginx -t
/bin/systemctl reload nginx
```

```sh
sudo chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
sudo systemctl enable --now certbot.timer
sudo certbot renew --dry-run
```

## 5. Запустите Veil как службу

Создайте `sudo nano /etc/systemd/system/veil.service`:

```ini
[Unit]
Description=Veil core node behind nginx
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
sudo systemctl enable --now veil
sudo systemctl status veil --no-pager
sudo journalctl -u veil -n 60 --no-pager
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node health
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node listens
sudo ss -lntp
```

В `ss` ожидаются nginx на 80/9443 и Veil только на **127.0.0.1:9080** для этого
входа. Все пути сохраняемого состояния узла должны быть внутри `/var/lib/veil`,
куда службе разрешено писать. Для подписи конфига и резервных копий см.
[Operations](../third_party/veil/docs/ru/OPERATIONS.md).

## 6. Проверьте вход и подключите приложение

На другой машине с CLI:

```sh
veil-cli debug transport connect wss://node.example.org:9443/veil
```

Это проверка транспорта, а не доказательство доставки сообщения или звонка.
Затем на сервере получите публичное приглашение:

```sh
sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml bootstrap invite --qr
```

Через `veil-cli bootstrap decode --uri 'veil:bootstrap?…'` проверьте, что приглашение
содержит **wss://node.example.org:9443/veil**, а не loopback. Если берётся другой
listener, сначала исправьте их порядок/набор. Передайте приглашение в xVeil:
раздел сети → добавить точку входа → вставить приглашение или считать QR.
После подключения проверьте сообщения и звонок в обе стороны.

Передавать можно приглашение; `node.toml`, приватные ключи и резервные копии
никому не отправляйте. Остальные узлы/приложения не обязаны пользоваться именно
вашим входом: до контакта должна существовать сетевая связность. Для частного
сегмента без публичного обнаружения есть отдельные настройки из
[общей инструкции](NODE-SETUP-RU.md#7-подключить-xveil-и-другие-узлы).

## Если не подключается

- **certbot не получил сертификат:** DNS/AAAA и доступность порта 80 снаружи.
- **502 у nginx:** Veil не запущен или слушает другой адрес/порт; проверьте
  `node listens`, `ss`, `journalctl -u veil` и `/var/log/nginx/error.log`.
- **404 / ошибка Upgrade:** точный путь `/veil`, заголовки WebSocket и WS backend.
- **Ошибка сертификата:** домен, срок сертификата и fullchain; не отключайте
  проверку сертификатов для обхода ошибки.
- **Соединение есть, контакт недоступен:** смотрите соседей/маршруты узла и
  адреса контакта. Страница nginx и успешный TLS ещё не означают доступность пира.

Для обновления сначала сохраните ключи/конфиг и установите новый CLI, затем
`sudo systemctl restart veil` и повторите проверки. nginx не нужно заменять
при каждом обновлении Veil.

Параметры сверены с локальным CLI и transport/config-кодом. Полный чистый Debian
с публичным DNS и Let's Encrypt в этом раунде не разворачивался.
WebSocket-проксирование: [официальная документация nginx](https://nginx.org/en/docs/http/websocket.html).
