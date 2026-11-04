# Свежий clock TTL после ожиданий хранилища — 2026-11-04

База: `846f1988`. Локальная правка, без push/релиза и изменений mailbox,
APK, движков, сидов или native ABI.

## Подтверждённый механизм

`_withoutExpiredDeviceBodies` захватывал wall clock до чтения tombstones,
контактов и завершения conversation prune. Если исходный post пересекал TTL
во время этих ожиданий, фильтр всё ещё считал зеркало живым и возвращал
неизменённый snapshot. Helper используется как при очистке журнала устройств,
так и при фильтрации complete queued snapshots.

Шесть настоящих assertion-red на исходном коде: удержанное чтение политики
с известной/неизвестной canonical row и удержанное завершение prune без
canonical row, каждый вариант на ordinary backing и worker/native HVS.
Fixture проверяет, что тот же snapshot допустим ДО gate; затем явно двигает
только domain clock на точную границу TTL. Pass/fail не зависит от скорости
сети или порога выполнения теста.

Первый кандидат обновил время решений, но ещё два red показали незавершённую
очистку: при удержанном prune с canonical row mirror уже отфильтрован, а
исходная запись остаётся без durable tombstone. Такой результат не засчитан
как полное удаление сообщения.

## Исправление

Cutoff строится после чтения политики, время original mirror сравнивается
после завершающих подготовительных storage waits. Если unseen expiry marker
отказан, проверяется собственный timestamp canonical row. Только действительно
истёкшая canonical запись позволяет повторить обычный conversation prune с
новым cutoff. Durable tombstone затем проверяется заново, включая удаление,
совпавшее с canonical lookup. Пустое чтение само по себе не разрешает удалять
прочие копии ID.

Более свежая canonical row сохраняется: старый clock зеркала не служит
разрешением удалить её. В этом случае ретируется только точная истёкшая
journal copy. Подписи, текущий membership, local sequence floors, правила
публикации и отказа/scrub остаются прежними. Повторный prune нужен только при
refused marker и проверенной истёкшей canonical row; обычный уже удалённый ID
не получает этих дополнительных чтений.

## Проверки

Новые случаи в [group_service_test.dart](../../../test/group_service_test.dart):
пять shapes × два backend. Помимо четырёх воспроизведённых гонок, отдельный
контроль удерживает prune при более свежей canonical записи того же ID:
зеркало исчезает, canonical body и отсутствие его tombstone сохраняются.
После очистки TTL выключается, domain clock возвращается назад и контейнер
открывается холодно: истёкшее тело не возвращается, независимая setting row
сохраняется. Это не изменение системного времени Android/Windows.

Scoped серия с явно заданной HVS: **28 passed, без skip**. Из них семь
worker/native HVS cases (пять новых + прежние paired-commit/clock-conflict),
21 ordinary. Включены прежние snapshot/compact-delta, post-save, epoch-sharing,
header/vacuum/segment failures и local floor guards. Signer этой unit fixture
синтетический; криптографический normal path квалифицируется отдельно стендом.
Analyzer helper и всего `test/` чистый.

Широкая серия: **1500 passed / 48 conditional skipped** в 84 файлах. Skipped
не считаются пройденными; явно выполненные native cases указаны отдельно выше.

Real-provider/signer A/B/C TTL/Outbox regression прошёл все пять gates: сначала
подтверждены живые исходные тела в mixed queued copy, затем ordinary cleanup,
чистые остановленные raw roots, свежая доставка и cold retention B при offline
A/C. Expired IDs не вернулись, независимое состояние сохранилось. Это normal-path
регрессия, а не физическое воспроизведение каждого удержанного storage future.

Test/driver/cleanup **0/0/0**; 27 PID / 28 портов проверены, своих живых
процессов/listeners нет, runtime удалён. 1458 выбранных source/test/package
hashes и native SHA неизменны, Veil/HVS clean. 141.271 с — длительность
всего сценария, не latency одного сообщения и не A/B ускорения.

## Границы

Исправлен clock внутри проверенного фильтра. Повторный допуск snapshot после
полного durable admission и ожидания native transport/fragmentation остаются
отдельной работой. Полная матрица одновременной смены TTL policy, skew между
устройствами, partial/legacy transfers и вся multi-device квалификация не
закрыты. Старые осиротевшие partials этим не восстанавливаются. Скорость
догрузки не измерялась и ускорение не заявляется.
