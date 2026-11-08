# NETCALL-01: проверка готовности не резервирует пустой TCP-канал

SDK `cca1204e` исправляет подтверждённую ошибку выбора ordered child channels.
Физическая квалификация и её ограничения приведены ниже. Сам NETCALL-01
остаётся открытым.

## Механизм и изменение

Ordered pool заранее открывает фиксированное число общих child connections.
Порядок завершения соединений может отличаться от порядка запуска. Раньше
проверка готовности оставляла ownership ещё не открытого physical slot даже
при результате `None`/not-ready. Два запроса до первого completion могли
закрепить разные пустые слоты: первый готовый child доставался более позднему
запросу, а первый продолжал ждать. Предыдущий фикс пустого eager prepare
не закрывал periodic publisher и фактический `selected_sender`.

Теперь ordered source/transit probes сохраняют новую reservation только при
успешном выборе ready channel. Failed probe освобождает только собственную
новую временную reservation. Ранее существовавшие владельцы сохраняются;
готовый чужой канал не отбирается. Общий код явных reservations, используемый
также QUIC, сохраняет прежнюю семантику. Изменён именно момент закрепления
нового владельца при ordered readiness probe.

Source demand сохраняется отдельно через lease текущей сессии. Первый
неудачный probe выставляет pending и будит runner; повторы не создают
бесконечные уведомления. Старый lease не меняет состояние преемника. При
готовности pending очищается, при недоступности остаётся. Сеть, wire,
аутентификация, FIFO/WRR, admission limits и число открываемых connections
не изменены. Source и neutral transit используют симметричный выбор.

## Компонентное доказательство

До фикса действительно выполнявшийся тест падал: периодический publisher,
затем отдельно фактический sender selection закрепляли пустой слот и меняли
получателя первого готового child. Тест использует управляемое завершение
кандидатов, без порога времени. Через настоящий session datagram path,
проверку proof и encrypted record codec проходит frame. Completion инъецируется
локально: это не полный тест исходящего TCP handshake или исполнения
периодического timer task.

Сравниваются контроль без раннего probe, eager prepare, повторный production
publisher и реальные sender probes без предварительного readiness API.
Отдельно проверены оба порядка source/transit, сохранность уже закреплённого
владельца, использование только свободного spare, capacity и stale lease.

Два промежуточных варианта отклонены собственными красными тестами:
без отдельного pending терялся source demand; без идемпотентности повторные
failed probes постоянно будили runner. Ошибка physical index в новом
transit test fixture исправлена как ошибка теста, не засчитана дефектом кода.

Финально **719 session passed / 8 ignored**, scoped Clippy и Android/aarch64
release FFI check прошли. Для Clippy сохранено прежнее исключение
`manual_async_fn` тестового helper. Остальные наборы предыдущего раунда
здесь повторно не заявляются.

## Физическая квалификация

Новые Android/Mac/Linux binaries собраны из чистого SDK;
проверены source/config hashes, exports, post-codesign SHA и отличие от
непосредственно предыдущих SDK artifacts. AOT/media/HV и seeds заморожены:
квалифицируется native SDK, не новая полная frontend-сборка.

Два relay-only звонка Poco → Mac через два изолированных QA Core, каждый
с Wi-Fi → Cellular → Wi-Fi и 60 с наблюдения каждого handover. Критерии
сохранены: PID/call ID, validated-сеть, последние пять native RX ages ≤1000 мс
и продвижение счётчика RX. **5/6 финальных окон passed.** Первое мобильное
окно failed: среди последних пяти samples были ages 1095 мс на Poco и
1081 мс на Mac. Продвижение RX не отменяет этот failure.

| Фаза | Максимальный RX age Poco / Mac после baseline/switch | Финальное окно |
|---|---:|---|
| Первый Wi-Fi baseline | 60 / 381 мс | passed |
| Первый → Cellular | 1095 / 1082 мс | failed |
| Первый → Wi-Fi | 173 / 357 мс | passed |
| Второй Wi-Fi baseline | 61 / 345 мс | passed |
| Второй → Cellular | 982 / 3284 мс | passed |
| Второй → Wi-Fi | 86 / 597 мс | passed |

