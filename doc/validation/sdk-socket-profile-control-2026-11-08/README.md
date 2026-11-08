# NETCALL-01: профиль сокетов Veil и контроль наблюдения по ADB

**Подтверждено:** штатный TCP-профиль Veil применён на телефоне и echo-серверах.
Все 22400 кадров получены, MSS телефона остаётся 1188 Б. При обычном host
опросе секундные паузы сохраняются; в одном прогоне с остановленным host ADB
максимум RTT — 618 мс. **Причинная роль ADB не доказана; NETCALL-01 открыт.**
Product-код, параметры аудио и transport defaults не менялись.

## Зачем другой контроль

[Предыдущий TCP_INFO-контроль](../tcpinfo-path-control-2026-11-08/README.md)
использовал системные настройки сокетов. В исходниках Veil уже реализованы
MSS 1200 до connect/listen, SO_SNDBUF 64 КиБ и TCP_NOTSENT_LOWAT 4096.
Новая серия повторяет эти defaults; это всё ещё самостоятельный C executable,
а не вызов SDK, ratchet, onion relay, медиа или UI приложения.

На Android профиль применяется к raw sockets до connect и к TLS sockets
через curl socket callback. На серверах MSS установлен на listener до listen,
остальные параметры — на accepted sockets. Readback проверяется, не только
факт вызова setsockopt. На телефоне получены MSS 1188 с TCP options,
SO_SNDBUF 131072 Б после удвоения Linux и LOWAT 4096; nodelay включён.
На обоих Linux-серверах эти ограничения также проверены перед передачей.

Источник сохраняет TCP_INFO и cadence. Отдельный native observer пишет в
свой файл default network ID, transport/VALIDATED, Awake/power/Doze snapshots.
Он работает и без host ADB, не использует stdout источника; descriptor'ы
сокетов имеют CLOEXEC. В этих файлах нет адресов, имён сетей или payload.
Период observer — около 10 с; краткие события между срезами не исключены.

До серии прошли Android USB-loopback normal/1100-мс held echo, по 60/60
кадров на четырёх каналах, с readback профиля. В held-контроле TCP ACK
progress продолжается — диагностируется именно удержание echo приложением.
Первый Mac-only setup отклонил pre-listen TCP_MAXSEG; он не зачтён как
прохождение. Успешные контроли используют Linux/Android enforcement и
поддерживаемый Mac fallback. Собственные reverse mapping и серверы убраны.

## План и результат

Четыре соединения: TCP и TLS к каждому из тех же двух адресов. Кадр 512 Б,
общий tick каждые 50 мс, 40 КиБ/с полезной нагрузки на направление.
Полное содержимое echo проверяется, skipped/непринятые кадры учитываются.
Перед каждой фазой — проверка target network/VALIDATED и новые sockets.
Это не handover внутри сохраняемого соединения.

| Фаза | Sent / echoes, все каналы | Max RTT | Max receive gap |
|---|---:|---:|---:|
| Wi-Fi до, 20 с | 1600 / 1600 | 280 мс | 214 мс |
| Cellular, обычный host ADB, 120 с | 9600 / 9600 | 1463 мс | 1157 мс |
| Cellular, host ADB остановлен, 120 с | 9600 / 9600 | 618 мс | 470 мс |
| Wi-Fi после, 20 с, продолжение серии | 1600 / 1600 | 137 мс | 70 мс |

Пропусков, дублей, повреждённых кадров, skipped work, missed ticks,
незавершённых подач и socket I/O errors нет. Max producer gap <62 мс,
local write wait <13 мс. RTT и receive gap — разные метрики; max RTT
не является one-way audio latency. Mac smoke перед серией — по 40/40
кадров каждого канала, отдельно от этих итоговых counts.

В Cellular при обычном наблюдении median RTT TCP R1/R2 — 161/101 мс,
TLS — 169/110 мс; p95 — 1123/973 и 1138/992 мс. Без host ADB медианы
169/100 и 169/110 мс, p95 — 386/312 и 382/323 мс. Различается прежде
всего хвост, не постоянная базовая задержка.

Во всех телефонных TCP_INFO samples MSS 1188: прежние MSS 48/закрытие
двух каналов default-profile контроля здесь не повторились. Это не
причинный A/B старого и нового профиля: другое время, соединения и радио.

## Что означает ADB-off

После наблюдения живого native PID, start и readback остановлен только
ADB server на Mac. Телефонный adbd и кабель остаются; питание подключено.
Forward/reverse mappings перед остановкой пусты, других устройств нет.
Во время интервала controller не вызывает adb; получает небольшие tail
наблюдения своих echo-services по SSH. Во всех 99 host checks listener ADB
отсутствует. Затем восстановлен прежний NATIVE/forced backend и повторно
проверен **тот же PID**, без перезапуска native job по истечению ожидания.

