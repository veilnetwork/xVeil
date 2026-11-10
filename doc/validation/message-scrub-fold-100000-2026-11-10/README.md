# Физическая очистка не сбрасывает актуальный message fold

## Подтверждённые затраты

В предыдущем native fixture проходы сразу после mirrored delete занимали около
0,4 с, остальные — около 0,1 с. Новый bounded counter фиксирует источник:
после каждого такого удаления `scrubDeleted` безусловно сбрасывал message
fold, и следующий `iterLogRange` возвращал все 100000 записей. Point delete
уже успевал убрать строку из `_scanById`, сохранить tombstone и сбросить
только materialized list, поэтому повторное декодирование было лишним.

Новый unit parent-red: после одного удаления и обязательной физической
очистки прочитано **100000** message-log records вместо **0**. Проверяются
99999 точных оставшихся строк, tombstone, обязательный вызов scrub и сохранение
forward watermark: следующий append читается incremental range, не full scan.
Тест не использует порога времени.

## Изменение и корректность

`KvLogStore.scrub` по существующему контракту сохраняет живые keys,
логические log IDs и значения. Ratchet cleanup и file-store vacuum уже
полагаются на это свойство. Обычный успешный физический scrub теперь сохраняет
актуальный fold; сам vacuum и завершение durable cleanup obligation выполняются
в прежнем порядке и не пропускаются.

Массовые rewrites не имеют point patch каждого cache entry. Remove, prune,
clear, emitted clear и remote clear явно инвалидируют fold перед физической
очисткой через общий private helper. Иначе сохранение кеша вернуло бы старые
строки. Для неопределённого результата commit/scrub recovery-flag сохраняется
в локальное решение **до** очистки durable marker: такой scrub по-прежнему
заставляет перечитать журнал. Нельзя принять потерянный ответ записи за
доказательство, что кеш совпал с диском.

Новые проверки покрывают все пять массовых путей с прогретым fold,
сохранность другого разговора и cold view. Отдельный fault публикует tombstone
batch, затем теряет ответ; следующий вызов — непосредственно scrub без
промежуточного recovery read. Старые строки после этого не появляются.
Wire, authorization/revoke, epoch/admission guards, ratchet, mailbox и
форматы хранилища не меняются. Это не ослабление forensic erasure.

## Два native сравнения

Локальный erasure A/B/A использует 100000 строк / 32 разговора, четыре
настоящих tombstone на источнике и восемь presence-проходов с пересозданием
MessagingService. Измеряются активная подготовка запросов и число records,
возвращённых message `iterLogRange`; exact-ID reads и KV metadata не выдаются
за измеренные этим счётчиком. Таймер включает один нулевой event-loop turn,
контрольный JSON hashing выполняется после его остановки.

| Метрика erasure fixture | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Сумма активной подготовки 8 проходов, мс | 1838,679 | 903,984 | 1758,672 |
| Медиана проходов после delete (3/5/7), мс | 420,088 | 111,846 | 393,925 |
| Records, возвращённые message iterLogRange | 300027 | 27 | 300027 |
| Запросы / JSON bytes | 260 / 94103 | 260 / 94103 | 260 / 94103 |

В каждом из восьми проходов совпал digest полного JSON набора запросов.
Все 99996 ожидаемых ID/body/status/conversation/author/seq/canonical/timestamp-ms
значений сохранились после cold reopen; все четыре удаления применены.
Первый проход читает только 27 incremental records после seed. Затем старый
код трижды перечитывает весь журнал после промежуточных удалений. Четвёртое
удаление идёт после последнего измеряемого запроса и проверяется cold reopen
вне окна. Счётчик не объявляется суммой всех IO/RPC или всех расшифровок.
Виртуальные часы между presence-проходами продвигаются на 11 минут; ускорение
активного участка не означает изменения реального anti-entropy cadence.

Отдельный сквозной A/B/A: 100000 архивных строк, два источника одной личности,
один получатель и counterpart, настоящие FFI/ratchet/контейнеры, три локальных
Core. Первые полные authenticated ответы обоих источников получены до release
apply; финальный oracle проверяет все 100001 ID/body/status/canonical/order,
оба cursor и cold retention при offline всех источников. Это не восстановление
истории, когда все держатели были offline ещё до получения данных.

Seed вне сравниваемого окна, CPU sampler/timeline выключены, poll 5 с,
рабочие счётчики и bounded wire capture включены одинаково. Источники сохраняют
исходный append order: одна новая строка перед архивом. Единственный production
variant — HiddenVolumeStorage. Native hashes/mappings и неизменность остальных
inputs проверяются для каждого прогона; cached binary не определяется только
по чистоте source tree.

| Сквозная догрузка 100000 архивных строк | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Apply release → финальная проверка, мс | 133383 | 133702 | 133927 |
| Release file → оба post-page inventory, мс | 129400,978 | 132252,531 | 131601,169 |
| Message / cursor / allocator commits | 782 / 784 / 394 | 782 / 784 / 394 | 782 / 784 / 394 |
| History apply callbacks | 200002 | 200002 | 200002 |
| Worker RPC calls | 178667 | 176811 | 179958 |

Все 100001 строка, оба cursor и cold retention точны. На каждом источнике
391 логический page query, повторных page queries нет, application frame bytes
по 54075350 одинаковы. Capture и census не обрезаны. Общего ускорения **не
выявлено**: candidate внутри интервала apply-времён двух контролей; passive
witness тоже не даёт основания объявить выигрыш. Разброс RPC/control-reads
наблюдён, не переведён в причинный эффект изменения.

1537 frozen inputs, один production variant и те же native artifacts во всех
full фазах; candidate восстановлен, все остальные байты сверены. Cleanup
проверил 36/37/40 собственных PID и 62/63/54 порта, собственных listeners и
живых процессов не осталось, runtime удалены. В erasure-серии по три процесса
каждой фазы тоже завершились и все три runtime удалены. Кеш сохранил 92 файла,
новых kernel entries нет; суммарная allocated delta full-серии около +0,555 МиБ.
На диске свободно около 147 ГиБ; сырые synthetic evidence занимают около 221 МиБ
вне Git. Публичная summary содержит только агрегаты.

**709 related checks passed / 1 skipped**, семь новых unit checks. Явно
включаемый roster lifecycle probe не засчитан пройденным. В набор вошли
нативные large-post/edit/delete и ratchet vacuum ID/value checks, crash recovery,
mutation ACK, clear/remove/prune, revoke/expiry и prepared history boundaries.
Analyzer трёх изменённых Dart-файлов чист. Длительный
anti-entropy cadence, NETCALL и оставшаяся multi-device matrix остаются в работе.
Android/AOT, мобильный провайдер и production relay paths этим Mac/JIT fixture
не квалифицируются. Push/релиза нет.
