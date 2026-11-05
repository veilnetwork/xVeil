# Независимая версия disappearing policy — 2026-11-05

База `c9150d88`. Локально, без push/релиза, сидов, APK/engine pins,
native ABI и mailbox для собственных устройств.

## Подтверждено

1. Политика имела свой `dsa/dsb`, но переносилась только внутри full contact
   preference snapshot. Gate и fold выбирали весь snapshot по его внешнему
   clock. Поэтому более поздний alias с прежней политикой мог скрыть новую
   policy другого устройства. Native/ordinary endpoints расходились и при live
   доставке, и после fold. Четыре assertion-red, два worker/native.
2. `winner` при равных времени и авторе оставлял первый аргумент. Два устройства
   одной личности могли держать разные TTL/read windows после одинакового
   набора событий. Два pure assertion-red на разном порядке получения.
3. После исправления порядка проверен и delivery identity: разные payload при
   том же clock/identity имели один frame ID. ACK одной policy мог удалить
   обязанность отправить другую на соседнем устройстве. Четыре дополнительных
   assertion-red до изменения ID, два worker/native. Эти red получены после
   промежуточной правки policy fold, не выдаются за один общий baseline-run.

Ошибки компиляции в промежуточном fixture не считаются assertion-red.
Фиксированное время — управляемое предусловие, частота такого совпадения на
живых устройствах не измерена. Исходная жалоба Windows этим не объяснена.

## Изменение

`contactUp/d:<peer>` — отдельный convergence key в том же подписанном device
journal, рядом с metadata `<peer>` и consent `s:<peer>`. Он несёт только четыре
policy поля и **исходную** версию policy. Publisher передаёт metadata и policy;
намерение считается покрытым committed journal после наличия обеих требуемых
проекций. При неподтверждённой policy metadata сама по себе не снимает обязанность.
На одну порцию не более 32 snapshots / 64 events, курсор продолжает оставшиеся.

Ненастроенный default `dsa=0` отдельной записи не требует. Настоящее выключение
окна имеет положительную версию и переносится как решение. History backfill
также публикует отдельную policy без переназначения её clock. Прежняя embedded
policy остаётся в metadata как fallback; она не заменяет независимую запись.

Live gate и compaction используют единый порядок: время, автор, TTL, read
window. Последние два поля разрешают ничью одной личности/одного clock.
Невалидная policy не вытесняет валидную при compaction. Структурный parser
нужен для durable ordering/emission; применение по-прежнему проходит проверку
clock через `fromMirrorJson`; policy за пределами допустимого clock skew
остаётся deferred.

Policy-only merge читает актуальный Contact в storage turn и меняет только
policy. Name, consent, P2P и прочие настройки сохраняются; неизвестный контакт
не создаётся, повторного publisher callback нет. Status materialization
повторяет обе проекции через их обычные gates.

ID внешней durable доставки теперь включает также TTL/read значения.
Повтор той же recipient/revision/content дедуплицируется, разные политики
не делят ACK. Декодирование payload, подписи/ACL и ratchet не менялись.
Системный marker ID этим шагом не менялся, старые tombstones сохраняют смысл.

## Проверки и границы

Новых случаев **20**, из них **пять worker/native**. Model/domain controls
сверяют порядок fold/gate/winner, отрицательные поля, mismatch clock, deferral
будущей policy, default против explicit-off. Настоящие durable wires двух
одинаковых identity endpoints применяются третьим получателем в обоих порядках;
дубликат и ACK другой policy не теряют правильное состояние. Local-only поля,
unknown contact и отсутствие echo проверены отдельно.

Scoped: **208 passed** в 8 файлах; история отдельно на окончательных исходниках:
**43 passed**. Diagnostic control: **719 passed**, 34 файла. Broad:
**2090 passed / 3 conditional skipped**, 113 файлов. History-backfill suite не
входит в эти широкие manifest lists, её результат приведён отдельно. Analyzer
десяти lib и всего test чистый. Headless AOT/--help прошёл, 581 input неизменен;
это не headless network qualification.

Два process A/B/C прогона на одном Mac прошли все **10 gates**. Последний
дополнен положительным precondition: obsolete alias реально коммитится в
подписанный журнал, затем заменяется. Explicit compaction удалила **10 rows**,
после cold B независимая policy сохранилась. Native этапы принудительно делают
outer alias B новее snapshot A, сначала публикуют B без доступа к новой policy,
потом восстанавливают A/B. Проверены совместные name/TTL, status и P2P deny,
а также одинаковый clock/identity с разными TTL после offline commits.

Финальный driver/Flutter/cleanup: exit 0; проверены 46 owned PID и 55 портов,
живых процессов/слушателей нет, runtime удалён. Все 1475 inputs и native SHA
остались неизменными. Первый проход без обязательного row-removal oracle
не используется как доказательство фактического удаления; он был повторён
после усиления fixture. Новых production debug hooks для этого не добавлено.

Полная clock/crash/revoke/split-brain матрица и физические Windows/Android
комбинации остаются открытыми. Совместимость старых приложений исключена из
гейтов решением владельца. Старые уже потерянные policy evidence не
реконструируются автоматически; следующий metadata edit/history replay может
передать policy, ещё сохранённую устройством. Offline archive projection
остаётся прежним embedded форматом и требует отдельной проверки.
Timeline caption при конфликте одинаковой версии не квалифицирован: marker
формат сохранён; в этом шаге утверждается сходимость самой policy.
