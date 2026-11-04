# TTL во время записи правки — 2026-11-04

## Подтверждение

На исходном `13399869` воспроизведены шесть TTL-сценариев:

- редактирование уже истёкшего исходящего сообщения всё ещё писало новую
  версию и передавало её required sibling publisher;
- исходящая правка истекала во время ожидания завершения edit commit, но
  всё равно попадала в sibling publisher;
- входящая правка в том же окне оставалась в переписке и публиковалась;
- отказ удалить такую входящую правку не мешал ACK отправителю;
- зеркальная правка и отдельная reflected own-echo правка оставались в
  хранилище после истечения исходного post во время записи.

Gate стоит ПОСЛЕ реального `super.editMessage`: текущая строка с новым body
доступна у gate до release. Доменное время сдвигается ровно на TTL исходного
post. Reflected путь проходит через настоящий outstanding own-echo ask и
аутентифицированный sync frame; новый production test API не добавлялся.

Шесть ordinary assertion-red и шесть native HVS assertion-red получены до
правки. После исправления fixture повторены все шесть native red на временно
восстановленных исходных product-файлах. Они снова упали на assertions;
current source восстановлен в finally и сверен SHA до последующих проверок.
Это не тест скорости реального fsync.

Не засчитаны как подтверждение: первые compile attempts с несуществующим
public `reflected` параметром. Fixture переведена на настоящий sync/echo путь.
Первый дополнительный seq-oracle ошибочно предполагал seq=2 после ручного
seed с explicit seq: такой seed не двигал local allocator. Теперь local post
получает номер через обычную аллокацию; incoming wire сохраняет свой seq=1.
Именно окончательная fixture повторно красная на прежнем product-коде.

## Изменение

Локальная правка проверяет исходный post до edit и повторно после его durable
записи. Истёкшая строка удаляется через прежний scoped erase/publication path;
передача edit body и его sibling publication не начинаются после отказа.

Входящий edit повторяет expiry/tombstone guard после записи и до publication.
При expiry сначала завершаются удаление и required deletion publication,
затем расходуется только аутентифицированный peer edit slot и разрешается
ACK. При ошибке frame остаётся без ACK, exact retry завершает очистку.

Mirror/reflected applier проверяет исходный clock после edit await. Локальная
очистка не рассылается обратно в device journal. Reflected revision не получает
права занимать авторский event slot. Общий edit guard признаёт и уже durable
tombstone, включая удаление во время записи при отключённом TTL.

Редакционные времена не продлевают жизнь post. Независимые peer/device
обязательства обычной живой правки и их failure propagation сохранены.

## Проверки

- 18 новых cases без skip при явно заданной проверенной HVS: 9 ordinary и
  9 native. Кроме шести TTL shapes, проверены incoming/outgoing/mirrored
  deletion во время edit при TTL-off.
- Committed body у gate обязателен; после отказа publisher не получает edit,
  wire и durable Outbox не содержат edit frame. Incoming ACK ждёт cleanup,
  repeat не пишет ещё один edit; ошибка представлена в anonymous report
  только безопасными category/type, без body/ID/path.
- Авторские outgoing/incoming edit slots после удаления bodyless; reflected
  seq не появляется в authored replay. Mirrored expiry не вызывает обратный
  onMessageDeleted. Каждый case завершает настоящую свежую правку как
  положительный контроль.
- Native cold roots не содержат новый expired edit body; fresh changed body
  обязан присутствовать ровно один раз. Cold reopen сохраняет tombstone и
  свежую строку. Это проверка доступных storage roots, не forensic erase диска.
- Вместе с прежними native ingress и append-boundary cases:
  **24 passed без skip** (15 native storage cases + 9 ordinary).
- Analyzer трёх изменённых product inputs и всего `test/` чистый.
- Широкая финальная серия в 79 файлах: **1447 passed / 14 native-conditional
  skipped**. Native прогоны выполнены дополнительно, как указано выше.

## Сквозная регрессия A/B/C

Три отдельных процесса на локальном native relay island: A/B одной личности,
C другой. B восстановил 100 конфликтующих правок через C при offline A;
значения сохранились после cold reopen и не превратились в authored proof.
Отдельная online wave сошлась на B, от C расшифрованы все 100 distinct echoes.
Затем настоящий автор A подтвердил те же значения при offline C. Дублей нет,
адресация reply ratchets осталась identity-wide.

Test/driver/cleanup 0/0/0, 210,523 с; 40 своих PID / 52 порта проверены,
runtime root удалён. Во время теста 1454 source/package inputs и native/HVS
SHA не менялись. Это регрессия обычных edit/history путей с настоящими
providers/ratchet, не gate задержанного edit commit и не A/B latency. Новые
native библиотеки не собирались; qualification Mac/JIT.

## Границы

Проверены завершение edit commit и начало следующего эффекта. Это не полное
закрытие TTL: более позднее ожидание publisher/Outbox/transport, уже принятые
сетевые bytes, неполные transfers, policy/clock skew и оставшаяся матрица
требуют своих gates. Native fixture использует настоящий HVS, но transport
захватывается локальным тестом; это не проверка слышимости или Android/Windows.
Mailbox собственных устройств, APK/engine pins/сиды/push/релиз не менялись.
