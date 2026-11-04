# TTL входящих файлов и предложений — 2026-11-04

## Подтверждение и изменение

На исходном `30cc14be` девять проверок воспроизвели legacy-file запись после
TTL, продолжение сборки после expiry между частями, запрос старых частей по
fileQuery и создание/удержание expired full manifest/ref. Даже когда surface
уже отказывал удалённому ID, его void-результат не мешал последующей регистрации
предложения и автозагрузке. Это общие пути приёма, а не установленная причина
исторической жалобы «33%». Первый compile-failure неверной сигнатуры test
storeFile исключён из red; зачтённый набор исполнялся и падал по assertions.

Маленький legacy файл проверяется до регистрации meta/query и перед приёмом
каждого следующего chunk. Эффективное время фиксируется один раз при принятии
метаданных; повторная meta и отсутствие sender timestamp не сбрасывают TTL.
Истёкший transfer удаляется из bounded RAM-сборки только после durable expiry
решения; сообщение ACKed без записи blob, filePost или уведомления. Ошибка
записи не превращается в ACK, точный retry остаётся у отправителя.

Full manifest/ref получает результат допуска от surface. Отказ TTL или
существующий tombstone останавливает handler до сохранения holder hint,
manifest/ref, resume-сигнала и старта автозагрузки. Живая существующая строка
по-прежнему допускает получение своих байтов; новая отправка того же content
с новым message ID остаётся новым сообщением. Нет глобального content-ID ban
или удаления общего blob, который относится к другой живой строке.

Отдельный red/green показал обход через eventless hint: отсутствие message ID
позволяло повторно зарегистрировать download, когда единственная named строка
того content ID уже истекла. Теперь для такого продолжения нужна хотя бы одна
живая совпадающая строка. Без совпадений сохраняется прежний legacy offer путь;
без доказанной авторской позиции не придумывается tombstone/void для hint.

## Самопойманная регрессия первого кандидата

fileQuery допускает claimed return path как читающую пробу. Первый кандидат
ошибочно передавал его метаданные новому expiry writer: непроверенный query мог
создать tombstone и отравить последующую аутентифицированную meta. Отдельный
тест красный на этом кандидате. Исправлено до зачтённых широких прогонов:
claimed query только читает существующий assembly и отвечает NACK; не создаёт
имя/clock/sequence сборки и не пишет expiry evidence. Authenticated query
сохраняет прежнюю возможность восстановить потерянную meta. Другой src не
может удалить занятый чужим transfer ID слот. Лимиты, wire и auth gates не
ослаблялись.

## Проверки

- 21 первичный targeted test прошёл после первых source изменений.
- 52 tests расширенного content/legacy набора прошли после authority фикса.
- Финальные 22 media/dedup tests прошли, включая eventless red/green.
- 1361 tests в 70 выбранных файлах прошли, 3 native-conditional отдельно skipped.
  Покрыты legacy assembly/eviction, content stream/credit/cancel/retry,
  per-message dedup, shared blob, TTL-off прежних путей, входящие сообщения,
  durable ACK и multi-device history регрессии.
- 6 native tests прошли без skip на обычной проверенной HVS: четыре новых
  legacy/full/ref/lost-expiry-reply и два предыдущих text ingress. Настоящий
  worker/container удерживается gate до tombstone commit — ACK ещё нет. Потеря
  ответа уже записанного expiry требует exact retry. Нет blob store вызовов,
  строки файла или зарегистрированного предложения. Stopped raw message roots
  не содержат старого имени; свежая контрольная строка обязательна. Cold reopen
  сохраняет tombstone, единственную живую строку и high-water 2.

## Сквозная регрессия свежих файлов A/B/C

Три отдельных процесса на локальном native relay island: A/B одной личности,
C другой. A → C и C → A по одному 32-КиБ файлу через production sendFileStreaming,
реальную подписанную доставку и автоматическое получение. На каждом получателе
и B ровно одна запись соответствующего file message. После остановки клиентов
два receiver-контейнера заново открыты и проверены байт-в-байт; исходные файлы
отправителей также целы. Новые production fault switches не добавлены.

Первый прогон НЕ зачтён: оракул ошибочно требовал обе копии blob в обоих
контейнерах. Обычный streaming sender намеренно сохраняет source path вместо
дублирования всего вложения, поэтому loadFile у источника закономерно null.
Исправлен тест, product inputs между попытками побайтно одинаковы. Повтор
прошёл все gates: два файла, две cold receiver копии, два целых source файла,
две sibling metadata copies, дублей 0. Это регрессия свежей доставки; expired
wire-ветки независимо квалифицированы unit/native без фонового sweep.

Зачтённый test/driver/cleanup 0/0/0, 152,342 с полного времени. Проверены
18 своих PID и 26 портов, процессов/listeners нет, runtime удалён. Первый
неуспешный оракул также полностью очищен: 18 PID/25 портов. В каждом прогоне
1450 source/package inputs стабильны, native SHA/dependencies прежние. После
зачтённого прогона только фигурные скобки в test finally исправлены по lint;
product code не менялся. Финальный analyzer трёх product inputs и всего test
чистый. Это не A/B измерение скорости; SDK/engine не пересобирались.

## Границы

Это TTL/admission конкретного сообщения и unsolicited auto-download. Отдельно
нужны квалификация expiry во время последующего append/publication I/O,
незавершённых persisted transfers и уже начатых explicit/shared-CID downloads,
других egress-путей (включая legacy NACK), policy/clock-skew и общей матрицы.
Application receipt по message ID проверен; generic transport frameId ACK
всех файловых wire kinds здесь отдельно не переквалифицирован. Доступные
committed roots не являются обещанием forensic erase носителя. Общая latency
не измерена парным опытом. Mailbox своих устройств, APK/engine pins, сиды,
push/релиз не менялись.
