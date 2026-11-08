# Догрузка: не разбирать JSON заведомо обычных сообщений ради адреса устройства

Последний CPU-профиль выделял `addressableOwnDevices` и поиск объявлений в
журнале устройств. В уже существующем sovereign V1 пути селектор полностью
декодировал body каждой строки, чтобы найти `DeviceSyncKind.identityDoc`.
Это включало обычные `msgMirror`, хотя для маршрутизации нужны объявления.

Теперь, если body не содержит ни буквального `identityDoc`, ни обратной
косой черты, полный JSON-разбор для выбора кандидата пропускается. Без
JSON escapes декодированное значение `identityDoc` обязано присутствовать
буквально; при любых escapes остаётся полный прежний parser, включая
escaped ключ/значение и duplicate keys. Наличие строки в payload само по
себе объявлением не становится. Результат используется только для выбора
работы, не даёт адрес, подпись или полномочие.

Оба последующих прохода по строкам и все правила relevant prefix, writer
scope, fork, цепочек, retention, времени, membership и signature сохранены.
Завершённый lookup не кэшируется. Legacy/encrypted/иной control path
сохраняет прежнюю полную проверку. Нового кэша payload/вердиктов, протокола,
таймаутов или sibling mailbox нет.

## Доказательство и регрессии

Два последовательных реальных routing lookup над 64 обычными mirror и одним
объявлением: **130 → 2 полных декодирования**. На baseline assertion-red
получен по числу вызовов, без порога времени. Новое чтение по-прежнему
читает header и проверяет подпись объявления каждый раз; сохранённые байты
журнала совпадают. Счётчик работает только внутри assertion и не экспортирует
body, ключи или вердикты.

Шесть новых семантических случаев: escaped kind, escaped key+kind, duplicate
kind, payload decoy, overwritten kind и malformed candidate. Проверяются
совпадение с полным `deviceSyncState` и повторный отказ после изменения
signature-verifier; work selection не становится authorization cache.
Прежняя матрица chained/unchained, gap/fork/future/retention/revoke также
прошла. Focused 33 — подмножество related, не дополнительная выборка.

**639 related tests passed, 11 skipped отдельно** (group service, own history,
retry lifecycle, history backfill). Analyzer двух изменённых файлов чист.
Непричастный churn от установленного formatter удалён: оставлены только
собственные вставки.

## Native crash/offline квалификация

Один новый A/B/C стенд: 512 входящих C→A, link B, SIGKILL B после наблюдения
141 строки; A/C offline. До сети после перезапуска B сохранены ровно 141
строка, их ID/тела/delivered/canonical positions. Возвращается только A;
все 512 ID/тела/порядок/позиции/delivered сходятся без дублей, completed-history
retries — 0. Ещё один boot B без источников сохраняет полную историю.
Test, qualification и cleanup — exit 0.

Migration clock 32,340 с включает crash/offline/restarts. После возврата из
`start(A)` до сходимости — 6,186 с. Это **не причинное A/B и не доказательство
ускорения всей догрузки**: сокращён конкретный разбор JSON, задержка истории
остаётся активной.

Mac/JIT/loopback, настоящие ratchet и контейнеры. Использована проверенная
release HVS `eceb9158` с прежним SHA; SDK runtime — frozen `c6699c28`, source
checkout — `bbcd967a`. SHA входных FFI/HVS/CLI и их mappings в трёх workers
проверены; 1514 source/dependency inputs неизменны во время запуска. Это
квалификация Dart-правки, не нового native SDK, Android/AOT/WAN. Нового Rust
build не было.

После стенда проверены 34 PID и 50 портов: своих живых процессов/listeners
нет, runtime/контейнеры удалены, native SHA совпали. Production, телефон и
реальные профили не затронуты. Raw evidence private; агрегаты в
[summary.json](summary.json). Коммит без подписи; push/релиза нет.
