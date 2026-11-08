# NETCALL-01: cold pool и ранняя публикация ordered readiness

SDK `cb54608d` устраняет подтверждённый компонентный дефект предыдущего
раннего publisher: вызов `prepare` на полностью пустом TCP child pool
резервировал слоты pending-отправителям до появления первого child. При
завершении outgoing slot 1 раньше slot 0 первый запрос мог остаться Warming,
а более поздний получить единственный готовый канал.

## Воспроизведение и границы исправления

Новый тест сравнивает одинаковые завершения с ранним `prepare` и без него.
Используются production `ParallelChannels::prepare`, `mark`, assignments,
настоящие parent/exporter-bound proofs и шифрованная ordered-передача кадра.
Виртуальные часы не двигаются: периодический tick не определяет результат.

Исходящий completion в slot 1 вводится явно, worker остановлен. Это
компонентная модель порядка завершения, **не полный исходящий TCP handshake**.
Контроль без eager prepare: первый запрос Ready, второй Warming. До фикса
ранний prepare давал обратное; regression выполнил ровно один тест и упал
на этом различии. Первоначальная ошибка типа в test wiring не засчитана как
regression-red. После исправления оба режима дают Ready первому, и полный
кадр проходит через зашифрованный child.

Ранний publisher теперь не вызывает `mark`, если все слоты None. При наличии
child он продолжает использовать прежние проверки parent/readiness; обычные
completion/timer passes, ownership, лимиты, FIFO и wire не менялись. Правка
не переносит канал здорового владельца другому. Более старое поведение
периодического `mark` на cold pool не менялось; универсальное устранение
всех ожиданий первого child не заявляется.

Проверки: **712 session passed / 8 ignored**, 4 целевых binding/readiness
теста, scoped Clippy lib+tests с прежним исключением `manual_async_fn`,
Android/aarch64 release FFI check и rustfmt/diff-check — passed.

## Физическая квалификация

Свежий SDK `cb54608d` собран для Poco/aarch64, Mac/arm64 и двух изолированных
QA Core/Linux. До установки проверены чистый SDK, 1055 source/config files,
SHA артефактов, архитектуры, post-codesign SHA Mac, 208 неизменных C exports,
подпись APK и неизменность всех его payload, кроме FFI. AOT/media/HV/seeds
заморожены: это квалификация native-изменения, не новой полной Flutter-сборки.
Read-only observer CLI имеет отдельную зафиксированную provenance.

Два relay-only звонка Poco → Mac, в каждом Wi-Fi → Cellular → Wi-Fi;
каждый переход наблюдался 60 с. Проверялись прежние PID/call ID, целевая
validated-сеть, последние пять RX ages ≤1000 мс и продвижение RX обоих концов.
Все **6/6 финальных окон passed**, но **NETCALL-01 остаётся подтверждённым**.

Ниже максимальный native RX age после baseline/возврата switch-команды:

| Звонок / фаза | Poco | Mac |
|---|---:|---:|
| Первый baseline Wi-Fi | 62 мс | 372 мс |
| Первый Wi-Fi → Cellular | **10965 мс** | **10905 мс** |
| Первый Cellular → Wi-Fi | 63 мс | 388 мс |
| Второй baseline Wi-Fi | 53 мс | 335 мс |
| Второй Wi-Fi → Cellular | **11754 мс** | **11704 мс** |
| Второй Cellular → Wi-Fi | 401 мс | 507 мс |

Первый Cellular-эпизод: RX обоих концов стоял **10,811 с** уже после первого
наблюдения Android validated Cellular. Все десять network-срезов строго
внутри оставались validated Cellular; это не доказательство готового TCP.
Native TX собеседников за внутренние окна продвинулся +162/+46; независимый
phone collector дал 15 внутренних срезов с тем же RX. Погрешность связи
часов ≤46,1 мс. Отдельный Mac flat 2,143 с также сохранился.

Во втором звонке максимальный flat **11,236 с** закончился до первого
наблюдения validated Cellular: его нельзя целиком приписать ожиданию после
готовности сети. Но отдельно после этого наблюдения **оба RX стояли ещё
10,206 с**, с девятью validated Cellular-срезами строго внутри; у телефона
был также flat 3,796 с, у Mac — 4,344 с. Эти интервалы не объединяются в
одну непрерывную паузу. Missing native stats и разные media epochs не
склеиваются; у первого звонка два Mac-среза media repair остаются unknown.

Это источники microphone/ambient/DTX. Непрерывная речь и человеческая
слышимость не квалифицируются. Серия не A/B: причинное ускорение/регрессия
не объявляются, компонентный фикс не объявлен решением этих пауз.

## Покадровая локализация

Для первого phone flat 10,811 с 180 конкретных Mac-origin RTP cells
наблюдаются на Core ingress. Стадии для созданных внутри flat cells
учитываются по всему захвату, не обязательно внутри самой паузы. Из них 91
имеет фактический target enqueue
accepted и target selection к телефону, 89 — только Missing. На последнем
участке есть **63 physical record copies** с локальным flush и без
наблюдаемого phone read; ещё есть незавершённые/error copies. Это не
утверждение о 63 разных cells: копии и логические кадры учитываются отдельно.
Не все selected-ветки имеют regular record-send witness.

Во встречном flat 52 конкретные phone-origin source cells не наблюдаются
на Core ingress. Только у **28 разных cells** есть regular record-send witness:
52 physical attempts, 50 local flush и 0 remote reads. У остальных 24 такого
witness нет. Во втором post-validation flat 10,206 с: из 52 source cells
**26 имеют по две physical attempts** к разным Core — все 52 copies flushed,
remote reads нет; у остальных 26 regular send-attempt witness не наблюдается.
Множества проверены отдельно: число физических копий не подменяет число cells.
В захвате сохраняются оба участка — до record send и local flush → read.

Локальный AsyncWrite/flush **не доказывает NIC egress, TCP ACK или потерю в
провайдере**. Следующая проверка — lifetime конкретного TCP child после
handover и связь его записи с remote read/сетевыми наблюдениями. Шестнадцать
phone source-pressure observations — aggregate, не индивидуальная атрибуция
каждого кадра. Политика relay FIFO/квот не изменялась.

Диагностическое покрытие проверено: на обоих Core до handover реально
наблюдались ordered records и queue outcomes. Полные журналы ниже лимита
чтения 200000 строк, record observations ниже cap 100000, точных trace-limit
markers нет. Отдельные NodeLogger-файлы проверены: FIFO wait rows **0/0**.
Accepted/Missing — попытки, не количество потерянных логических сообщений.

## Завершение стенда

Source/config snapshot, все 40 frozen harness files и identity probes сверены
после звонков. Архивы обоих Core и каждый member проверены по SHA. Свои
collectors/apps/Core/observers остановлены, процессы и порты освобождены,
временные server units/config/state/stage удалены. Прежний QA APK, основной
APK и старый QA root container сверены по SHA; сеть, microphone permission,
четыре operator properties, stay-on и P2P choices восстановлены. Независимые
проверки подтвердили прежние production PID/restarts/executable/config.

Push/релиза нет. Raw записи, ID, адреса и корреляционные метаданные остаются
в private evidence и не входят в этот документ или anonymous export.
