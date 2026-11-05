# BootstrapJoin: изоляция отмены подключений и повтор NETCALL-01

Исправлен подтверждённый native-дефект: регистрация одного bootstrap peer
отменяла ещё не завершённые подключения к другим peer. Однако физическая
пауза аудио при Wi-Fi → cellular **остаётся**: в текущей серии 19–20 с с
автоматическим выбором P2P/relay и 10,3 с при заранее отключённом P2P.
Это три контрольных звонка, не контролируемый A/B и не проверка слышимости.

## Исправление и причинное воспроизведение

Veil `c65a8d0c` заменяет общий cancellation wake в IPC BootstrapJoin drain
на уже существующее обновление конкретного peer. Прежде drain после каждой
записи вызывал `force_reconnect_notify.notify_waiters()`. Этот же сигнал
прерывает transport dial в `outbound_connector` с причиной `network_changed`.
Новая регистрация другого узла и повтор неизменившегося приглашения поэтому
могли отменить полезный handshake.

Drain выделен в `bootstrap_join::spawn_dial_drain`: production IPC и тесты
используют одну реализацию. Queue cap 128, runtime ownership/shutdown,
проверки приглашений, admission и криптография сохранены. Per-peer watch
уже будит idle retry и отменяет попытку при действительной смене её адреса
или ключевого материала. Глобальная отмена при настоящей смене сети остаётся.

Регрессионные проверки используют настоящий NodeRuntime/NodeServices,
BootstrapJoinForwarder и production drain; транспорт удерживает dial через
gate, а Drop фиксирует отмену. Часы виртуальные, сетевых порогов нет.

| Проверка | Результат |
|---|---|
| Новый сосед во время dial другого peer | Assertion-red на прежней логике; green после фикса |
| Повтор прежнего приглашения во время dial | Assertion-red на прежней логике; green после фикса |
| Повтор приглашения во время idle retry | Будит retry до 60-с backoff; последующая смена адреса отменяет прежнюю попытку |
| Контроль смены endpoint/key и настоящего network change | Пройден; нужные отмены сохраняются |

Baseline: 10 passed / 2 failed, обе ошибки — `BootstrapJoin cancelled an
unchanged in-flight dial`. Финальный focused run: **13 passed**, без ignored.
Полный контроль: veil-ipc **198 passed / 5 ignored**, veil-node-runtime
**801 passed / 11 ignored**. Итого **999 passed / 16 ignored**; ignored не
считаются пройденными. Scoped formatting и diff checks чистые.

## Сборка и физический стенд

Poco / Android 16 с SIM и мобильными данными, Windows 11 по Wi-Fi. Отдельные
QA-профили, настоящие native nodes и production-сеть. Android profile/AOT
собран из текущего xVeil `9cbef2a0` с Veil `c65a8d0c`. Android HVS/media
байты совпадают с прежними квалифицированными ELF; 74 media source inputs
не менялись. Windows сохраняет ранее квалифицированный profile/AOT
`3e8cea24` и прежние Veil/HVS/media DLL: **оба frontend не объявляются
собранными из одного последнего коммита**.

Rust host и Android targets разделены, provenance проверен. Cargo 1.97.1,
production features, Android NDK 26.3/platform 24; внешняя ФС проверялась
watchdog до и во время сборок, потери mount не было. Android native собран
из закоммиченных входов; APK checked по замороженным Dart inputs, трём
native SHA и подписи прежнего QA. Flutter: `TMPDIR=/private/tmp/`,
`VEIL_SKIP_CARGO=true`. Windows exe/AOT/native SHA проверены до/после стенда.

Перед handover требовались один call ID и пять последовательных срезов
свежего native RX на обоих концах: active, running=true, worker_stalled=0,
packets>0 и age 0–1000 мс. ОС опрашивалась примерно раз в секунду; возраст
аудиопакетов — примерно каждые 0,5 с. Порядок endpoint чисел: Android/Windows.

| Сценарий | Наблюдение |
|---|---|
| Новый звонок на Wi-Fi, автоматическая политика | Incoming 0,157 с; первый fresh RX обоих концов 1,636 с |
| Wi-Fi → cellular внутри этого звонка | Cellular validated впервые sampled через 1,121 с; fresh RX после перерыва через 18,943 / 20,044 с; max native age 18,107 / 19,190 с |
| Возврат Wi-Fi | Тот же call ID; max native RX age 3,274 / 3,418 с |
| Выключить Wi-Fi и сразу начать следующий звонок | Incoming 14,585 с; первый fresh RX обоих концов 16,826 с; затем 25 с наблюдения |
| Контроль: P2P deny у обоих тестовых контактов до звонка | Incoming 0,089 с; первый fresh RX 0,771 / 1,298 с |
| Wi-Fi → cellular внутри relay-only звонка | Cellular validated впервые sampled через 1,049 с; fresh RX обоих концов через 10,296 с; max native age 9,565 / 9,537 с |
| Возврат Wi-Fi в relay-only звонке | Max native RX age 1,311 / 1,177 с |

Все три звонка сохранили свой ID и завершены командами стенда. 173 среза на
endpoint в каждом handover, 54 в последнем новом звонке; неожиданных call ID
нет, tail RX свежий. Максимальные sample gaps: 0,822 / 1,081 / 0,738 с.
[Агрегаты](summary.json) не содержат адресов или идентификаторов.

В auto-серии после первого cellular-события пять dial cancellations пришлись
на первую секунду настоящего network change; далее до Wi-Fi — **ноль**.
Второй переход cellular дал ту же картину. Это согласуется с исправленной
изоляцией, но не доказывает причинного ускорения относительно прежнего прогона.

## Что остаётся

На auto-маршруте transport оставался P2P примерно до 19-й секунды, затем
наблюдался relay и восстановление RX; позже вернулся P2P. Этот порядок сам
по себе не доказывает место всех потерь: relay-only контроль тоже даёт
существенную паузу после validated cellular. Нельзя приписать все 20 с P2P,
вычесть времена двух разных маршрутов как причинный эффект или объявить
BootstrapJoin причиной всей прежней паузы. Маршруты и кэши не фиксировались.
Следующая граница: восстановление overlay/медиамаршрута после готовности
новой сети и доставка/подтверждение replacement channel.

Счётчики могут отражать тишину/CNG. Человеческая слышимость, эхо,
шумоподавление, качество речи и видео в этой серии не проверялись.
NETCALL-01 открыт; native-дефект отмены BootstrapJoin закрыт отдельно.

## Уборка

Оба контакта возвращены к прежнему `followGlobal`; validated Wi-Fi,
wifi_on/mobile_data/stay_on_while_plugged_in восстановлены. QA-контейнеры
закрыты, свои приложения/task остановлены, runtime/staging Windows,
туннель и ADB forward убраны; оба порта свободны. Windows frozen bundle
не менялся. Android QA APK возвращён с побайтной сверкой SHA; исходный
большой QA-контейнер сохранил SHA, отдельный новый профиль оставлен для
будущих повторов. Основной `0.13.94-fingerprint.2` имеет прежний SHA;
пользовательский контейнер не открывался.

Первая попытка возврата QA APK ждала optional Play Protect scan prompt и
истекла по таймауту клиента. Диалог закрыт без изменения глобальной защиты;
повтор установки успешен, результат принят только после сверки APK.
Собственный build staging удалён после сохранения provenance. Private cache
содержит сырые логи/ключи/артефакты, публичный отчёт — только агрегаты.
Push/релиза, изменений сидов, normal APK или own-device mailbox нет.
