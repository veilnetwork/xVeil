# TTL после durable enqueue правки — 2026-11-04

## Подтверждение

На `02d6f6bd` пять negative cases воспроизведены обычным backend и async native
HVS (по пять assertion-red, два здоровых контроля проходили):

- TTL исходного post истекает при задержанном завершении enqueue;
- post явно удаляется в том же окне при выключенном TTL;
- enqueue заканчивается после TTL для обычного online адресата;
- ошибка required replacement не замечается, когда live leg пропущен;
- истёкший legacy edit без seq остаётся в очереди.

Gate стоит после настоящего `super.enqueueOutboxFrame`; положительный контроль
читает exact committed wire и timestamp до release. Тест хранит last-seen
двухдневной давности для silent path. У fresh/TTL-off контролей body остаётся
queued, а transport не вызывается — это прямой свидетель пропуска live leg.

Проверка expiry была только перед enqueue и внутри tryLive. Silent-ветка
вообще не запускала второй guard; при detached live caller тоже мог закончить
handoff раньше cleanup. Кроме того, после await sendDurable caller ещё мог
передать истёкшее тело required sibling publisher.

Промежуточная правка закрыла body/ошибки, но оставила три age assertion-red
на обоих backend: замена edit на void сбрасывала возраст очереди. В initial
validation helper не получал storage stamp, и replacement ставил текущее
время. Пять миллисекунд разделяют реальные backend timestamps в fixture;
это сравнение сохранённых метаданных, не latency/performance gate.

## Изменение

После enqueue edit проходит обязательную persisted revalidation до выбора
live/skip/detach ветки. Cleanup теперь часть durable handoff: storage error
не скрывается как сетевой best-effort сбой. Поздняя tryLive проверка остаётся,
поскольку время может истечь и после этой границы.

Перед required sibling edit publication caller повторно проверяет original
post/tombstone. Guard расположен внутри прежнего independent-attempt блока:
ошибка peer persistence по-прежнему возвращается вызывающему, а живая правка
сохраняет независимую попытку синхронизации устройств.

При expiry helper получает фактический queue stamp из exact peer/frame entry,
если caller его ещё не знает. Здоровый путь не сканирует очередь. Durable
replacement по-прежнему CAS-проверяет peer/id/wire; новая запись получает
исходный возраст. Уже ACKed/replaced entry не создаётся повторно. Placeholder
не содержит target/body, сохраняет только корректный authored seq; legacy
без позиции локально удаляется. Mailbox и call-control ветки не менялись.

## Проверки

- Новые 14 cases: 7 ordinary + 7 native. Они включают recovery после отказа
  replacement через close/reopen/sweep и оба здоровых silent-контроля.
- Publisher не получает expired edit, canonical row становится tombstone;
  wire/queue не содержат старый edit. Возраст bodyless замены точно равен
  committed original. Ошибка не объявляется успехом, old frame остаётся
  durable retry obligation до восстановления.
- Во всех случаях после операции доходит обычный live non-edit control к
  другому адресату. Cold reopen сохраняет требуемую пустую замену либо живой
  edit при TTL-off/fresh.
- Native stopped raw Outbox roots не содержат старого edit body; ровно один
  healthy control обязателен как положительный контроль чтения roots.
  Native storage fixture не является проверкой криптографии транспорта.
- Вместе с прежним native direct-edit/cold-root тестом — 15 passed без skip
  (8 native storage cases + 7 ordinary), повторено после финальных style
  исправлений fixture. Широкая серия: **1454 passed / 21 native-conditional
  skipped** в 80 файлах. Analyzer трёх product inputs и всего `test/` чистый,
  включая последующую корректировку e2e oracle.

Одна промежуточная попытка не зачтена: удалённый неиспользуемый fixture
completer оставил ссылку и вызвал compile error. Существовавший lookup test
также завис: он ожидал завершения edit до release его теперь awaited guard
и привязывался ко второму чтению. Тест исправлен без ослабления invariants:
запускает future, ждёт реального queued edit вместо счётчика вызовов,
сдвигает время/release, затем ждёт завершения. No-wire/bodyless проверки
сохранены. Анализаторные style issues устранены до финальных прогонов.

## Сквозные проверки A/B/C

Первый native process-стенд прошёл все пять gates: смешанный durable snapshot
с двумя будущими expired IDs действительно существовал, background sweep
очистил его и raw native roots, живая настройка сохранилась на cold B без A/C,
новая доставка работала. Test/driver/cleanup 0/0/0, 139,576 с;
28 своих PID / 35 портов / 1455 frozen inputs, runtime удалён.

Первый direct-edit прогон прошёл live queue, automatic cleanup и raw-root
проверки, но остановился на первом raw read C. Приватный журнал одного
receiver показывает: debug read завершён в .817, уже запущенный startup
sweep — в .864 той же секунды. API читает raw storage; UI использует отдельный
TTL projection. Startup job по контракту owned/asynchronous, а не барьер
каждого raw read. Это ошибка прежнего oracle, прогон целиком не засчитан.
Cleanup 23 PID / 27 портов завершён, runtime удалён.

Oracle теперь ждёт automatic raw cleanup без явного sweep, в оставшемся
прежнем 30-с бюджете от запуска C. First-read-clean остаётся наблюдением,
а не предположением; UI hiding отдельно проверено startup unit cases.
Граница не увеличена. Product code между direct попытками не менялся.

Повтор direct-edit прошёл все пять gates: live edit существовал, затем
заменён одним void, raw roots чистые, C очищен до старого первого timer
(наблюдение 9273 мс от запуска), void сохранён до ACK, queue у A освободилась,
свежее сообщение доставлено. Test/driver/cleanup 0/0/0, 110,391 с;
24 своих PID / 30 портов / 1455 frozen inputs, runtime удалён. Native/HVS SHA
в обоих стендах прежние. После первого snapshot-стенда менялся только
неисполнявшийся им direct-edit e2e oracle; остальные inputs сверены.
Это Mac/JIT regression с реальными providers/ratchet, не A/B latency и не
физическое ожидание двух суток offline. Source-level enqueue gates отдельно
квалифицированы на native HVS выше. Новые native библиотеки не собирались.

## Границы

Это проверка завершения стандартного edit enqueue и последующей публикации.
Более поздние transport/native waits, ранний live+ACK, конкурирующие cleanup,
неполные group transfers, policy/clock skew и вся matrix не закрыты этой
серией. Отказ storage остаётся явным failed operation с durable retry, а не
обещанием очистки недоступного носителя. Storage roots не означают forensic
erase диска. APK, engine pins, public seeds, push/релиз не менялись.
