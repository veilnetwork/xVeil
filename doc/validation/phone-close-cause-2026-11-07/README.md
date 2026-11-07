# Диагностика телефона и шесть переключений в одном звонке

**NETCALL-01 остаётся открытым.** Звонок Poco ↔ Mac продолжался 424,103 с под
одним call ID и пережил шесть смен Wi-Fi/Cellular. Прежний эпизод 9,6 с после
смены сети не повторился. Но в отдельном контрольном звонке на Cellular,
**без переключения сети**, native RX age на Mac достиг **4061 мс** уже после
первоначальной готовности приёма. Полного устранения задержек аудио нет.

## Сборка и подлинность клиента

На Poco — SDK `7d34e4e5`, оба независимых Core используют тот же исходный
commit; Mac остаётся на `c6699c28`. Android-библиотека собрана из чистого дерева
в прежнем внешнем target с mount/free-space watchdog: arm64, NDK 28.2,
API 24, `allow-empty-seeds,node-embedded,packet-tunnel`, без default features.
Это QA/testnet artifact. Его проверенные признаки:

- ELF aarch64 и новые terminal/first-cause markers присутствуют до и после strip;
- все 208 C exports совпадают с прежним клиентом, исходники C API не менялись;
- в APK заменён только FFI payload; AOT/frontend, media/HVS libraries и seeds
  побайтово прежние;
- signer прежний, 16-KiB zip alignment проверен после подписи;
- SHA реально установленного APK совпадает с candidate;
- до длительного звонка в телефонном логе получен новый `record_close_reason`.

Это не чистое A/B добавления диагностики: телефон также получил прежний
bootstrap-retry фикс. Причинное ускорение не заявляется. Исходные 870 tests /
8 ignored из [предыдущего раунда](../record-close-cause-2026-11-07/README.md)
заново не суммируются: в этом раунде исходники SDK не менялись, выполнены
Android cross-build, APK/ABI checks и физическая квалификация.

## Контроль сходимости наблюдений

Три логических звонка: два фиксированных контроля и один длительный. Девять
результатов в summary — это два контроля, baseline длинного вызова и шесть
переходов, а не девять звонков. После готовности длинного вызова есть 745
срезов на каждом конце: call ID прежний, RX counter нигде не отсутствует и
не регрессирует. В каждой финальной пятисрезовой проверке counter увеличился.

Критерий свежести: active call с ожидаемым ID, running, worker_stalled=0,
RX packets > 0, native RX age 0–1000 мс. Дополнительно пять последних срезов
должны показывать рост RX counter: застывший кэш с маленьким старым age не
считается успехом. После каждого перехода — 60 с наблюдения; следующая смена
разрешается только после новой свежей продвигающейся пятисрезовой серии.

| Этап | Native RX age max: Poco / Mac | Строгий финальный критерий |
|---|---:|---|
| Wi-Fi контроль | 376 / 392 мс | Пройден |
| Cellular контроль | 1360 / 4061 мс | Не пройден |
| Wi-Fi baseline длительного вызова | 390 / 359 мс | Пройден |
| 1: Wi-Fi → Cellular | 1142 / 1518 мс | Пройден |
| 2: Cellular → Wi-Fi | 487 / 313 мс | Пройден |
| 3: Wi-Fi → Cellular | 1195 / 1641 мс | Пройден |
| 4: Cellular → Wi-Fi | 899 / 820 мс | Пройден |
| 5: Wi-Fi → Cellular | 1416 / 1640 мс | Не пройден |
| 6: Cellular → Wi-Fi | 376 / 375 мс | Пройден |

Для переходов максимум относится только к post-command samples. Два отказа
финального критерия вызваны срезами Mac с age 1007 / 1103 мс в последних пяти
измерениях; RX после них продвинулся. Это не делает зелёной всю серию:
**7/9** строгих окон, **5/6** переходов. В Cellular-контроле отдельно есть
более длинный 4061-мс эпизод внутри наблюдения. PID телефона не менялся,
каждая целевая сеть validated, ошибок API/OS-наблюдения нет.

