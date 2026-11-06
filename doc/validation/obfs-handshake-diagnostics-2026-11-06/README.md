# obfs4: диагностика первой посылки до transport upgrade

**Закрыт пробел диагностики, NETCALL-01 остаётся открытым.** Новый TCP observer
ещё не устанавливался на телефон. Физический контроль ниже выполнен до этой
правки, с SDK `81436bd1`; его нельзя считать квалификацией нового observer.

Продолжение [локализации obfs4/TCP](../delivery-obfs-handover-2026-11-06/README.md).
Анонимные агрегаты: [summary.json](summary.json).

## Повтор Poco ↔ Mac

Один Mac → Poco звонок с исходным двусторонним native RX, запретом P2P,
отключением Wi-Fi на 50 с и возвратом на 30 с. Обе ОС/QA-личности и native/AOT
те же, что в предыдущей серии. Звонок завершён стендом, неожиданных отбоев и
canonical obfs4 timeout нет. Максимальный native RX age — **1326/2066 мс**
(телефон/Mac). Это счётчики прихода пакетов, не слышимость человеком.
Результат не закрывает предыдущий timeout/односторонний RX: нет A/B,
вариативность маршрута/сети остаётся.

Сокеты телефона снимались с sleep 250 мс: **391 срез, 3570 строк сокетов**.
Android отклонил netlink (`Permission denied`); `ss` перешёл к ограниченному
fallback. Send queue наблюдалась до 9883 байт, но полноценные TCP_INFO
bytes_sent/acked/notsent доступны не были. Главное предусловие — зависший
canonical handshake — не сложилось. По этим очередям нельзя приписывать
потерю первой посылки конкретному прошлому dial.

На NIC отдельного QA-Core: **18040 TCP packets**, kernel drops **0**,
43 flow, из них 35 с client payload. Все 35 получили первый server payload
за **0,246–1,358 мс**. Это время на интерфейсе сервера, не RTT и не гарантия
доставки медиа. Оставшиеся flow не атрибутируются отсутствующему timeout.

## Изменение SDK

Veil `cce33acf` + `29ee0700` (текущий SDK pointer).

Existing TCP writer trace начинает наблюдение уже **после obfs4 upgrade**.
Он даёт kernel snapshots на обоих клиентах, но не видит первую посылку
handshake. В Android запись может не содержать Rust log target, поэтому
поиск только `transport.tcp_trace` ошибочно пропускает реальные записи;
проверены сами поля SocketMetadata/KernelSnapshot. Полные kernel snapshots
внутри процесса доступны, в отличие от shell netlink.

Добавлен локальный `HandshakeStream` в `veil-transport`:

- Использует тот же opt-in rt-trace gate, по умолчанию не хранит наблюдение.
- На client и обеих server accept ветках фиксирует начало, стадию I/O,
  число байтов, принятых writer/read, и завершение. Успешный write означает
  приём сокетом, а не получение сервером.
- При ошибке, отмене или timeout Drop снимает TCP_INFO **до закрытия
  единственного сокета**. Дескрипторы не дублируются, новых фоновых задач нет.
  `incomplete` не различает эти причины самостоятельно: нужен outer result.
- Сообщение имеет явный префикс `tcp_handshake` и остаётся распознаваемым в
  Android logcat без log target. Connection number и local/peer ports —
  только локальные operator correlation; IP/PSK/ключей/содержимого нет.
- После успешного upgrade подсчёт handshake прекращается, последующие
  application bytes через observer не учитываются. Отключение rt-trace
  прекращает выдачу записей незавершённого handshake.

Аутентификация, ciphertext framing, wire, C ABI, 10-с дедлайны и порядок
протокольных операций сохранены. Observer не выбирает новый путь и не
объявляется исправлением паузы. Нативные артефакты клиентов/сидов в этой
части не обновлялись: следующий физический шаг требует пересобрать FFI,
проверить её происхождение и повторить захват с новым observer.

## Проверки

Четыре новых real-TCP unit-теста проверяют прозрачную передачу байтов,
отсутствие состояния при выключенном наблюдении, остановку счётчиков перед
application I/O, pending read и закрытие сокета после отмены. Отдельный
logger recorder получает настоящую `incomplete` запись из Drop: в ней
kernel snapshot успешен (дескриптор ещё жив), стадия Read и счётчик первой
посылки сохранены; payload-canary и IP в запись не попадают. Это диагностика,
не red/green-доказательство устранения сетевого дефекта.

Полный `veil-transport`: **161 unit + 5 smoke + 2 doc**, ignored 0.
Сохранились существующие obfs4 authentication/active-probe и independent
child tests. Target на внешней ФС проверен до запуска и непрерывно
контролировался. SHA исполнявшегося test binary и исходников записаны;
новые тесты действительно перечислены в результате.

`diagnostic_journal_test.dart`: **19 passed**. Новые operator поля, ports,
connection ID и handshake trace отвергаются allowlist анонимного экспорта,
включая объект, который нельзя случайно сериализовать. Проверка фактического
Dart AOT diagnostic artifact также прошла (**1 test**, обычный и diagnostic
flag варианты), с TCP canaries и проверкой через existing artifact gate.
Raw operator trace в пользовательский anonymous JSON не добавлен.

## Очистка

Собственные capture/Core остановлены до их предельного срока; PCAP сохранён
приватно с проверкой SHA. QA unit/config/binary/state/runtime и сетевые порты
удалены; production PID, executable/config SHA и NRestarts не менялись.
Socket collector остановлен по проверенному собственному PID; его script
удалён с телефона. QA APK восстановлен по SHA, основной APK и прежний root
QA-контейнер не менялись. Восстановлены Wi-Fi/mobile/awake/P2P-настройки,
validated Wi-Fi проверен. Свои приложения/ADB forward/Mac runtime закрыты;
для точного Mac PID после SIGTERM grace потребовался SIGKILL. Mac bundle
signature повторно проверена после архивации созданного им runtime log.
Адреса, ID, PSK, пароли, PCAP и raw socket inventory в приватном кеше.
Push/релиза нет.
