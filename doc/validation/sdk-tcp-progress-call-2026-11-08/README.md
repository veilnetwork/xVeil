# NETCALL-01: настоящий SDK и минимальный host polling

**NETCALL-01 остаётся открытым.** Один relay-аудиозвонок Poco↔Mac пережил
Wi-Fi→Cellular→Wi-Fi без повторного вызова. На мобильном участке повторились
секундные остановки native RX counter даже без опроса телефона с Mac.
Это не квалификация слышимости речи и не доказательство виновности провайдера.

## Сборки и границы

Клиентские FFI пересобраны из SDK `c8f4929b`, добавляющего
[TCP byte progress](../sdk-tcp-progress-2026-11-08/README.md).
Проверены snapshot 1057 source inputs, новые маркеры, architecture,
неизменные 208 C exports, Android signer/zipalign и post-codesign Mac SHA.
В QA APK заменена только FFI: AOT, media engine, hidden-volume и seeds прежние.
На Mac проверен фактически загруженный dylib, на Poco — установленный APK.
Два изолированных Core используют прежний побайтно проверенный `e974cebe`:
их runtime не пересобирался и не обозначен новой версией.

P2P запрещён для этой проверки; оба Core доступны обоим клиентам.
Production service, binary и config не менялись. Это не шестизвенная линия.
Operator tracing включена, в том числе source cells/opaque records;
накладные расходы такого режима не исключены.

На телефоне два ограниченных локальных collector: native logcat и loopback
`call_state`. Во время трёх measured intervals host не вызывает phone API,
adb shell или dumpsys. Mac опрашивает только своё приложение. Смена радио,
clock probes и network checks находятся между intervals. Host ADB daemon,
USB-кабель и питание остаются: это **не ADB-off** и не причинный A/B.
Cellular VALIDATED проверена перед/после двухминутного интервала, не непрерывно.

## Наблюдения

| Интервал | Длительность | Max native RX age, Poco | Max native RX age, Mac |
|---|---:|---:|---:|
| Wi-Fi до | 25,4 с | 124 мс | 350 мс |
| Cellular | 120,4 с | 1391 мс | 1314 мс |
| Возврат Wi-Fi, включая восстановление | 35,5 с | 394 мс | 794 мс |

В конце каждого участка native counters продвигаются, media работает,
transport остаётся relay. Process телефона не менялся. Локальный collector:
361/361 успешных HTTP observations, max request 370 мс, max start gap 950 мс.
Поэтому отсутствие секундного plateau в телефонных samples не исключает пауз.
Неизвестные/сменившие epoch native counters не склеиваются в один plateau.

На Mac — 10 plateau с нижней границей 1014–1031 мс. Внутри них Poco
сформировал **56 distinct audio cells**; все 56 сопоставлены с поздним
аутентифицированным RTP на Mac по epoch/seq и полям RTP. Это не только DTX
или тишина микрофона. Данные не доказывают, что все остальные клетки серии
получены: полного packet-completeness verdict здесь нет.

## Что добавили TCP counters и record stages

Private trace содержит 845 kernel snapshots. Readback socket binding:
MSS 1188, send buffer 131072 Б, LOWAT 4096 — штатный Linux профиль SDK.
LOWAT является readiness threshold, а не жёстким пределом текущего not-sent.

Для 56 клеток найдены 112 физических попыток через два Core:

* RTP sealed→первый write: 1,019–5,357 мс по одним часам Poco.
* У 111 копий есть flush, first write→flush ≤0,612 мс; у одной свидетель
  flush отсутствует. Локальный flush не означает доставку.
* Для 108 копий есть matching Core read; read→authenticated frame ≤0,707 мс
  по одним часам Core. Четыре отсутствующих read не объявлены доставленными.
* Для 64 копий Core read определённо позже конца соответствующего Mac plateau.
  У остальных clock bounds/отсутствие read не позволяют такой вывод.

Межхостовые границы проверены отдельно: phone clock intersection 34,8 мс;
Core probes через новое SSH-соединение сначала давали слишком широкие
819–1451 мс. Дополнительные read-only probes через уже установленное SSH
сузили intersection до 53,7/113,1 мс. Observed remote wall-minus-monotonic
между pre/post отличается ≤0,01 мс; мгновенные промежуточные clock changes
этим не исключены. Same-host elapsed не вычисляются вычитанием противоположных
концов clock intervals. Сырые clocks и operational identifiers остаются private.

В одном matching TCP flow bracket, охватывающем plateau, за 1,29 с
acked bytes не продвинулись, sent выросли на 3931 Б, retransmitted — на 542 Б.
На альтернативе ACK продвигался; одним таким наблюдением нельзя объяснить
оба пути. В других brackets ACK успевает продвинуться; 1-Hz kernel log
не локализует каждую короткую потерю. Retransmission — не доказательство
конкретного места потери. Паркующиеся старые sockets дают большие RTO даже
при здоровом Wi-Fi: их общие максимумы **не** названы задержкой аудио.

В этой выборке задержка подтверждена после быстрой локальной записи и до
Core read для части копий. Следующий разбор — эти конкретные flows и NIC
capture Core: отделить отсутствие TCP bytes/дыру сборки от позднего чтения.
Увеличение окна аудио, изменение transport defaults или новая write-size
эвристика из этих данных не следуют. Причинное ускорение не заявляется.

## Восстановление

Call/harness inputs сверены до/после. Phone collectors завершены, logs скопированы
с проверкой SHA, directory/API-header удалены. P2P choices, permission,
debug properties, Wi-Fi/data/stay-on восстановлены. Main/QA APK и неизвестный
QA root container совпали с baseline. QA приложения остановлены; Mac пришлось
завершить SIGKILL после истечения grace, затем отсутствие процесса проверено.
Own ports/runtime удалены, Mac подпись проверена.

Оба Core, observers и capture остановлены; evidence скопировано с проверкой
archive/file hashes. Own units/state/config/binary/stage удалены. Production
PID/restarts/binary/config независимо сверены после очистки обоих серверов.
Raw observations остаются private. Коммит без подписи, push/релиза нет.
