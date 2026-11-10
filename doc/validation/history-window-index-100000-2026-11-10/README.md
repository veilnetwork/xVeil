# Страницы истории по текущему индексу ключей — 2026-11-10

## Механизм

Обычный unrestricted history-page путь получал полный список сообщений
разговора и заново проходил его порядок для каждой страницы. На архиве
100000 строк это повторяет линейную работу сотни раз, хотя wire-страница
содержит не более 256 строк. Добавлена optional storage projection
`MessageHistoryWindowReader`: HVS один раз строит wire-order индекс ключей,
затем на текущем fold выбирает exclusive cursor бинарным поиском и отдаёт
только нужное окно. Ключи сортируются по milliseconds/message-ID тем же
алгоритмом ordered/two-run/fallback, что и обычная история.

Индекс хранит только ссылки на storage keys, без payload, verdict, документа
авторизации или сохранённого read callback. Перед каждым чтением выполняется
свежий critical fold. Строки, status и signature берутся из текущих live maps.
Любая инвалидация прежнего materialized read view сбрасывает и индекс,
включая point-delete без изменения log frontier. Это дополнительный O(N)
набор ссылок, не сокращение самого durable архива и не измерение RSS.

Suspended read привязан к storage owner и maintenance epoch: закрытие,
смена личности даже с повторным handle, erase и maintenance fences не могут
вернуть старый успешный ответ. Ошибка свежего fold или advertised capability
проходит вызывающему; fallback на запомненный успешный snapshot отсутствует.
Обычные stores без capability сохраняют fresh full-read путь.

Индекс используется только для bounded page с текущей unrestricted policy.
TTL/retention-фильтр, inventory, prefix proof и full snapshot остаются на
прежнем fresh пути. Signed transport, ACL, revoke/consent/binding, page
checkpoint и durable completion не заменяются этим индексом. Sibling mailbox
не включён; wire и storage formats не менялись.

## Проверки

Два assertion-red на прежней production-проводке: 100000-row tail-page
не обращался к bounded capability. Нет временных порогов. Отдельный mutant
без инвалидации индекса при in-place delete провалил проверку тёплого чтения;
это guard собственной новой правки, а не прежний пользовательский дефект.

Модель сверяется с независимым wire-order oracle на ordered, reverse,
rotated и interleaved вводах, отсутствующих и exclusive cursor, wire-ms
равенствах, нулевых/больших limits и invalid arguments. После построения
100000-key tail-window требует не более 280 lookup для 257 строк, запрос
после хвоста — не более 20; порогов времени нет.

HVS проверки покрывают append, edit, status/signature, canonical ordering,
conversation isolation, detached results, point-delete при прежнем frontier,
clear/erase, incremental read failure, close/reopen с тем же handle и
смену пространства. Реальный encrypted worker проверяет повторные тёплые
окна без native record RPC, затем delete/edit/metadata и точное cold reopen.

**1342 passed / 0 skipped**, анализатор 14 Dart-файлов — 0 issues.
В related входят history/TTL/retention/revoke, erasure и file-read lifecycle,
prepared batches/bytes, ordering/CAS, reservations, guard/profiler checks.

## Исправление измерительного стенда

Setup worker брал seed batch из product row cap, а поле отчёта всегда
показывало 64. Это позволяло менять layout исходного контейнера вместе
с проверяемым ceiling. Исправлено: общий helper задаёт setup отдельно от
production cap, а worker считает только успешно завершённые публикации.
Controller и независимый qualifier сверяют фактические свидетельства обоих
источников. Для 100000 сообщений: 1563 публикации, максимум 64 строки,
последний набор 32. Время setup по-прежнему вне измеряемого окна.

В прежних [128-row](../history-cohort128-100000-2026-11-10/README.md) и
[256-row](../history-cohort256-100000-2026-11-10/README.md) отчётах добавлено
уточнение: старые числа остаются наблюдениями, изолированное влияние cap
на latency по ним не доказано. Exact/cold/crash checks сохраняют силу.
Прерванный прогон индекса со старым setup исключён; восстановлены candidate
sources, остановлены только его оставшиеся testers, проверены PID/порты
и удалён только собственный runtime root.

## Повтор row-cap сравнения при фиксированном setup

Текущий общий код, index выключен во всех пяти фазах. Это нормализованное
сравнение одного ceiling на текущей базе, не повтор старых коммитов целиком.
Все 1543 frozen inputs совпадают, кроме одного production-файла с cap;
native SHA и реальные worker mappings одинаковы. Время setup не входит
в окно, его фактические свидетели одинаковы. CPU sampler/timeline выключены.

