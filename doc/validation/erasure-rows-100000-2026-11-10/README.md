# Сравнение удалений без лишней UI-проекции

## Подтверждённая работа

Перед формированием erasure-запроса клиент вызывал `loadMessages`.
Hidden-volume adapter строил display order с author-monotone timestamps,
сортировками авторских последовательностей и общим UI ordering. После этого
сам erasure-путь сортировал тот же набор по raw timestamp: экранная проекция
для него не используется. Unit assertion-red на настоящем HVS adapter над
FakeKvLogStore фиксирует **100000 строк через display path** вместо нуля;
два запроса при этом содержат ровно ожидаемые 400 ключей.

## Изменение

Используется уже существующий `readMessageRows`: актуальный fold с теми же
status/signature overlays, deleted/clear semantics и detached list, без
вычисления UI display order. Путь по-прежнему сортирует выбранный разговор
по raw timestamp. Хранилища без capability используют прежний `loadMessages`;
отказ advertised capability распространяется и не превращается в пустой
успешный snapshot. Проверки принадлежности устройства, authenticated inbound,
точного набора requested keys, page rotation, throttle и durable setting не менялись.

Это **не** ограниченное чтение только 400 строк. Весь текущий разговор всё
ещё материализуется и сортируется, а contact census/fold остаются прежними.
Expiry/retention/authorization не устанавливаются row reader: они остаются
обязанностями прежних вызывающих путей. Нового кэша авторизации или sibling
mailbox нет, wire/storage format прежние.

## Проверки и native A/B/A

Новый regression check отдельно проверяет точный набор двух страниц и отсутствие
UI-проекции на 100000 строк. Наличие capability не принимается за пустой успех:
существующие row-reader checks проверяют fallback/error, свежие edits/status,
canonical adoption, isolation, удаление/clear и detached snapshots.
Presence checks сохраняют отбрасывание незатребованных и неподтверждённых ответов.

Native fixture: ровно 100000 строк / 32 разговора, источник с четырьмя
tombstone, восемь presence-проходов. MessagingService пересоздаётся после
каждого прохода; все 99996 ожидаемых строк проверяются после cold reopen.
Счётчики row/display reads только наблюдают существующие методы adapter.
Seed и проверки данных вне измеряемого окна.

Измеряется **presence dispatch → последний сформированный запрос + один
нулевой event-loop turn**, включая локальные awaits; это не время сетевой
доставки или полной синхронизации. После остановки таймера считаются JSON
bytes/digest запросов, поэтому hashing контрольного oracle не включён в окно.
A/B/A source variant единственный: production-вызов row reader. Все остальные
lib/test/config inputs зафиксированы, SHA/mapping native HVS сверены.

Related suite: **577 passed / 1 skipped**. Явно включаемый roster lifecycle
probe не засчитан пройденным. Analyzer трёх изменённых Dart-файлов чист.

| Метрика активной подготовки запросов | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Сумма восьми проходов, мс | 2174,328 | 1824,236 | 2229,214 |
| Медиана прохода, мс | 179,405 | 133,954 | 185,990 |
| Строки через UI read path | 795990 | 0 | 795990 |
| Строки через raw read path | 0 | 795990 | 0 |
| Запросы | 260 | 260 | 260 |
| JSON bytes запросов | 94103 | 94103 | 94103 |

Digest полного JSON набора в каждом из восьми проходов совпадает между всеми
тремя вариантами: не только число запросов. Во всех случаях cold reopen
сохранил ровно 99996 ожидаемых ID/body/conversation/status/author/sequence/
canonical/timestamp-ms значений; все четыре удаления применены, дублей нет.

Около 16–18% выигрыша относится к сумме **активных локальных подготовок**
этого JIT-стенда. Тестовые часы между проходами продвигаются на 11 минут;
фактические network/anti-entropy интервалы не измерены и не изменены. Весь
fixture с seed/проверками/close занял примерно те же 30,6–30,7 с. Ускорение
полной догрузки, сети или AOT этим сравнением не доказано.

1514 неизменных nonvariant inputs сверены до/после, единственный production
variant восстановлен и проверен. По три собственных процесса каждого прогона
завершились; все три native runtime каталога удалены. Кеш остался 92 файла /
около 9,5 ГиБ; новых kernel entries нет. Локальные пути, mapping logs и сырые
измерения остаются вне Git.
Общая догрузка 100000 строк (~134 с в прежнем стенде), медленный полный
anti-entropy обход, NETCALL и оставшаяся multi-device matrix не закрыты.
Push и релиза в этом цикле нет.
