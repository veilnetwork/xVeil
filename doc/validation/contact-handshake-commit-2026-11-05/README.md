# Ответственность за запрос: ACK после сохранения — 2026-11-05

База `37d0e18a`. Локально, без push/релиза, изменений сидов, native ABI,
engine pins и mailbox для собственных устройств.

## Подтверждённые находки

| Участок | Механизм | Результат |
|---|---|---|
| Request/reconnect от accepted contact | Общий gate отправлял ACK и запоминал frameId до durable enqueue accept. Ошибка записи оставляла запрос уже подтверждённым; тот же ID мог больше не дойти до обработчика. | ACK отложен до сохранения ответа, повтор того же запроса может восстановить ответ. |
| Mailbox verdict | Pending delivery через 3 с и исключение callback считались успехом. Relay ACK удалял копии без доказанного принятия приложением. | Таймаут/ошибка/закрытие сохраняют копию; позднее завершение не разрешает удаление задним числом. |
| Поглощённая ошибка dispatch | Ошибка чтения контакта до handler превращалась в успешно завершившийся delivery Future. | Локальный отказ передаётся carrier callback, ошибка записывается в безопасном виде. |

Это воспроизведения механизмов на стенде тестов, не атрибуция пользовательского
Windows ↔ Android случая. Его причина остаётся открытой.

## Исправление

Accepted request/reconnect обходят ранние ACK/seen gates. После полного durable
приёма ответа ACK идёт по существующей bounded receipt queue. Повтор того же
wire ID намеренно обрабатывается: после утраты состояния у собеседника может
потребоваться новый accept даже для ранее подтверждённого запроса. Outbox key
остаётся стабильным, сетевые ответы объединяются очередью из предыдущего шага.
Unknown/pending/blocked consent policies и проверки происхождения не ослаблены.

MailboxService ждёт завершения локальной обработки, но не считает таймаут её
успехом. Синхронные и асинхронные исключения обрабатываются одинаково. Прежнее
трёхсекундное ограничение drain сохранено; незавершённый callback не отменяется,
его поздний результат не меняет уже возвращённый отказ. Используются прежние
refused-copy cooldown (две минуты, ограниченный кэш) и TTL реле; новые хранилища
или продление TTL не добавлены. Отказавшая копия не блокирует следующую почту.

GUI и headless wiring используют `deliverInbound(..., waitForReceipts: false)`:
carrier может подтвердить локальную обработку, не ожидая исходящего сетевого
ACK собеседнику. Обычные явные callers сохраняют прежний default с ожиданием
receipt. Это не разрешает подтверждать незавершённую запись. Запрос, дошедший до закрытого messaging
service, получает явный отказ carrier вместо успешного no-op.

Dispatch failure больше не маскируется успешным delivery. Анонимный error report
получает только source-owned `contact-request-persist`/`inbound-dispatch`, класс
ошибки, безопасные project frames и числовой errno. Сообщение, путь,
FormatException.source и исходный OS message не сохраняются в error entry.
Прежние авторизационные/криптографические барьеры не перенесены за ACK.

## Проверки

- **12 assertion-red на базе**: request/reconnect × hold/pre-commit failure/
  persisted-but-lost-reply × ordinary/worker-native HVS. После правки проверены
  отсутствие раннего ACK, отказ carrier при ошибке, повтор того же frameId,
  восстановление уже подтверждённого accept и cold reopen.
- **4 assertion-red исходного MailboxService** на настоящих orchestrator/relay
  implementations с loopback crypto: timeout до позднего успеха/отказа,
  async failure, failure перед здоровым следующим сообщением. Копии реально
  исчезали из InMemoryMailboxRelay. После правки остаются и принимаются новой
  mailbox instance. Это проверка логики ACK, не физический onion/crypto тест.
- Дополнительный red промежуточного кандидата: ошибка getContact до handler
  всё ещё удаляла relay copy. Общий dispatch catch теперь передаёт отказ.
- Healthy controls: успешная запись удаляет копию; slow peer-ACK не мешает
  принять сохранённый ответ; pending write и закрытый owner не разрешают
  удаление. Проверены private canaries в StateError/FormatException и
  FileSystemException с сохранением errno 13.

Scoped до дополнительных privacy controls: **97 passed, без skip**. Финальная
control-серия с `XVEIL_DIAGNOSTICS=true` и явно выбранной HVS: **408 passed,
без skip**, включая восемь worker/native случаев. HVS сверена по SHA,
Veil/HVS деревья clean, библиотеки не пересобирались.

Широкая финальная серия: **1803 passed / 64 conditional skipped**, 99 файлов.
Пропуски не считаются выполненными native проверками. Analyzer пяти изменённых
lib и всего test чистый. Начальные незавершившиеся widget fixtures, compile
failure при доработке test assertions и запуски с ним не засчитаны как red или
успешная квалификация; указанные red/pass относятся к исправленным fixtures.

`dart build cli` успешно собрал актуальный headless AOT; `--help` завершился
с кодом 0. 576 выбранных lib/pub hashes неизменны во время сборки. Это build/
argument smoke, не сетевой запуск daemon. Stand-приложений, серверов и listeners
в этом цикле не запускали; native test workers завершились. Собственные 14 МБ
AOT артефактов удалены после SHA/smoke. Обычный `dart compile exe` сначала был
отклонён SDK из-за build hooks и не засчитан как проверка; штатный `dart build`
прошёл, Rust build не выполнялся.

## Остаток

Первичное принятие пользователем (local accepted status → durable accept) и
полная атомарность его публикации ещё требуют отдельной проверки. Глобальное
«все данные всех устройств сошлись», power-loss crash матрица, длительный
определённый offline и слышимость звонка этим не квалифицированы. Windows SSH
повторно недоступна; исходный пользовательский случай недоставки остаётся
активным. Снижение сетевой latency не измерялось и не объявляется.
