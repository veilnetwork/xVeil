# NETCALL-01: физическая трасса до ordered record и готовность прогретого соединения

**Паузы звука остаются активным дефектом.** На immutable SDK `5f194c38`
выполнены две отдельные серии Poco ↔ Mac с двумя независимыми QA Core.
Первая дала 6/6 финальных окон, вторая — 5/6. Внутри второй наблюдалась
пауза приёма Mac **2613 мс**, хотя телефон продолжал создавать аудио.
Позднее компонентным тестом найдено и исправлено отдельное ожидание
публикации готовности прогретого ordered child. Его влияние на эту паузу
физически ещё не квалифицировано.

## Стенд и критерии

В каждой серии — два отдельных звонка, Wi-Fi → Cellular → Wi-Fi в каждом,
всего четыре переключения и шесть контрольных окон. P2P запрещён, media
идёт через изолированные Core. Критерии зафиксированы до запуска:
неизменный call ID/PID, растущий RX counter и последние пять age-срезов
не старше 1000 мс. Внутренние паузы учитываются и при успешном конце окна.
Это автоматическая квалификация native packet progress; непрерывная речь
и слышимость человеком не проверялись, DTX не выключался.

Android FFI, Mac FFI и Linux Core собраны из одной неизменной SDK-ревизии.
Проверены исходники, provenance выбранных библиотек, post-codesign SHA Mac,
208 C exports, подпись и alignment APK. Dart/AOT, media engine, hidden-volume
и seeds заморожены; readonly observer имеет отдельно проверенное происхождение.
Это изоляция native-изменений, не квалификация новой полной frontend-сборки.

## Две серии и границы покрытия

| Серия | Финальные окна | Наибольший RX age Poco / Mac | Ограничение |
|---|---:|---:|---|
| Первый захват | 6/6 | 1047 / 1726 мс | Core INFO record target отфильтрован logger |
| Повтор с исправленным logger | 5/6 | 1473 / 2782 мс | Первое Cellular-окно не прошло критерий свежести |

Первый захват сохраняется как частичный: environment gate был включён,
но `env_logger` standalone CLI по умолчанию оставлял `warn`. Node config
`log_level` управляет другим logger. Его отсутствующие Core read/write
события **не являются доказательством потери records**. Перед второй серией
исправлен RUST_LOG target и на каждом Core проверены реальные record events.

Во второй серии Core собрали 7075 и 6686 `read_complete`; число `decode_input`
равно соответствующему числу чтений. Предел trace observations не достигнут,
journal tail не обрезан, `independent_fifo_wait` не наблюдался. Это не означает,
что отсутствующая запись всегда доказывает wire loss.

## Что произошло внутри паузы 2,6 с

Пауза определена по неизменному native RX counter Mac, а не по периодичности
записи файла или числу сетевых соединений. Host-срезы дают **2612,6 мс**
неподвижного RX и прирост phone native TX на 18 внутри этого интервала.
Независимый локальный collector телефона даёт четыре среза строго внутри
тех же консервативных clock bounds: native TX вырос на **25**. Разные приросты
относятся к разным внутренним наборам срезов; они не суммируются.

С packet-level привязкой внутри паузы найдены **29** конкретных source
payload-RTP cells. Ни одна не наблюдается на Core ingress или в Mac receipt:

- У **27** нет source transport-selection witness. Из этого не следует,
  что все они отвергнуты одной конкретной ветвью `child_unavailable`.
- У двух есть selection и send-attempt. Их четыре физические transport
  copies имеют локальные admission/first-write/flush, но Core `read_complete`
  для этих records не наблюдается. Это локальный flush, не NIC egress,
  remote TCP ACK или доказательство потери в сети.

Два успешно записанных source диапазона лежат в начале паузы, вскоре после
смены сети. Остальные наблюдения давления источника и открытия сессий
согласуются с прогревом новых соединений, но не доказывают единственную
причину всех 2613 мс. Следующий участок — готовность конкретного source child
после открытия canonical session и судьба уже flushed copies до Core read.

