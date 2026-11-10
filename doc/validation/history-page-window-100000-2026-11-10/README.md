# Страница истории без полного слияния архива — 2026-11-10

## Подтверждённая лишняя работа

Источник заново читал свежие строки и приводил **весь** архив к wire cursor
order перед каждой страницей. Порядок уже состоял из двух sorted runs:
позднее новое сообщение в начале append-журнала, затем 100000 старых строк.
Полное слияние двух частей повторялось ради окна в 256 сообщений.

Реальный source call-site regression, запрос хвостовой страницы: parent
**300273 timestamp reads**, candidate **не более 101000**. Parent-red —
assertion по счётчику, не таймер; отдельный финальный запуск на восстановленном
candidate прошёл и подтверждён JSON reporter. Already ordered случай сохраняет
прежнюю верхнюю границу 101000. Это не счётчик сетевых пакетов или fsync.

## Алгоритм и свежесть

`messageHistoryWindow` проверяет порядок одного свежего списка. При нуле/одном
разрыве ищет cursor отдельно в каждом sorted run и сливает только нужное окно.
При большем числе разрывов сортирует отдельную копию прежним comparator.
Исходный список не изменяется. Вызов сервера ограничен page cap + одним
lookahead: максимум 257 строк. Для record нужен первый текущий кандидат.
Сам общий helper не устанавливает протокольный cap — его сохраняет caller.

**O(N) fresh order scan и полный raw row read остаются.** Удалено дополнительное
полное слияние/копирование в обычной page-ветке, не вся квадратичная работа.
Нет сохранённого plaintext snapshot, нового индекса, кеша разрешений или
предположения о неизменности журнала между запросами.

Inventory/digest и любой запрос с prefix proof сохраняют полный свежий снимок.
Без него ограниченный список мог бы неверно доказать совпадение prefix.
Строгая проверка cursor, отдельные row/byte/slice caps, свежая видимость,
paired edit-frontier reads с retry и current-device/binding проверки сохранены.
Record hash/offset/changed и существующая сериализация apply не менялись.
Wire milliseconds/id order применяется и к submillisecond/local timestamps.

Три новых helper checks сравнивают окна со свежей полной сортировкой для
ordered/reversed/shuffled/rotated/interleaved данных, пустых/малых/больших
наборов, курсоров до/внутри/после, отсутствующего ID и больших limit.
Есть readonly input, поздняя замена данных, partial cursor и negative limit
и 100000-row bounded-work проверки. Старые независимые millisecond/id oracle
и общие sort/range проверки также проходят.

**1082 related checks passed / 0 skipped**, 23 файла; helper suite — 13 checks.
Analyzer четырёх изменённых production/test файлов: 0 issues. Prefix repair,
редактирование/удаление/expiry, oversized record, revocation, restart и read-state
lifecycle включены. Ошибки компиляции/единиц измерения prototype не считались red.

## Native A/B/A, 100000

Тот же local Mac/JIT стенд: три устройства одной личности, два authenticated
источника, counterpart, настоящие FFI/ratchet/HVS и три Core. CPU/timeline
sampling выключены, compact progress poll 5 с. **1540 frozen inputs**, только
два production variants; 1538 остальных одинаковы. Нативные SHA и mapping
проверены. Candidate восстановлен; текущие source hashes сверены.

| Метрика | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Apply release → финальная проверка, мс | 139095 | 133964 | 134346 |
| Release file → оба post-page inventory, мс | 133328,659 | 130369,313 | 131451,491 |
| Query at A → full reply, p50 мс | 95,069 | 92,281 | 97,080 |
| Query at E → full reply, p50 мс | 94,534 | 90,525 | 95,570 |
| Full reply → next query at A, p50 мс | 190,632 | 192,886 | 187,095 |
| Worker RPC на получателе | 130405 | 129783 | 130071 |
| Message / cursor / allocator commits | 782 / 784 / 394 | 782 / 784 / 394 | 782 / 784 / 394 |

Общее ускорение **не доказано**: A₁/A₂ отличаются примерно на 4,75 с,
а B/A₂ — лишь на 0,38 с; финальная проверка ещё и опрашивается раз в 5 с.
Passive этап в B закончился на 1,08–2,96 с раньше контролей, source p50 ниже,
но это одна серия с разбросом, не устойчивое обещание ускорения всего пути.
Секунды не переводятся в проценты батареи/Android/AOT.

Во всех фазах ровно 100001 ожидаемых ID/body/status/canonical/order, без потерь
и дублей. Оба cursor закончены; cold retention проверен до включения сети B,
когда все источники offline. 200002 apply callbacks. По 391 logical page query
на источник, повторов нет; application bytes по 54075350 во всех фазах.
Census/wire не обрезаны, одинаковые пустые выборки не считаются прохождением.

Остаток после full reply всё ещё около 190 мс; у B **24567 header loads + 24567
segment batch loads**, почти 130000 worker RPC. Удаление слияния не устраняет
эти IO/authorization/commit ожидания; их нужно разбирать отдельно. Это следующий
кандидат, а не доказанное распределение всех 134 с по физическим причинам.

## Очистка и приватность

Во всех фазах проверены выход owned PID/listeners и удаление runtime roots.
Related run также проверил выход 23 owned PID. Cache во всех фазах 92 файла,
новых entries 0, allocated delta суммарно около −1,98 МиБ. Кеш около 9,5 ГиБ,
свободно около 146 ГиБ. Без случайных Dart defines.
Шесть собственных source snapshots сжаты без потерь: 114,03 → 5,09 МиБ;
SHA-256 распакованных байтов сверён до удаления исходных JSON. Повторный анализ
после архивирования подтвердил результат. Сырые IDs/адреса/пути остаются вне Git.

Latency, NETCALL и остальная multi-device matrix открыты. Sibling mailbox не
включался; совместимость со старыми версиями не квалифицировалась по решению
владельца. Push/релиза нет.
