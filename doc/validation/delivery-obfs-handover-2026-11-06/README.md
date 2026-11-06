# Delivery handover: obfs4 и TCP после смены сети

**NETCALL-01 остаётся открытым.** Новая серия отделила установление TCP от
obfs4 и восстановления аудио. Production-код не менялся: данных пока
недостаточно, чтобы обоснованно выбрать исправление.

Продолжение [Poco ↔ Mac Delivery](../poco-mac-delivery-reconnect-2026-11-06/README.md).
Анонимные агрегаты: [summary.json](summary.json).

## Что удалось установить

1. В прежнем обратном прогоне, завершившемся liveness timeout, на **одних
   часах Android** после `NetworkChanged(Cellular)` новая попытка начиналась
   сразу. Затем obfs4 дважды ожидал по 10 с: первый отказ +10,323 с, следующая
   попытка +11,205 с, второй отказ +21,321 с. Следующий dial +23,362 с завершился
   +23,605 с уже около возврата Wi-Fi. Для этого захвата версия «новый dial
   ждал выхода старого runner» опровергнута. Ошибка obfs4 возникает после
   завершения `connect_tcp_stream`, внутри ограниченного transport handshake.
2. На текущем SDK три перехода Wi-Fi → cellular → Wi-Fi **без звонка** прошли
   без timeout obfs4 основного QA peer. Это не отсутствие любых сетевых ошибок:
   обнаруженные альтернативные QUIC/peer попытки также отказывали; они не
   учитываются как obfs4 timeout этого seed.
3. В следующем Mac → Poco звонке baseline на обоих концах прошёл. При
   переключении Wi-Fi → cellular зарегистрирован **один** timeout obfs4
   основного peer. Два текстовых упоминания в полном Android logcat —
   native-событие и его копия через logging bridge, а не два разных dial.
   После возврата Wi-Fi разговор завершён командой стенда. Самопроизвольного
   отбоя не было, но maximum observed native RX age достиг 14672/14685 мс
   (телефон/Mac). Это возраст последнего принятого пакета, не акустическая
   задержка и не доказанная длительность слышимой тишины.
4. На отдельном QA-Core одновременно захвачены **19170 TCP packets**, kernel
   drops **0**, 154 flow. У 107 flow первый client payload виден на NIC;
   во всех 107 первый server payload появился через **0,240–1,305 мс**, и его
   ACK со стороны клиента также виден. У 47 flow TCP SYN/SYN-ACK присутствует,
   но client payload на NIC вообще не наблюдался. Это не измерение RTT,
   не подтверждение доставки медиапакетов и не оценка CPU crypto отдельно.

В окне единственного timeout телефона есть кандидат TCP flow: SYN/SYN-ACK,
ACK клиента, отсутствие payload, затем server FIN примерно через 10 с.
Но приложение не сохранило local port именно этого handshake; при
параллельных children и неопределённости cross-host часов привязка только по
времени **не доказывает**, что это тот же dial. Объявлять конкретный flow
причиной timeout нельзя. Также нельзя приписывать весь 14,7-с RX age этому
одному ожиданию.

В DEBUG-журнале Core — 40 `obfs4 server handshake timed out`, без
`session.accept.scanner_dropped` / `session.accept.capacity_dropped`.
Нет основания связывать каждую серверную ошибку с основным dial телефона:
есть независимые children и соединения обоих клиентов.

## Стенд и границы

- Poco / Android 16 с SIM и MacBook; Windows отключена и не используется.
  Те же собственные QA-профили, их identity проверены перед звонком.
- SDK release FFI `81436bd1`, сохранённые квалифицированные Android/Mac AOT,
  native/media/HVS hashes сверены перед установкой. При копировании Mac
  bundle сохранены framework symlinks; runtime-created log вынесен из bundle
  перед повторной проверкой подписи. Переподписи не было.
- Один изолированный QA-Core obfs4/TCP, P2P звонка запрещён на обоих клиентах.
  Путь **non-onion Delivery**, не private onion; исправление `PinnedRoute`
  этой серией по-прежнему не квалифицируется. Core из `ade3130a`: relevant
  runtime/session/crypto/CLI diff до SDK клиента пуст.
- Три network-only цикла: 28 с с выключенным Wi-Fi и 16 с после его включения.
  Во время каждого есть срезы фактической validated cellular/Wi-Fi сети.
  Отдельно один звонок, 50 с наблюдения после Wi-Fi off, затем 30 с после on.
- Capture только собственного QA TCP-порта, без promiscuous mode, snaplen
  192, независимый срок 10 минут, лимиты RAM/file/CPU; Core ограничен 30 мин.
  Ни capture, ни Core не дождались предельного срока — остановлены вручную.
  PCAP, socket inventory, PSK, адреса, ID и полные журналы только в приватном
  кеше. В этом отчёте нет содержимого коммуникаций.
- Первый запуск Android не передал флаг QA-профиля из-за неверного имени
  Flutter intent extra. Unlock вернул false; этот запуск **не засчитан**.
  Подтверждённый `dart_entrypoint_args` и полный перезапуск выбрали нужный
  профиль; известная identity и successful unlock проверены до серии.
- A/B и слышимость человеком не проверялись. Единичный успешный разговор
  не закрывает ни предыдущий неожиданный отбой, ни односторонний RX.

## Следующая проверка

Синхронно с повтором handover собирать TCP queue/INFO на телефоне **в течение
самого handshake**, включая его local port. Сопоставить с relay NIC по flow
при доказанном NAT mapping. Нужны bytes queued/notsent/unacked/retransmitted:
это разделит задержку до записи в сокет, kernel queue и потерю на пути.
Поздний socket inventory текущей серии снят после проблемного dial и эту
дыру не закрывает. Уже существующий TCP writer trace начинается после
obfs4 upgrade, поэтому он не свидетельствует о первом handshake flight.

Таймауты, аутентификация obfs4, anti-probing и изоляция медиаканалов не
ослаблялись. Уменьшение таймера или новая параллельная попытка без измерения
не объявляются исправлением причины.

## Очистка

Capture остановлен, PCAP скопирован со сверкой SHA; QA service/config/binary/
state/runtime/ports удалены. Production PID, binary/config hashes и NRestarts
сверены с fresh baseline и не менялись. QA APK восстановлен по SHA, основной
APK и прежний root QA-контейнер не менялись; исходные network/awake/P2P
настройки восстановлены, validated Wi-Fi проверен. QA приложения завершены,
свои ADB forward и Mac runtime удалены. Для точного Mac PID после SIGTERM
grace потребовался SIGKILL; выход подтверждён. Push/релиза нет.
