# История: меньше запросов при том же байтовом пределе

Максимум сообщений own-history страницы увеличен **32 → 64**. Предел 128 КиБ,
4-КиБ slices, 64 части, одна outstanding query на sibling и durable cohorts
по 16 строк сохранены. Byte ceiling по-прежнему может закончить страницу
раньше row ceiling. На больших событиях работает прежний record-протокол.
Проверки membership, binding, expiry, signatures и durable cursor не ослаблены;
sibling mailbox не подключён.

Это меняет допустимое число событий в прежнем wire envelope. Старые application
decoders с максимумом 32 могут отвергнуть страницу. Совместимость со старыми
версиями исключена владельцем; mixed-version квалификация не заявляется.

## Регрессии

Два assertion-red через настоящие MessagingService/HVS с fake KV: 64 коротких
incoming/outgoing сообщения требовали двух data-page запросов вместо одного.
После изменения требуется один. Базовый вариант также делал четыре commit
курсора (inventory/page progress/completion), новый — три. Счётчик учитывает
только успешно завершившиеся commits тестового KV, не физические fsync.
Запись сообщений в обоих вариантах — **четыре группы по 16**. Проверены все
ID, тела, direction, delivered и canonical sequences.

Обновлены границы over-cap (65), числа страниц для 65 строк и fault injection
первого page cursor (`m0063`). Первый related run выявил старый триггер
`m0031`, который больше не совпадал с границей страницы; это исправление
fixture, не product failure. **167 related tests passed, 0 skipped**,
analyzer четырёх изменённых Dart files чист. Повторы не суммируются.

## Невалидный контроль исключён

Первые три no-crash backlog запуска прошли сверку 512 сообщений, но доставляли
их через snapshot: **0 page queries**. Поэтому их времена исключены из
доказательства эффекта row cap. В backlog fixture проверка тел теперь включена
и в non-crash сценариях с positions, а не только при crash. Новый summary
явно сообщает `initialBodiesCompared`.

## Native A₁/B/A₂: архив вне device journal, два источника

Существующий four-device стенд: A/E/B — одна личность, C — другая. C offline;
A и E имеют одинаковые 512 архивных строк, отсутствующих в device journal.
B уже имеет одну обычную строку. Оба источника достигают encode gate; B до
release не имеет архивных строк. После первых двух полных authenticated
ответов снимается apply gate. Все 512 архивных ID/тела/порядок/positions/
delivered и прежняя строка сходятся; оба source cursor завершаются. После
перезапуска B до сети при offline A/E/C сохранены все **513** строк.

| Измерение | A₁, 32 | B, 64 | A₂, 32 |
|---|---:|---:|---:|
| От encode release до полной сходимости | 4649 мс | 3775 мс | 4250 мс |
| От apply release до сходимости | 4321 мс | 3390 мс | 3926 мс |
| Запросов B к A/E, полученных источниками | 34 | 18 | 34 |
| Повторных запросов в этой выборке | 0 | 0 | 0 |

Запросы считаются на источниках и сопоставлены по приватному request token с
parts целевого receiver boot. Открытия/закрытия probe определяют boot; dropped
records — 0. Это запросы B к A/E, не посторонние взаимные pulls источников.
Измерения — parent Stopwatch, без межустройственного clock skew. Polling
fixture 250 мс (opt-in 50–5000, default 1000 прежний); CPU/timeline profiling
отключено. Фиксированные encode/apply gates и observers входят в измерение.

A₁/A₂ source inputs byte-identical; в B отличается только row-cap constant
в `messaging_own_history.dart`. Source hashes и выбранные native SHA проверены
для каждой фазы, mappings FFI/HVS — у трёх живых участников overlap. HVS —
release `eceb9158`, SDK runtime frozen `c6699c28`, source checkout `bbcd967a`.
Это Mac/JIT/loopback и короткий текстовый архив, не Android/AOT/WAN/media-rich
квалификация. В этом стенде B быстрее обоих контролей; одного A/B/A
недостаточно для универсального вывода о скорости догрузки.

## Финальный candidate: SIGKILL во время неполной догрузки

На окончательном 64-row source ещё один A/B/C native run: B убит SIGKILL при
наблюдении 206 строк; до сети после restart сохранены 253, включая все
наблюдавшиеся ID/тела/состояния и допустимые in-flight строки source oracle.
A/C offline; возвращается только A. Все 512 строк сходятся по ID/телам/
порядку/positions/delivered, completed-history retries — 0. Следующий boot B
без источников сохраняет полную историю. Пять запросов страниц сопоставлены
с реальными parts получателя: целевой page path действительно выполнен.

Все четыре финальных native qualification/cleanup exit 0; 1514 frozen inputs
сверены в каждой. Проверены PID/порты по фазам: 36/46, 35/41, 36/41 и 27/25.
Своих процессов/listeners нет, runtime roots/контейнеры удалены, native hashes
совпали. Не зачтённые первые три стенда тоже очищены. Новых Rust builds,
изменений телефона/production, push/релиза нет. Raw IDs/keys/captures private;
[summary.json](summary.json) содержит агрегаты.

**Задержка истории остаётся активной.** Уменьшено число запросов и показан
ограниченный выигрыш на контролируемом archive path; общий cold/WAN путь и
полная multi-device матрица не объявлены завершёнными.
