# NETCALL-01: TCP capture после проверки с минимальным host polling

**NETCALL-01 открыт.** Offline-разбор
[звонка Poco↔Mac](../sdk-tcp-progress-call-2026-11-08/README.md)
подтвердил паузы до появления TCP DATA в capture Core. Новых приложений,
серверов или захватов не запускали, телефон и production не менялись.

От 56 audio cells внутри десяти Mac RX plateau прослежены 108 физических
копий до authenticated Core read и далее до трёх конкретных TCP flows:
opaque/record digest → receiver child → socket binding → captured ports.
У выбранных flows единственная пара SYN generations, нет неоднозначности
четвёрки адресов/портов. Четыре копии без Core read не приписаны какому-либо
TCP flow. Получено 19 наблюдений flow/plateau, не 19 независимых соединений.

Во всех 19 наблюдениях перед matching read найдена пауза входящих DATA
**1097,740–1429,749 мс**, затем рост contiguous prefix и чтение за
**0,062–12,137 мс** после завершающего паузу DATA packet. Это не задержка
одной 256-КиБ части файла и не ожидание обработки уже готового аудио в UI.

Некоторые интервалы содержат чистые ACK: отсутствие DATA не названо полным
отсутствием всех пакетов. В окнах завершения этих пауз не обнаружены
sequence holes длительностью ≥100 мс: данные не лежали в capture весь
интервал разрозненными частями за наблюдаемой дырой. Дроп/потеря до точки
захвата, TCP congestion, ядро/модем телефона и capture scheduling этим не
разделены. Окончательную потерю payload из overlaps/SACK не выводили.

Попытка получить контрольный Mac TCP DATA witness в середине этих окон
дала 0/19. Покрытие Mac TCP bindings неполно; это не доказательство
отсутствия связи с Mac и не основание объявить все остальные пути здоровыми.

Сохранённый TCP_INFO log имеет период около секунды. После строгого учёта
clock bounds внутри соответствующих NIC DATA silences осталось по одному
snapshot в 17 наблюдениях и ни одного в двух. **Дельту sender counters внутри
этих пауз доказать нельзя.** Прежний 1,29-с bracket с acked=const остаётся
более широким наблюдением, а не новым доказательством для каждой NIC паузы.
Новая граница задачи — наблюдение ядра/пути на стороне телефона, а не
уменьшение таймера чтения на Core. Изменения окна аудио не обоснованы.

PCAP/Core journals совпали с SHA исходных collection manifests. Kernel
capture drops — 0 на обоих Core; у B filter count на три packets больше
записанного count, полная безусловная capture completeness не заявлена.
TCP listings разобраны полностью: 21416/27853 rows. Остальные flows,
не сопоставленные с authenticated bindings, не объявлялись пользовательскими.
Parser controls проверяют wrap, out-of-order hole, повтор, idle и DSACK;
первое выполнение нового join исправляло ошибку схемы offline artifact
(`source` вместо `summary.sourceCells`), исходный отказ не является отказом SDK.

All observation inputs сверены до/после. Raw captures, IDs, bindings, clocks,
адреса, порты и digests остаются private. Ранее выполненная очистка стенда
сохранена; source/бинарники SDK не менялись. Push/релиза нет.
