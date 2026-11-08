# NETCALL-01: фактические queue outcomes и повтор Poco ↔ Mac

**Паузы остаются подтверждёнными.** SDK `ae352464` добавляет операторское
наблюдение исхода outbound enqueue, сохраняя поведение очереди. На двух QA
Core новая диагностика физически проверена; клиенты оставлены на immutable
`e136c71f`. Два звонка, четыре переключения: **5/6 финальных окон passed**.
Внутри окон подтверждены паузы native RX до **13,83 с**, включая последующее
пересоздание медиадвижков. Устранение пауз этой диагностической правкой
не заявляется.

## Что добавлено и проверено компонентно

`SessionTxRegistry::send_to_arc_with_carrier` теперь наблюдает фактический
результат своего обычного `try_send` / `try_send_on_carrier`:
`accepted`, `missing`, `closed`, `full`. Результат не заменяется оценкой
`has_session`, queue depth или отсутствием поздней transport-selection записи.

Новая строка — `delivery.opaque_trace stage=queue_admission outcome=...`.
Она связывает нормализованный SHA целого opaque payload с ключом lookup
адресата. У registry нет local node ID: остаётся `node=-`, а контекст узла
задаётся процессом. Lookup key может быть identity alias, поэтому его нельзя
молча приравнивать к физическому транспортному peer. Привязка известных
адресов в захвате проверяет отсутствие коллизий восьмизначных prefixes.

`accepted` означает только локальный enqueue, не durable ACK, готовность
транспорта или доставку. Timestamp записывается после получения результата;
другая задача уже могла выбрать кадр до вывода строки. Отрицательную разницу
с поздно записанным queue timestamp нельзя читать как отрицательное ожидание.

Используется прежний точный default-off operator gate и прежний общий лимит
524288 observations. Разбирается только ограниченный Forward/RecursiveRelay
wrapper: body ≤8192 байт, без интерпретации приложения/медиа и без plaintext
в выводе. В выключенном режиме разбор/хеширование frame не выполняются.
Результаты, accounting, ownership, FIFO, приоритеты, квоты и wire не изменены.

Regression на настоящем `SessionTxRegistry` с capacity=1:

- До правки: при enabled gate 0 observations вместо пяти, несмотря на
  правильные реальные queue results. Первоначальная compile error теста
  не считалась regression-red.
- После: missing → accepted → full → accepted → closed. Проверены обычный
  и carrier-пути, неизменные bytes/priority, отсутствие прямой отправки
  из enqueue, отказ от observation для malformed frame, отсутствие plaintext.
- Default, `0`, `1`, invalid `true` проверяются в изолированных процессах;
  каждый subprocess обязан реально выполнить ровно один passing test.

Финально **711 session passed / 8 ignored**, scoped Clippy lib+tests с прежним
исключением `manual_async_fn`, Android/aarch64 release FFI check с реальными
flags приложения, rustfmt/diff-check — passed. **19 DiagnosticJournal tests**
и AOT export gate (diagnostic flag on/off) прошли с новыми canaries.
Raw queue strings/outcomes не добавлялись в anonymous allowlist.

## Физический повтор

Обновлены только два изолированных QA Core. Их executable SHA и новый marker
проверены до запуска, фактические record/queue events — после первоначального
native audio baseline и до handover. Клиенты — ровно прежние проверенные
APK/Mac FFI, с теми же AOT/media/HV/seeds. Source/config snapshot Core и
measurement harness сверены после звонков; transport/identity/instance
обоих клиентов до и после не изменились.

Сохранены критерии прошлой серии: call ID/PID, relay-only, валидированная
целевая сеть, последние пять RX ages ≤1000 мс и продвижение RX на обоих
концах. Каждая смена сети наблюдается 60 с. Источник — микрофоны/ambient/DTX;
не квалифицируются непрерывная речь и человеческая слышимость. Это не A/B
и не причинное доказательство ускорения/регрессии; включённая operator trace
также является частью условий измерения.

| Звонок / фаза | Финальное окно | Максимальный RX age Poco / Mac |
|---|---|---:|
| Первый baseline Wi-Fi | passed | 295 / 362 мс |
| Первый Wi-Fi → Cellular | **failed** | **7065 / 7228 мс** |
| Первый Cellular → Wi-Fi | passed | 573 / 1330 мс |
| Второй baseline Wi-Fi | passed | 62 / 354 мс |
| Второй Wi-Fi → Cellular | passed | **11183 / 13955 мс** |
| Второй Cellular → Wi-Fi | passed | 561 / 1056 мс |

