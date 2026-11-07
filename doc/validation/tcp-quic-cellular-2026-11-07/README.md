# Аудиопауза на Cellular: TCP / QUIC / TCP

**NETCALL-01 остаётся активным.** Девять новых звонков Poco ↔ Mac через два
QA Core показали паузу и на QUIC без смены сети. Отдельный дефект восстановления
подтверждён регрессионными тестами и исправлен: повторные ACK больше не
выдаются за подтверждение новых данных. Физическая серия выполнена **до этой
правки**; её влияния на паузу пока не измеряли.

## Условия и происхождение сборок

Во всех трёх фазах SDK клиентов и Core — `7d34e4e5`. Mac FFI пересобран из
проверенных исходников; 208 C exports совпадают, подпись проверена. Android
использует ранее проверенный QA native payload с тем же SDK. TCP-фазы имеют
одинаковый APK; QUIC-вариант отличается только двумя seed assets. AOT,
медиадвижок, HVS и прочие APK payloads не менялись; signer и alignment
проверены. Реально установленный APK сверялся по SHA.

Каждая фаза: два отдельных Core, только явные peers/seeds, discovery/PEX
отключены, P2P запрещён; media transport во всех наблюдениях relay. Core и
клиенты используют только выбранный для фазы транспорт. Listener/readiness
и настоящие session URI проверены; перед звонками оба Core видели другой
Core и обоих клиентов. В финальном архиве каждого Core наблюдается только
тот же выбранный транспорт. Сеть телефона была validated Cellular ещё до
старта приложения; переключений Wi-Fi/Cellular в этих девяти звонках нет.

Три отдельных звонка в каждой фазе: инициатор телефон, Mac, телефон. После
свежей пятисрезовой серии с ростом native RX counter — 60 с наблюдения.
Финальный строгий критерий требует running/active, прежний call ID,
worker_stalled=0, RX age ≤1000 мс в последних пяти срезах и роста RX counter.
Он характеризует **конец наблюдения**, а не отсутствие пауз внутри звонка.

| Фаза | Звонок | Native RX age max: Poco / Mac, мс | Финальный критерий |
|---|---:|---:|---|
| TCP-1 | 1 | 597 / 618 | Пройден |
| TCP-1 | 2 | 758 / 859 | Пройден |
| TCP-1 | 3 | 1065 / 1146 | Не пройден |
| QUIC | 1 | 1058 / 1351 | Пройден |
| QUIC | 2 | **5621** / 845 | Пройден после восстановления |
| QUIC | 3 | 1662 / 1106 | Пройден |
| TCP-2 | 1 | 1350 / 1333 | Пройден |
| TCP-2 | 2 | 642 / 767 | Пройден |
| TCP-2 | 3 | 652 / 604 | Пройден |

Все звонки сохраняли call ID/PID и native RX progress; регрессий counters и
ошибок control API нет. Итог финальных проверок — 8/9. Краткие эпизоды около
секунды не имеют двух внутренних срезов peer TX, достаточных для доказательства
непрерывной отправки; не объявлены потерями сети или проблемой DTX. Серия мала,
маршруты/состояние сети не детерминированы: преимущества TCP или QUIC по ней
не заявляются. Слышимость человеком и акустическое эхо не проверялись.

## Подтверждённый QUIC-эпизод

Во втором QUIC-звонке native RX counter Poco не менялся в течение как минимум
**5458 мс** между внутренними наблюдениями; RX age достиг **5621 мс**. В девяти
срезах Mac строго внутри интервала native audio TX counter вырос на **73**.
Это исключает одно лишь молчание источника, но не доказывает его NIC egress.
К концу звонка приём восстановился — поэтому финальный критерий зелёный.

При консервативном учёте границ синхронизации часов:

- Core A видел 64, Core B — 92 Mac-origin media-marker frames; каждому найден
  ровно один phone-directed TX witness в пределах захвата. Совпадение opaque
  preview не доказывает аутентифицированный audio class или wire delivery.
- В полностью внутренних секундных receive windows телефона от A принято
  3 datagrams, от B — 5; все dispatched. Fragment/decode rejection,
  ineligible/rate-limit/violation/unexpected counters — нули в этих окнах.
- На одном соединении A за 2 с socket-admitted bytes и ACK counter не выросли,
  outgoing datagram expiries +30; in-flight 9939 Б при cwnd 7278 Б, PTO=2.
  На аналогичном соединении B за 3 с socket-admitted bytes +1442 Б,
  ACK counter без роста, expiries +47; in-flight до 9929 Б при cwnd 6836 Б,
  PTO=2. Возраст последнего confirmed ACK доходил до 4,70 / 4,62 с.
