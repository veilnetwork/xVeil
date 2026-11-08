# Анонимный снимок Android при смене сети

## Изменение

Независимые socket-пробы показали, что одного события «Cellular» и числа
соединений недостаточно для разбора отказа. В существующий read-only
`diagnosticBackgroundState` добавлены категории состояния Android:

- наличие active network и доступность её capabilities;
- Wi-Fi / Cellular / VPN, metered, INTERNET / VALIDATED / NOT_SUSPENDED;
- наличие process-bound network и совпадение с active default;
- `restrictBackgroundStatus`: Android 1=disabled, 2=whitelisted, 3=enabled.

Отсутствующее/недоступное значение пропускается. Отказ чтения capabilities
отмечается `networkSnapshotAvailable=false`; частичные результаты этой
операции не публикуются. Ограничения API M/N/P проверяются до вызовов.
Data Saver — категория политики, **не доказательство блокировки**.
VALIDATED — мнение Android, **не доказательство доступности Core**.
Это последовательные чтения ОС, не атомарный снимок всех подсистем.

В opt-in диагностической сборке при изменении attachment запускается
асинхронный снимок. Переподключение его не ждёт. Повторные события
коалесцируются: один native read и один ожидающий повтор. Если native read
завис дольше секундного diagnostic timeout, слот не освобождается до его
фактического завершения: новые запросы не накапливаются в канале.
Dispose снимает ожидающий повтор; уже начатое чтение не отменяется.

Обычная сборка с выключенным `XVEIL_DIAGNOSTICS` не вызывает этот probe.
Нет автоматических DNS/TCP/HTTP-проверок или отправки отчётов. Сетевые
адреса, имена интерфейсов/сетей, network handles, UID, идентификаторы SIM
и тексты исключений не добавляются в журнал. Dart повторно фильтрует
поля: только известные boolean и целый policy code 1–3. Старые плагины
без новых полей остаются поддержанными.

## Проверка

- `TMPDIR=/private/tmp/ flutter test --reporter expanded
  test/diagnostic_background_test.dart test/diagnostic_journal_test.dart
  test/network_reconnect_test.dart`: **41 passed**.
- Целевая `flutter analyze` пяти изменённых Dart/test файлов: **no issues**.
- `TMPDIR=/private/tmp/ python3 scripts/test_verify_diagnostic_artifact.py`:
  **1 passed**, проверены реальные AOT executable с включённым и выключенным
  флагом. Канарейки network handle / UID / SSID / address не экспортировались.
- Android `:veil_flutter:compileProfileKotlin` с JBR Android Studio,
  `VEIL_SKIP_CARGO=true`, compileSdk 36: **BUILD SUCCESSFUL**. Rust и native
  библиотеки не пересобирались/не подменялись.
- Тест с незавершённым OS read доказал, что обе handover-нотификации
  завершаются до ответа ОС; timeout не запускает перекрывающиеся чтения.
  Проверены disabled, dispose, отказ наблюдателя и границы policy code.

Новый plugin/Dart на Poco не устанавливался: физические socket/idle замеры
в [README](README.md) относятся к зафиксированным там старым AOT/native.
Диагностическое расширение не объявляется устранением NETCALL-01.
