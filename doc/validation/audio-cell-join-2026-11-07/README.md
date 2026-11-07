# RTP и стадии отправки при смене сети

**NETCALL-01 не закрыт.** Два новых звонка Poco ↔ Mac выдержали шесть реальных
смен Wi-Fi/Cellular; прежние 8,6 с не повторились. Максимальный post-switch
native RX age Mac — 1726 мс. Это не причинное ускорение: изменения этого раунда
относятся к диагностике, сеть и нагрузка не были фиксированным A/B.

## Что изменено

В SDK `b01c633b` существующий режим `VEIL_RT_TRACE_SEALED_EVERY` получил
Android-источник `debug.xveil.sealed_every`: у embedded app нет окружения
запускающего adb shell. Значение читается один раз, только при отсутствии
environment option. Диапазон 1–50; default остаётся 50, существующий trace gate
не обходится. Process environment после запуска native threads не меняется.
Wire, crypto/replay, admission, приоритеты и квоты не менялись.

Последующий `0c3715b6` сохраняет default 50 и для явно заданного non-UTF8
environment value. Окончательный veil-util suite: **74 passed**, без ignored;
Android/aarch64 check, rustfmt и diff-check прошли. Физические записи сделаны
на `b01c633b` с отсутствующим environment option и Android property=1;
добавочный non-UTF8 guard физически не исполнялся. Предыдущий 73-test запуск
в итог 74 не прибавляется.

Android release-cross-build проверен по чистому SDK/source snapshot, ELF,
новому marker, 208 C exports, фактическому APK SHA, signer и 16-KiB alignment.
Изменена только FFI-библиотека; frontend/media/HVS/seeds прежние. Mac и два
Core намеренно оставлены на проверенных immutable binaries `5d89beb5`, где
полная sampling-настройка уже поддерживалась через environment. Реле получили
operator-only opaque hash tracing. На Poco наблюдались последовательные
source sequence witnesses — property=1 действительно применена.

AOT gate анонимного экспорта прошёл. Подробные RTP/opaque/operator записи
остаются приватными: их поля не добавлены в пользовательский anonymous report.
Значение свойства восстановлено после остановки QA app.

## Стенд и случаи

Два отдельных Core, только явные peers/seeds, discovery/PEX отключены, own
advertise и targets проверены. Listener PID/протокол и загруженные библиотеки
сверены. P2P denied, все recorded active media samples — relay; production
не менялся. Сначала один звонок с двумя переключениями, затем **отдельный**
звонок с четырьмя на тех же процессах/соединениях. Дополнительный driver/plan
зафиксирован до его старта; исходный driver и capture не переписывались.

После baseline — по 60 с post-switch наблюдения и validated target network.
Call ID/PID в каждой серии сохранились. Финальный критерий: пять последних
срезов age ≤1000 мс и рост RX counter. Все восемь case windows прошли его;
это не критерий отсутствия пауз во всём разговоре. Звук человеком, громкость,
эхо и речь под постоянной активной нагрузкой не проверялись.

| Звонок / этап | Post-switch RX age max: Poco / Mac, мс |
|---|---:|
| 1: Wi-Fi baseline | 348 / 383 |
| 1: Wi-Fi → Cellular | 982 / 1524 |
| 1: Cellular → Wi-Fi | 361 / 389 |
| 2: Wi-Fi baseline | 294 / 370 |
| 2: Wi-Fi → Cellular | 1012 / 1525 |
| 2: Cellular → Wi-Fi | 403 / 427 |
| 2: Wi-Fi → Cellular | 1343 / 1726 |
| 2: Cellular → Wi-Fi | 782 / 1133 |

На Poco локально работали bounded/private HTTP stats collector и logcat
именно QA PID. Это сохраняет данные отдельно от host forwarding. Local stats:
**1087/1087** успешных записей, maximum request 270 мс, sample-start gap 880 мс.
Local native log содержит все 1000 payload-RTP cell keys первого host capture
и дополнительные данные второго звонка; начальный участок не потерян.

