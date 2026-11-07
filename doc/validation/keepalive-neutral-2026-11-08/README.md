# Собственная проба не должна блокировать нейтральную пересылку

SDK **`04584523`** исправляет подтверждённый компонентный механизм: таймер
ставил собственный Keepalive в INTERACTIVE FIFO перед пересылаемыми клетками.
Если основной writer не мог принять probe, нейтральные клетки не выбирались,
даже когда их отдельный transport был готов. **NETCALL-01 остаётся открыт:**
причина физических 2,7/8,6 с этим тестом не доказана.

## Изменение

Собственные timer probes используют существующую локальную очередь управления
сетью. Нейтральная пересылка сохраняет обычную INTERACTIVE FIFO, WRR-слоты,
квоты и bandwidth admission. Обход надёжного FIFO для чужих клеток не добавлен.
В частности, тест `neutral_datagram_cannot_jump_past_reliable_fifo_head`
сохранился и проходит. Не раскрываются роли аудио/видео и не добавляются
wire priority, capability, endpoint label или новый транспортный пул.

Keepalive **обязательно остаётся на canonical connection**. Исходящий
auxiliary selector исключает именно Control/Keepalive: успешная отправка по
здоровому child не должна ложно подтверждать TX заблокированного parent.
Приём Control/Keepalive и ответы KeepaliveAck не ограничены новым selector.
Random padding, encoded header, oldest-unacked ledger и условия terminal
keepalive teardown сохранены.

## Что доказано тестами

Regression сначала воспроизвёл прежнюю классификацию после механического
выделения прежнего enqueue в общий helper. Настоящий production writer-task
пишет в непрочитанную in-memory трубу; его канал заполнен. Две нейтральные
Forward-клетки не могли выбираться из-за собственной пробы в голове FIFO.
Это падение по результату выбора, без порога времени или предположения о сети.

После исправления обе клетки выбираются в прежнем порядке и реально проходят
через ordered child с parent/exporter proof, session AEAD и decode. Всё это
время в основном writer остаётся 0 свободных слотов.
Обе неподтверждённые пробы остаются в очереди, oldest timestamp не обновляется;
после снятия блокировки исходные байты основного writer читаются в том же FIFO.
Это проверка компонента, не полный SessionRunner/телефонный stand.

Отдельный red guard проверил необходимое условие нового маршрута: Keepalive
нельзя переносить на auxiliary child. До переноса очереди INTERACTIVE сам
не выбирал этот auxiliary путь; это защита изменения, а не второй объявленный
доказанным дефект старой сборки.

## Границы переноса внутренней очереди

Проверки промежуточного кандидата поймали ещё два риска: числовой индекс private
queue мог включать батарейное накопление и понижать probe ниже BULK/BACKGROUND
при overflow. Оба guard сначала упали. Теперь эти две политики используют
логический класс: DATA — background, собственное network control/signaling —
interactive. Раздельные FIFO и WRR, вместимость, защищённые reliable credits,
учёт lossy drops и трактовка обычных wire-классов 0–3 сохранены. Батарейный
тест использует настоящий OutboundBatchCoalescer; admission-тест проверяет
сохранение пробы при полном bulk-буфере и отказ background вытеснить её.

## Проверки и границы

- Окончательный `veil-session --lib`: **708 passed / 8 ignored**. Промежуточные
  706/8 и focused 2/2 не прибавляются к этому числу.
- Clippy именно `veil-session`, lib+tests, `--no-deps -- -D warnings` — passed.
  Первоначальный запуск с lint зависимостей остановился на прежнем
  `too_many_arguments` в неизменённом `veil-ipc::forward_ordinary_family_copy`;
  полный dependency lint не объявляется зелёным.
- Android/aarch64 release FFI check с реальными feature-флагами приложения
  `allow-empty-seeds,node-embedded,packet-tunnel` — passed. Первый standalone
  release check без выбора сети правильно остановил bootstrap guard; он не
  считается пройденной Android-проверкой. FFI check включает изменённый SessionRunner.
- Rustfmt и diff-check прошли. Сборки контролировали mount identity и место
  внешнего target. Для продолжения удалены только старые incremental caches
  `veil-session` старше 48 часов; итоговые libraries/binaries/rollback сохранены.

В этом раунде приложения, телефон и серверные стенды не запускались/менялись.
Native release binaries с этим исправлением ещё не квалифицированы. Прошлые
два звонка/четыре handover выполнялись на `92cebc7e`, без нового исправления.
Наличие FIFO-wait на Core в том захвате не идентифицировало конкретную peer
queue; новая диагностическая строка `09b84565` и этот фикс задним числом
такую идентификацию не дают. Нужен физический повтор с per-session trace,
проверкой всей паузы и сохранением source/Core/authenticated receipt witnesses.
Anonymous export не расширен; private IDs/адреса/payload metadata сюда не входят.
Коммиты локальные, без push/релиза и sibling mailbox.
