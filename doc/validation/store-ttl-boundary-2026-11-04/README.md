# TTL между append и публикацией — 2026-11-04

## Подтверждение

На исходном `57338c15` три отдельные проверки воспроизвели истечение TTL,
пока Future append ещё не вернул результат: входящий post публиковал body и
уведомлял пользователя; исходящий возвращал success и отправлял старый текст;
file offer публиковался и запускал auto-download. Gate стоит после реального
append: положительный контроль видит committed строку, но required publication
и ACK ещё не произошли. Время сдвигается ровно на TTL перед release. Это
модель задержанного завершения записи/планирования продолжения, не измерение
реальных 30 с дискового fsync.

## Изменение

Общий `_store` после append заново проверяет tombstone и исходный post clock
по текущему shared TTL. Если строка истекла/удалена, existing scoped deletion
и required own-device deletion publication завершаются до возврата. Сохраняется
реальный авторский slot строки; local outgoing/system marker не превращается
в фиктивный peer slot. Body не поступает в `onMessageStored`.

Внутренний результат `_store` теперь nullable: `null` означает отсутствие живой
строки после этой границы. Адаптированы вызывающие обработчики:

- исходящий text, recommendation, shared/byte/streaming content прекращают
  сетевую отправку/advertise; соответствующие bool/nullable APIs сообщают отказ;
- необъявленный streaming source закрывается ровно один раз;
- входящий text, recommendation, chat marker и legacy/content file не создают
  уведомление/autofetch после отказа; application ACK следует durable решению;
- истёкший локальный greeting не попадает в connection request, сам handshake
  сохраняется; Saved Messages reference-copy не сообщает успех при null.

Просто добавить guard общего метода было недостаточно: промежуточный вариант
всё ещё уведомлял/запускал загрузку в вызывающих ветках. Целевые tests оставались
красными до обработки null. Отдельный red поймал два onMessageDeleted в новом
сочетании pending delete + append expiry. Теперь pending-delete handler не
повторяет уже завершённое удаление; тест и его native аналог требуют ровно один
callback. Ошибка expiry erase оставляет входящий frame без ACK, exact retry
после восстановления записи завершает tombstone. Свежий delayed append
сохраняет обычные publication/send, TTL-off не отменяет явный tombstone.

## Проверки

- 3 исходных red tests на прежнем HEAD; затем 35 и 62 targeted tests прошли.
- Широкая промежуточная серия: 1430 passed / 3 native-conditional skipped в
  78 файлах. После pending-delete guard финальные 78 targeted tests прошли,
  включая mutation ACK/retry, входящий text/media и unfinished publication.
  Повтор всей финальной серии после исправления pending-delete:
  **1432 passed / 3 skipped** в тех же 78 файлах.
- 10 native tests без skip на обычной проверенной HVS: четыре новых incoming,
  outgoing, legacy-file, pending-delete и шесть прежних ingress cases. Committed
  строка существует у gate, после expiry/release отсутствует; metadata/ACK
  следуют решению, callback удаления один. У legacy файла нет сохранённого blob.
  После остановки доступные raw roots не содержат старого body/имени, свежая
  строка обязательна как положительный контроль. Cold reopen сохраняет
  tombstone и bodyless slot именно оригинального автора/seq.
- Analyzer восьми product inputs и всего `test/` чистый.

## Сквозная регрессия A/B/C

Три отдельных процесса на native relay island, A/B одной личности и C другой.
Два свежих 32-КиБ файла A → C и C → A доставлены, на B по одной metadata копии,
дублей нет. После остановки две receiver-container копии проверены байт-в-байт;
два исходных файла отправителей целы. Это проверка обычного пути после nullable
изменения, не физическое воспроизведение долгого append (он проверен gates).

Test/driver/cleanup 0/0/0, 157,053 с. Все 18 своих PID завершены, 30 портов
свободны, runtime root удалён. Во время теста 1452 source/package inputs
стабильны; native SHA и dependencies прежние. После стенда уточнён только
комментарий контракта sendText; исполняемый product code не менялся. Это не
A/B измерение latency; native/engine не пересобирались.

## Границы

Закрыта граница после canonical append и ДО начала publication. Истечение
внутри уже запущенного publisher/его очереди и native handoff, применение
редакций во время I/O, неполные persisted transfers, source legacy NACK,
explicit/shared downloads, policy/clock skew и остальные части matrix требуют
отдельных проверок. Committed raw roots не обещают forensic erase носителя.
Mailbox собственных устройств не добавлялся; APK/pins/сиды/push/релиз не менялись.
