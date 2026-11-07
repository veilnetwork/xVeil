# Не повторять shutdown после терминальной ошибки writer

**Подтверждён и исправлен лишний барьер reconnect.** После ошибки записи
или истечения idle deadline `writer_task` выходил из цикла и вызывал
`write_half.shutdown().await`. Для буферизованного obfs4 это новая попытка
flush тех же недоставленных bytes. Она могла зависнуть, а session runner
ждал ещё пятисекундный graceful-drain timeout перед abort.

Механизм найден при разборе [длинного Poco ↔ Mac прогона](../reverse-handover-2026-11-07/README.md):
30-с flush timeout, закрытие primary read, ещё 5,003 с до `session.close`,
затем новая session через 0,36 с. Это объясняет отдельное локальное ожидание;
почему сам flush завис, не установлено. Первая пауза другого разговора —
отдельный случай, этим исправлением не атрибутирована.

## Изменение и границы

На write error и write/flush idle timeout writer теперь возвращается сразу:
освобождаются очередь приёма и write half. Уже существующее ожидание
`wire_tx.closed()` будит runner, после чего выполняется обычный reconnect
с новой аутентификацией. Повторной попытки на испорченном потоке нет.

При штатном закрытии очереди прежние accepted bytes дренируются и вызывается
graceful shutdown. Wire, AEAD/ratchet, авторизация, admission, ACK, таймаут
обнаружения неисправного writer (30 с) и обычный drain bound (5 с) прежние.
Терминальная ошибка и прежде завершала сессию без обещания доставки bytes.

## Доказательства

Три регрессионных теста красные на прежнем `runner.rs`, проходят на candidate:

- `write_error_does_not_enter_blocked_transport_shutdown`: BrokenPipe при
  записи, shutdown навсегда Pending. На baseline writer остаётся Pending.
- `flush_timeout_does_not_enter_blocked_transport_shutdown`: запись принята,
  flush Pending, виртуальные часы доведены ровно до прежнего idle deadline.
  На baseline writer снова Pending; на candidate Ready, shutdown calls 0,
  sender queue закрыта.
- `failed_flush_releases_runner_and_registry_without_drain_grace`: настоящий
  SessionRunner/SessionTxRegistry, live producer, silent reader, выключены
  keepalive/idle timeout. После достигнутого flush deadline, без дальнейшего
  продвижения часов, runner завершается, запись registry удаляется, transport
  освобождается. Baseline assertion-red: `terminal flush still gates reconnect
  on drain grace`. Peer EOF/outbox close не могут заменить тестируемый исход.

Полный `cargo test -p veil-session`: **697 passed, 0 failed, 8 ignored**;
один doc-test ignored отдельно. Штатный drain accepted blob, graceful registry
replacement, явная retirement и keepalive-terminal проверки проходят в suite.
Ignored не считаются пройденными.

Сборки/тесты — на том же checkout, без dependency overrides, внешний target
проверяется перед запуском и watchdog во время работы. При красном контроле
временно заменялся только runner; candidate восстановлен с проверкой bytes
перед полным suite. Проверены новые имена тестов в исполненном binary.
Scoped rustfmt чист; workspace fmt обнаруживает прежний порядок mod в
`veil-routing/src/lib.rs`, к этой правке файл не относится и не изменён.

## Физический повтор на SDK c6699c28

Mac/Android FFI и Linux QA Core заново собраны и проверены (1533 frozen
inputs, actual session rebuild, 208 прежних C exports, ABI, post-sign SHA,
загруженная Mac FFI и установленный Android APK). Прежний qualified signed
QA AOT/media/HVS сохранён. Один изолированный Core, obfs4/TCP, P2P denied,
discovery/builtin seeds отключены. [Агрегаты](summary.json).

**Терминальная ветка реально сработала:** в первом разговоре после 30-с
flush timeout `writer_closed` и `session.close` записаны в ту же миллисекунду
по часам телефона. Новая `session.open` — через **354 мс** после close.
Прежнее дополнительное ожидание 5003 мс отсутствует. Это квалификация
конкретного барьера, не причинное ускорение всего звонка в несопоставимых
сетевых условиях.

| Вызов | Входящий | Пять fresh RX | Результат после возврата Wi-Fi |
|---|---:|---:|---|
| Poco → Mac | 1,107 с | 6,592 с | 60 с, тот же call ID, пять конечных fresh; max age 5904 / 1966 мс |
| Mac → Poco | 1,090 с | 30,672 с | **FAIL** через 25,320 с: liveness timeout на обоих endpoints |

Во втором разговоре NetworkChanged на телефоне действительно снял старую
session через ~1,64 с после команды on. Новая canonical session до отбоя
не открылась: два obfs4 client handshake timeout, около +11,76 и +22,84 с.
Это подтверждённая недоставка на восстановлении, **NETCALL-01 открыт**.

На +16–17 с оба приложения попытались локально восстановить медиадвижок;
media epoch и RX counters сменились. После этого native RX age = **-1**,
а не свежий приём: новый движок не получил audio packets. Max положительного
age 13,191 / 13,315 с поэтому не описывает весь последующий разрыв.
В журналах до команд завершения теста: `origin=livenessTimeout`, silence
23 / 22 с. Пользовательский или скриптовый hangup не является причиной.
Это не доказательство тождества историческому отдельному случаю «25 с».

В полном захвате — 21 783 пакета, 225 flows, 217 новых SYN. У всех 71 flows
с наблюдаемыми client payload bytes есть server payload bytes; начальный
ответ всё ещё не доказывает исправность canonical session. В окне второго
возврата четыре incomplete primary/backup handshake имеют ровно по одному
подходящему flow по local port; каждый записал 107–166 client bytes локально,
а серверный NIC не наблюдал ни одного client/server payload byte этих flows.
На клиенте read bytes 0. Это port/time correlation, не межхоповый
криптографический witness; точка потери между сокетом телефона и NIC сервера
не установлена. Нельзя считать эти четыре записи независимыми ошибками:
primary и backup относятся к двум общим попыткам.

Уборка выполнена после успешной полной копии PCAP с проверкой size/SHA.
QA APK/settings/P2P values и stored values восстановлены; обычный APK и
прежний root QA-контейнер совпали по SHA. Собственные apps/logcat/probe/Core/
порты удалены/остановлены, production PID/executable/config/NRestarts прежние.

Подготовка исправлена до зачтённых звонков: первая копия Mac framework
потеряла symlinks и была отклонена codesign; пересоздана с сохранением ссылок.
Первая Android-упаковка ошибочно использовала rollback APK, а не qualified
QA frontend: контейнер не открывался, SHA прежний, упаковка исправлена.
Во время паузы QA Core остановился по 30-минутному RuntimeMaxSec; только он
заново запущен после проверки production. Перед звонками оба точных transport
peer подтверждены **active**, headers CLI разобраны. Эти неудачные подготовки
не считаются тестовыми звонками. Logcat во время driver держал отдельный
supervisor; source/driver hashes после серии совпали.

Следующий контроль — тот же obfs4 endpoint через свободный стандартный
TCP-порт: отделить влияние тестового порта/сетевого пути от восстановления
приложения. Увеличение liveness timeout пока не обосновано.
Production-сиды/пользовательские данные не менялись, push/релиза нет.
