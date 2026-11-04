# TTL: старый mirror и живая canonical row — 2026-11-04

## Подтверждение

На исходном `cd1b6413` один сценарий воспроизведён на FakeHv и на настоящем
async HVS. В переписке хранится живая canonical row. В подписанном журнале
устройств есть её свежий mirror и отдельная правка; позже приходит mirror
того же ID с уже истёкшим старым clock. После включения TTL/compaction
исчезали все три journal rows, хотя canonical row оставалась живой.
Оба red упали именно на отсутствии свежего mirror, не на предусловиях.

Причина: `recordExpiredMessage` защищает существующую canonical row и
возвращает false. Compaction игнорировала результат и добавляла ID в свой
набор удалённых, как будто bodyless tombstone был сохранён. Это превращало
конфликт времени одной копии в удаление других живых копий того же ID.

## Изменение

Общий expiry helper теперь различает durable deletion и отдельную старую
копию. Весь ID удаляется только после успешной записи marker либо проверки
уже существующего tombstone. Если unseen-marker отказал при живой canonical
row, удаляется только конкретный expired mirror. Свежие mirror/edit остаются.

Выбор отдельных rows хранится в локальном identity set: дополнительные hashes
всех здоровых rows не вычисляются. Авторские sequence floors, durable scrub
marker, подписи и admission rules не меняются. Новое поведение используется
как для журнала, так и для фильтра уже queued snapshot/delta.

## Проверки

- Два настоящих assertion-red на прежнем helper: FakeHv и async native HVS.
- Финальные scoped tests с явно заданной проверенной native HVS:
  **14 passed, без skip**. Два из них — native container cases (новый конфликт
  и прежняя paired completion), остальные — ordinary fixtures.
- Queued snapshot сохраняет точные подписанные JSON rows свежих mirror/edit;
  тело старой копии отсутствует. До cleanup старый сегмент читается и содержит
  stale marker, после cleanup его storage file ID недоступен. Canonical row
  и отсутствие tombstone проверяются отдельно.
- Cold reopen сохраняет живые rows и floor удалённого author tail; новый event
  получает больший seq. Затем время доходит до TTL самой canonical row:
  она, mirror и edit удаляются, несвязанная настройка остаётся. Это обязательный
  положительный контроль обычного expiry после изменения.
- Analyzer helper и всего `test/` чистый. Широкая серия на окончательном коде:
  **1438 passed / 5 native-conditional skipped**, 78 файлов. Native случаи
  дополнительно выполнены явно, как указано выше.

## Сквозной сценарий

Тестовый worker получил только file-controlled fixture action: построить
synthetic old-clock mirror через настоящий GroupService/signer текущей
личности. Production API, часы ОС и код приложения для инъекции не менялись.
A/B одной личности, C другой; B offline во время post/edit A → C. После
правки C выключается перед инъекцией конфликта; B должен восстановить её
от A и сохранить после cold restart при offline A/C. Проверяется непустой набор реально
верифицируемых rows, отсутствие stale body/tombstone и дублей.

Все три gates прошли: live signed rows на A сохранены, offline B восстановил
правку при offline C, cold B сохранил ровно одну строку с нужным ID/текстом
при offline A/C. Это Mac/JIT с native SDK/HVS и отдельными процессами,
не Android/Windows квалификация и не замер ускорения. Test/driver/cleanup
0/0/0, 82,942 с; 24 своих PID / 26 портов проверены, runtime root удалён.
Во время прогона 1453 source/package inputs не менялись; native/HVS SHA и
зависимости прежние. Новые native библиотеки не собирались.

## Границы

Это защита существующей canonical row при противоречивых clocks копий.
Новая копия не продлевает TTL исходного сообщения; обычное истечение его
сохранённого original clock остаётся действующим. Сценарий не квалифицирует
всю clock-skew матрицу, изменение системного времени Android/Windows,
transport I/O expiry, неполные transfers или остальные multi-device сценарии.
Чтение через storage API не доказывает forensic erase носителя. Mailbox
для собственных устройств, APK/pins/сиды/push/релиз не менялись.
