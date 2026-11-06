# Poco ↔ Mac: первая obfs4-посылка после смены сети

**NETCALL-01 снова воспроизведён; новый observer физически квалифицирован.**
В одном соединении телефон передал 171 байт в TCP, затем 10 с не получил
ответа. В финальном snapshot один сегмент не подтверждён, ядро повторило его
четырежды; `notsent=0`. Это исключает ожидание **до записи в сокет** для
этого timeout. Конкретный участок ОС/модем/NAT/сеть ещё не установлен.

Продолжение [SDK handshake diagnostics](../obfs-handshake-diagnostics-2026-11-06/README.md).
Анонимные агрегаты: [summary.json](summary.json).

## Происхождение сборок и стенд

Оба release FFI собраны из чистого SDK `29ee0700` с прежними QA feature sets:
Mac `testnet-seeds,node-embedded,packet-tunnel`, Android
`allow-empty-seeds,node-embedded,packet-tunnel`, без default features.
Target — прежний target этого checkout на внешней ФС, без dependency override;
mount/device и свободное место контролировались непрерывно. Сохранены команды,
результаты и SHA артефактов; новый `tcp_handshake` marker есть в обоих binary.
C API — те же 208 экспортов; Mac ABI contract сверён с baseline.

Android QA APK получил только новую FFI: остальные ZIP payloads, AOT, media,
HVS и signer совпадают с исходным. Собственный QA-профиль и identity
подтверждены до звонка; root QA-контейнер с неизвестным паролем не открывался.
На Mac основной подписанный bundle/AOT сохранён без переподписи, новая FFI
выбрана через штатный `VEIL_FFI_DYLIB` override. Реально загруженный путь
проверен по mapping процесса. **Новый trace есть на обоих живых узлах**;
недостаточно было бы только проверить string в binary.

Poco / Android 16 с SIM, MacBook, прежние подтверждённые QA-контакты. Windows
отключена владельцем и не использовалась. P2P запретили и перечитали policy
на обоих клиентах. Actual media path — **non-onion Delivery relay**. Private
onion `PinnedRoute` этой серией не проверяется.

Один отдельный QA-Core, obfs4/TCP, прежний `ade3130a`. Его runtime/session/
crypto/CLI исходники до SDK клиента не менялись; новая transport диагностика
стоит на клиентах, а на реле только DEBUG-журнал и packet capture. Production
не обновлялся. Собственный Core имеет 30-мин bound; capture — отдельный
10-мин bound, фильтр только QA TCP-порта, snaplen 192, без promiscuous mode.

## Звонок

Перед переключениями выполнен baseline с пятью последовательными срезами
свежего native RX обоих концов. Один Mac → Poco звонок, три Wi-Fi → cellular
перехода по 35 с с последующим возвратом Wi-Fi на 20 с:

| Цикл | Максимальный native RX age, Poco / Mac | Результат |
|---|---|---|
| 1 | 1202 / 1418 мс | Звонок сохранился после обоих переходов |
| 2 | 1151 / 1582 мс | Звонок сохранился после обоих переходов |
| 3 | 9665 / 10095 мс | Call state потерян через 35,896 с после Wi-Fi off, уже после команды включения Wi-Fi |

Оба endpoint devlog содержат `reason=timeout origin=livenessTimeout` до
команд завершения стенда. Третий возврат в разговоре не считается пройденным.
После failed observation finally включил Wi-Fi; полная очистка дополнительно
дождалась actual validated Wi-Fi, а не засчитала возврат `svc wifi`.

Native RX age — возраст последнего пакета в текущем media epoch, не слышимая
задержка. Rebuild может обнулить epoch/счётчик; максимум этих ages не задаёт
полный промежуток без peer activity для liveness. Слышимость человеком и A/B
не проверялись. Это конкретный handover-case, не доказанная причина прежней
отложенной жалобы о самопроизвольном завершении примерно через 25 с.

## Что сообщил новый observer

Только для QA endpoint у Poco есть 31 `incomplete` transport observation,
все в фазе Read с одним unacked TCP packet. Большинство закрыты внешней
подготовкой child примерно через 3 с; их нельзя считать отдельными
10-с timeout основного подключения.

Один canonical dial имеет полный набор на часах **самого телефона**:

- `elapsed_ms=10001`, `written_bytes=171`, `read_bytes=0`, phase Read;
- kernel `queued_bytes=171`, `notsent_bytes=0`, `unacked_packets=1`,
  `retransmitted_packets=4`, `tcp_nodelay=true`, send MSS 1024;
- через 1 мс после Drop snapshot — outer `peer.connect.failure` с
  `obfs4 client handshake timed out`;
- через 4,786 с после ошибки — phone call-end с `livenessTimeout`.

Так observation привязан к настоящему canonical timeout, а не только к
спекулятивному child. Write/flush завершились: версии «SDK всё время ждал
свободную writer-очередь до первой отправки» и «Nagle удержал первую посылку»
для него не подтверждаются. `notsent=0` и повторы — свидетель TCP send path,
**не доказательство**, что радио/NIC физически передал пакет.

Это ещё не причинное разложение всего звонкового провала: последний
неподтверждённый пакет не объясняет автоматически весь интервал без медиа.
Таймауты, socket options, auth, wire и call liveness не менялись.

## Реле и границы сопоставления

Capture: **23868 packets**, kernel drops **0**, 112 flow. У 80 flow дошёл
client payload; во всех первый server payload появился через
**0,261–1,233 мс**. Это NIC-интервал сервера, не RTT.

Для 33 успешных Poco handshake local port + time дают единственный flow,
и во всех 33 длина первого payload совпала с `written_bytes`. Для
неудачных mobile соединений прямого port-match нет: NAT binding не доказан.
Не следует выдавать совпадение количества ошибок и пустых flow за связь.

33 успешных пары дают согласованное окно смещения phone/server clocks
шириной 49,346 мс: получение server response клиентом ограничивает одну
сторону, получение client flight сервером — другую. С этим окном и SYN RTT
канонического сокета остаётся один временной кандидат: SYN/SYN-ACK, client
ACK, ни client/server payload, server FIN примерно через 10 с. Но это
**временной кандидат**, без прямого NAT-port или packet witness; точная
привязка canonical flow не объявляется доказанной. DPI, конкретный оператор
или конкретный hop причиной не объявляются.

## Следующий контроль

Проверить восстановление при нескольких доступных QA-реле: если новое
соединение к одному пути теряет первую посылку, сможет ли звонок использовать
другой уже доступный путь. Это отдельный эксперимент с маршрутами; текущая
серия из одного Core не доказывает ни необходимость, ни эффективность
нового параллельного dial. Изменение аудиобуфера или механическое уменьшение
10-с timeout до такого контроля не обосновано.

## Очистка

Observer выключен, endpoint states/journals сохранены приватно. Capture
остановлен, PCAP скопирован со сверкой SHA; QA unit/config/binary/state/runtime
и порты удалены. Production PID, binary/config hashes и NRestarts прежние.
Собственный socket collector остановлен по проверенному PID, script удалён.
QA APK восстановлен по SHA; основной APK и прежний root QA-контейнер
не менялись. Сетевые/awake/P2P-настройки восстановлены, validated Wi-Fi
подтверждён. Свои приложения/forward/Mac runtime закрыты; для точного Mac PID
после SIGTERM grace потребовался SIGKILL. Исходная подпись bundle проверена
после архивации runtime log. Удалены 161091938 байт только собственных
packaging intermediates; final QA/rollback и приватные свидетельства сохранены.
Production-код в этом цикле не менялся. Push/релиза нет.
