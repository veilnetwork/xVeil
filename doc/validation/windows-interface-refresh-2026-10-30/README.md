# Обновление исходящего интерфейса Windows — 2026-10-30

Исходная Veil — `c96bd930`, xVeil — `0c543691`. Проверен кандидат из
[анализа открытых случаев](../open-findings-2026-10-28/analysis-2026-10-29.md):
пин исходящих IPv4/IPv6-интерфейсов вычислялся единожды в NodeRuntime::start,
а socket factories читали только сохранённые индексы. Код не обновлял их после
смены default route, Wi-Fi/Ethernet, сна или внешнего VPN.

Это подтверждает механизм устаревшей привязки, но не доказывает, что именно
он вызвал пользовательскую одностороннюю доставку Windows 10 ↔ Android.

## Изменение

На Windows configure_outbound_socket перед настройкой сокета заново определяет
default-интерфейсы нужных семейств через прежний IP Helper route lookup.
Полученная пара публикуется целиком под mutex: ошибка второй части не оставляет
половину обновлённого состояния. IPv4-сокет не зависит от наличия IPv6-маршрута.

Слепой re-pin мог выбрать сам Wintun. Поэтому сравнивается alias фактического
интерфейса из Windows API с общим именем адаптера helper, `xVeil VPN`:

| Состояние | Решение |
| --- | --- |
| Текущий default вне своего туннеля | Обновить соответствующий pin |
| Default через свой туннель; сохранённый индекс существует и не принадлежит ему | Сохранить прежний внешний pin |
| Default через свой туннель; сохранённый индекс исчез, неизвестен или стал туннелем | Ошибка настройки, без неявного перехода в свой туннель |
| Известное отсутствие default route | Pin 0, остаются допустимыми локальные LAN-маршруты ОС |
| Ошибка определения/классификации | Ошибка настройки, частичное обновление не публикуется |

Имя больше не дублируется литералами в helper и utility: helper использует
одну публичную константу из veil-util. Добавлен Windows-only dependency и его
lock-entry. При ручном переименовании Wintun alias этот контракт требует
отдельной проверки; физического опыта переименования не было.

Ноль теперь действительно записывается в socket option. Иначе ранее настроенный
UDP-сокет при повторной настройке сохранял бы свой старый pin. Microsoft
определяет zero как unspecified для
[IPv4 IP_UNICAST_IF](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ip-socket-options)
и [IPv6 IPV6_UNICAST_IF](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ipv6-socket-options).
IPv4 network byte order и IPv6 host byte order сохранены.
Alias определяется через стандартные
[преобразования IP Helper](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/convertinterfaceluidtoalias).
Новые сетевые объявления или приоритеты реле не добавляются.

На прочих платформах socket configuration остаётся no-op. Утилита для пары
сохранённых pin использует mutex вместо двух независимых atomic-полей.
Попутно устранены два существовавших Windows-clippy замечания: Unix-only
clock-тесты не импортируются на Windows, а Windows create-new ветка использует
обычное tail expression. Маска DACL/доступа и owner-only file create не менялись.

SDK-исправление закоммичено как `ea7e8388`; указатель xVeil обновлён вместе
с этим отчётом.

## Проверки и их сила

* Host tests: **72 veil-util + 11 veil-vpn-helper passed**. Два существующих
  doctest ignored посчитаны отдельно. Восемь новых policy/application тестов
  входят в 72; они проверяют применяемую production-логику на заданных ответах
  route lookup, а не выполнение Windows API на Mac.
* Проверены повторные изменения defaults, внешний VPN, отказ при неизвестном
  underlay своего туннеля, LAN-only zero, раздельные IPv4/IPv6, отсутствие
  частичного обновления, применение zero к сокету и byte order.
* Host clippy обоих пакетов и Windows clippy veil-util с all-targets:
  **-D warnings прошёл**. Не использовались подавления обнаруженных предупреждений.
* Cross-target cargo check **veil-node-runtime с production-seeds и
  veil-vpn-helper, x86_64-pc-windows-gnu, прошёл**. Это проверка компиляции,
  не сборка и запуск готового Windows exe.
* Windows all-targets check/clippy компилирует дополнительный ignored Winsock
  regression test. Он требует настоящей Windows с внешним IPv4 default route:
  ```text
  cargo test -p veil-util winsock_socket_replaces_a_stale_interface_index -- --ignored
  ```
  Тест подставляет несуществующий индекс и вызывает настоящую настройку UDP
  сокета. Здесь он **не выполнялся** и не прибавлен к прошедшим тестам.

В Windows-core cross check первый запуск остановился на host clang без
правильных Windows C headers для aws-lc. Повтор с установленным MinGW C/AR
прошёл; source crypto не менялся. Оба исходных Windows-clippy замечания были
в других строках старого исходника и исправлены перед окончательной проверкой.

Native runtime red/green на Windows не запускался. Доказательство исходного
stale-pin механизма — реальные старые call sites и отсутствие refresh, а не
выдача новой model-функции за тест старого бинарника. CodeGraph указал util
функцию, но не разрешил её caller edges; они проверены непосредственно в коде.

Все Rust-команды использовали target на подтверждённом отдельном файловом
томе с непрерывной проверкой mount и остановкой собственной process group при
его потере. Mount не исчезал. SHA-256 проверенных исходников и итоговые статусы
команд — [summary.json](summary.json); raw logs приватны.

## Оставшиеся границы

Нужен Windows 10 стенд: исходная переписка в обе стороны, sleep/resume,
Wi-Fi ↔ Ethernet, внешний VPN, свежие входящие и исходящие соединения, сообщения
и звонки. Особенно важны multihomed/split-route варианты. Уже открытые сокеты
сами по себе не мигрируют от этой правки.

Если свой Veil VPN активен и прежний физический underlay исчез, код отказывается
перепинить control traffic на собственный Wintun. Автоматический выбор другого
underlay под активным своим туннелем, обновление его excluded routes и полная
миграция UDP/QUIC остаются отдельной задачей. Не обещаются исправление отсутствия
звука, onboarding и всех причин пользовательского Win10-репорта.

Приложения, звонки, телефоны и серверы в этом цикле не запускались/не менялись.
Готовые SDK-библиотеки не устанавливались. Коммиты без подписи, push/релиза нет.
