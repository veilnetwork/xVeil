# History: свежая проверка у следующей записи

**Убрана лишняя roster-проверка после state-free mirror.** До применения
сообщения membership проверяется свежим чтением. Prepared publication имеет
свои admission/beforeCommit/post-commit проверки. Если после apply нет
`historyEditSeq` или `historyDelivered=true`, следующая запись — следующая
строка/публикация либо cursor checkpoint; каждая из них сама проверяет доступ.
Повторное чтение roster после каждой такой строки не защищало новую запись.

Теперь state-free continuation немедленно проверяет текущий pull/binding,
затем заканчивается. Это не cache разрешений: свежие проверки перед записью
сохранены. При edit/delivery correction прежняя post-apply membership проверка
остаётся перед чтением/изменением строки. Cursor по-прежнему требует свежего
доступа до и после durable putSetting. Обычный per-row путь и prepared cohort
используют те же границы; protocol/таймауты/mailbox не менялись.

## Регрессии

Gate после первого завершившегося apply последней публикации показал на базе
**16** одновременно ожидающих roster callbacks вместо **1** у следующего
checkpoint. Assertion-red воспроизведён без порога времени. На candidate
ожидает один checkpoint callback; строки уже опубликованы, cursor ещё нет.
Снятие gate позволяет сохранить cursor. Первый, недостаточный вариант
наблюдателя ставил gate только после всех 32 apply и не различал ветки;
он не засчитан как доказательство.

Отдельные revoke-проверки покрывают ordinary и prepared пути: отзыв после
первой записи/cohort останавливает следующую запись, а отзыв на последней
строке/cohort запрещает cursor checkpoint. При этом уже разрешённые durable
строки сохраняются. Stateful вариант доказывает, что отзыв внутри applier не
даёт дописать `delivered` correction. Current binding/teardown/expiry/ordering
guards входят в related suite. **165 tests passed, 0 skipped**, analyzer чист.
Повтор прежних 163 тестов не прибавлен к числу различных проверок.

## Native A₁/B/A₂

Три последовательных отдельных стенда: 512 **входящих** сообщений C→A,
link B, SIGKILL B после наблюдения ≥128, A/C offline, boot inspection B до
сети, возвращается только A, полная сходимость, затем ещё один boot B без A/C.
Все фазы: test/qualification/cleanup exit 0; все 512 ID/тела/порядок/positions/
delivered сохранены, дублей и completed-history retries нет. Дополнительные
in-flight строки проверяются по полному source oracle.

Для короткого сценария fixture допускает `XVEIL_E2E_MIGRATION_POLL_MS=250`
(предел 50–5000, default прежние 5000). Параметр действует только на polling
fixture, не на product. Во всех фазах выбран одинаковый интервал.

| Измерение | A₁ | B | A₂ |
|---|---:|---:|---:|
| Строк наблюдалось до SIGKILL | 206 | 142 | 141 |
| Сохранено до сети нового B | 253 | 189 | 174 |
| `historyApply` в final receiver census | 211 | 259 | 275 |
| `ownDevices` callbacks в том же census | 584 | 460 | 752 |
| Header RPC в `ownDevices` | 191 | 216 | 237 |
| Полных неповторённых primary page pairs | 7 | 9 | 9 |
| Receiver stage median, мс | 242,616 | 213,815 | 222,853 |
| После возврата из `start(A)` до сходимости, мс | 5219 | 5480 | 5584 |

Это не детерминированный replay: crash prefixes, work volume, snapshots,
keys/маршруты и scheduling различаются. Census включает и другие callers
`ownDevices`, awaits могут перекрываться; их сумму нельзя считать CPU time
или длиной critical path. Часть строк приходит через snapshot, поэтому
`historyApply` count не обязан равняться всей догрузке. **Общее причинное
ускорение и снижение физических I/O не доказаны.** Убрана конкретная лишняя
проверка; receiver stage и общая догрузка остаются активными.

1509 source/dependency inputs заморожены в каждой фазе. A₁/A₂ byte-identical;
в B отличается только `lib/state/messaging_own_history.dart`. Native inputs
одинаковы, FFI/HVS наблюдались в mappings трёх workers каждой фазы. Runtime
SDK — прежний проверенный `c6699c28`, source checkout — `c8f4929b`. Это
Mac/JIT/loopback квалификация Dart-изменения, не Android/AOT/WAN или новая
SDK-квалификация. После фаз добавлены только два дополнительных unit-case
для последнего checkpoint; production и native fixture не менялись.

Проверены 27/27/26 PID и 27/27/24 портов; своих процессов/listeners нет,
runtime/контейнеры удалены, native hashes совпали. Candidate source восстановлен.
Телефон, реальные профили и production не затронуты. Raw evidence private;
[summary](summary.json) содержит только агрегаты. Коммит без подписи, push/
релиза нет; sibling mailbox не подключён.