Нет missing native stats в host-срезах; gaps не склеиваются через media epochs.
Независимый phone collector дал 544/544 успешных HTTP-наблюдения. Ambient/DTX,
а не непрерывная речь: слышимость человеком и субъективное качество не
квалифицированы. Серия не A/B; меньшие maxima одного звонка не объявляются
ускорением или устранением NETCALL-01.

## Оставшаяся подтверждённая пауза

Во втором переходе на Cellular native RX Mac не продвигался **3157,820 мс**.
Внутри интервала пять host-срезов показывают phone TX +20; четыре независимых
phone-local среза также дают +20 в одной media epoch. После первого observed
validated Cellular остаются **2420,523 мс** этого flat; ещё три validated
среза находятся строго внутри. Это не доказательство пригодности TCP-сессий.
Ширина границы совмещения часов — около 47 мс.

31 distinct phone-origin RTP cell находится строго внутри паузы и имеет
source relay-send witness. Ни для одной не наблюдается Core ingress или
target RTP receipt за захват. Только **одна** из этих cells имеет regular
record send-attempt: **две physical copies**, по одной через каждый Core.
Обе locally flushed, remote read не наблюдается. Остальные **30 distinct
cells** не имеют regular phone record-attempt witness. Это не утверждение
об отсутствии всех возможных transport paths.

Обе copies связаны с конкретными TCP sockets; binding пропусков для них нет.
Handshake start обоих наблюдался до команды переключения. Внутри flat есть
только по одному kernel sample: RTO 336/256 мс, queued/notsent 482/617 Б,
unacked и retransmitted — 0. Один срез не исключает stall, не показывает его
длительность и не доказывает дефект lifetime старого socket.

Три sparse source-pressure события строго внутри обеих границ совмещения
часов относятся к логическому source slot 0; aggregate drops = 20. Это
подтверждает исполнение missing-sender ветки, но не атрибутирует её всем
31 cells поштучно. Логический slot не равен physical child index.

Таким образом, ошибочная reservation при failed readiness probe исправлена
и проверена компонентно, но **остаток source readiness и отдельная ветка
local flush → no remote read сохраняются**. Следующий участок — lifetime и
готовность уже закреплённого child при handover: отличить ожидание нового
handshake от отсутствия свободного готового child и перехода старого owner.
Снятый механизм не объявляется доказанной причиной прежних пауз.

## Полнота захвата и уборка

Record stages + bindings: Poco 64129, Mac 82134, Core 70229/92827 — ниже
прежнего cap 100000; limit markers отсутствуют. Core journals 145463/193435
строк, ниже tail limit 200000. Отдельные NodeLogger files не содержат
FIFO-drop rows. Это контроль сохранности конкретного захвата, не гарантия
нулевых потерь транспорта: в серии есть истекшие/отказавшие physical copies
вне разобранного эпизода. Raw IDs, addresses, hashes клеток и socket metadata
остаются private, anonymous export не расширялся.

После звонков сверены 1056 SDK source/config hashes, clean SDK HEAD,
42 исходных harness scripts и identity probes. Первый сбор журнала одного
Core превысил 20-секундный таймаут уже после остановки его процессов;
неуспешный результат сохранён. Повторный bounded collection успешен. Это
ошибка/восстановление сбора стенда, не отказ приложения и не потеря журнала.
Архивы и каждый member сверены по SHA до удаления своих remote данных.

Оба QA Core, observers и клиентские процессы остановлены. Собственные unit,
state/runtime/config/binary/stage paths удалены, порты освобождены. APK обоих
phone-приложений, исходный QA root container, user-0 microphone permission,
P2P, debug properties, исходная validated-сеть и stay-on восстановлены.
Production PID/restarts/binary/config и удаление своих ресурсов проверены
повторно независимо. Mac runtime удалён, его собственный log перенесён
в private evidence, подпись app проверена. Push/релиза нет.
