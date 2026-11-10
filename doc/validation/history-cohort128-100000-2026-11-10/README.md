# До 128 коротких строк при прежнем byte budget публикации

## Подтверждённый участок затрат

После [предыдущего цикла](../history-unrestricted-100000-2026-11-10/README.md)
снят новый bounded CPU-профиль получателя на 100000 сообщений. Production
соответствовал `59ec95e0`; профиль не смешан с A/B по времени. Native-прогон,
оба cursor и cold retention прошли для всех 100001 строк, wire/census не обрезаны.

Захват: 24 chunks, 105688 непротиворечивых physical samples, 14239 повторов
overlap удалены, 347 конфликтующих ключей исключены, 2820 стеков обрезаны.
Покрыто 155581,350 из 160516,389 мс активного окна; начального разрыва нет,
последние 4935,039 мс не покрыты. Один terminal endpoint error, 13 ответов
недоступных isolates, лимиты не достигнуты. Сжатый поток — около 1,95 МиБ.
Адрес управляющего VM endpoint, URI и сырые стеки остаются приватными.

Среди символов: `HvKvLogStore.commit` — 36501 inclusive samples,
`__fcntl` — 34555 exclusive, `_readOwnDeviceAddresses` — 4904 inclusive,
`loadMessageById` — 2317 inclusive. Это указатели на синхронную работу
хранилища и повторные reads, не доли wall time; inclusive counts перекрываются.
Счётчики отдельно подтвердили **1563 message commits**, **784 cursor commits**
и **393 allocator commits**. Их await времена тоже нельзя складывать:
операции и контексты могут перекрываться.

## Изменение и ограничения

Row ceiling подготовленной публикации увеличен **64→128**. Независимые
storage limits остаются **1800 UTF-8 encoded bytes на строку** и
**115200 суммарных payload bytes**. Большой набор, не помещающийся по байтам,
возвращает `null` до захвата очередей записи/выделения ID/вызова admission.
Те же bounds применяются к bodyless ordering corrections. Metadata/shard markers
по-прежнему публикуются атомарно с данными; лимит payload не объявляется
размером всей native-транзакции с её служебными записями.

Подготовка держит до 128 distinct rows. Это увеличение числа подготовленных
строк, а не прежний 64-row concurrency bound. Набор остаётся ограничен
страницей; frame/admission/record budgets не расширены. Для отказавшего
крупного набора cohort сначала пробует последовательные части до 64 строк,
затем прежний single-row fallback. Это сохраняет меньшие/unsupported adapters
и не превращает один отказ большого набора в 128 отдельных fsync-публикаций.

Каждая часть проходит свежий admission до native transaction и после неё;
future строки не завершается раньше durable publication. Ошибка после уже
записанной части не подтверждает остальные строки и не продвигает page cursor.
Abort присоединяет все начатые continuation, включая ещё не дошедшие до stage.
Порядок write families, CAS ordering, per-message mirror slots, serialization
страниц одного разговора, revoke, consent, TTL, binding и erasure сохранены.

Политика резервов отделена от нового row ceiling: успешные prepared
публикации от 64 строк прогревают прежнее окно **64→128→256**. Обычное окно
**8→64**, reset, reserve-before-ID и максимум 256 неиспользованных внутренних
ID prepared-пути прежние. Refused/uncertain publication не зарабатывает credit. Авторские
sequence numbers и сообщения резервом не подтверждаются.

Wire page остаётся **256 строк / 128 КиБ / 64 части**, меньшие requested limits
и legacy absent default прежние. Wire/storage format не менялся, sibling
mailbox и cache авторизации не добавлялись.

## Регрессионные проверки

Два parent assertion-red через обычную history-доставку: 128 коротких
incoming/outgoing сообщений требовали `[64, 64]` вместо одной публикации
`[128]`, без временного порога. Candidate публикует один cohort, данные,
статусы, direction, canonical positions и page cursor совпадают.

Шесть новых byte-boundary cases: posts и ordering при 115200 **−1 / 0 / +1**
байт. Размер выведен из реально закодированной probe-строки, без копирования
storage encoder в тест. +1 отвергается без admission/data publication;
−1 и точная граница дают один commit. Проверены полные bodies/status/raw
positions и результаты ordering, не только число записей. Лимит 129 строк
и отдельный oversized payload также отказывают до публикации.

Новый меньший adapter показывает попытки **128→64→64**, две пакетные записи
и точное итоговое состояние. Отказ второй части проверен для cap 64 и 128
в обоих вариантах — storage failure и revoke; прежняя проверка отказа
четвёртой 64-row части также сохранена через smaller adapter. Уже durable
prefix остаётся, cursor не перескакивает отказавшую часть; restart завершает
историю без дублей. Native checks для 64 и 128 проверяют ожидание commit,
pre-commit refusal, потерянный post-commit response и cold restart.

**400 related checks passed / 0 skipped**, включая ordinary coalescing,
ordering, reservation reset/failure, immutable inputs, erasure, detached bindings,
mirror concurrency/status, TTL, native expiry, sparse prefix и byte/page budgets.
Analyzer семи изменённых Dart-файлов чист. Crash-стенд вычисляет ожидаемый
prefix от действующего publication cap; конкретный выбранный fault отдельно
должен оставлять незавершённую страницу, что проверяется по durable cursor.