## Локализация 4-секундного эпизода

После исходной готовности разговора на Mac RX counter не менялся в нескольких
последовательных срезах как минимум 3765 мс; native age дошёл до 4061 мс.
За тот же интервал native TX counter Poco вырос на **44**, Mac RX — на **0**.
Оба worker running, worker_stalled=0. Это не объясняется одним молчанием
источника, но TX counter ещё не доказывает socket/NIC egress.

В консервативной внутренней части окна на Core A (2530 мс) и B (3185 мс)
не наблюдались media-marker Forward от телефона; встречные Mac-origin
26 / 35 frames имеют Core TX witness. В выбранных 9 / 18 receiver windows
от телефона datagrams, decode_rejected, rate_limited и violations — нули.
Mac family-3 observer за 4-с окно увидел одну входящую media-marker запись.

На телефоне около этого интервала зафиксированы два `partial_record_expired`
с write maximum около 200 мс и endpoint source-pressure drops 11 / 17 / 8
в соседних окнах. Последний pressure-срез уже шире точного RX-gap окна;
эти числа не объявлены числом потерянных RTP packets. Source tracing sparse,
приём Core bounded/rate-limited; отсутствующий witness не доказывает wire drop.

Фронт сужен до phone producer → локальная source admission/независимый канал
→ транспорт → Core observer. Конкретная очередь/socket/ветка пока не связаны
с данным RTP-диапазоном. Приписывать задержку декодеру Mac, криптографии,
провайдеру или только смене сети по этим данным нельзя. Следующий разбор —
состояние source channels и их восстановления при этих pressure/expiry.

## Новые terminal observations и путь медиа

Внутри консервативных окон длинного звонка: Core A — 14 terminal events,
B — 31, телефон — 45. У телефона 40 завершений ordered receivers с typed
cause, 4 QUIC receiver errors без record cause и один receiver exit при ещё
`open` record plane. Последний не считается закрытием record plane: parent
binding может завершить ожидание раньше её собственного close. Исходный
error text и receiver numbers остаются приватными.

На телефоне действительно были QUIC sessions к Mac. Само их наличие не
доказывает прямой медиапуть. Все доступные active call snapshots имеют
`transport=relay`. На Mac наблюдались 21108 outgoing / 18622 incoming opaque
media-marker Forward через Core и **0** таких записей непосредственно к/от
телефона. Прямые Forward other — 196; их содержимое не классифицировано.

Проверена проводка `relay:true` → `veil_media_open_relay_channel` →
`IPC_SEND_FLAG_RELAY_REALTIME`: native handler исключает direct branch и
конечного получателя из first-hop candidates. Обход P2P-медиазапрета не
подтверждён. Стенд квалифицирует relay **media**, но не физическую изоляцию
всего overlay/control traffic. TCP PCAP также не покрывает QUIC; утверждения
о полной сетевой трассе нет. Слышимость, эхо и mouth-to-ear delay не проверялись.

## Восстановление

Оба тестовых Core, capture/subscribers, их данные и порты убраны; production
PID/binary/config прежние. Телефонная QA-сборка, permissions, P2P choices,
сеть и stay-on восстановлены; QA/root container и normal APK hashes совпали.
Mac/phone QA и все записанные дочерние процессы завершены. Собственный Mac
runtime удалён, debug log вынесен из bundle, strict/deep signature прошла.
Архивы и каждая запись проверены, 27 наблюдательных входов заморожены с
приватными SHA, harness не менялся во время звонков. Push/релиза и sibling
mailbox нет. Публичный [summary](summary.json) не содержит stand IDs, адресов,
портов, путей, raw errors, ciphertext previews или их хешей.

Poco отключён владельцем уже после восстановления; подключённый Blackview
не использовался в этой серии и не поддерживает проверку мобильного handover
без SIM. Сохранённого захвата достаточно для продолжения локального разбора.
