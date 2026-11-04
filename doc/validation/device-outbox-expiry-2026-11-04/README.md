# TTL собственных снимков в Outbox — 2026-11-04

## Подтверждённый дефект и локальный результат

На продукте после `ac9298de` истёкшие mirror/edit bodies удалялись из текущего
device journal, но прежние serialized snapshots/chunks оставались в durable
Outbox. Его самостоятельный шестичасовой срок не был TTL переписки.

| Случай | Проверка до изменения | Результат |
|---|---|---|
| Короткий смешанный snapshot | Восстановленный из Outbox JSON всё ещё содержал expired body после успешной очистки журнала | Исправлено локально, живое состояние сохранено |
| Chunked смешанный snapshot | То же, из полной последовательности частей | Исправлено локально, новая полная копия сохраняется до удаления старого индекса |
| Компактная delta `mid`/`mh` | Первый native стенд оставил два expired ID: полный snapshot очищался, две data delta — нет. Отдельные короткий/chunked тесты красные | Добавлена сверка `mid`/`mh` с текущим локальным genesis; компактная форма остаётся компактной |
| Неполная durable передача | Негативная проверка: одной части нет | **Остаётся отдельной работой**. Без полной копии нельзя доказать сохранность остальных данных; новая очистка её не удаляет |

Это исправление проверенного пути complete own-device transfers, а не всей
гарантии TTL для каждого места хранения.

## Как сохраняется надёжность

Очистка рассматривает только текущий локально принятый device group. До decode
прочих payload проверяется group scope в canonical transfer ID. Данные должны
соответствовать SHA-256 всего transfer, destination и количеству/индексам частей.
Неизвестные, повреждённые и неполные формы остаются нетронутыми.

Group owner использует действующую локальную TTL-политику и tombstones. Для
snapshot проверяется полный манифест; для data delta — `mid` и `mh` текущего
манифеста и пустой control delta. Сохраняются точные raw maps оставшихся
подписанных rows и остальные поля исходного payload. Старый снимок не заменяется
сегодняшним более коротким журналом: это могло бы потерять ещё нужное состояние.

Из очищенного JSON создаётся новый digest/transfer ID. Adapter сначала
сравнивает все ожидаемые peer/wire bytes и пишет **все** replacement rows,
пачками до восьми. Между пачками освобождается Outbox lane: посторонние ACK не
ждут большую передачу. Принятая операция фиксирует прежнюю storage session,
а close/erase дожидается её завершения. Входные byte arrays копируются заранее.

Только после повторного сравнения старых и новых записей одним commit
удаляется весь старый index set и записывается scrub obligation. При отказе
стадии исходная полная копия остаётся; при потере ответа после retirement
reload увидит целиком новый образ. Недостающая replacement row не считается
доказательством доставки. Это локальная замена, не peer ACK отсутствующих байтов.

Очистка payload garbage и vacuum повторяются после reopen. Обязанность снимается
только после успеха. Первоначальный возраст очереди сохраняется, silent-peer
probe policy тоже. Блокируются только обрабатываемые transfer IDs, а не весь
сетевой flush. Фильтр имеет owner/binding guards и отсоединяется при teardown.

## Проверки

- 790 основных Flutter tests прошли, 3 native-conditional tests отдельно
  skipped. Включены четыре полного/компактного × короткого/chunked случая,
  неверный manifest hash, inventory bindings, прежние queue/chunk ACK,
  backpressure, concurrent flush и history checks.
- 9 replacement contract cases прошли на fake backing и на настоящем HVS
  worker/container: reopen, exact bytes/возраст, отказ и потеря ответа во время
  staging и retirement, vacuum retry, stale/conflicting records, посторонний
  ACK между cohorts, владение входными bytes и close fence.
- Ещё один native case проверил независимый raw-root oracle: после retirement
  большой копии он действительно увидел более 1024 orphan payload records и
  pending obligation; после очистки — ни одного непустого orphan и нет marker.
  Эти 10 native cases выполнены с обычной проверенной HVS-библиотекой, без skip.
- 6 transport guards: чужой scope, неполная копия, неверный digest, rebind во
  время await, malformed candidate рядом с исправным, публикация нового кадра
  в штатную initial-send lane. Analyzer 9 изменённых lib inputs и всего `test/`
  — без замечаний.

Native A/B/C запускает настоящие отдельные процессы с production providers,
signer, HVS worker/container и embedded nodes на локальном relay island:

1. A/B — одна личность, C — другая. Общий TTL 30 секунд принят заранее, B
   выключен. C→A и A→C действительно видны у источников до истечения TTL.
2. Дополнительно через настоящий queue-only sender ставится полный snapshot
   с обоими исходными телами и неистекающей signed setting row. Private
   fixture-проба подтверждает оба ID и их соседство с живым state в одной
   полной queued copy. Автоматические data delta также остаются в очереди.
3. Обычный background sweep, без ручного вызова, убирает expired rows из
   всех полных transfer этого group; нет partial/malformed candidates,
   live state остаётся, scrub obligation завершена.
4. A остановлен. Контейнер открыт напрямую через raw async KV port, **до**
   Outbox loader, который мог бы автоматически убрать мусор. Проверены
   текущие index roots, descriptors/parts и весь payload namespace: target
   ID нет, partial/malformed нет, непустых orphan rows нет, pending marker
   нет, живое состояние сохраняется. Контейнер закрыт до запуска A.
5. A и B запущены. B получает retained state, свежее A→C сообщение получают
   B и C. Затем A/C остановлены, B холодно перезапущен: expired ID отсутствуют
   в переписке и device journal, неистекающая row сохранена.

Финальный test/driver/cleanup — 0/0/0; 27 PID, 26 портов, своих процессов и
listeners не осталось, runtime удалён. 1434 выбранных source/package inputs
стабильны во время прогона, native SHA неизменны. Обычные Veil `b8647716` и
HVS `eceb9158`, private commit-stage probe не использован. 139,459 с — время
всего сценария, не метрика скорости доставки.

Первый стенд завершился test/driver=1, cleanup=0; он не засчитан. Именно он
показал пропуск компактных delta. Повтор выполнен после соответствующих красных
тестов и исправления. Промежуточные ошибки конструктора/import в новой test
fixture исправлены и не считаются продуктовыми находками или green runs.

## Остаток

Неполный persisted transfer, например после crash до завершения enqueue,
нуждается в доказуемом восстановлении/замене. В этой ветке прежние байты
сохраняются; нельзя объявлять её очищенной. Не охвачены остальные durable
виды, в частности peer-directed edits, весь peer-wire ingress, порядок
«mirror раньше политики», полный clock skew, резервные копии и Android.
Форензика всего носителя/памяти не проводилась: raw-root проверка доказывает
состояние доступных committed records, а scrub идёт по прежнему native контракту.

Mailbox собственных устройств не добавлен. Реле, APK и engine pins не менялись;
push/релиза нет. Private fixture-проба — только в `test/`, нового application
debug endpoint нет. В публичном отчёте только агрегаты, без реальных адресов,
ID, ключей, исходных тел и сырых native-логов.
