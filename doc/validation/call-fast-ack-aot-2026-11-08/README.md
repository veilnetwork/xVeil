# Fast ACK: первая проверка с реально обновлённым Mac AOT

**Fast receipts подтверждены на настоящем Poco ↔ Mac.** Авторизация и
retirement не ослаблялись после отрицательных смешанных запусков.

После [AOT-коррекции](../call-aot-provenance-2026-11-08/README.md) заменён
целый `App.framework` из profile target Flutter assemble. Mac engine arm64 UUID
совпадает с текущим official profile cache. AOT содержит ожидаемые source
revision/digest/receipt markers. До unlock authenticated `/health.build`
совпал с compiler inputs: source `460d74e2`, lib source digest, profile,
diagnostics enabled. После запуска проверены actual mapping и SHA самого
`App.framework/Versions/A/App` плюс выбранной FFI. Runtime metadata работает
как precondition драйвера; missing/stale build прекращает квалификацию.

Android — неизменный проверенный c5677f38 AOT APK; в его `libapp.so` есть
fast-receipt и compile-time QA markers, kernel в APK отсутствует. SDK по-прежнему
Android bbcd967a / Mac c8f4929b / Core e974cebe. Media/HVS и QA seeds сохранены
побитно; это не синхронный выпуск всех новых native зависимостей.

## Relay-only звонок

Оба endpoints `P2PGlobalPolicy.denied`. Во всех 29 samples call/native route —
relay. Audio counters выросли +149/+312, media epoch 1, max native RX age
426/400 мс Mac/Poco. Слышимость человеком не проверялась.

| Source signal | Fast receipt после исходной отправки | Ordinary receipt той же отправки |
|---|---:|---:|
| Mac answer | 96,086 мс | 112,460 мс |
| Mac end | 182,910 мс | 3248,335 мс |
| Poco offer | 99,621 мс | 106,495 мс |
| Poco answerSelected | 94,692 мс | 142,357 мс |
| Poco end | 1198,009 мс | 3225,773 мс |

Оба момента сопоставлены по одному frame ID и часам одного source процесса,
межустройственный clock skew здесь не нужен. Только Poco end успел сделать
два fast redrive; остальные четыре — без них. Source/receiver logs без dropped
rows. Mac diagnostic state=16 подтверждает проход новой ветки; последующие
unknown-row decisions не объявлены дефектом или поштучно атрибутированными
повторами. Final Outbox API показывает 0 call frames у обоих endpoints;
это наблюдение API после обработки, не crash/reopen proof на диске.

Это подтверждает доступность и полезность быстрого receipt path в этом
звонке, не общее ускорение или устранение NETCALL-01. Цифры прежних смешанных
серий не используются как causal A/B. Следующий контроль — смена сети с тем
же фактически загружаемым AOT.

## Завершение

Driver/cleanup exit 0. Phone original network/permissions/P2P/debug properties,
main/QA APK и root QA container восстановлены и сверены по SHA. Apps, phone
collectors, local/remote subscribers и owned runtime остановлены/удалены.
Два test Core с unit/state/config/binaries удалены, test ports свободны;
production PID/binary/config независимо совпадают. Raw IDs/keys/captures
private. Новых Rust builds, push или релиза нет.
