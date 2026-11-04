# TTL входящего текста и правок — 2026-11-04

## Подтверждение

На исходном `df6db012` семь целевых проверок были красными: новый старый post
писался в message log и публиковался собственным устройствам; retry с новым
wire timestamp повторно публиковал старый held post; peer edit и mirrored
edit записывали новое тело поверх уже истёкшего исходного сообщения. Также
не соблюдалась точная TTL boundary, а проверки отказа ожидаемой expiry-записи
не находили ни такой записи, ни запрета ACK. Это несколько путей одного TTL
дефекта, а не семь независимых сетевых причин.

Сервис в тестах намеренно не запускает фоновый sweep. Проверяется сам приём,
а не скрытие UI или последующее удаление периодическим таймером. До правки
fixture компилировалась и исполнялась; compilation failures в red не включены.

## Изменение

- После прежних authentication/consent/sequence gates входящий обычный текст
  сверяется с TTL. Для duplicate авторитетно время уже сохранённого original,
  а не более свежий timestamp повторного wire кадра.
- Новый истёкший post оставляет только durable tombstone/пустой peer seq slot;
  его body, цитаты и emoji не передаются обычному append/publisher/notification.
  Сохранённый старый target удаляется прежним локальным deletion/scrub путём.
- Входящая правка сверяется с возрастом original. Истёкший target удаляется;
  собственный seq аутентифицированного peer сохраняется пустым. Edit-before-post
  не получает ранний ACK; если поздний original уже expired, ни одно тело не
  записывается, а exact retry edit завершает его пустой slot.
- Mirrored/reflected edit истёкшего original удаляет локальный target без
  обратной публикации. Его revision не объявляется доказанным authored slot.
- Required publication удаления ждётся до application ACK. Ошибка записи,
  scrub, publication или void оставляет кадр не подтверждённым и доступным
  точному повтору. Успешная publication не выполняется второй раз из-за
  следующей стадии того же edit. Повтор/запись используют существующие APIs.

Если mirror вставил тот же ID, пока recordExpiredMessage ждал, перед удалением
проверяется время появившейся строки. Живая копия не удаляется по старому
wire timestamp. TTL-off и направление авторства сохраняют прежнее поведение:
peer edit не может ни менять, ни удалять нашу outgoing строку под видом TTL.
Новые wire kinds, mailbox и доверие к claimed provenance не добавлены.

## Проверки

- 39 первичных targeted tests прошли после source fix.
- 113 расширенных tests прошли: ingress, peer gap-fill/own-echo, peer-history
  TTL и ACK/мутации.
- 1167 tests в 53 выбранных файлах прошли, 3 native-conditional отдельно skipped.
- После добавления privacy case финальные 37 ingress/ErrorJournal tests прошли.
  Проверены inclusive boundary/соседняя миллисекунда, старый original при свежем
  retry, отказ tombstone/delete/void, held write до ACK, неудачная required
  deletion publication и её точный retry, edit-before-post, TTL-off и outgoing
  authority gate. Анонимный JSON содержит постоянный kind `inbound-expiry`/тип,
  не исходный текст исключения, тело, peer ID или абсолютное время в режиме
  экспорта без timestamps.
- 8 native cases прошли без skip на обычной проверенной HVS. Два новых через
  настоящий async worker/container удерживают expiry commit до release: до
  него ACK отсутствует. Lost-reply после успешного commit тоже не получает
  ACK до точного повтора. Peer edit занимает пустой следующий slot, свежий post
  продвигает high-water до 3. После остановки raw log roots не содержат ни
  expired post, ни expired edit; свежий body — обязательный положительный
  контроль чтения. Cold reopen сохраняет tombstone, единственную живую строку
  и high-water. Ещё шесть cases повторяют предыдущие peer-source/mirror
  admission safeguards.
- Analyzer пяти product inputs и всего `test/` чистый.

## Сквозная регрессия A/B/C

Три отдельных процесса с настоящими providers, подписанными native
сообщениями и контейнерами на локальном relay island. Повторно пройдены все
пять обязательных gates прежнего direct-edit сценария: настоящая queued edit
до expiry; её фоновая очистка при offline C; stopped raw roots без старого
edit/orphan payload; чистый первый raw read C до прежнего 30-с timer;
durable ACK пустого slot и свежая доставка после него. Это регрессия прежнего
сквозного пути; непосредственный expired wire post намеренно проверен
отдельными unit/native cases без фонового sweep, а не этим сценарием.

Test/driver/cleanup 0/0/0, полное время 235,499 с. Первое чистое чтение C через
9270 мс от запуска процесса — прежний startup gate, не скорость доставки.
Все 24 своих PID завершены, 32 порта свободны, runtime удалён. 1447 source/
package inputs неизменны во время прогона; native SHA и чистота зависимостей
проверены до/после. Это не A/B замер общей latency.

## Границы

Это обычный wire text и общий applyEdit, не полная TTL модель всех видов медиа.
Content/file offers, неполные persisted transfers, неизвестный original,
истечение срока во время дальнейшего append/publication I/O, смена политики
и clock skew требуют отдельной проверки. Отсутствие старого текста в доступных
committed roots не является обещанием forensic erase всего носителя.
Общая latency и остальная multi-device матрица не закрыты. APK, native pins,
production seeds, push/релиз не менялись; mailbox своих устройств отключён.