## Проверенные локальные границы

В полном повторе 2388 phone-origin cells имеют **равные точные наборы**
Core ingress, target selection и authenticated Mac receipt. Всего источник
создал 2441 cell: одна без source relay-send witness, ещё у 52 нет полного
authenticated receipt. Для встречного направления: 4201 source cell,
4201 Core ingress, 4197 target selections и 4165 строгих RTP receipts.
Отсутствие receipt не переименовано в доказанный drop.

На сопоставленных observations phone send-attempt → first-write занимает
не более 4,008 мс; Core read → session-auth — 1,465 мс, Core send-attempt →
first-write — 6,278 мс; Mac read → auth — 0,986 мс, phone read → auth —
3,445 мс. Эти верхние границы относятся только к наблюдаемым совпадениям,
а не к пропавшим cells. Межхостовые времена не считаются по сырым часам.
Исправленная IPC-выборка также подтверждена физически: в первом захвате
все 7298 phone и 6366 Mac receipts получили daemon/SDK ages; прежнего
жёсткого ограничения раз в 50 больше нет.

## Отдельный исправленный механизм

SessionRunner немедленно просыпался по запросу local datagram readiness,
но `ParallelChannels::prepare` обрабатывал только QUIC. Ordered pool уже
мог иметь аутентифицированный свободный child; назначение и публикация
его готовности ждали следующего **250-мс** worker tick.

SDK `e136c71f`: ordered prepare теперь вызывает прежний publisher под тем же pool lock.
Сохраняются ownership, проверка live parent, квота, FIFO, wire и независимый
предварительный прогрев соединений. Новых соединений этот вызов не открывает.

Regression проходит реальный exporter-bound proof/ACK, production registry
и production `ParallelChannels::prepare`. До фикса он падает на `Warming`
вместо `Ready` при остановленных виртуальных часах. После — готовность
публикуется без тика, второй источник не присваивает тот же child, реальный
AppRtData frame доставляется и расшифровывается, retired parent не может
снова объявить готовность. Ранние compile errors самого теста/фикса не
засчитываются как regression-red или успешная проверка.

Физические захваты выше выполнены **до этой правки**. Устранение лишнего
ожидания readiness доказано компонентно; сокращение аудиопаузы не заявляется.

Финальная проверка `e136c71f`: **710 session passed / 8 ignored**, scoped
Clippy lib+tests с `-D warnings` и прежним исключением `manual_async_fn`
для тестового helper, Android/aarch64 release FFI check с реальными флагами
`allow-empty-seeds,node-embedded,packet-tunnel`, rustfmt и diff-check прошли.
Повтор целевого теста не прибавляется к числу всей suite. Android check —
компиляция, не новый APK и не физическая квалификация этой правки.

## Гигиена и приватность

Сырые hashes, CID, child/peer IDs, адреса, RTP metadata и clock probes
остались в private capture, не в анонимном отчёте. Оба собственных стенда
остановлены. APK основного/QA-приложений и старый QA-контейнер сверены SHA,
properties, permissions, сеть, stay-on и P2P восстановлены. Mac потребовал
SIGKILL после grace; выход процесса проверен. Убраны observers/collectors,
их device directories/keys, runtime, forwards и порты. QA Core units,
конфиги, binaries и state удалены; production PID/restarts/binary/config
проверены независимо и не менялись.

При выгрузке второго захвата scp превысил deadline. Приложения и Core
остановлены отдельно; сбор evidence продолжен bounded chunks с проверкой
remote prefix и полного archive/member SHA, затем выполнена независимая
проверка cleanup. Этот сбой выгрузки не скрывает failed Cellular-окно.

Rust builds проверяли identity внешнего filesystem и свободное место;
preflight-отказ из-за места не считался ошибкой SDK. Для продолжения удалены
только около 690 МиБ старых rebuildable IPC/transport incremental caches;
готовые artifacts, rollback и исходники сохранены. Push/релиза и sibling
mailbox нет.
