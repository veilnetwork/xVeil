# History: не читать строку повторно без исправления состояния

После применения history mirror клиент загружал ту же строку, даже если в
событии нет ни edit revision, ни `historyDelivered=true`. Результат такого
lookup не использовался: отсутствие строки также не приводило к отказу.
Теперь при отсутствии этих двух видов коррекции лишний lookup пропускается.
Это убирает serialized storage work; **не каждый warm lookup является RPC**,
поскольку allocator/fold могут быть закэшированы. Пропорционального сокращения
физического I/O или ускорения всей догрузки не заявляем.

Проверка доступа после применения остаётся до раннего return. Границы
cohort commit, передача результата durable publication, admission и cursor
checkpoint сохранены. Edits/delivery-state correction по-прежнему загружают
строку и используют прежний merge/persistence путь. Протокол и sibling
mailbox не менялись.

## Регрессии

Два теста через настоящий MessagingService/HVS и fake KV отдельно создают
64 входящих delivered и 64 исходящих sent без state corrections. Observer
считает обращения к хранилищу **после** завершения обычного mirror applier.
На прежнем production-коде оба теста дали assertion-red: 64 вместо 0.
После исправления — 0. Сверены все ID, тела, direction, status и positions,
четыре durable cohorts по 16, завершённый cursor и пустой error journal.
Подготовительные чтения не скрываются и не считаются устранёнными.

159 связанных history/backfill/retry tests прошли без skips. Analyzer для
production и двух изменённых test files — без замечаний; format/diff чисты.
Весь набор после фикса выполнен один раз; это не сумма повторов двух тестов.

## Native: входящая история и crash/reconnect

Существующий backlog fixture дополнен opt-in
`XVEIL_E2E_BACKLOG_DIRECTION=incoming` при `XVEIL_E2E_MIGRATION_ONLY=1`.
C отправляет A 2000 сообщений, затем B добавляется к личности A.
Это упражняет state-free incoming history, в отличие от прежней исходящей
delivered истории с `historyDelivered=true`. Sender хранит полный oracle;
fixture сначала ждёт совпадения receiver ID/order, затем проверяет миграцию.

Первый запуск исключён: после последнего send receiver A ещё держал 1999/2000,
а новый fixture преждевременно считал его полной исходной историей. Отказ
произошёл **до linking/crash B**. Полный oracle перенесён к отправителю;
реальное ожидание доставки сохранено. Первый run и его очистка сохранены,
это не исправление product delivery и не зачтённое прохождение миграции.

Новый отдельный прогон завершён с test/qualification/cleanup exit 0:

* B остановлен SIGKILL после наблюдения 542 сообщений.
* A/C offline; до создания сети нового B найдены 573 строки, включая все
  542 наблюдённых ID/тела/delivered/canonical positions, без дублей/пропусков.
  Дополнительные in-flight строки проверены по полному source oracle.
* Возвращается только A. Все 2000 ID, тексты, позиции, delivered и порядок
  сходятся; completed-history retries — 0.
* После повторного отключения A/C и нового старта B до сети сохранены все
  2000 строк и их состояние.

Всего migration clock — 46,405 с с crash/offline/restarts; от возврата из
`start(A)` до сходимости — 20,446 с. После последнего открытия A наблюдены
45 полных неповторённых primary page replies: source stage median 78,186 мс,
receiver stage median 245,192 мс. Есть один repeated query, исключённый из
wire stage pairs; это не повтор завершённой истории. **Нет парного A/B:**
оставшиеся ожидания догрузки активны, скорости прежних outgoing сценариев
не считаются контролем этой incoming серии.

Три Mac/JIT provider процесса, loopback Core, настоящие ratchet и контейнеры.
Native artifacts зафиксированы на ранее проверенном SDK `c6699c28`, hashes
совпали до/после, FFI/HVS наблюдались в mappings трёх живых workers. Source
SDK checkout `c8f4929b` не выдаётся за runtime SDK. Это не Android/AOT/WAN
квалификация и не проверка новых SDK-правок. 1509 source/dependency inputs
совпали во время run; после него уточнён только комментарий про RPC, exact
comment-only replacement проверен отдельно, исполняемый код не менялся.

Оба стенда очищены: 15/27 PID, 15/25 портов проверены, своих процессов и
listeners нет, runtime/контейнеры удалены. Production/реальные профили/телефон
не затронуты. Raw evidence остаётся private; public summary — только агрегаты.
Коммит без подписи, push/релиза нет.
