# Подтверждения звонков: первые доставки и медленный обратный путь

## Уточнение предыдущей серии

[Прошлая сводка](../call-route-physical-2026-11-08/README.md) показывала до
44 с receipt age всех realtime transportInfo копий. Покадровое сопоставление
меняет вывод: **это не 44 с ожидания первого изменения маршрута**.

Сопоставлены source `[durable] fid` и receiver ACK frame ID: все 7 Mac→Poco
и 6 Poco→Mac logical transitions, наборы равны. В обоих devlog rings dropped=0.
Входящий call log и ACK log имеют соседние sequence numbers, поэтому timestamp
из канонического frame ID связывает копию с исходной отправкой. Первые
доставки Mac→Poco: 20–3432 мс; Poco→Mac: 86–408 мс. Все первые копии пришли
через realtime. Поздние ordinary/realtime копии доходили и спустя 68,9 с.
Первые 44 с нельзя приписывать сетевому blackout или ожиданию FSM.

Выделен другой подтверждённый участок: между первым receiver ACK log и
sender `delivered` log проходило **0,923–44,319 с**. Это совокупный обратный
путь, включая native send, сеть и ordinary receiver queue; конкретный вклад
каждой стадии не доказан. На все 13 transitions наблюдались 3–4 fast retries;
на отдельный ID получалось до 57 copies. Relative times и агрегаты приведены
в JSON; исходные frame IDs/клоки/адреса остаются private. Первоначальная
source-выборка включала и входящие `recv fid`; финальный join ограничен
`[durable]` источником и проверен на равенство наборов.

## Исправление

Раньше call signal шёл одновременно по ordinary и realtime путям, а ACK —
только обычным путём. Теперь к нему добавлен best-effort realtime ACK. Старый
ordinary ACK и one-time reply сохраняются; отправка fast ACK не ждёт их.
При доказанном srcDevice прямой fast ACK адресован этому устройству в
identity endpoint; relay realtime copy остаётся дополнительным путём.

Приём расширен **только** для короткого пустого ACK существующего локального
callSignal frame. Проверяются sender provenance, accepted/own-device consent,
точный (peer, frameId), wire kind исходной строки. Prefix `call:` сам по себе
не даёт права удалить сообщение. Body/seq/nested frame ID исключены.
Volatile индекс ограничен 4096 ключами, прогревается durable rows после
рестарта и учитывает early-live до enqueue. Удаление использует прежний
Outbox retirement с прежней durability и защитой раннего ACK; delivered/read
состояния чата по этому пути не меняются. Неизвестные receipts не читают store.

Anonymous local posture, anonymous reply handles и claimed-source deliveries
сохраняют ordinary ACK; источник без доказательства не получает fast ACK.
Group ACK не расширен, wire fields/ratchet/mailbox/route qualification не
менялись. Отсутствующий fast путь оставляет существующие durable повторы.

## Проверки и границы

Два assertion-red до реализации: обычный ACK удерживается gate, доставленный
call остаётся в Outbox; authenticated realtime ACK восстановленной строки
игнорируется. **14 focused cases** включают ранний ACK до enqueue, restart,
claimed/stranger/wrong accepted peer, неверный kind за call-prefix, malformed
ACK, anonymous/reply posture и адресное подтверждение конкретному device.
Девять связанных файлов: **199 passed / 7 skipped**; отдельно consent /
provenance / multi-space ACK / bridge: **34 passed / 17 skipped**. Skips не
зачтены. Analyzer трёх Dart files чист, diff check прошёл.

Физический прогон: [отрицательный результат](../call-fast-ack-physical-2026-11-08/README.md), fast ACK не зарегистрирован. Это исправление доступности
быстрого receipt path, а не доказанное устранение NETCALL-01 или всех причин
поздних копий. Push/релиза нет.