| Метрика | 64 A₁ | 128 B₁ | 256 | 128 B₂ | 64 A₂ |
|---|---:|---:|---:|---:|---:|
| Apply release → финальная проверка, мс | 144376 | 128837 | 128829 | 133928 | 139217 |
| Release file → оба post-page inventory, мс | 138306,790 | 127383,149 | 124649,585 | 128397,444 | 137989,823 |
| Message commits | 1563 | 782 | 391 | 782 | 1563 |
| Cursor commits | 784 | 784 | 784 | 784 | 784 |
| Allocator commits | 393 | 393 | 392 | 393 | 393 |

Обе 128-фазы быстрее обоих 64-контролей. Для 256 против соседних 128-контролей
финальная polling-метрика почти совпала с одним контролем; независимый
post-page свидетель раньше на 2,734–3,748 с. Пятисекундный poll не позволяет
объявлять точный end-to-end процент. P50 full reply → next source query:
229–236 мс при 64, 186–192 мс при 128 и 171–179 мс при 256. Это целый участок
с транспортом и очередями, не exclusive CPU и не чистая цена fsync.

Во всех пяти фазах 100001 точных ID/body/delivered/canonical/order, без потерь,
дублей или лишних строк; оба cursor завершены, cold reopen до сети при offline
источников сохранил всё. По 391 logical page query/source, без повторов,
по 54075350 application-frame bytes; 200002 callback, uncapped wire/census.
Allocator counts наблюдаются отдельно; их различие не объявляется эффектом.
Это локальный Mac/JIT стенд, не квалификация Android/AOT/мобильного пути.

## Native сравнение индекса и восстановление

Local Mac/JIT, три собственных устройства A/B/E, чужая личность C и три
Core. Два authenticated источника, 100000 архивных + 1 прежняя строка.
Страницы 256 строк / 128 КиБ / 64 части; production cap 256 / 115200 bytes
одинаков, setup 64 подтверждён фактическими публикациями. 1543 frozen inputs,
пять production variants, остальные 1538 одинаковы. Новый index-файл в
контроле — unused library placeholder; исходная production-проводка прежняя.
Native pins/реальные mappings совпадают; sampler/timeline выключены.

| Метрика | Без индекса A₁ | Индекс B | Без индекса A₂ |
|---|---:|---:|---:|
| Apply release → финальная проверка, мс | 130185 | 124671 | 129171 |
| Release file → оба post-page inventory, мс | 126286.426 | 123000.103 | 127373.576 |
| Source full-row reads A/E | 395/396 | 7/5 | 396/395 |
| Query → full reply P50 A/E, мс | 96.43/92.405 | 94.332/87.999 | 92.272/92.689 |
| Full reply → next query P50 A/E, мс | 182.033/176.294 | 177.836/174.996 | 181.729/174.513 |
| Message commits | 391 | 391 | 391 |
| Cursor commits | 784 | 784 | 784 |
| Allocator commits | 392 | 392 | 392 |
| Receiver worker RPC | 74527 | 75211 | 75290 |

В этой серии B раньше обоих контролей: финальная проверка на 4.5–5.514 с, post-page свидетель на 3.286–4.373 с.
Это одна локальная A/B/A серия с 5-с polling, не универсальное ускорение
мобильного/AOT пути и не exclusive CPU measurement. Число полных чтений
подтверждает реальное переключение storage-пути; оставшиеся inventory и
proof reads намеренно не удалены. На всех фазах прежние byte/frame/query
counts, 200002 callbacks, ноль page retry, 100001 exact/cold строки и оба
завершённых cursor. Payload/verdict/authorization cache не добавлялся.

## SIGKILL и очистка

На том же candidate и тех же frozen inputs/native pins B принудительно
завершён после publication строки 50080, до page checkpoint. Exit −9,
публикация оставила prefix 50176 и прежнюю контрольную строку. Cold B при
offline обоих источников сохранил точный prefix и оба прежних cursor strings.
Один источник восстановил 100001 точную строку без дублей; повторный cold
reopen подтвердил полный набор и cursor. Это один crash window, не полная
revoke/split-brain/offline матрица.

Все девять стендов проверили owned PID/listeners, закрыли свои процессы,
удалили только свои runtime roots; исходники восстановлены. Cache во всех
восьми сравнениях не получил новых kernel entries. Собственные 27 snapshots
сжаты без потерь 510.03→22.69 МиБ со сверкой распакованного SHA
до unlink. Свободно около 144.41 ГиБ. Raw IDs/пути/адреса/VM capabilities
и cursor strings не публикуются.

## Остаток и следующий приоритет

Догрузка 100000 строк всё ещё занимает порядка двух минут: latency не закрыта.
Индекс снимает один линейный участок, остальные свежие чтения служебного
журнала устройств и durable I/O требуют отдельного профиля. Await-суммы
пересекаются и не являются причинным разложением wall time. NETCALL и
непроверенная multi-device матрица этим раундом не квалифицированы.

По новому указанию владельца следующий приоритет — пропавший звук
телефон → Windows 11. После его исправления и проверки разрешён релиз.
В этой итерации push/релиза и обновления APK/сидов нет; sibling mailbox
не включён.
