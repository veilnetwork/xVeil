# Отметки чтения принадлежат своей личности — 2026-11-10

## Подтверждённые дефекты

При разборе записей между страницами обнаружено отдельное семейство гонок.

| Путь | Результат parent |
|---|---|
| `markRead` / `setReadMarker`, read завершён после open другой личности | Timestamp A записан в B; в A не сохранился |
| Старое обновление завершается после нового | Marker уменьшается с 3000 до 2000 |
| Одинаковые вызовы, включая потерянный ответ commit | Несколько одинаковых durable записей |
| `MessagingService.markRead` продолжился после dispose | Shown clock записан в другую личность; поздний callback |
| Старый сервис после dispose | Local/mirrored read и expiry продолжали запись |
| Одновременные посещения чата | Старый shown snapshot заменил новый: покрытие 2000→1000 |

12 storage и 5 client assertion-red воспроизводят эти случаи. Два теста
отказа commit/следующего обновления уже проходили на parent и не считаются
новыми дефектами. Причиной прежних пользовательских жалоб это не объявляется.

## Исправление и закрытие

Оба storage writer используют существующий `_metadataWrite` с общим ключом
`read:<conversation>`. Весь scan/read/compare/commit привязан к исходному store;
close/open/erase дожидаются операции. После maintenance fence новый writer
отказывается. Следующий timestamp сравнивается после предыдущего commit:
больший marker не заменяется меньшим, повтор не создаёт padded commit.
Первый отказ остаётся ошибкой; следующий caller перечитывает durable состояние.

Messaging owns полный mark/read/shown и mirrored-read путь до teardown.
Закрытие синхронно останавливает admission и дожидается начатых операций;
retired callbacks не начинают новые записи/уведомления. Только read/modify/write
таймера показа сериализован по разговору. Другие разговоры независимы, готовый
snapshot не кешируется. Ошибка не отравляет очередь и не обрывает shutdown.

Промежуточный candidate держал ту же очередь во время `markRead` scan.
Получался цикл: scan ждёт history publication, а её visibility check ждёт эту
очередь. Новый fakeAsync тест на настоящем HVS `beforeCommit` и scan gate
показал незавершённую публикацию. Ownership всего вызова отделён от короткой
очереди shown-state; финальный тест подтверждает завершение обоих действий
без wall-time порога. Первая ошибка компиляции fixture не считалась red.

Формат хранилища, wire, ACK/ratchet и mailbox policy не менялись. Это не аудит
всех методов Storage. Production `deleteIdentity` выполняет session/stack
teardown перед close/open/erase; client lifecycle проверен в этом порядке.

## Настоящие worker-backed контейнеры, 100000 строк

B содержит 100000 canary rows и marker 1000, A — одну строку с новым marker
2000000. Разговор имеет один synthetic peer на обеих сторонах. Gate удерживает
завершённый read marker из A. Отдельные кейсы: `markRead` и `setReadMarker`.

| После cold reopen | Parent, оба метода | Candidate, оба метода |
|---|---:|---:|
| Marker A, ожидается 2000000 | 0 | 2000000 |
| Marker B, ожидается 1000 | 2000000 | 1000 |
| Точные уникальные canary rows B | 100000 | 100000 |
| Open/close A раньше release gate | да | нет |

Negative control намеренно дожидается open B до release; candidate обязан
ждать исходную операцию. В positive run 50 мс дают возможность попытаться close,
но pass определяют данные и порядок действий, не длительность. Это проверка
корректности, не performance A/B. Parent здесь не потерял текстов сообщений:
испорчена именно отметка чтения.

Проверены ID/body/status/timestamp/author/seq/canonical position каждой строки,
уникальность/полнота, cold reopen обеих сторон и строка A. HVS dylib проверена
по SHA и реальному mapping работающего процесса. Для зачтённого последнего
parent/candidate прохода прочие source inputs зафиксированы; их hashes сверены
с текущим деревом. Rust и authorization gates не упрощались.

21 focused проверка охватывает смену личности, close/erase, поздние вызовы,
понижение marker, повторы, отказ commit/ответа, race visits, независимый чат,
отказ shown-clock записи и найденный lock inversion. **1062 related checks
passed / 0 skipped**, 21 файл; JSON reporter подтверждает все 21 новых cases.
Analyzer шести production/test файлов: 0 issues. Native cases квалифицируют
storage; client lifecycle — детерминированные тесты. Это не физическая проверка
Android/Windows и не полная multi-device matrix.

## Очистка и остаток

В зачтённых native проходах проверен выход по три owned PID, удалены по два
runtime каталога. Related run проверил выход 20 owned PID. Своих процессов и
native контейнеров не осталось. Private evidence всех итераций около 4,3 МиБ;
кеш около 9,5 ГиБ / 92 файла, свободно около 147 ГиБ. Случайных Dart defines нет.
Реальные ID, пути, mappings и сырые журналы остаются вне Git; summary содержит
только synthetic значения и агрегаты.

Главная задержка догрузки, NETCALL и остальная matrix остаются открытыми.
Сквозное ускорение в этом раунде не измерялось. Push/релиза нет.
