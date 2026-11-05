# Один запрос отпечатка при Android startup unlock

## Причина и границы

Владелец подтвердил: после локальной установки `0.13.94-fingerprint.1`
быстрый вход заработал, но требовал два отпечатка. `openSystem` сначала
вызывал LocalAuth, затем холодный secure-storage запрашивал CryptoObject
для распаковки application key. Удаление только первого запроса небезопасно:
`FlutterSecureStoragePlugin` кэширует инициализированное хранилище по namespace,
а повторный `initialize` возвращает успех без новой криптографической проверки.

## Реализация

Android использует отдельный `xveil/quick_unlock` read. Для **каждой** операции
создаются свежие cipher factory, Cipher и BiometricPrompt.CryptoObject;
Keystore key распаковывает application key только после сильной биометрии.
После этого расшифровывается одна существующая запись. Factory/StorageCipher
взяты из закреплённого `flutter_secure_storage` 10.3.4, формат данных не меняется.
Кэш plugin для чтения не используется; отдельный LocalAuth для Android убран.
Desktop сохраняет LocalAuth перед чтением, iOS-путь не меняется.

Native read проверяет алгоритмы **до** создания factory (иначе та могла бы
записать отсутствующие markers), наличие wrapped key/IV и существующего
Keystore key. KeyInfo обязан указывать auth-per-use и invalidation при смене
биометрии; на API 30+ допускается только AUTH_BIOMETRIC_STRONG. Prompt также
разрешает только сильную биометрию, без device credential fallback. Чтение не
выполняет migration, reset, изменение namespace или запись нового секрета.
Настройка, verification после записи и удаление остаются у plugin.

Одновременно разрешена одна операция. Stop Activity отменяет её; destroy
закрывает channel и worker. Поздние success/error/negative-button callbacks
привязаны к исходной операции, не могут завершить или отменить преемника.
Plaintext buffer очищается; unwrapped cipher не сохраняется между запросами.
Dart дополнительно сверяет поколение и сохранённый slot после native await,
так что forget/reconfigure не публикуют результат уже отменённого входа.
Ошибки bridge не содержат ключей, путей и текстов исключений. Отсутствующий
bridge не включает запасное чтение из расшифрованного plugin-cache.

## Проверки

- До правки: два новых regression case красные, три прежних controls зелёные.
- После: 80 связанных Flutter tests passed, без skip; analyzer чистый.
- Cold/warm/recreated vault каждый делают один authenticated read; cancellation
  не возвращает пароль; отсутствие bridge fail-closed; поздний результат после
  forget отвергнут. macOS/Windows сохраняют явное подтверждение ОС.
- Kotlin/JVM smoke проверяет ownership, overlap, повтор, cancel и dispose gate.
- Отдельный Android QA APK с настоящим HVS-контейнером собран; core/Kotlin source
  SHA сверены, исходный plugin cache не модифицировался. Rust не пересобирался.

Изменён тестовый storage port в прежнем in-memory suite: fake теперь явно
моделирует authenticated read, вместо обращения к отсутствующему Android
channel. Первые три отказа этой suite были ошибкой проводки fake и не считаются
production-regression или дополнительными baseline-red.

## Физическая проверка — ожидается

Первая установка отдельного probe отклонена Android: INSTALL_FAILED_USER_RESTRICTED.
У владельца запрошено подтверждение USB-установки и настоящий отпечаток.
Сборка обычного приложения подготовлена отдельно на release base 0.13.94;
установка до завершения физической проверки не засчитана. Пока основное
приложение остаётся `0.13.94-fingerprint.1`, пользовательский контейнер не
открывался. Наличие одного диалога на реальном устройстве пока не заявлено.
Подготовленная обычная сборка `0.13.94-fingerprint.2` имеет исходную release
подпись и versionCode 2113; четыре native-библиотеки и application assets
побайтно совпали с установленной `.1`. Test hooks не включены. Сохранены
проверенные APK и SHA/source proofs, лишний build staging удалён. Probe не
установлен и не запущен; пользовательское приложение не обновлялось этим раундом.
Push, публичного релиза и обновления сидов нет.
