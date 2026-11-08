# Poco ↔ Mac: новый frontend и смена сети

**Коррекция:** [проверка AOT artifact](../call-aot-provenance-2026-11-08/README.md)
отозвала утверждение о текущем Mac Dart/JIT ниже. Запускался прежний profile
AOT, свежий kernel не использовался. Android AOT был обновлён. Сетевые данные
сохранены для этой фактической пары; effect новых Mac app-правок не доказан.


**NETCALL-01 остаётся открытым.** Физически проверен frontend `b59970fb`,
включая [fresh repair](../call-repair-freshness-2026-11-08/README.md) и
[очистку старых route snapshots](../call-route-outbox-2026-11-08/README.md).
Android AOT и Mac JIT собраны с полным текущим `lib/`; source hashes и
Dart artifacts сохранены private. Native libraries заморожены: Android SDK
`bbcd967a`, Mac `c8f4929b`, Core `e974cebe`; media/HVS совпадают с прошлой
серией. Android plugin platform code и package Dart wrappers — текущие;
это не A/B только двух app-правок. Production не обновлялся.

## Звонок

Один настоящий Poco ↔ Mac audio call, оба direct, P2P policy `contacts`.
Два независимых изолированных Core с публичными UDP reflectors. Wi-Fi 30 с →
Cellular 120 с → Wi-Fi 45 с. Host не опрашивал телефон внутри интервалов;
phone-local collector: 351/351 успешных HTTP-ответов, max sample start gap
940 мс. Host ADB оставался включён. Слышимость человеком не измерялась.
Installed APK проверен по SHA после установки до запуска; Mac FFI проверен
по SHA и actual process mapping; media/HVS — по SHA после codesign.

| Фаза | Max native audio RX age, Poco | Mac |
|---|---:|---:|
| Wi-Fi до переключения | 425 мс | 418 мс |
| Cellular | 4838 мс | **7202 мс** |
| Возврат Wi-Fi | 3458 мс | 6820 мс |

Call и native telemetry согласованно показывают P2P ↔ relay переходы.
Media epoch оставался 1 у обоих endpoints на протяжении всех фаз. В последних
трёх секундах каждой фазы полученные audio counters выросли в той же epoch;
паузы и восстановление подтверждены native age, а не состоянием кнопки.
Два established-stall watchdog события на каждом endpoint; в сохранённых
полных Dart devlogs нет `candidate delivery unconfirmed`. Это отличается
от прошлой серии, но один прогон с другими сетевыми условиями и кэшами
не доказывает причинного выигрыша или устойчивого ускорения.

Отдельно подтверждён остаток control-plane: transportInfo receipt age после
калибровки часов достигал 44,067 с на Mac / 34,291 с на телефоне при
local queue/handler 0 мс в этих логах. Clock-probe half-width 18,895 мс.
Это задержка до Dart receive dispatch; конкретная native очередь/сеть
не атрибутирована. `transportInfo` копии могут уже находиться в SDK или
транспорте: durable cleanup не отзывает их. Число физически удалённых
superseded rows этим захватом не измерялось.

## Завершение

Driver и cleanup exit 0 — исполнение и teardown, не QoE pass. Phone APK/main
APK/root QA container совпали с hashes до/после, прежние mic permission,
P2P policy, network и debug properties восстановлены, original network
validated. Обе test Core/capture/subscribers/config/state/unit/binaries
удалены с проверкой production PID/binary/config и свободных портов.
Mac app/collectors завершены, runtime удалён, подпись проверена повторно.
Own external build target/source/duplicate assets удалены после проверки
сохранённых APK/kernel; новых Rust builds не было. Raw IDs/адреса/keys/
clocks/журналы остаются private. Push/релиза нет.

Следующий участок: разделить позднюю доставку control до Dart и время
подтверждённого fallback до свежего audio RX. Увеличение аудио-окна или
принятие неподтверждённого маршрута этими данными не обосновано.
