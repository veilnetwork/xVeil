# Атомарное обновление настроек контакта — 2026-11-05

База `b4997d11`. Локально, без push/релиза, изменений сидов, APK, engine pins,
native ABI и mailbox для собственных устройств.

## Подтверждённые находки

Старые writers читали Contact, меняли поле в копии и позже сохраняли весь
объект. Между read и write могли завершиться accept/block, изменение другого
поля, новая TTL-политика или удаление контакта. Последняя запись возвращала
старое состояние. Речь о потерянном обновлении, а не о конфликте формата wire.

**22 assertion-red на базе + 2 healthy controls**, по 11 red и одному control
на ordinary/worker-native HVS. Проверены rename/accept, rename/block,
mirror/block, local P2P/block, disappearing/block, retention/block,
mirror/local P2P deny, rename/new TTL, mirror/new TTL, rename/archive,
rename/remove. Старый DTO реально возвращал pending после accept, отменял
block/deny/TTL и воссоздавал удалённый contact.

Gate расположен перед storage write turn. На базе он оборачивает upsertContact,
после изменения — новый updateContactPrefs; backend commit не удерживается
искусственно, чтобы другой контактный writer мог завершиться. Исходный test
fixture сохранён отдельно от расширенной версии. Это управляемая async модель
на настоящем storage backend, не утверждение о частоте гонки на телефоне.

## Изменение

Storage получает синхронный transform, читает текущий Contact внутри того же
сериализованного turn, где выполняет KV commit, и возвращает его сохранённую
версию. Отсутствующий контакт не создаётся. Попытка сменить nodeId или status
через preference API отклоняется. Generic upsert для явного создания/других
доверенных callers не меняет контракт.

Локальные setters изменяют только запрошенные поля свежей записи. Mirrored
preferences оставляют текущие status и device-local P2P override; сравнение
shared TTL выполняется под той же блокировкой. Local P2P не зеркалируется.
Callback получает committed record, а не ранний DTO. Закрытый messaging owner
не начинает обновление и не публикует его поздний результат. Turn присоединён
к закрытию HVS и не переезжает в другую открытую личность.

Два clock-поля disappearing setting теперь используют свежую вторую половину
при записи. Локальная версия монотонна относительно сохранённой: два изменения одного контакта
за один тик не делят один disap frame ID и не теряют второе изменение на peer.
Эти новые clock controls не объявляются частью 22 исходных baseline red.

Дополнительно подтверждён отказ carrier verdict: при ошибке policy commit
handler оставлял live frame без ACK, но не запрещал relay deletion. Один
дополнительный assertion-red получен до правки этой ветви. Теперь вызывается
onDeclined; копия не выдаётся за успешно обработанную. Нового mailbox хранения
не добавлено, новый deposit policy по-прежнему ограничен handshake.

## Дополнение: собственная запоздавшая копия

Расширение process A/B/C дважды остановилось на реальной потере `pinned` у A:
последовательные name → pin → archive оставляли name/archive/block, но pin
становился false. Первый прогон не имел observation; во втором добавлены
снимки состояния. Оба прогона красные, не квалификация. Cleanup прошёл в обоих.

Четыре дополнительных assertion-red (два worker/native) воспроизвели
собственную старую проекцию до admission и за gate перед storage turn.
Исходный механизм остаётся отдельным от stale Contact DTO: outgoing device
stream повторно применяет уже сохранённую локальную настройку и может записать
старый full snapshot после следующего действия пользователя.

Локальная preference-запись теперь меняет opaque witness внутри storage turn.
Снимок получает слабую привязку к нему. GUI outgoing echo передаёт guard,
проверяемый **внутри** следующего transform, после всех async ожиданий. Старый
собственный снимок занимает свою ordering slot, но не откатывает новую запись.
Последний собственный снимок по-прежнему может восстановить состояние после
старого sibling apply. На входящие события других устройств этот локальный
guard не накладывается. Timestamp резервируется в callback до async own-device
lookup, чтобы порядок публикации не определялся длительностью этого lookup.
Отказ записи восстанавливает прежний witness по CAS; чужой контакт и mirrored
apply не инвалидируют его. При dispose guard отказывает. Map растёт только
от локальных preference-действий, snapshots удерживаются через Expando.

## Проверки

**46 новых случаев**, 23 worker/native: baseline окна, cold reopen, два поля
TTL, фиксированный clock и три distinct durable frame ID, winner из реальных
wire payload, отказ неверного transform, unknown contact, сохранность decision
floor/token и ожидание закрытия pinned turn без late callback. Incoming policy
с более старой версией не откатывает более новую локальную запись.

Scoped: **139 passed**, пять файлов. Старый ACK-тест теперь инъецирует отказ
в underlying KV commit, поэтому проверяет обе storage API. Фиксированная
задержка заменена signal-барьером сериализованного inbox. Возврат после ошибки
проверяется тем же frame ID. Два timeout в расширенном fixture были вызваны
неправильно выбранным будущим тестовым временем: wire parser законно отвергал
пакет до gate. Fixture исправлен, эти timeout не считаются red-продукта.

Diagnostic control с явно выбранной HVS: **669 passed, без skip**, 30 файлов.
Broad с HVS: **2040 passed / 3 conditional skipped**, 109 файлов. Skip не
считается квалификацией. Analyzer семи изменённых lib и всего test чистый.
Схема анонимного диагностического экспорта не расширялась.

Headless AOT собран с неизменностью 579 выбранных исходных файлов; `--help`
завершился успешно. Это build/startup smoke, не headless network qualification.
Veil/HVS не пересобирались; их source SHA и выбранные native SHA сохранены.

Process A/B/C на одном Mac, в отдельных процессах с настоящими контейнерами и
локальным relay island, прошёл все пять gates: неопубликованное committed
решение, boot recovery с исходной версией, повторный boot без restamp,
name/pin/archive при сохранённой блокировке и независимом P2P deny на B,
перезапуск B с теми же полями. Это квалификация production GUI bridge; не
физический Windows/Android звонок и не полная конфликтная матрица. После
исправления own-echo потеря pin в этом сценарии не воспроизвелась. Driver
завершился с exit 0; cleanup проверил 27 owned PID и 43 TCP/UDP порта:
процессов/слушателей не осталось, runtime удалён. Все 1469 frozen inputs и
выбранные native-библиотеки остались неизменными.

## Границы

Механизм может объяснять потерю accepted после настройки контакта, но причина
исходного PC ↔ Android репорта этим не доказана. Полная crash/conflict матрица,
все post-commit marker/prune/announce waits, unversioned status callers и
crash-durable публикация preferences пока не квалифицированы. Сохранение
данных локально не выдаётся за передачу всем своим устройствам при любой
ошибке callback или аварии. Совместимость старых clients не является гейтом
по решению владельца.