Перед остановкой проходит стартовый интервал: его консервативная верхняя
граница в source time <1,12 с. При сравнении кадров, созданных в 10–110 с,
максимумы остаются теми же: 1463 против 618 мс. Startup под ADB не выдан
за полностью автономный handshake. Перезапуск host daemon меняет его PID,
transport numbering и место собственного log; это не рестарт приложения
или production Veil. Backend и прежние forward/reverse mappings восстановлены.

В обоих мобильных прогонах 12 native environment snapshots: одна и та же
наблюдаемая default mobile network, VALIDATED, Awake, питание, Doze/Light Doze
ACTIVE. В обычном host опросе 12 срезов содержат один и тот же ADB transport ID;
переобнаружение USB в эти срезы не попало. Вне этого участка журнал host ADB
содержит многочисленные USB read failures/kicking — причина пока не установлена.

**Это одна последовательная пара, не доказательство ADB-causality.** Вместе
с присутствием daemon убраны host shell/proc polling и дополнительные
host-triggered dumpsys; native observer остаётся. Состояние сети меняется
во времени. Отдельно USB-ошибка, влияние опроса и радио ещё не разделены.
Нельзя объявлять исправление пользовательских звонков или всех пауз.

## TCP и продолжение после сбоя наблюдения

При обычном host опросе phone not-sent достигает 7168 Б, RTO — 3124 мс;
без host ADB not-sent равен нулю в samples, RTO достигает 1232 мс.
Retransmissions сохраняются в обоих прогонах. LOWAT 4096 — readiness
threshold с допустимым overshoot, а не жёсткий cap каждого текущего write.

Server echo work достигает 268 мс, log work <2,6 мс. Поэтому server arrival
intervals нельзя автоматически объявлять чистой сетью: echo backpressure
может откладывать следующую обработку. Общий capture всё ещё не NIC trace.

После трёх завершённых фаз ADB-вызов чтения owner marker временно вернул
ошибку, из-за чего основной controller остановился до запуска последнего
Wi-Fi. Затем directory/marker оказались на месте; отсутствие файла не
подтвердилось. Первый cleanup телефона тоже не прошёл это чтение.
Обе пары remote services были остановлены/удалены с проверкой production.

Перед продолжением проверены отсутствие нового phase intent/output и всех
своих активных native processes. Архив первой invocation сохранён. Только
**незапущенный** Wi-Fi этап выполнен с новым lease своих серверов, теми же
frozen source/binary/runtime inputs и совпавшим production baseline.
Read-only/idempotent observations повторялись отдельно; запуск native не
повторялся после неоднозначного ответа. Completed native jobs не перезапускались.

Postprocessor различает invocation вместе с session ID, проверяет оба
набора server sequences, guards и provenance. Исходный controller failure
сохранён; прерванная pipeline не объявляется непрерывно зелёной. Все четыре
фазы после продолжения проверены по фактическим данным.

## Проверка ещё одного кандидата

Отдельный Android plain-TCP loopback с тем же send-buffer/LOWAT/MSS
профилем и намеренно малым receive buffer проверил крупный write. Попытка
подать 64 КиБ одним send и подача порциями по 4096 Б дали одинаковые
accepted-before-drain 5346 Б и peak not-sent 4158 Б. После снятия backpressure
в обоих вариантах все 65536 Б проверены побайтно, sockets закрыты.

Дополнительное дробление Linux writes не обосновано этим результатом.
Это один kernel/plain-TCP контроль; TLS buffers, все ОС и все комбинации
не объявлены квалифицированными. Локальный helper завершён и удалён.

## Следующее действие и восстановление

Нужен настоящий SDK/звонок с минимальным host polling. Существующая
[opt-in TCP trace](../../../third_party/veil/crates/veil-transport/src/tcp_trace.rs)
уже снимает MSS/send-buffer/not-sent/RTO/retransmission counters. Для такого
же разбора ей недостаёт sent/acked/received bytes и readback LOWAT; эти поля
надо добавить с returned-length guards, unsupported=None и проверкой, что
private socket trace не попадает в анонимный отчёт. В этом раунде SDK не менялся.

Все свои процессы, directories, binary/token/CA, reverse mapping и временные
server units/credentials удалены. Исходные Wi-Fi/data/stay-on и validated сеть,
main/QA APK и QA root container сверены после полного восстановления.
Контейнеры не открывались, приложения не устанавливались/не запускались.
Production PID/restarts/binary/config обоих серверов проверены независимо
после обеих invocations. Frozen inputs совпали; resume/postprocessor имеют
отдельный provenance. Raw records/operational metadata остаются private.
Коммит без подписи, push/релиза нет.
