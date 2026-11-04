# TTL при запуске и чтении — 2026-11-04

## Подтверждённые пути и результат

На `dd7e3c64` первый физический sweep назначался только периодическим timer
30 с. Отдельные tests воспроизвели пять путей, не полагаясь на сеть:

| Путь | Свидетель до изменения | Локальный результат |
|---|---|---|
| Cold start с уже истёкшей строкой | `start()` не вызвал prune после обработки микрозадач; чат не открывался, timer не наступал | Первый owned sweep запускается сразу, повторяется при готовности текущего group host |
| Первый список сообщений | Provider вернул expired body при ещё существующей raw row, без sweep | Read-time TTL filter использует тот же clock; независим от успешного физического удаления |
| Превью переписки | Conversation provider отдал истёкший `lastMessage`; raw положительный контроль подтверждал исходный текст | Истёкший preview скрывается, contact и raw unread accounting сохраняются до физического prune |
| Повтор обычного сообщения | Пока физический prune удерживался gate, transport получил expired post вместе с живым | Истёкшие rows исключаются до recovery/retry, TTL и tombstone проверяются после async подготовки |
| Точное равенство `post + TTL == now` | Generic `pruneBefore` оставлял строку, хотя domain TTL считает её expired | TTL передаёт cutoff + 1 мкс в строгий generic primitive; следующая 1 мс остаётся |

Первый вариант boundary test был непригоден: микросекунды `DateTime.now`
усекались при записи, и «равная» строка становилась строго старше cutoff.
Зачтённый красный тест использует целые сохранённые миллисекунды. Generic
retention API остаётся строго `before`; меняется только вызов для TTL.

## Lifetime и очереди

`start()` идемпотентен. Immediate cleanup — один owned job, без более частого
периодического timer. Готовность нового текущего group host запрашивает проход
с его актуальными callbacks; повторные notices объединяются. Старый owner не
может его запустить. Одновременный `sweepAllDisappearing()` ждёт уже идущий
проход; больше не возвращает фиктивный ноль до окончания записи. Dispose
останавливает timer, закрывает lifecycle и дожидается уже принятого sweep до
закрытия контейнера. Начатый локальный prune может закончить свою запись;
callbacks после disposal не вызываются.

Пока initial cleanup выполняется, group initial sends/Outbox redrive и запуск
own-history отложены. Байты остаются durable, ожидание локальной очистки не
тратит network backoff. После прохода возобновляются durable controls и
own-history; обычная message recovery сохраняет свой прежний cadence. Call
control не ждёт этот барьер. Это проверено независимой held-prune очередью с
group frame и call frame; это не акустическая/медиаквалификация звонка.

Старая binding pull удаляется синхронно до паузы нового host: иначе её позднее
продолжение могло установить cooldown вместо нового pull. Часовой retention
budget не расходуется на проход, не посетивший ни одной retention-переписки.

## Регрессии промежуточных вариантов и корректность проверок

Пойманы и исправлены до зачтённых прогонов:

- пауза готовности оставляла old history continuation возможность поставить
  cooldown замене;
- пропущенная из-за локальной очистки group попытка ждала лишний 20-с backoff;
- пробный общий `_retryFlush` после cleanup менял give-up status старых
  ordinary rows раньше прежнего cadence; оставлено возобновление Outbox;
- FakeAsync fixture не дренировала real/cached Future из иной Zone. Заменена
  инвентаризацией реальных Timer и lifecycle gates, без skip.

Три прежние fixture предпосылки уточнены, сами invariants сохранены: cold-cap
теперь действительно получает 300 persisted rows **до создания** service;
ACK race и wire binding начинаются после initial maintenance, отдельно от
проверяемого startup defer. Включённый более широкий source guard экрана был
устаревшим ещё на HEAD: `_exportStillOurs` читает текущего владельца только для
сравнения с captured storage. Guard допускает ровно это полное выражение один
раз; остальные dynamic reads по-прежнему запрещены. Production chat screen
не менялся, защиту экспорта не удаляли.

## Проверки

- 1044 основных tests прошли в 48 выбранных файлах, 3 native-conditional tests
  отдельно skipped. Покрыты startup/late bindings, callback owner/revoke,
  история и delivery-state, очередь/ACK/chunks/backpressure, первый cap,
  read-window и UI projections, controlled expiry/retry, inclusive boundary,
  idempotent start, отказ prune и teardown.
- 15 native cases прошли без skip на обычной проверенной HVS: прежние 14
  replacement/edit/orphan cases и новый startup case. Удерживаемый real-worker
  prune на точной TTL boundary дренируется при dispose. Stopped raw message-log
  roots не содержат старого тела и сохраняют соседнюю свежую строку; после
  reopen tombstone сохраняется. Это проверка доступных committed records.
- Analyzer 8 lib inputs и всего `test/` чистый.

Native process A/B/C (production providers/signer, native worker/container,
embedded nodes на локальном relay island), прямой edit-сценарий:

1. A/B — одна личность, C — другая; TTL 30 с уже принят обеими сторонами.
   C offline после получения исходного post; настоящая queued edit на A
   подтверждена до expiry.
2. Обычная background очистка A заменяет edit на void; stopped raw roots
   проверены до application Outbox loader, без target edit/orphan payloads и
   pending marker.
3. C холодно запускается. **Первый** raw API read уже не содержит expired ID;
   от запуска процесса до этого чтения 9270 мс, меньше прежнего 30-с timer.
   Это свидетель отсутствия зависимости от первого periodic tick, не скорость
   самого prune и не latency звонков/доставки.
4. Сохранён прежний void ACK/high-water gate и успешная новая доставка;
   истёкшая строка не возвращается.

Все пять markers есть, test/driver/cleanup 0/0/0, полное время 118,632 с.
24 PID / 28 портов: своих процессов/listeners нет, runtime удалён, reuse нет;
1441 source/package inputs стабильны во время прогона, native SHA неизменны,
Veil `b8647716` / HVS `eceb9158`, dependencies чистые. Private probe не применён.

Вторая независимая process A/B/C серия повторила прежние full/chunked own
snapshot gates на этой же финальной frontend-сборке: обе expired ID действительно
находились вместе с живой setting в очереди до TTL; автоматический sweep убрал
их из всех полных transfers, stopped raw A roots чистые до app loader. После
возврата B retained state и свежая доставка A→B/C работают; cold B без A/C не
воскресил expired chat/journal rows. Все пять markers, test/driver/cleanup
0/0/0; 139,374 с всего сценария, 26 PID / 24 порта, runtime удалён, своих
процессов/listeners и reuse нет; те же 1441 frozen inputs и native SHA.

Оба process сценария прошли с первой попытки этого финального исходного дерева.
Это два локальных JIT/native стенда на одном Mac, не Android/Windows, не A/B
ускорения, не полная latency или multi-device/crash матрица.

## Границы

Initial prune остаётся best effort при отказе хранилища, с последующим periodic
retry. UI projection не объявляет эти bytes физически удалёнными. Она не
пересчитывает unread до успешного prune. Не дана гарантия успешного rewrite
каждой собственной копии при I/O/verification failure или неполном transfer.
Не квалифицированы все peer gap-fill/ingress пути, policy-before-mirror,
изменение политики во время отказа записи, полный clock skew/Android и вся
матрица. Нельзя отозвать bytes, уже переданные native transport/fragmentation.

Mailbox собственных устройств, APK, реле, engine pins/native исходники не
менялись; push/релиза нет. Public отчёт содержит только агрегаты, без реальных
ID, адресов, ключей, исходных тел и raw логов.
