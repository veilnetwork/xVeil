# TTL прямых правок в Outbox — 2026-11-04

## Подтверждённые механизмы

После `498bedba` очистка сообщений и собственных snapshots не затрагивала
отдельную durable копию `WireKind.edit`, адресованную собеседнику. Два теста
на настоящем `editOwnMessage` воспроизвели: после удаления исходного сообщения
по TTL текст правки оставался в Outbox; очередной flush снова передавал его
транспорту. Сбой первой test fixture, которая не дожидалась асинхронной первой
отправки, исправлен до зачтённого повторного красного прогона.

При проверке замены найден второй дефект: `voidSeq` с frame ID попадал под
общий ACK **до** `applyRemoteVoid`. Gate-тест увидел ACK при остановленной
записи; отказ записи уже не мог заставить отправителя повторить слот.

| Случай | Локальный результат |
|---|---|
| Правка пережила TTL исходного сообщения | Удаляется её отдельная queued копия; срок считается от исходного post, не от edit/enqueue |
| Уже существует scoped tombstone | Правка не возвращается после reopen, отключения TTL или отката часов |
| Правка истекла до enqueue | Её тело не записывается в Outbox и не передаётся в live leg |
| TTL истёк во время ожидания первой попытки или redrive | Повторная проверка не отдаёт тело штатной live leg |
| Валидный seq правки | Вместо текста сохраняется идемпотентный `voidSeq` без target ID и body, с прежним возрастом очереди |
| Legacy-правка без положительного seq | Exact compare и локальное удаление без выдуманного ACK/seq |
| Refusal/lost reply/отказ scrub | Состояние восстанавливается из committed roots, обязанность scrub переживает reopen |
| Refusal записи входящего void | ACK не отправляется; повтор того же frame ID применяет слот и получает ACK после сохранения |

## Границы и надёжность

Правило проверяет wire kind, scoped target, исходную outgoing row и действующую
политику. Префикс frame ID не даёт полномочий на удаление: неизвестные targets,
другие conversations, non-edit и повреждённый wire не удаляются этой веткой.
Уже существующая локальная tombstone достаточна независимо от текущей политики.
Для истёкшей live row используется существующий локальный erase без peer-delete
intent; старые event-log версии превращаются в bodyless slots.

Проверки выполняются до enqueue, перед первой live leg, во время flush до
проверки retry/backoff и ещё раз перед выбранным redrive. Ошибка чтения оставляет
durable row, но не разрешает отправить непроверенный edit; другие адресаты
продолжают работу. Очистка также входит в обычный background sweep независимо
от наличия device-group owner.

Для замены используется прежний `replaceOutboxFrames`: все новые байты durable
до атомарного удаления старых indexes и постановки scrub obligation. Разрешён
пустой replacement для локального discard, с теми же peer/wire compare и
scrub-retry. Это не ACK от отсутствующего получателя. Сохраняется первоначальный
возраст очереди, wire void не несёт исходных target/body. Его новый ID зависит
от exact old wire и адресата; повторная очистка не создаёт иной слот.

## Проверки

- 776 основных tests прошли в 35 выбранных файлах; 3 native-conditional tests
  отдельно skipped. Включены TTL boundary, поздняя правка, TTL off, reopen и
  clock rollback после tombstone, legacy seq, чужой scope/non-edit/malformed,
  blocked peer, gates первой отправки и выбранного flush, отказ чтения и
  независимый адресат, прежние mutation ACK и Outbox сценарии.
- 14 native cases прошли без skip с обычной проверенной HVS-библиотекой:
  12 shared replacement contracts, raw-orphan positive control и прямой edit.
  Empty replacement проверен при успехе, отказе и потере ответа retirement,
  с отказом vacuum и reopen. Исходные байты и чужая очередь сохраняются при
  неверном expected peer.
- Native edit case сначала видит настоящий текст в stopped roots, затем
  запускает messaging sweep на worker/container. До application reopen raw
  roots содержат только ожидаемый void: body/target отсутствуют, непустых
  orphan payload records и pending scrub marker нет. После reopen сообщение
  tombstoned, placeholder сохраняет seq.
- Analyzer изменённых lib inputs и всего `test/` — без замечаний.

Отдельный native process A/B/C прогон использует production providers,
signer, worker/container и embedded nodes на локальном relay island:

1. A/B связаны как одна личность, C — другая. C принимает общую политику 30 с,
   B выключается. Исходный A→C post действительно виден на A и C до expiry.
2. C выключается. A через настоящий `/edit_message` создаёт правку; private
   read-only fixture подтверждает ровно одну queued edit с положительным seq.
3. Без ручного sweep/ACK, пока C offline, обычная служба убирает тело и
   оставляет ровно один void; scrub obligation завершена.
4. A остановлен. Raw KV port, до application loader/GC, видит bodyless void с
   ожидаемым seq, ни одной прежней target edit, ни непустых orphan payloads,
   ни pending marker. Raw handle закрыт до старта A.
5. A/C возвращаются. High-water C включает слот, queued void A исчезает после
   ACK. Новое A→C сообщение доходит. После обычного TTL sweep C прежняя строка
   отсутствует; проверяется eventual state, а не мгновенная очистка при unlock.

Test/driver/cleanup — 0/0/0; все четыре квалификационных маркера есть.
24 PID и 30 портов проверены: своих процессов/listeners нет, runtime удалён,
чужого переиспользования портов нет. Все 1438 выбранных source/package inputs
стабильны в течение прогона; обычные Veil `b8647716` и HVS `eceb9158` с прежними
SHA, зависимости чистые. Private commit-stage probe не использован.
139,421 с — полное время сценария, не скорость доставки.

Первый process прогон — test/driver=1, cleanup=0 — не зачтён. Очистка источника,
raw-root и ACK/new-delivery gates там прошли, но финальная проверка ожидала
отсутствие старой строки C раньше первого фонового прохода после restart.
Уточнён oracle: дождаться фактической очистки, максимум 30 с. Product code между
двумя process прогонами не менялся. Отдельно исправлено предусловие void unit
test: high-water считается непрерывно, поэтому перед seq=2 нужен slot=1;
без него фактический high-water 0 не был дефектом записи.

## Что остаётся

Это исправление app-level durable edit copies и границ их live attempts, не
отзыв уже переданных транспорту bytes/пакетов. Не квалифицированы все ожидания
внутри native send, большие fragmented live edits, полный peer-wire ingress,
порядок mirror/policy, clock skew разных устройств, Android и весь forensic
носитель/память. Неполные own-device transfers из предыдущего раунда и другие
body-bearing durable kinds остаются отдельными путями проверки.

Подтверждено наблюдение при cold restart: ранее сохранённая истёкшая строка
доступна raw history API до первого background sweep. В `start()` сейчас
устанавливается периодический timer 30 с без немедленного прохода. UI-видимость
не проверялась; гарантия немедленной очистки при unlock этим раундом не дана.

Mailbox собственных устройств не добавлен. Реле, APK, engine pins и native
исходники не менялись; push/релиза нет. Новые probes живут в `test/`, без нового
application debug API. Здесь только агрегаты, без реальных ID, адресов, ключей,
исходных тел и сырых журналов.
