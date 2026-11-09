# Архив читает строки без построения экранного порядка

## Подтверждение и исправление

Own-history вызывала `Storage.loadMessages`, которая строит author-monotone
display order: группирует сообщения по авторам, сортирует seq, вычисляет
effective timestamp и сортирует результат. Затем `_MessagingOwnHistory`
снова сортировала те же неизменённые строки по raw timestamp/id. Первая
проекция была лишней для этого потребителя.

Диагностический профиль на 100000 строк обнаружил этот путь, но **сохранил
только хвост**: около 28,7/30,4 с у A/E из запрошенных 275,6/345,5 с. В нём
`HiddenVolumeStorage.loadMessages` присутствует в 3201/2806 из 8154/6520
captured samples, собственная хронологическая обработка — в 769/665.
Это не проценты CPU или wall time полного прогона. У E один завершённый
isolate уже недоступен; его работу не считают нулевой. Полные количества
вызовов ниже получены отдельным census во всех A/B/A фазах.

Добавлена optional capability `MessageRowsReader`. HVS читает текущий fold
с прежними status/signature overlays, отбирает один разговор и возвращает
отдельный список без экранной сортировки. Own-history продолжает свежую
visibility-фильтрацию и прежнюю сортировку raw timestamp/id. **Нового кэша нет.**
Парные чтения edit frontier до/после строк, current-device/binding gates,
revoke, expiry/retention, публикации и durable cursor не менялись. Сам reader
не разрешает доступ и не обещает атомарность с отдельно прочитанным frontier.

Обычный `loadMessages`, его display order и UI consumers не изменены. У stores
без capability работает прежний путь. Ошибка объявленной capability
пробрасывается: нет fallback к старым данным или пустому успешному snapshot.
Wire, page cap 128, 128 КиБ/64 части, публикации по 64 и обычный live coalescing
по 16 прежние. Sibling mailbox не включён.

## Проверки

Новая source-проверка на родителе assertion-red: **1** display read вместо 0.
В ней UI order намеренно отличается от raw chronology из-за clock skew,
разных авторов и legacy-строки. Wire chronology и исходные timestamps
проверены независимо; candidate проходит без вызова экранной проекции.

Reader-проверки покрывают fallback, ошибки без stale/empty fallback,
conversation isolation, отдельный список, status/signature overlays, поздние
append/edit/delivery, ordering adoption, delete и clear после тёплого чтения.
Оба пути fixture сохранили before/after-read hooks, поэтому прежние edit,
revoke, visibility и publication race guards не обходятся новой capability.
Отдельно проверен reset census, различающий display и row read.

**352 related passed / 0 skipped**, включая **16 native HVS**; analyzer чист.
Также прошли прежние UI-order recovery и device-backfill проверки.

## Native A/B/A на 100000 сообщений

Production parent `aa675a8a` → candidate → parent. Общие test instruments во
всех фазах одинаковы. Четыре независимых Mac/JIT процесса, A/B/E одной личности,
C другой; три изолированных Core, loopback TCP и настоящие FFI/ratchet/HVS.
Первый apply удержан до authenticated ответов обоих полных источников.
Sampling/timeline выключены; compact observer каждые 5000 мс, seed по 64
до измеряемого окна. Итог проверяется полным snapshot и отдельным cold boot
до сетевого восстановления при offline A/E/C.

| Метрика | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Apply release → сходимость, мс | 281201 | 245933 | 271050 |
| Release file → post-page inventory у обоих источников, мс | 280030,466 | 240353,284 | 269711,085 |
| Display API calls источника A / E | 890 / 909 | 91 / 113 | 885 / 906 |
| Page queries каждого источника A / E | 782 / 782 | 782 / 782 | 782 / 782 |
| Application-frame bytes от каждого источника | 54217516 | 54217516 | 54217516 |
| Коммиты сообщений / cursor | 1563 / 1566 | 1563 / 1566 | 1563 / 1566 |
| HistoryApply callbacks | 200002 | 200002 | 200002 |

Display counters охватывают работу соответствующего source instance, включая
других потребителей обычного API; оставшиеся вызовы не объявляются ошибкой
и этой правкой не убирались. Снижение — наблюдаемое выполнение нового пути,
а не вывод из хешей исходников или состояния compiler cache.

Все 100000 архивных плюс одна прежняя строка совпали по IDs, телам,
delivered, canonical positions и порядку, без пропусков/дублей/лишних строк;
оба conversation cursor завершены. Cold boot без источников сохранил 100001.
Каждый forward query связан с полным authenticated ответом; wire/census
не обрезаны. Не засчитывается равенство пустых наборов или только счётчик строк.

На этом стенде candidate быстрее обоих контролей на **25–35 с**. Observer
имеет шаг 5000 мс и включает финальную проверку. Passive post-page witness
отдельно подтверждает сокращение этапа примерно на 29–40 с; он включает
доставку следующего inventory запроса и не является точной меткой UI.
Это одна локальная JIT серия, не универсальный процент для AOT/мобильной сети.

Query у источника → полный ответ у B: P50 parent 144–157 мс, candidate 86–96 мс
(781 наблюдение на источник, первый gate-crossing ответ исключён).
Полный ответ → следующий query остаётся P50 около 167–169 мс (780).
RPC counts немного варьировались; их разница не заявляется устранением
authorization/ratchet I/O. Стадии не суммируются как exclusive CPU/disk time.
**Остаточная latency активна: около 4 мин 06 с на 100000 сообщений.**

## Происхождение и уборка

**1527 frozen inputs**: три варьируемых production-файла, остальные 1524
одинаковы. Новый reader definition общий для фаз; parent его не импортирует.
Native SHA/mappings проверены до/после, Rust не собирался. Candidate восстановлен.
Кэш **92→92**, новых entries 0 во всех фазах; место не чистилось во время
измерений. Телефон, пользовательские контейнеры и production не затронуты.

Cleanup A/B/A проверил 38/39/48 PID и 61/64/61 порт: своих процессов/listeners
нет, synthetic runtime удалён. В отдельном profiling run первая проверка
увидела ещё завершающийся helper; после его выхода повторная проверка 49 PID
и 91 порта прошла. Этот диагностический запуск не перезапускался и не включён
в таблицу latency. В A/B/A cleanup-wrapper допускал до 10 с для выхода owned PID, после чего
по-прежнему требовал отсутствие процессов.

Только агрегаты: [summary.json](summary.json). Raw profiles/IDs/пути приватны.
NETCALL-01, физическая/AOT квалификация и оставшаяся multi-device матрица
не закрыты. Коммит локальный unsigned, push/релиза нет.