## Сопоставление конкретных блоков

Endpoint RTP header witnesses сопоставлены с source sealing/send samples по
epoch/sequence/index, затем с полными opaque hashes на Core и authenticated
RTP receipt Mac. Реле не классифицировали media или RTP. Проверены точное
равенство наборов, уникальность payload hashes и соответствие RTP headers;
равенство одних счётчиков не использовалось как oracle.

- Всего **3192** source payload-RTP encrypted cells, **3196** packet witnesses
  с учётом batch. Повторных RTP header identities в этой выборке нет.
- Для **3162** cells наблюдаются Core phone ingress, Core selection к Mac
  и authenticated Mac RTP receipt; эти три набора **совпадают по identities**.
  Они содержат 3166 packet witnesses. Наблюдаемой потери после такого Core
  ingress до authenticated receipt в этой выборке нет. Результат относится к
  логическому cell; судьба каждой его transport copy этим не доказана.
- Для остальных **30** cells authenticated receipt не наблюдался. У **22**
  нет `relay_queued` witness; у **8** он есть, но нет наблюдаемого Core
  dispatcher ingress. Все 30 относятся к post-switch окнам, примерно
  **0,16–1,95 с** после команды. Это не доказательство wire drop: между local
  admission и dispatcher остаются writer, transport и приёмная обработка.
- 3039 cells имеют queue witnesses к двум различным first hops, 131 — к одному,
  22 — без такого witness. Сам admission не объявляется доставкой.

Source-stage измерение начинается на SDK sealing witness. Для всех 3192 cells
есть relay-send, IPC socket-written, daemon-read и handler-enter observations.
Sealing → send pump: median 0,142 / max **1,118 мс**; sealing → handler-enter:
0,698 / **4,358 мс**. Для 3170 cells с relay admission: 0,860 / **4,478 мс**.
Время микрофона/кодека и очередь до этого sealing witness в измерение не входят.
Эти числа относятся к новым случаям, а не ретроактивно к прежним 8,6 с.

Для matched cells clock-offset intersection имеет ширину 25,329 мс; с учётом
миллисекундной гранулярности stamps median end-to-end bounds от sealing до
authenticated RTP receipt — **71,186–98,515 мс**, maximum upper bound —
**1553,375 мс**. Это не mouth-to-ear и не измерение playout buffer.

Следующий непроверенный участок для admitted-but-unobserved cells — реальная
отправка конкретным ordered child, транспорт и ingress до dispatcher. При
повторении долгого случая теперь можно отличить его от source preparation
и от смешения RTP с feedback. Полная причина прежних 8,6 с не установлена;
исчезновение симптома не приписывается переключателю логирования.

## Сохранность наблюдений и cleanup

Core traces находились в journal текущего invocation, а не в node log file;
их наличие проверено без перезапуска. Journal tail/row/file limits не достигнуты.
Все remote archives и файлы сверены по SHA. Private source/kernel/cipher/RTP
metadata не копируются в этот отчёт.

При cleanup выяснилось, что logcat отделил собственную process group. Первый
pull не прошёл SHA-проверку из-за ещё живого logger; он не был засчитан. Точный
logcat child проверен по UID, QA PID и private output path, остановлен, затем
повторный стабильный pull прошёл SHA. Frozen harness не редактировался задним
числом. Отдельный cleanup resume исправил quoting пустого значения в `adb
shell setprop`; после него фактическое исходное значение свойства проверено.

Все свои Core/observers/capture/collector processes завершены, private device
directories/header keys удалены, QA unit/state/runtime/config/binaries и порты
освобождены. На Mac точный app PID завершён, runtime удалён, подпись проверена.
APK, unknown root QA container, user-0 mic grant, Wi-Fi/mobile/stay-on/P2P
восстановлены с независимыми проверками. Production PID/binary/config прежние.
Push/релиза и sibling mailbox нет.
