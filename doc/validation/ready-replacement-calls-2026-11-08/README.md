# NETCALL-01: повторный запрос после отказа готового ordered child

SDK `e974cebe` закрывает оставшийся край предыдущего readiness-фикса.
После успешной публикации child статус источника — `Ready`, pending уже
очищен. Если writer/receiver отказывал до следующего periodic publication,
фактический выбор sender возвращал `None`, но `request_pending` видел прежний
`Ready` и не сохранял запрос замены. Поздний готовый spare мог остаться
неиспользованным при следующей публикации без нового source request.

Теперь неудачный source selection сначала инвалидирует собственные stale
readiness/framing, затем идемпотентно сохраняет pending. Выбор и инвалидирование
выполняются под одним pool lock: worker не может опубликовать новую готовность
между проверкой и сбросом старой. Оба изменения статуса по-прежнему проверяют
lease owner, старый runner не меняет successor. Успешный selection, neutral
transit, ownership, limits, wire и transport authentication не изменяются.

## Компонентная проверка

Новый тест действительно выполнялся и падал на прежнем SDK: после failed
selection оставался `Ready` вместо `Warming`. Первый запуск с ошибкой borrow
в тестовом fixture не засчитан как regression red; значимый красный результат
получен после исправления fixture без изменения product-кода.

На каждом из четырёх ordered local source priorities тест публикует первый
аутентифицированный child, делает его sender broken и выполняет ровно одну
неудачную попытку выбора. Затем без нового source request и без продвижения
виртуального времени публикует готовый spare в другом physical slot. Статус
снова `Ready`, pending очищен; через выбранную замену проходит настоящий
зашифрованный session datagram и восстанавливается исходный frame.

Worker остановлен, completions и сбой инъецированы локально. Это проверка
production selection/publication и encrypted codec; не полный TCP-handshake,
не физическая потеря сети и не доказательство причины пользовательской паузы.

Финально **720 session passed / 8 ignored**, scoped Clippy и Android/aarch64
release FFI check прошли. Сохранено прежнее Clippy-исключение
`manual_async_fn` тестового helper. Повторно не заявляются transport/journal
наборы предыдущих раундов. Новых diagnostic fields или правил экспорта нет.

## Физическая проверка

Новые Android/Mac/Linux binaries собраны из чистого SDK с проверкой 1056
source/config hashes, exports, архитектуры, post-codesign SHA и отличия от
непосредственно предыдущих SDK artifacts. AOT/media/HV и seeds заморожены:
это квалификация native SDK, не нового полного frontend. Release Core build
имеет прежнее предупреждение linker об ignored deprecated optimization setting;
scoped Clippy прошёл без новых исключений.

Два relay-only звонка Poco → Mac через два изолированных Core, каждый
с Wi-Fi → Cellular → Wi-Fi и 60 с наблюдения handover. Сохранены критерии
PID/call ID, validated-сети, последних пяти RX ages ≤1000 мс и продвижения RX.
**5/6 финальных окон passed.** Первое мобильное окно failed по прежнему
порогу; продвижение RX не превращает его в passed.

| Фаза | Максимальный RX age Poco / Mac после baseline/switch | Финальное окно |
|---|---:|---|
| Первый Wi-Fi baseline | 70 / 332 мс | passed |
| Первый → Cellular | 1202 / 1035 мс | failed |
| Первый → Wi-Fi | 631 / 576 мс | passed |
| Второй Wi-Fi baseline | 41 / 390 мс | passed |
| Второй → Cellular | 1153 / 1114 мс | passed |
| Второй → Wi-Fi | 271 / 367 мс | passed |

617/617 независимых phone HTTP-срезов успешны. Нет missing native counters
в host-срезах, media epochs не склеиваются. Ambient/DTX: непрерывная речь и
слышимость человеком не квалифицированы. В этой серии нет flat ≥1,5 с;
прежние 3158 мс не воспроизвелись. Это не A/B и не доказательство, что именно
новая правка устранила прежнюю паузу. **NETCALL-01 остаётся открытым.**

