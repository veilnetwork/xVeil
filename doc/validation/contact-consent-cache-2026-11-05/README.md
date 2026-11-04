# Кэш согласия после конкурентной блокировки — 2026-11-05

База `49d3d71c`. Локальное исправление без push/релиза, изменений сидов,
APK, engine pins, native ABI и mailbox для собственных устройств.

## Подтверждённые механизмы

| Путь | Старое поведение | Проверенная граница |
|---|---|---|
| Первичное принятие / unblock / mirrored accept | После записи accepted обработчик ждал retireRequests. За это время более новая блокировка завершалась, затем старый обработчик снова добавлял peer в positive cache | В хранилище blocked, но следующий APP_RT offer доходил до call callback |
| Входящий APP_RT offer / endpoints | Задержанный результат getContact(accepted) применялся после завершённого block | Разрешался входящий control callback |
| Исходящий offer / endpoints | Тот же старый результат разрешал отправку и прогревал кэш | Управляющий кадр передавался transport после block |
| Ordinary endpoints | Ordinary dispatch тоже прогревал тот же кэш из старого contact snapshot | Endpoint callback и последующий offer обходили новое состояние |

На базе **16 assertion-red + 2 здоровых controls**. Восемь красных случаев
используют worker/native HVS, восемь — ordinary backend. Управление порядком
через Completer gates после настоящих storage reads, без сетевых таймингов.
RT answer-барьер подтверждает, что очередь обработала предшествующий offer;
ожидание фиксированного числа миллисекунд не используется как доказательство.
Начальная ошибка отсутствующего import в fixture не считается red.

## Исправление

Positive cache пополняется только по storage snapshot с актуальным witness
этого контакта. Изменение согласия инвалидирует кэш и ожидающие reads перед
записью и при её завершении, включая ошибку/потерянный ответ. Второе действие
не даёт пережить commit чтению, начавшемуся во время записи и увидевшему ещё
прежний accepted. Запоздалые accept-side effects больше не создают positive
cache entries.

Witness независим для каждого peer; readonly stranger не выделяет отдельной
map entry. Неустойчивое чтение повторяется не более одного раза. Warm-cache
входящие и follow-up сигналы активного звонка сохраняют прежний быстрый путь;
проверки криптографического происхождения и собственных устройств не ослаблены.
Это не обещание немедленно прекратить уже активное медиа при блокировке.

Ordinary dispatch сверяет snapshot после чтения, перед control admission и
после последующих waits перед offer/endpoints callback. При необходимости
проверяет текущее согласие ещё раз. Исходящий endpoint share повторно проверяет
его после ожидания очистки старой очереди. Принятие решения уже после admission
не может отозвать ранее отправленные в сеть байты; глобальная отмена всех
in-flight пакетов не заявляется.

Закрытый messaging owner не получает late positive authorization, не вызывает
старые status callbacks и не начинает новые contact writes. Mirrored action
повторно проверяет закрытие после preflight awaits. Это защита данного пути,
не общая квалификация всех методов Storage при смене личности.

## Проверки

**34 новых сценария**, из них 17 worker/native HVS: исходные гонки и controls,
потеря ответа local block, отказ до записи, чтение accepted во время такой
записи, endpoint cleanup wait, независимый peer, закрытие во время inbound/
outbound/mirror read и вызовы уже закрытых API. Новые fault controls задерживают
Future доменного storage port; это не инъекция отказа питания в native commit.
Native backend хранит и читает настоящие contact/outbox/floor records.

После исправления offer checks проходят через настоящий `CallService` FSM:
blocked не достигает ringing, здоровые controls достигают. Media controller
не устанавливается, реальный микрофон/динамик не запускается. Это control-plane
проверка, не слышимость речи и не физический Windows звонок.

Финальные scoped: **151 passed**, пять файлов с realtime/decision/accept
регрессиями. Diagnostic control: **539 passed без skip**, 21 файл, HVS явно
выбрана. Broad: **1985 passed / 3 conditional skipped**, 106 файлов, HVS также
выбрана явно. Skip не считается пройденным. Analyzer трёх изменённых lib и всего
test чистый. Схема диагностического экспорта и набор отправляемых данных не
расширялись.

Headless AOT собран штатным `dart build cli`, `--help` завершился с кодом 0.
578 source/pub hashes неизменны; собственные 14 МБ build-артефактов удалены
после SHA/smoke. Это build/argument smoke, не сетевой headless запуск. Veil/HVS
не пересобирались, выбранные библиотеки проверяются по source/artifact proof.

Финальный process A/B/C прошёл все три contact-decision gates: реальное
подтверждение контакта и linking, восстановление решения после boot и повторный
boot с неизменной версией. Это отдельная регрессия GUI bridge/native transport;
управляемая IO-гонка воспроизводится в scoped tests, не на физической сети.
Teardown проверил **24 PID / 42 порта**: процессов/listeners нет, runtime удалён.
Все **1468 frozen inputs** и native SHA неизменны, Veil/HVS source trees clean.
Серия 218,9 с — не замер скорости звонков. Телефон не переустанавливался.

## Остаток

Не установлено, что найденная гонка объясняет исходный PC ↔ Android случай:
сценария блокировки в пользовательском репорте нет. Windows повторно
не отвечает по SSH. Другие writers контактной записи (например, старый
preference read-modify-write), полная conflict/crash матрица и слышимость
звонков остаются отдельными проверками.
