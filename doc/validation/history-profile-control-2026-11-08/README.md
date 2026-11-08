# Догрузка: контроль профиля и native-сборки

**Задержка догрузки остаётся активной. Product-оптимизаций в этом раунде нет.**
После [снятия повторной roster-проверки](../history-publication-auth-2026-11-08/README.md)
снят CPU profile и закрытый storage timeline настоящего A/B/C stand.
512 входящих сообщений, SIGKILL B во время неполной догрузки, A/C offline,
возврат только A, затем повторный boot B без источников. Все ID, тела,
positions, порядок и delivered сохранились; completed-history retries — 0.

## Что измерено

Для разбора выбран именно boot с восстановлением истории, по наличию
history-стеков, а не последний или самый большой CPU-файл. В main isolate
1568 samples; 134 содержат VM `StackTrace_current`, вместе с кадрами
`package:stack_trace` тестового раннера. Это не доказательство дорогого
production stack capture на каждом storage RPC. Проверка исходников не нашла
такого capture в обычном RPC-пути; удалять диагностику смерти worker незачем.
Samples native worker с `__fcntl` тоже не объявляются чистым временем fsync.

Строгий анализ закрытого uncapped timeline квалифицировал 2658 RPC/handlers
на 22,520 с: 273 `readLogGroups` — 704,804 мс внутри worker; 86 commits —
1404,984 мс. Handler включает native работу и Dart adapter. Inclusive await
может перекрываться; сумма не является exclusive critical path. VM timestamp
и wall-clock history log не имеют bracketing-пробы: точное сопоставление
каждой history page с этим timeline пока не заявлено.

## Контроль native-библиотеки

Профиль frozen stand library содержит debug-check функции Rust. Её build
profile не записан в прежнем manifest; один SHA и чистые исходники не
доказывают release-режим. Поэтому отдельно собрана **текущая** HVS `eceb9158`
через `cargo build --locked --release -p hidden-volume-ffi --lib`.
Новый отдельный external target; mount/free-space watchdog, 373 исходных
файла сверены до/после, SHA выбранного dylib сохранён. Старую библиотеку
из приложения 0.13.88 не использовали: она не квалифицирована на новые
проверки digest. Пять native checks новой библиотеки прошли, включая
повреждённую ссылку и hash на cache hit в настоящем worker.

Контроль exact log groups: **один неизменный synthetic container**, все байты
проверяются на каждом чтении. 100 проходов в отдельных процессах:

| Данные | Frozen A₁ | Current release B | Frozen A₂ |
|---|---:|---:|---:|
| Сжимаемые | 116,930 мс | 30,569 мс | 117,408 мс |
| Псевдослучайные | 153,594 мс | 69,652 мс | 155,436 мс |

Это различие выбранных native artifacts в изолированном чтении, не новый
исправленный дефект production и не процент ускорения полной миграции.

Повтор полного crash/offline stand с новой release HVS тоже прошёл:
141/512 строк до kill и до сети после restart, полные 512 после возврата
только A и на финальном boot без источников. После `start(A)` до сходимости
6257 мс против 6378 мс у profiled frozen run. Объём остаточной работы разный
(141 против 189 сохранённых строк), потому глобального causal A/B нет.

Новый закрытый timeline: 2911 RPC, 22,872 с; `readLogGroups` 301 вызов /
160,006 мс handler; commits по-прежнему 86 / 1524,520 мс handler.
Переносить всё улучшение isolated read на задержку истории нельзя.
Для следующих latency-замеров подготовлена release-библиотека с явным
происхождением; остаются main-isolate обработка, ожидание ответов и durable
commits. Кэшировать permissions между изменениями и ослаблять durable gates
этот профиль не обосновывает.

Оба stand прошли независимый teardown: по 34 PID и 48 портов, живых owned
процессов/listeners нет, runtime roots удалены; по 1509 frozen inputs и
native SHA сверены. Raw profiles, VM IDs, clocks и контейнеры private.
Телефон/production для этих controls не использовались. Push/релиза нет.