## Короткие паузы — дополнительная атрибуция

Отдельный analyzer с порогом 1,0 с, не подменяющий прежний analyzer 1,5 с,
выделил пять RX flats **1038–1078 мс**. Четыре — после перехода на Cellular;
один — ещё на Cellular до команды возврата Wi-Fi. Поэтому последний не
попадает в after-switch maxima строки Wi-Fi таблицы выше.

Внутри каждого flat сформированы 12–18 distinct source RTP cells, всего
**77 различных cells**, с полным совпадением encrypted-cell hash и RTP
witnesses. Все они в итоге приняты, но уже после соответствующего flat
по observed clock bounds (ширина около 42–44 мс). Это не просто тишина
источника или отсутствие двух host-срезов для вычисления TX delta.
Приём RTP не доказывает слышимость человеком.

Для наблюдаемых stage-пар этих конкретных cells:

- source sealed → regular record attempt: максимум **5,692 мс**;
- record attempt → first write: максимум **1,583 мс**, → flushed **1,824 мс**;
- на одном Core ingress → target selection: максимум **0,644 мс**;
- earliest matching physical read получателя → RTP received: максимум
  **8,369 мс**. Используется первый read среди копий, а не более поздний
  read дубликата: последний даёт бессмысленные отрицательные интервалы.

Следовательно, секундные паузы в этих пяти эпизодах не объясняются долгим
seal/IPC enqueue, Core dispatch/queue selection или обработкой RTP после
первого read. Остаток — между локальной записью record и чтением на другом
конце. Local flush не равен NIC egress, TCP ACK или доставке; конкретный
хоп, транспортный механизм, ядро и сеть пока не атрибутированы. Следующий
шаг — сопоставить сохранённые socket bindings и NIC capture, не менять
таймауты или fairness ради прохождения финального окна.

В отдельных Core-B node logs есть семь `independent_fifo_wait` observations.
Это ожидание очереди, **не потеря NodeLogger logs**. Их нельзя автоматически
приписать разобранным cells: измеренная очередь на пути этих cells короткая.
В одном эпизоде из 17 source cells на Core A видны только три copies, на B
все 17; конечный приём всех cells не доказывает сохранность каждой копии.

## Происхождение данных и уборка

Record stages + bindings: Poco 64132, Mac 76869, Core 63679/88828 — ниже
cap 100000; limit markers отсутствуют. Core journals 133061/185972 строк —
ниже tail limit 200000. Эти проверки не объявляются гарантией нулевых потерь
всего транспорта. Raw IDs, addresses, cell hashes, ports и RTP metadata
остаются private; anonymous export не расширялся.

Первый запуск Core не засчитан: в подготовленной копии config сохранились
пять runtime paths прошлого namespace. Health gate не прошёл, QA процесс
остановлен; первые попытки cleanup/preflight также не зачтены. Перед новым
стартом reset-failed выполнен до systemctl clean, проверены ownership и SHA,
неприкосновенность старых путей и production. Пять путей обоих configs
исправлены и проверены отдельно; новый native validation/preflight/health
прошёл. Это ошибка подготовки стенда, не product defect.

После звонков повторно сверены clean SDK, source hashes, 42 исходных harness
scripts, runtime inputs и identity probes. Оба архива и каждый member
проверены по SHA. Клиентские процессы, collectors и оба QA Core остановлены;
свои units/state/runtime/config/binary/stage paths удалены. APK обоих phone
приложений, исходный QA root container, microphone permission, P2P, debug
properties, исходная validated-сеть и stay-on восстановлены. Mac runtime
удалён, собственный app log перенесён в private evidence, подпись проверена.
Production PID/restarts/binary/config, отсутствие своих ресурсов и свободные
порты сверены независимо. Host API keys удалены. Push/релиза нет.