У первого failed-окна не было ни свежести, ни продвижения последних RX
срезов. Его не выкинули после успешного возврата Wi-Fi или второго звонка.
Успешный конец второго Cellular-окна не отменяет длинную паузу внутри.

## Покадровые результаты

**Первый звонок, поздняя Cellular-пауза.** Телефонный RX стоял **6584 мс**,
Mac RX — **7129 мс**, при продолжающемся native TX обоих концов. Независимый
phone collector подтвердил неподвижный RX и создание исходящего аудио.

Из 33 конкретных Mac-origin RTP cells внутри phone gap все дошли до Core.
Для 31 наблюдаются `accepted` к телефону на Core B и target selection;
30 records локально flushed, но phone `read_complete` для них не наблюдается.
Ещё один record завершился partial expiry/write error. Для двух cells у B
наблюдается `missing`; у A lookup телефона возвращал missing для всех 33,
после чего кадры пересылались B. Это не отсутствие всех queue attempts:
31 успешный enqueue теперь доказан непосредственно.

Во встречной паузе 34 phone-origin source cells не наблюдаются на Core.
У 30 есть source record-send/flush к B, без Core read; у четырёх такого
record-attempt witness нет. **Flush не является NIC egress, TCP ACK или
доказательством потери в провайдере.**

**Второй звонок.** RX Mac стоял **13832 мс**, native TX телефона +89;
20 локальных phone-срезов строго внутри интервала дали +92 TX. Разные
приросты относятся к разным внутренним наборам срезов и не суммируются.
95 source cells внутри интервала не наблюдаются на Core ingress. У одной
есть две physical copies, локально flushed к разным Core без remote read.
У остальных нет regular record-send-attempt witness. Семь aggregate source
pressure наблюдений соответствуют отсутствию готового sender, но точная
ветвь каждой отдельной ненаблюдаемой попытки этим не доказана.

RX телефона во втором звонке стоял **10665 мс**. 155 Mac-origin cells внутри
этого интервала дошли до Core; у 78 есть хотя бы один accepted enqueue
адресату, у 77 — только missing. Для 52 accepted cells target selection
не наблюдается; у остальных 26 есть selection. Два строгих RTP receipts
найдены позже, ни одного — внутри самого flat-интервала. Не все selected
ветки имеют новую record-link проводку (ранний Carrier путь остаётся
отдельной границей покрытия).

За весь захват queue trace дала 23547 accepted и 1250 missing attempts,
без наблюдаемых full/closed. Это **попытки**, не число логических потерянных
клеток: один payload может иметь fallback/повторные попытки на разных Core.

## Media repair и корректность анализа

Во втором handover у Mac два среза, у телефона три среза содержали
`running=false, media_repairing=true` без native audio counters. После этого
изменились media epochs и накопительные counters. Это наблюдаемый ремонт
после тишины, не доказанный crash или отдельная ошибка медиадвижка.
В текущем коде silent-relay recovery намеренно может пересобирать локальную
media session; отменять этот механизм по одному совпадению таймингов оснований нет.

Первый offline summary предполагал постоянное наличие `audio_rx_pkts`
и остановился с KeyError; это ошибка анализатора, не приложения. Отдельная
исправленная версия сохраняет неизвестные срезы, разрывает группы на repair
и смене `media_epoch`, не подставляет нули и не склеивает counters разных
движков. Synthetic guard проверяет одинаковые counters по обе стороны
неизвестного/нового epoch. Измеренные выше flat-интервалы не проходят через
пересоздание, а итоговые pass/fail взяты из неизменённого driver-критерия.

## Следующий участок и гигиена

Queue ambiguity для захваченных attempts снята. Дальше требуется разбирать
готовность/время жизни конкретного TCP child и границу локальный flush →
remote read, включая случаи отсутствия sender на телефоне. Рост пауз
между сериями не приписан новой диагностике или одному прежнему фиксу.
Из прежнего захвата также сохранён отдельный доказанный FIFO-wait эпизод;
его нельзя автоматически считать причиной всех новых пауз.

Core journals содержат 110395 / 159388 строк, tail limit и trace caps не
достигнуты; Core PID и restart counts за измерение не менялись. Архивы и
все members проверены SHA. Все свои app/observer/collector процессы, ports,
runtime/device directories/keys убраны; исходные APK/старый QA-контейнер,
properties/permissions/network/stay-on/P2P восстановлены. Production
PID/restarts/binary/config независимо совпали с первоначальным baseline;
QA units/config/binary/state/stages удалены. Сырые адреса/IDs/hashes/RTP
metadata остались только в private capture. Push/релиза и sibling mailbox нет.
