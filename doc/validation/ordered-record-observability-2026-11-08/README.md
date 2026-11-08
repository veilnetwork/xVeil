# NETCALL-01: закрытие пробелов наблюдения после выбора транспорта

**Дополнение:** последующая [физическая проверка Poco ↔ Mac/Core](../record-boundary-calls-2026-11-08/README.md)
выполнена на SDK `5f194c38`: 6/6 и 5/6 финальных окон в двух отдельных
сериях; внутри полного повторного захвата подтверждена пауза приёма 2613 мс.
Диагностика IPC/record boundaries квалифицирована; ниже сохранён исходный
статус компонентного раунда до этих звонков.

**Паузы звонка остаются активным дефектом.** SDK `f5a246ab` / `26686d56`:
в этом раунде исправлена
подтверждённая ошибка диагностической выборки и добавлена привязка клетки
к ordered record. Нового физического звонка пока не было; устранение или
сокращение пауз не заявляется. Предыдущий
[Poco ↔ Mac захват](../keepalive-calls-2026-11-08/README.md) остаётся
последней физической квалификацией: 5/6 финальных окон, паузы порядка 1,6 с.

## Подтверждённая ошибка выборки

`f5a246ab` устраняет рассогласование: endpoint/send tracing использовал
настроенный интервал, а `route_trace::delivery_digest` жёстко выбирал
первую и каждую пятидесятую клетку. Даже при full-capture остальные
authenticated receive samples не могли получить локальные IPC timings.

Это подтверждено двумя независимыми способами:

- На прежнем коде regression с полной выборкой упал на sequence 2:
  authenticated local delivery ages отсутствовали. Тест проходит реальный
  `observe_local_delivery_at` → `authenticated_local_delivery_ages`, с тремя
  локальными границами; конфигурации проверяются в отдельных процессах,
  без мутации окружения параллельных unit-тестов.
- В предыдущем физическом захвате **точные наборы** cells с daemon/SDK ages
  совпали с фиксированной выборкой: **44/2319** Poco → Mac и **59/3139**
  Mac → Poco. Это объясняет пропуск этих времён в старой трассе;
  не объясняет сами задержки звонка.

Теперь используется тот же `sealed_trace::sample`, что на endpoint/send.
Default остаётся раз в 50; full-capture — каждую клетку. Проверены default,
1, 10 и два недействительных значения. TTL 30 с, cap 256, full-ciphertext
digest, первое наблюдение, однократное потребление после аутентификации
и очистка при выключении сохранены. Отдельного network/IPC поля нет.

`daemon_queue_age` для обычного `AppMessage::Deliver` по-прежнему неизвестен:
этот путь не несёт timestamp начала очереди. Исправление sampling не
создаёт отсутствующие границы и не подменяет неизвестное нулём.

## Новая привязка ordered records

Добавлена отдельная operator-only трасса `transport.ordered_record`.
Она регистрирует bounded encrypted session record, его целую SHA и локальный
номер child. Транспорт не разбирает Forward, RTP, роли или источники.
Размер ограничен прежними 1200 байтами, вывод — 100 000 observations на
процесс с отдельной отметкой достижения предела. Хеш исключает двухбайтовый
framing prefix, поэтому совпадает у отправителя и получателя.

Наблюдения различают:

- `send_admitted` — постановку в локальную record-очередь;
- `write_start` — начало попытки записи;
- `first_write` — принятие первых байтов `AsyncWrite`, не всей записи;
- `flushed` — завершение локальных `write_all` и `flush`;
- истечение до записи / после частичной записи, write error / timeout;
- `read_complete` — сборку record перед входной очередью;
- `decode_input`, ожидание остальных фрагментов и отказ декодирования.

**Локальный flush не является remote ACK или доказательством приёма NIC.**
`read_complete` тоже предшествует session authentication и admission входной
очереди. Эти события не вводят подтверждений доставки и не участвуют
в выборе транспорта, квотах, WRR, FIFO или дедлайнах.

SessionRunner дополнительно связывает непрозрачную Forward-клетку с SHA
её record fragments (`delivery.opaque_record`). На отправке это
`send_attempt`, перед вызовом handle; на приёме — `authenticated_frame`
после AEAD/replay/eligibility checks. При сборке из нескольких фрагментов
приёмная связь указывает на последний record, завершивший сборку.
Она не означает доставку приложению. У принимающего независимого task
локальный node prefix не придуман: поле неизвестно, лог привязан к процессу.

Связь отправки добавлена в обычную исходящую datagram-ветку SessionRunner.
QUIC-пакеты и отдельная ранняя ветка `Carrier::try_send` этой новой связью
не покрываются. Generic record events сами по себе не атрибутируют эти пути
конкретному источнику. Полнота нужной ветки требует нового физического захвата.