- Другие соединения к тому же телефону прогрессировали. Это не остановка всех
  соединений; привязка конкретного audio source lane к двум указанным stalled
  connections ещё не доказана. Локальные event/timer/socket-wait срезы не
  показывают многосекундной остановки syscall в этих окнах.

Следовательно, старый TCP head-of-line — не единственное возможное объяснение
пауз. В этом QUIC-эпизоде следующий участок — выбор/восстановление конкретного
исходящего канала Core → Poco и доставка после admission. NIC/transport/source
нельзя склеивать только по соседним временам. Наблюдавшиеся recovery cancellations
пока не объявлены ложными: необходима их привязка к coherent delivery snapshots.

## Исправленный дефект восстановления

Правка SDK — `5d89beb5`. `ChannelRecovery` использовал число **полученных ACK
frames**. Quinn увеличивает
его до проверки, подтверждает ли ACK хоть один ещё учтённый packet. Повторный
ACK range мог обновить baseline ожидания; при PTO=0 мог выдать `Progress`,
из-за которого `ParallelSession` отменял подготовку проверяемой замены.

Теперь при наличии штатного `confirmed_delivery` используются newly wire-ACKed
congestion-counted Data packet bytes/packets текущего route epoch. Это
транспортный прогресс; в него могут входить QUIC control packets, поэтому он
не называется доставкой аудио. Первый snapshot, новый epoch, rollback counters
или смена реализации наблюдений только задают baseline. Непроверенный route
не может отменить замену. Для транспорта без этих counters сохранён ACK fallback.

Без изменений: необходимость PTO + in-flight + реальных expiries, 500-мс stall
guard, 2-с attempt spacing, один общий spare и fairness, selected-channel gate,
аутентификация/parent proof, quota, congestion state и wire protocol. Новые
права, media-role hints или обход congestion limit не добавлены.

Три регрессионных сценария упали на старом коде (два прежних прошли):
повторные wire ACK при стоящей доставке; ложная отмена replacement; новый
route, ошибочно выданный за recovery. После правки они проходят. Дополнительные
guards покрывают реальный confirmed progress, retry spacing после reset,
rollback/смену counters и отсутствие churn без PTO/flight. Полные результаты
проверок: **703 session + 173 transport passed**, **8 ignored** отдельно;
8 focused recovery tests входят в session-набор. rustfmt, diff-check и AOT
gate анонимного экспорта прошли. Отдельный запуск vendor `quinn-proto` tests
из корневого workspace отвергнут Cargo до исполнения: пакет с dev-dependencies
не входит в workspace. Его тесты не засчитаны; семантика counters проверена
по исходникам, vendor-код не менялся. Детали — в `summary.json`.

## Поправка к прежнему стенду

При подготовке обнаружена **ошибка моей конфигурации QA-стенда**: Core B
объявлял host Core A в `listen.advertise`, хотя explicit peer/seed targets были
верными. В этой серии исправлены own advertise и targets обоих Core с явными
assertions. Это не дефект xVeil и не исправление production-конфига.

Прежние захваты остаются свидетельствами наблюдавшихся TCP sequence holes,
RX counters и пакетов; полноценной квалификацией discovery/failover при
корректной топологии их считать нельзя. Это дополнение относится и к
[прежнему phone-close-cause стенду](../phone-close-cause-2026-11-07/README.md).
Read-only проверка двух выбранных production-hosts показала правильные own
advertise hosts; остальные production-hosts этим не квалифицированы.

## Гигиена и продолжение

Сверены 295 observation inputs и 21 harness-файл в каждой из трёх фаз.
Remote archives проверены по размеру/SHA и каждому файлу. Сначала остановлены
свои observer/capture, затем QA Core; QA units/state/runtime/config/binaries
удалены, порты освобождены. Production PID/binary/config не менялись.

Точные Mac PIDs завершены (после grace потребовался SIGKILL), runtime удалены,
подпись app проверена. QA-приложение телефона остановлено, прежние QA APK,
mic permission, Wi-Fi/mobile/stay-on и P2P choices восстановлены; старый
неизвестный QA container и основной APK побайтово прежние. Сырые журналы,
идентификаторы, адреса, keyed previews и SHA payloads в этот отчёт не включены.

Следующий физический раунд должен проверить правку recovery на Poco с теми же
ограничениями и новой provenance-проверкой бинарников. Затем — повтор смены
сети в активном звонке. Отсутствие паузы в коротком прогоне не закроет весь
NETCALL-01. Push/релиза и sibling mailbox нет.
