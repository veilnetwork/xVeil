# NETCALL-01: связь record writer с конкретным TCP socket

SDK `b214219a` добавляет недостающую привязку между per-cell record traces
и TCP kernel observations. Доставка и восстановление TCP этим не изменяются.

## Изменение и проверка

Раньше handshake и последующий TCP writer получали независимые connection
numbers; `child_local` record plane не был связан ни с одним из них. Совпадение
чисел/времени нельзя было считать привязкой конкретного socket.

Теперь obfs4 writer сохраняет observation ID своего handshake, если tracing
был включён при handshake; иначе остаётся прежняя ленивая выдача ID. Record writer
передаёт свой локальный child ID через scoped task-local context. При наблюдаемой попытке
записи TCP observer однократно выводит `tcp_ordered_binding` с connection ID,
child ID и существующей port-pair metadata. Номер не уходит в протокол, не
даёт полномочий, не определяет маршрут/приоритет. Обычные записи вне record
writer не наследуют этот context.

Привязка требует обоих прежних default-off operator gates: RT trace и ordered
record trace. Stages и bindings делят прежний общий cap 100000 observations;
повторное включение RT trace может повторно опубликовать binding. В строке нет
payload, IP-адреса, роли приложения или media classification. Это не TCP ACK
или доказательство доставки. Raw metadata
остаётся private; anonymous export не расширялся.

Регрессионный тест до изменения выполнялся и падал: 0 bindings вместо двух.
После изменения две независимые реальные obfs4/TCP connections передали по
два record payload с правильной привязкой к своим handshake IDs и socket
ports. Обычная третья TCP-запись не создаёт record binding. Проверены default,
оба отдельных disabled gates, оба enabled и invalid values — в изолированных
процессах, каждый обязан выполнить ровно один passing test. Plaintext canaries
не попадают в captured logs. Это transport observability, не тест выдачи OVL1
полномочий.

Финально **179 transport passed**, **712 session passed / 8 ignored**, scoped
Clippy и Android/aarch64 release FFI check — passed. **19 DiagnosticJournal
tests** и реальный AOT export gate с diagnostic flag on/off — passed с новыми
raw binding canaries.

## Физическая проверка

Новые Android/Mac/Linux binaries собраны из чистого SDK с source/config hashes,
проверенными exports, post-codesign SHA и маркером новой привязки. AOT/media/HV
и seeds заморожены; квалифицируется native SDK, не новый полный frontend.

Два relay-only звонка Poco → Mac через два изолированных QA Core; каждый
с Wi-Fi → Cellular → Wi-Fi и 60 с наблюдения каждого handover. Прежние
критерии PID/call ID, validated-сети, последних пяти native RX ages ≤1000 мс
и продвижения RX сохранены. **6/6 финальных окон passed; NETCALL-01 открыт.**

| Фаза | Максимальный RX age Poco / Mac после baseline/switch |
|---|---:|
| Первый Wi-Fi baseline | 62 / 348 мс |
| Первый → Cellular | 1530 / 3203 мс |
| Первый → Wi-Fi | 1015 / 998 мс |
| Второй Wi-Fi baseline | 61 / 378 мс |
| Второй → Cellular | 1130 / 2792 мс |
| Второй → Wi-Fi | 1067 / 998 мс |

Нет missing native stats в host-срезах; gaps не склеиваются через разные
media epochs. Источник microphone/ambient/DTX: непрерывная речь и слышимость
человеком не квалифицируются. Серия не A/B, диагностическая правка не
объявляется ускорением или устранением прежних 10–11-секундных пауз.

## Что меняет следующий шаг

В первом Cellular-окне RX Mac стоял **3166 мс**, native TX телефона +22;
пять независимых phone-срезов внутри дали +30 TX. Для всех **32 разных
phone-origin RTP cells** внутри этого flat нет regular record-send witness,
Core ingress или target receipt. Два source-pressure события строго внутри
по обоим phone clocks указывают на `local_slot=0`, aggregate drops=16.
Это наблюдение ветки отсутствия source sender, не индивидуальная атрибуция
всех 32 cells.

Во втором flat **2620 мс**: peer TX +16, четыре phone-среза дали +21 TX.
Из 27 разных source cells только **3 имеют 4 physical record attempts**;
у остальных 24 таких attempts не наблюдается. Три physical copies достоверно
связаны с двумя TCP sockets; для ещё одной binding не наблюдается, причина
не установлена. Две target RTP receipts случились позднее flat, внутри него
строгих receipts нет. Три aggregate source-pressure события внутри, drops=19.

После первого наблюдения Android validated Cellular внутри этих flat остаются
**1505 / 1055 мс** соответственно. Первый интервал содержит один дополнительный
validated Cellular-срез; во втором дополнительных срезов строго внутри нет.
Готовность ОС не объявляется готовностью TCP, и все 3,2 с не приписываются
ожиданию уже работающей сети.

У двух сопоставленных TCP sockets есть handshake start/complete и по одному
kernel sample строго внутри второго flat: RTO 336/296 мс, unacked=1,
retransmitted counter=0. По одной точке нельзя исключить потери или приписать
этим sockets всю паузу. Local flush по-прежнему не является NIC egress,
TCP ACK или доказательством доставки.

**Следующий приоритет — source readiness/назначение уже готовых ordered
children**, включая оставшийся периодический publisher. Здесь преимущественно
нет regular record-send witness и отдельно подтверждена ветка отсутствия
source sender. Ненаблюдаемая regular-ветка не доказывает отсутствие передачи
через любой другой путь; поштучной атрибуции всем cells пока нет. Прежние
подтверждённые эпизоды local flush → no remote read остаются отдельной открытой веткой.

## Покрытие и завершение

Наблюдаемая привязка: 18 разных children на Poco, 6 на Mac, 33/27 на Core.
Actual records/queue outcomes/bindings обоих Core проверены до handover.
Reader-only channel без writer observation не получает этой привязки; полное
покрытие всех возможных record planes не заявляется. В частности, одна из
четырёх физических попыток рассматриваемого flat остаётся без binding.

Shared record+binding rows — ниже 100000 на всех четырёх процессах; точных
trace-limit markers нет. Core journals 137674/156909 строк, ниже tail cap
200000. Отдельные NodeLogger files проверены: FIFO wait rows **0/0**.

1056 source/config files, все 42 frozen harness files и identity probes
сверены после звонков. Архивы обоих Core и каждый member проверены по SHA.
Свои collectors/apps/Core/observers остановлены и удалены с их временными
server units/config/state/stages, порты освобождены. Старый QA APK, основной
APK и старый QA root container сверены по SHA; сеть, microphone permission,
operator properties, stay-on и P2P choices восстановлены. Независимые проверки
подтвердили прежние production PID/restarts/executable/config.

Push/релиза нет. Адреса, ID, порты и сырые записи в этот документ не включаются;
они остаются только в private evidence и не входят в anonymous export.