## Включение и приватность

На host Core/Mac `VEIL_DIAG_ORDERED_RECORDS=1` включает record observations;
для связи с Forward дополнительно нужен `VEIL_DIAG_OPAQUE_FORWARD=1`.
На Android соответствуют `debug.xveil.ordered_records=1` и
`debug.xveil.opaque_forward=1`. Gates фиксируются при первом использовании
в процессе; после изменения нужен перезапуск. Явная environment-настройка,
включая недействительную/non-UTF8, имеет приоритет над Android property.
Везде действует точное значение `1`, по умолчанию выключено.
При физическом захвате исходные значения обоих Android properties нужно
сохранить и восстановить вместе с прежней sampling property.

У standalone CLI отдельный `env_logger`, по умолчанию с уровнем `warn`.
Для его INFO-событий нужны также разрешённые targets, например
`RUST_LOG=warn,veil_session::opaque_forward_trace=info,veil_transport::ordered_record_trace=info`.
`[global] log_level` управляет другим NodeLogger и эту настройку не заменяет.
Перед измерением нужно увидеть реальные record events на каждом Core:
одного присутствия environment gates в `/proc` недостаточно.

Это private operator capture, **не анонимный пользовательский отчёт**.
Raw hashes, child IDs, node/peer prefixes и строки трассы не добавлены
в anonymous allowlist. Расширены canary-проверки реального DiagnosticJournal
и скомпилированного AOT-экспорта; они проверяют исключение новых полей.
В публичном отчёте ниже остаются только агрегаты.

## Проверка

- Финальные host suites: **199 IPC / 709 session / 177 transport / 76 util
  passed**. **5 IPC + 8 session ignored** отдельно. Промежуточные повторы
  не прибавляются к итоговым числам.
- `5f194c38` добавляет явный guard против нулевого числа tests в дочернем
  процессе: одной успешной команды недостаточно, требуется ровно один
  выполненный passing test. Все три затронутые suites повторены после guard,
  с теми же итоговыми числами, без дополнительного суммирования.
- Строгий Clippy lib для session/transport/util — passed. Проверка lib+tests
  всех четырёх пакетов прошла с двумя именованными исключениями:
  `manual_async_fn` и `too_many_arguments`. Без исключений запуск остановился
  на прежних `obfs4_backup_tests::attempt` и
  `veil-ipc::forward_ordinary_family_copy`; эти файлы не изменялись.
  Полный строгий Clippy всех tests не объявляется зелёным.
- Android/aarch64 release FFI check с реальными флагами
  `allow-empty-seeds,node-embedded,packet-tunnel` — passed, включая новые
  property gates. Это compilation check, не установка APK и не физическая
  квалификация чтения новых properties на Poco.
- **19 Flutter DiagnosticJournal tests** и AOT artifact/export gate — passed.
  Новый canary покрывает record hashes, local child IDs и строки обоих
  видов trace; anonymous allowlist не расширен.
- Rustfmt, Dart format и diff-check прошли.

Реальный I/O regression использует production OrderedRecordPlane, duplex
stream и writer/read tasks: `flushed` наблюдается ещё **до запуска** reader
другой стороны; затем проверяются совпадение record SHA, чтение байтов,
различные локальные номера child и неизменность payload. У record,
истёкшего в очереди, есть expiry, но нет `flushed`. Проверены disabled,
enabled и invalid gates в отдельных процессах. Session linkage отдельно
проверена при всех четырёх комбинациях двух gates, с отказом на malformed
frame/oversized record и без вывода содержимого.

Новая диагностика пока квалифицирована компонентными тестами и компиляцией.
Она не превращает прежние отсутствующие receipts в доказанные wire losses.
Следующий физический шаг — свежие Poco/Mac/Core native builds, проверка их
происхождения и захват с этими gates, полной выборкой и прежним критерием
свежести звука. Успешные финальные окна не должны скрывать паузы внутри них.

Приложения и серверные стенды в этом раунде не запускались/изменялись;
production, APK и контейнеры не трогались. Rust-проверки контролировали mount
identity и место внешнего target. Preflight дважды отказал в запуске из-за
места; это не падение SDK и не пройденная проверка. Для продолжения удалены
только 55 rebuildable incremental-каталогов IPC/transport старше 48 часов
(около 1,84 ГиБ), с повторной проверкой возраста каждого файла и filesystem.
Готовые binaries/libraries/rollback и исходники не удалялись. Финальные
проверки завершились с сохранением mount identity; живых build handles нет.
Push/релиза и sibling mailbox нет.
