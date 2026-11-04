# Полная durable-копия chunked snapshot до первой отправки — 2026-11-04

База: `6ad130e0`. Локальный цикл без push/релиза, изменения native ABI,
движков, APK или сидов. Mailbox собственных устройств не добавлялся.

## Подтверждение

Прежний sender сохранял обычный большой snapshot по одному кадру, а queue-only
ответ — пачками до восьми. Уже сохранённые части могли отправляться до того,
как существовала полная durable-копия. После потери ответа хранилища оставались
1 либо 8 частей из 17. При restart получателя/отправителя недостающие байты
могли уже не иметь transport-копии. TTL-фильтр обоснованно отказывался удалять
такой неполный смешанный payload: это потеряло бы и живое состояние.

Восемь проверок прежнего sender дали настоящие assertion-red: ordinary/native
HVS × awaited/queue-only × первый send/потеря commit reply. Проверяется точная
полнота и исходные bytes, не равенство двух пустых историй и не latency threshold.
Первая ошибка конструктора fixture была compilation error и не засчитана.

## Изменение

`Storage.enqueueOutboxTransfer` публикует все логические кадры передачи одним
атомарным набором индексов. Принятая запись закрепляет storage session и
владеет исходными bytes до ожидания lane. Повтор требует точного совпадения
peer/wire; возраст существующих кадров сохраняется. Границы — один получатель,
4096 кадров, 16 МиБ wire и прежний лимит одного storage payload.

Для небольшого transfer payloads/indexes остаются одним commit. Максимальный
snapshot выявил отказ промежуточного кандидата: HVS ограничивает одну транзакцию
1024 log append. Лимит не увеличен. Большие копии предварительно сохраняются
payload-only cohorts (до 8 кадров / 32 КиБ, отдельный большой кадр остаётся
в пределах собственного лимита), затем публикуется весь index set одним commit.
Во время staging новые кадры не видны Outbox и не могут быть отправлены.
Marker существующего cleanup-контракта записывается вместе со staged bytes;
при отказе/restart неиндексированные данные удаляются с повторяемым scrub.
При потере ответа финальной публикации загрузчик видит полный образ.

Весь admission остаётся в одной Outbox lane: это преднамеренно удерживает
ACK/cleanup от удаления ещё не опубликованных staged records. Это ограниченная
операция, но большая передача может задержать другие операции этой lane;
уменьшение общей задержки и отсутствие влияния на звонок здесь не доказаны.
Постоянного отдельного архива тел или нового формата transport не добавлено.

Sender начинает live legs после durable admission. Awaited путь сохраняет
ожидание обычной ограниченной сетевой попытки; queue-only ответ не ждёт сеть
в ingress. У awaited пути сохранена попытка после startup cleanup; queue-only
путь этот барьер не ждёт. Небольшой single-frame путь по-прежнему использует
обычный enqueue.

Отдельная регрессия кандидата поймана двумя ordinary/native red: после TTL
cleanup начальный sender повторно enqueued 16 уже удалённых частей. Теперь
он не сохраняет кадры повторно. Перед live attempt выполняется O(1) exact
peer/wire lookup текущей записи, без обхода всей очереди; retired copy не
восстанавливается. Ratchet reservation/checkpoint и прежние transport policy
остаются в единой обычной отправке.

## Проверки

- [Sender fixture](../../../test/group_transfer_atomic_admission_test.dart):
  awaited и queue-only, lost reply, cold reopen, последующая TTL-перезапись
  с сохранением unrelated state, expiry внутри первого send. Также ровно
  максимальные 3 800 000 UTF-8 bytes и отказ размеру +1 до enqueue.
- [Storage contract](../../../test/outbox_transfer_storage_test.dart): отказ до
  commit, потеря ответа, конфликт existing id, владение bytes и close fence,
  отказ/потеря ответа payload staging и потеря ответа финальной публикации.
  Для staged-failure до loader видны raw payloads без новых Outbox indexes;
  после cleanup нет их доступных records и marker, unrelated frame сохранён.
  Для publish-lost полный образ сохраняется, cleanup его не удаляет.
- [Queue regression](../../../test/group_source_queue_test.dart) проверяет
  отсутствие network/ACK при отказе нового transfer writer, отдельно для
  маленькой и chunked формы. Старый failure double был расширен под новый
  порт; его первоначальный bypass не выдан за продуктовое прохождение.
- Учитываются также прежние chunk ACK, revoke/admission, mixed/legacy,
  backpressure и malformed/digest guards. Они не ослаблены.

Одна промежуточная fixture неверно ожидала удаления всех payload records после
publish-lost; исправлено ожидание сохранения живых indexed данных. Два таких
assertion-failure не являются находками продукта.

Финальные scoped серии: **26 passed без skip** (13 настоящих worker/native HVS
cases и 13 ordinary). Широкая регрессия: **1495 passed / 43 conditional skipped**
в 84 файлах; skip не выдаются за прохождение. Analyzer пяти lib inputs и всего
`test/` — без замечаний.

Native process A/B/C прошёл все пять gates настоящего own-device TTL/Outbox
сценария: до expiry подтверждена mixed queued copy с обоими телами и живой
setting row, обычный sweep очистил все полные queued transfers, остановленные
raw roots не содержали expired bodies/непустых orphan payloads, новая доставка
прошла. B после cold restart при offline A/C сохранил живое состояние без
возвращения expired IDs. Это end-to-end regression с production providers,
signer, HVS worker и SDK, не физическое воспроизведение всех injected failures.

Test/driver/cleanup **0/0/0**. Проверены 28 PID / 29 портов, своих живых процессов и
listeners нет; runtime удалён. Все 1458 выбранных source/test/package hashes и
native SHA неизменны во время прогона; Veil/HVS sources clean. 145.05 с — время
всего сценария, не метрика доставки и не A/B latency.

## Остаток

Исправлено появление НОВОГО неполного logical transfer при прерванном admission.
Уже существующие orphaned legacy partials без полной transport/source-копии
этим не восстанавливаются и не удаляются слепо. Нет ACK отсутствующих частей.
Отдельные shared-document transfers используют прежний путь; общий результат
на них не переносится. TTL внутри уже начатого native send/fragmentation,
вся policy/clock-skew матрица, Android/AOT и общая latency не закрыты.
