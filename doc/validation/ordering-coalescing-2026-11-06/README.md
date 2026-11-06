# Уточнения порядка сообщений объединяются перед сохранением

Агрегаты: [summary.json](summary.json).

## Подтверждённый расход и ошибка завершения

В предыдущем native-прогоне 98 исходящих сообщений получили исходную
физическую позицию через одиночный `adoptMessageOrdering`. Этот путь
сохранял каждое уточнение отдельной транзакцией, хотя для явных history
cohorts уже существовал bounded batch API. На контролируемом burst из
64 независимых вызовов прежний код делает 64 транзакции — подтверждено
как in-memory, так и через настоящий native worker.

Найден и отдельный дефект lifetime: одиночный метод учитывался в close/erase
только во время commit, а последующее обновление fold уже не удерживало
принятую операцию. Управляемый тест разрешает сохранение одновременно
с close: прежний метод падает на чтении уже закрытого storage после
успешной записи. Это storage-воспроизведение, не атрибуция пользовательской
жалобы о доставке.

## Изменение и сохранённые границы

Ожидающие одиночные уточнения одного `(conversation, provisional author)`
могут разделить транзакцию: до 16 разных message ID и не более 1800
UTF-8 байт metadata суммарно. Пачка закрывается в начале своего sequence
turn, до I/O. Append, явная prepared-операция, oversized correction или
конкурирующее уточнение того же message ID создают отдельный turn;
поздний вызов не присоединяется через такой барьер.

Проверка и публикация используют ту же critical-секцию, что существующий
prepared ordering API. Каждый caller получает собственный compare-and-adopt
результат после durable commit. Проверяются текущее наличие исходящего
сообщения, исходная пара author/seq, отсутствие уже принятого ordering и
пересечение с erasure. Текст, исходные author/seq и delivery status не
перезаписываются; canonical metadata не получает экспортируемый seq-слот.
Кто вправе сообщить позицию, по-прежнему проверяет messaging caller.

Close/erase теперь дожидаются всего принятого одиночного turn, включая
post-commit fold. Новые вызовы во время maintenance отклоняются. Большая
одиночная metadata сохраняет существующий fragmented path. Форматы на
диске и wire, ratchet и authorization barriers не менялись.

При отказе общей транзакции ошибку получают все её callers. После потери
ответа уже сохранённая metadata обнаруживается повторным fold; retry
не создаёт повторных correction-строк. Это атомарное поведение пачки,
а не обещание независимого успеха её участников при отказе одного commit.

## Проверки

На точном production-файле `7fd4924a` focused suite: **32 passed,
5 assertion failures и одна ошибка closed storage**. Эти шесть различий
не объявляются шестью дефектами: часть тестов проверяет новый контракт
batch atomicity, очереди и maintenance. Отдельный native burst assertion-red:
64 commit при бюджете не более восьми. После baseline candidate восстановлен
побайтно, сохранены SHA исходников и неизменных тестов.

Candidate: **38 focused passed**, связанные suites — **235 passed / 0 skipped**
(focused входят в это число). Проверены конкурирующие corrections, барьер
между пачками, отказ до commit и потеря ответа после него, повтор,
close/erase, fragmented fallback, stale/absent/deleted/canonical targets,
admission и erasure во время prepared-публикации. Существующие проверки
message appends, seq, payloads, own-device history и статусов также прошли.

С настоящей HVS: **17 passed / 0 skipped**. Новая проверка подтверждает
64 corrections не более чем за восемь транзакций, пределы 16/1800,
сохранность тел/status/raw positions/canonical positions после перезапуска
worker и отсутствие canonical metadata в экспортируемом event stream.
Прежний same-image A/B/A контроль явного prepared API оставлен без изменения
семантики; sequential одиночные вызовы по-прежнему делают отдельные commit.
Analyzer, format и diff checks чисты.

## Native A/B/C: общий выигрыш не подтверждён

Три Mac/JIT процесса, две личности, три loopback Core, настоящие
transport/ratchet/HVS. Provider fixture не равен полному foreground
SessionPipeline. Сравнение с предыдущим qualified-прогоном на `7fd4924a`:
одинаковые stand/instrumentation и native artifacts, свежие identities/caches.

| Измерение | Прежний single API | Coalescing |
|---|---:|---:|
| Все 2000 строк видны | 32,231 с | 32,755 с |
| Полная сходимость ID/порядка/позиций/delivered | 32,236 с | 32,755 с |
| Message commit, окно census | 429 | 360 |
| Message commit, закрытое FIFO-окно | 429 | 356 |
| Их worker handler time | 8,612 с | 7,462 с |
| Все commit, закрытое FIFO-окно | 915 | 838 |
| Их worker handler time | 18,834 с | 17,686 с |

Все 2000 сообщений delivered, без дублей/потерь, позиции и порядок сошлись;
повторов завершённой истории — 0. Обе VM-трассы строго qualified: по одному
worker, непрерывные RPC sequence, полное FIFO-соответствие; суммы фиксированных
категорий равны всем commit. Handler включает FFI и Dart worker adapter,
это не чистое время fsync; census и VM имеют разные границы окна.

Число записей уменьшилось, но общая догрузка осталась около 32 с.
По одному прогону с опросом около 5 с нельзя объявлять ни ускорение,
ни регрессию на 0,5 с. Суммы await у параллельных callers пересекаются.
Догрузка остаётся активной: следующий участок — обработка/запись порций
группового журнала и ожидания между источником и ingest.

## Стенд и приватность

SDK `b9b88bb7` и HVS `eceb9158` прежние. Проверены SHA immutable FFI/CLI/HVS,
1504 frozen source/package inputs, CPU samples и фактические OS mappings
обеих выбранных библиотек у трёх клиентов. Сырые trace/IDs/адреса остаются
в приватном cache; в отчёт вынесены фиксированные категории и агрегаты.

После прогона проверены 22 PID / 34 порта: своих процессов/listeners нет,
runtime root удалён. Native fixtures закрыты и удалены. Телефон отключён;
mobile handover, длительный offline/crash и полная multi-device матрица
в этом сценарии не выполнялись. Пользовательские контейнеры и production
не менялись. Push/релиза нет.
