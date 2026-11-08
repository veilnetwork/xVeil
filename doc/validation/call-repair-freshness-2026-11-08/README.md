# Звонки: свежесть repair-запросов и P2P при смене сети

**Исправлен отдельный control-plane дефект. NETCALL-01 остаётся открытым.**

## Подтверждённая ошибка и исправление

Датированный `health` мог запоздать или повториться после нового состояния
того же звонка. Route/capture поля уже имели защиту порядка, но
`mediaRepairRequested` безусловно вызывал `repairRoute()`. Старый запрос мог
повторно перестроить работающий медиатракт, в том числе при ещё незавершённой
первой обработке той же логической просьбы.

Теперь repair сверяется с последним датированным health и transportInfo того
же peer/call; один timestamp допускается к repair один раз. Сравниваются
timestamps отправителя, не часы двух устройств. Floor меняется только для
текущего аутентифицированного собеседника и очищается при новом звонке.
Запрос помечается обработанным после active/busy guards, до native await.
Поэтому пришедшая до старта медиа копия может примениться после его запуска.
Свежие запросы, недатированные legacy-запросы и локальный watchdog сохраняют
прежнее поведение. Durable ACK, wire, consent и квалификация маршрута не менялись.

Четыре assertion-red до исправления: старый repair после нового health с
маршрутом, health без маршрута, transportInfo; повтор одной просьбы.
Зелёные проверки дополнительно держат первый repair незавершённым, проверяют
новый запрос, другой peer/call, сброс floor для следующего звонка и startup.
Пять focused cases входят в **248 passed / 0 skipped** четырёх связанных файлов;
анализатор двух затронутых Dart files чистый. На телефон этот Dart-фикс не
устанавливался; исправление не объявляется причиной или решением паузы ниже.

## Физический контроль до исправления

После [TCP-атрибуции](../sdk-fine-tcp-call-2026-11-08/README.md) проверено,
помогает ли разрешённый P2P уйти с проблемного relay TCP. Один настоящий
Poco ↔ Mac звонок: Wi-Fi 30 с → Cellular 120 с → Wi-Fi 45 с, оба direct
posture, политика `contacts`. Внутри интервалов host не опрашивал телефон;
collector работал локально. Host ADB оставался включён. Слышимость человеком
не измерялась.

Android SDK `bbcd967a`, Mac SDK `c8f4929b`, два изолированных Core `e974cebe`.
Восемь call/network Dart files frozen frontend совпадали с root `5b010063`
до нового исправления. Это не квалификация всего текущего frontend: отдельно
известны три отличающихся файла IDs/own-history. Candidate APK проверен
по SHA **после установки, до запуска**, Mac dylib — по SHA и actual mapping.

Первый pre-call deployment был TCP-only, с loopback UDP-reflector. Звонок на
нём не запускали; он собран и очищен отдельно, не зачтён как P2P-проверка.
Затем только у тестовых Core reflector выставлен на публичный UDP/443.
Оба ответили на независимый 64-byte nonce probe с равным размером ответа;
порт/службы production не менялись. Клиенты узнали reflector обычным
аутентифицированным обменом; listener P2P у обоих не loopback.

| Фаза | Max native audio RX age, Poco | Mac |
|---|---:|---:|
| Wi-Fi до переключения | 407 мс | 385 мс |
| Cellular | 9924 мс | **28639 мс** |
| Возврат на Wi-Fi | 4764 мс | 5210 мс |

На Wi-Fi relay сменился P2P. После Wi-Fi→Cellular звонок сохранился, но был
длинный интервал без свежего принятого аудио, затем несколько переходов
P2P→relay→P2P. И call state, и native channel transport подтверждают смены;
это не только надпись интерфейса. В конце phases counters снова продвигались.
Mac engine epoch оставался 1, у телефона были локальные перестройки.
Script exit 0 означает исполнение/cleanup, **не прохождение NETCALL/QoE**.

В Mac devlog watchdog заметил established audio outage при native age 3229 мс.
До восстановления четыре relay candidates не прошли delivery qualification;
между попытками действует существующая пауза повторов. Поэтому версия
«watchdog вообще не замечает остановку» исключена для этого случая.

В probe trace нет matching late relay replies с budget 600 мс. Есть
expired/mismatched наблюдения, но без связи с уже закрытым challenge они не
доказывают, что увеличение бюджета помогло бы. Probe deadlines не увеличены,
принятие не подтверждённого маршрута не разрешено. Следующий участок —
почему кандидаты не получили нужного echo и почему route/control доставка
долгая; P2P пока нельзя объявить решением секундных TCP-пауз.

## Teardown и границы

Оба terminal runs (pre-call и основной) собраны раздельно. Archives и все
extracted raw inputs проверены по SHA; два production PID/binary/config
независимо сверены. Own Core/capture/subscribers/state/config/binaries удалены,
test ports свободны. Mac app/collectors завершены, runtime удалён.
Исходные main/QA APK и root QA container совпали с SHA до проверки;
microphone permission, P2P policy, trace properties и validated Wi-Fi сеть
восстановлены. Raw clocks, IDs, адреса, keys и nonce остаются private.
Новых Rust builds, push/релиза и установки нового Dart в этом раунде нет.
