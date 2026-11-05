# Старый звонок не возвращается после перезапуска — 2026-11-05

База `676d335f`. Локально, без push/релиза, APK, engine pins, обновлений
публичных сидов, native ABI и mailbox для собственных устройств.

## Подтверждённые причины

В предыдущем process-прогоне B после restart снова перешёл в ringing для
отменённого первого вызова на 21–31 мс своей диагностической шкалы. Native
trace связал offer/cancel с тем же старым call ID. Finished-call cache был
только в памяти CallService. Сохранённый call journal при старте не читался.

Четыре assertion-red через настоящий callServiceProvider и live ordinary
inbox: local/mirrored finished row × ordinary/worker-native HVS. Запись сначала
сохранена и контейнер холодно открыт; старый offer всё равно звонит. Два
положительных other-peer контроля проходят: совпадение ID с записью другого
собеседника не должно блокировать новый входящий. Начальный fixture использовал
legacy-mailbox deliverInbound, который намеренно исключает звонки; он отвергнут
до зачтённых red. Валидный fixture идёт через живой transport stream и ждёт ACK,
поэтому пустой callback не считается доказательством подавления replay.

Отдельный assertion-red подтвердил горячий вариант: после forked answer peer
становится physical endpoint, а finished cache запоминал только это имя.
Поздний offer от stable identity снова звонил. Тест сперва проверяет реальный
FSM rebind к устройству и сохранность mediaIdentity, затем hangup и replay.

## Исправление

Production provider передаёт загрузчик retained call journal, привязанный к
Storage активной личности до await. CallService восстанавливает peer/call-ID
пары до подключения consumer. Предыдущий ACK-фикс сохраняет ранние копии для
retry; отдельный ingress buffer не появился. Outgoing placeCall ждёт тот же
startup barrier, чтобы ответ не пришёл до подключения обработчика.

Прогрев однократный: per-frame дискового ожидания нет. Восстанавливаются до
256 строк, покрывая стандартное retained окно из 200; cache ограничен 256
записями и использует прежний offer-age срок. Старые строки вставляются до
новых. Невалидный peer пропускается отдельно. При локальном завершении
запоминаются actual endpoint и stable media identity, если они различаются.

Dispose во время чтения не подключает старый consumer и не отправляет
ожидавший вызов через ушедшую личность. Неудача callback загрузки диагностируется,
но не лишает пользователя всех свежих звонков: handler всё равно подключается.
Это availability policy, не ослабление transport provenance, consent, revoked
keys или onBehalfOf-проверки. Уже удалённую/вытесненную историю восстановить
этим способом нельзя. Существующий Storage.callLogEntries может возвращать
пустой список при unreadable namespace; его контракт не менялся. Restore success
означает завершение loader API, а не отдельное доказательство здоровья диска.

В opt-in диагностике добавлены source-owned callHistoryRestore (success и
число восстановленных строк) и счётчик callReplayRejected без идентификаторов.
Restore outcome сохраняется отдельно от общего bounded ring. Ошибочные тексты,
peer/call IDs и пути в эти события не попадают.

## Проверки

Пять assertion-red: четыре cold и один identity/device rebind; native — два
cold случая. Шесть cold-provider тестов включают два разрешённых same-ID /
other-peer контроля и следующий свежий вызов. Дополнительно проверены
pending outgoing + dispose/successor, loader failure с privacy canary и все
200 retained записей с malformed соседней строкой. Исходники при baseline
hot-контроле восстановлены побайтово.

Финальный diagnostic control: **802 passed / без skip**, 39 файлов с явно
выбранной проверенной HVS. Analyzer шести изменённых lib/test inputs чистый.
Native HVS source/artifact pins прежние; Rust и engine не пересобирались.
Временных unit-контейнеров не осталось. Отдельная AOT/Android/Windows сборка
этой правки не выполнялась.

## Контролируемый native replay

Process A/B/C на одном Mac, anonymous/onion, три локальных relay. Сначала
обычный C→A/B вызов отменён; на всех уже проверена durable строка точного ID.
После cold B проверены успешный nonempty restore и отсутствие даже раннего
callState до API-ready. Затем приватный fixture A отправляет новый
аутентифицированный onBehalfOf(C) offer того же логического звонка прямо
своему B, через обычный anonymous transport. Это повтор call ID с новым
transport frame, не побайтовый replay ciphertext. Production API не добавлялся,
подписи/ratchet и own-device admission не обходились.

Доставка подтверждена ingress witness свежего fixture frame в B; тот же старый
call ID имеет запись ignored. CallReplayRejected растёт, а callState/callEnded
B остаются нулевыми. Так проверено подавление краткого ringing, которое нельзя
увидеть одним поздним current==null. После этого все пять прежних exact-call
сценариев проходят: обе online, cold B, A offline, B→C, B joins ringing.

Суммарные terminal events теперь **A=2, B=5, C=5**, без прежнего лишнего B.
Шесть реальных diagnostic snapshots проверены по enum/field/numeric allowlist;
dropped events 0. Длительность всей серии 122,955 с не является latency benchmark.
Все семь markers присутствуют (replay, пять сценариев и общий).

Заморожены **1479** source/test/dependency inputs; native source/lock/features
и Veil/HVS SHA сверены. Teardown проверил **25 PID / 33 порта**, процессов и
listeners стенда нет, runtime удалён. После квалификации менялась только
документация, влияющие на проверку исходники сохранены.

## Остаток

Произвольный crash до durable записи завершения, отсутствие/удаление journal,
полная clock-skew и offline матрица здесь не квалифицированы. Медиа и слышимость
не проверялись. Исходный пользовательский Windows ↔ Android случай не
атрибутирован. В конце цикла прежний Windows стенд снова доступен по SSH:
known host принят, вход выполнен; ОС сообщает 10.0.26300.0, xVeil не запущен,
сохранён QA data directory. Это подготовка следующего физического прогона,
а не проверка сборки или звонка и не квалификация пользовательского Windows 10.