## Native A/B/A на 100000

Parent `59ec95e0` → candidate → parent. Четыре Mac/JIT процесса, три
изолированных Core, настоящий FFI/ratchet/HVS. Два источника одной личности,
первые полные authenticated ответы получены до apply release. Seed вне
измеряемого окна, progress компактный каждые 5 с; CPU sampler и timeline
выключены. Источники сохраняют исходный append order: одна новая строка
перед 100000 архивными, без перестройки fixture ради кандидата.

| Метрика | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Apply release → финальная проверка, мс | 144010 | 133706 | 144067 |
| Release file → оба post-page inventory, мс | 141224,858 | 130257,520 | 141211,527 |
| Message commits | 1563 | 782 | 1563 |
| Cursor commits | 784 | 784 | 784 |
| Allocator commits | 393 | 394 | 393 |
| History apply callbacks | 200002 | 200002 | 200002 |
| Page queries каждого источника / retries | 391 / 0 | 391 / 0 | 391 / 0 |
| Application-frame bytes каждого источника | 54075350 | 54075350 | 54075350 |
| Receiver worker RPC calls | 198931 | 178532 | 197998 |

В этом сравнении candidate быстрее обоих контролей на **10,304–10,361 с**,
около **7%**. Независимый passive witness сокращён примерно на 11 с.
Это локальная JIT-квалификация, не универсальное ускорение Android/AOT/интернета.
Message publications почти вдвое меньше; callbacks, объём данных и cursor
commits прежние. Один дополнительный allocator commit наблюдён явно;
амортизация резервов не объявляется улучшенной. Разницу всех RPC и фоновых
ratchet/outbox commits одному изменению message publications не приписываем.

Reply → next query P50 теперь около **188–198 мс** вместо **239–245 мс**,
query → full reply в candidate **94–97 мс** против **83–86 мс** в контролях.
Это полные участки с очередями/транспортом, не exclusive CPU, и их медианы
нельзя складывать в wall time. Итоговое время проверено независимо.

Во всех фазах **100000 архивных + 1 прежняя строка** совпали по ID, body,
delivered, canonical positions и порядку, без пропусков, дублей и лишних строк.
Оба cursor завершены; холодное открытие до сети при offline всех источников
сохранило весь набор. Wire/census не обрезаны. Native artifacts и реальные
worker mappings сверены; **1532 frozen inputs**, ровно **3 production variants**
и 1529 одинаковых inputs. Candidate восстановлен с проверкой hashes.

Cleanup A/B/A проверил **39/37/39 PIDs** и **56/62/60 портов**: owned процессов
и слушателей нет, synthetic runtime удалён. Cache **92→92**, новых kernel
entries 0.

## SIGKILL внутри незавершённой страницы

На candidate повторён отдельный native-сценарий на 100000 строк. Selected-row
gate с индексом **50080** оставил **50048 архивных строк durable** и одну
прежнюю. Как минимум один из двух курсоров строго отстаёт от записанного
prefix: это незавершённая страница, а не удачно выбранная чистая граница.
B принудительно завершён с exit **−9**, A/E/C offline.

До запуска сети новый storage inspector подтвердил точные **50049 строк**
с body/delivered/canonical positions и точное равенство обоих raw cursor values
сохранённым перед SIGKILL. После возвращения **только A** получены все
**100001 строки** без пропусков/дублей и с совпадающим порядком. В новом B
наблюдались **4893 authenticated recovery parts** именно от этого источника,
history failures **0**. Полной копии архива в bounded device journal источника
нет. Затем ещё одно холодное открытие при offline всех источников сохранило
весь набор и оба курсора.

Разрешение apply → выбранный gate **65,066 с**, запуск A → полная сходимость
**71,350 с**; это одиночный fault-прогон, не дополнительный A/B-замер ускорения.
SIGKILL обрывает первый wire log: его полнота не заявляется. Начальные полные
authenticated ответы подтверждены до crash, recovery — отдельным live snapshot
нового процесса. Это fault внутри страницы, не принудительная остановка
в выбранной native-инструкции fsync/ratchet/ACK.

Cleanup crash-проверки: **45 PIDs / 67 портов**, owned процессов/слушателей
нет, synthetic runtime удалён. Все 1532 inputs совпадают с candidate A/B/A;
native artifacts прежние. Cleanup профиля: **47 PIDs / 89 портов**, runtime
удалён, sampler завершился с кодом 0. После завершения всех прогонов 12
собственных raw CPU JSON losslessly сжаты **445,48→29,81 МиБ**, SHA и повторный
анализ проверены, сводка не изменилась. Синтетические контейнеры удалены,
kernel cache остался около **9,5 ГиБ / 92 entries**, свободно около **146 ГиБ**.

Latency остаётся активной: примерно 134 с на этом локальном 100000-row стенде.
Физическая/AOT квалификация, NETCALL-01 и оставшаяся multi-device matrix не
закрыты. Секреты, адреса, ID и пользовательские пути в публичные артефакты
не добавлены. Push/релиза нет.
