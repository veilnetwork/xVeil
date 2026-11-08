# Native проверка быстрого ACK: отрицательный результат

**Коррекция:** [проверка AOT artifact](../call-aot-provenance-2026-11-08/README.md)
отозвала утверждение о текущем Mac Dart/JIT ниже. Запускался прежний profile
AOT, свежий kernel не использовался. Android AOT был обновлён. Сетевые данные
сохранены для этой фактической пары; effect новых Mac app-правок не доказан.


**Кандидат c5677f38 не доказал исправление задержки ACK на настоящих клиентах.**
Его тестовая модель проходит, но физический путь пока не квалифицирован.

## Состав и исполнение

Android AOT / Mac JIT со всем текущим app `lib/`; native libraries и QA seeds
побитно сохранены от предыдущей серии: Android SDK bbcd967a, Mac c8f4929b,
два isolated Core e974cebe. APK проверен после установки до запуска,
Mac kernel/FFI/signature и actual FFI mapping проверены. Никаких Rust builds
или production upgrades. Один primary call: Wi-Fi 30 с → Cellular 120 с →
Wi-Fi 45 с без host polling телефона внутри интервалов. Затем отдельный
15-секундный звонок с `P2PGlobalPolicy.denied` на обоих устройствах; call и
native telemetry подтверждают только relay. Слышимость человеком не проверялась.

| Primary фаза | Max native audio RX age, Poco | Mac |
|---|---:|---:|
| Wi-Fi | 326 мс | 400 мс |
| Cellular | 10995 мс | 11719 мс |
| Возврат Wi-Fi | 4962 мс | 3971 мс |

Оба движка сохраняли media epoch 1. Все фазы завершились с приростом audio
counters в последние три секунды. По два `candidate delivery unconfirmed`
в Dart logs каждого endpoint; watchdog фиксировал established stalls.
Различия с прошлыми 7,2/4,8 с не являются A/B-регрессией или ускорением:
маршруты и сеть не фиксировались. NETCALL-01 остаётся открытым.

## ACK и контроль модели

Для 4+4 transportInfo transitions source/receiver frame sets совпадают,
все outgoing transitions представлены, оба log rings без dropped rows.
Принятых fast receipts **0/8**. От первого receiver ACK log до первого
ordinary sender delivered — 8,188–48,085 с. На ID до 32 copies.
Калибровка timezone ISO-логов проверена по explicit epoch ACK/delivered
логам того же процесса: максимальное расхождение clock-read 0,999 мс.
Поправка межустройственных часов — по bounded ADB probe; это не измерение
слышимости или только сетевого RTT.

Relay-only control: 29 samples с каждой стороны, native/call route relay,
audio counters +92/+239, max native RX age 387/62 мс; **fast receipts 0**,
включая offer/answer. Это не подтверждает пригодность новой ветки для relay.
Из этих данных нельзя выбрать между отсутствием source proof, несовпадением
pending peer/frame и consent gate. Авторизация не ослаблялась по предположению.
Для следующего захвата добавлены source-owned numeric receipt decisions;
они отдельно проверяются с diagnostics enabled и disabled.

Первый default тест новых диагностических codes ожидал события при выключенном
compile-time флаге и упал; fixture исправлен. Финальные enabled **117/117**
и disabled **117/117** включают privacy guard: в экспорте только числовые
codes, без frame/call/peer токенов. Эти режимы не суммируются как независимые
functional tests. Analyzer чист. Физический прогон выше был **до** этих codes.

## Завершение и границы

Оба calls ended, driver и cleanup exit 0. Apps/collectors/subscribers/runtime
остановлены и проверены. Два test Core с конфигами/state/unit/binary удалены,
production PID/binary/config независимо сверены; test ports свободны.
Main/QA APK и исходный root QA container совпали с SHA до/после, прежние
network/permissions/P2P policy/debug properties восстановлены и сеть validated.
Попытка дополнительного чтения Outbox пришлась уже на lock/teardown и не
дала результата; пустота durable Outbox этим прогоном не доказана.
Raw captures/keys/адреса/IDs остаются private; публичные JSON содержат только
агрегаты и relative times. Push/релиза нет. Собственный Dart build cache
сохранён для ближайшей проверки diagnostic gate, без повторной native сборки.

## Codes следующего захвата

`callSignalDecision`, `code=-1`; обычные state 0–8 не менялись.

| state | Source-owned decision |
|---:|---|
| 9 | send: source unproven |
| 10 | send: attempted |
| 11 | receive: shape/posture rejected |
| 12 | receive: source unproven, exact pending row known |
| 13 | receive: source unproven, pending row unknown |
| 14 | receive: authenticated source, pending row unknown |
| 15 | receive: consent rejected |
| 16 | receive: accepted for existing retirement path |
| 17 | send: posture/reply/size/transport ineligible |

`accepted` — допуск к локальному retirement, не доказательство завершённого
durable commit. Коды не содержат call/frame/peer IDs или native timestamps.
