# Android: замена сети при неизменном типе подключения

## Подтверждённый механизм

Прежний app-путь различал только Wi-Fi / cellular / ethernet / offline.
Закреплённый connectivity_plus 6.1.5 передаёт из Android callback список типов,
а его Dart-обёртка применяет `distinct` к этому списку. При замене default
Network с Wi-Fi A на Wi-Fi B без промежуточного offline приложение поэтому
могло не вызвать `networkChanged`: старые сессии оставались до иных механизмов
восстановления. Даже повторный список Wi-Fi в app-наблюдателе не создавал
нового поколения.

Это отдельный подтверждённый пробел наблюдения. Он **не доказывает причину
исходной паузы Wi-Fi → cellular во время звонка**. NETCALL-01 остаётся открыт.

## Изменение

- Android 8+ наблюдает default Network через собственный engine-owned callback.
  Равенство Network проверяется только в Kotlin. В Dart передаются категория
  подключения и локальный счётчик изменений: без network handle, SSID/BSSID,
  адресов или записей этих идентификаторов в диагностику.
- Новый Network с той же категорией создаёт новое поколение уведомления.
  Повторы capabilities того же Network не вызывают новое переподключение.
  Поздние capabilities/lost прежнего Network и callbacks после retirement
  не заменяют актуальное состояние.
- Существующие отдельные очереди личностей, сериализация IPC, bounded retries
  и защита от запоздалого initial query сохранены. Одновременно используется
  один источник событий. На других платформах, Android ниже 8 и при отказе
  нового наблюдателя остаётся прежний connectivity-путь.
- Отмена подписки/отсоединение engine снимает callback. Observer использует
  application context и не открывает окна, настройки или новые соединения.
  Не менялись seed policies, mailbox, проверка медиапути и wire-протокол SDK.

Callback использует переданные Android capabilities, без синхронного запроса
ConnectivityManager внутри callbacks. Начальный снимок берётся отдельно.
Основание: [Android NetworkCallback](https://developer.android.com/reference/android/net/ConnectivityManager.NetworkCallback#onAvailable(android.net.Network))
и [registerDefaultNetworkCallback](https://developer.android.com/reference/android/net/ConnectivityManager#registerDefaultNetworkCallback(android.net.ConnectivityManager.NetworkCallback,android.os.Handler)).

## Проверки

Регрессия через реальный ProviderContainer, method/event codecs и fake native
port: Wi-Fi revision 1 → Wi-Fi revision 2 должна вызвать две отправки transport.
На прежнем app-коде assertion падает: отправка одна. Повтор revision 2 не
создаёт третью. Это контролируемая замена сети, не физический Wi-Fi roaming.
Первоначальный запуск с ошибкой API фикстуры не засчитан как baseline-red.

Новая серия проверяет также замену во время незавершённого IPC, late snapshot,
независимость от legacy-событий, fallback, cancel и формат входа. Она поймала
промежуточную регрессию самого нового fallback: старый seed перекрывал более
свежее событие. Отдельный assertion-red воспроизведён; поздний seed теперь
принимается только при отсутствии новых наблюдений.

- **314 related Flutter tests passed, 0 skipped**, включая все 32 проверки
  network source/reconnect, call service, route queue/qualification и retirement.
  Эти 32 не прибавляются повторно к 314. Анализатор изменённых Dart-файлов чист.
- Kotlin JVM fixture `test/native/DefaultNetworkStateSmoke.kt` проверяет
  замену, повтор capabilities, superseded callback, offline/reconnect,
  retirement и точный состав передаваемой map. Проверки прошли.
- Новый native adapter отдельно скомпилирован с настоящими Android/Flutter API;
  затем полный `:app:compileDebugKotlin` прошёл, включая проводку MainActivity.
  Для итоговой компиляции SDK взят из точного опубликованного ARM64 APK
  0.13.102 после проверки SHA; `VEIL_SKIP_CARGO=true`. Прежняя staging-копия
  сохранена и восстановлена с проверкой байтов. Первая попытка Gradle запустила
  лишнюю Cargo-сборку и была остановлена; она не считается квалификацией.
- **Два настоящих native IPC-теста прошли**, Unix и authenticated loopback TCP:
  по семь notifications, включая подряд Wi-Fi/Wi-Fi и cellular/cellular,
  доходят до daemon до закрытия временного клиента. Использована сохранённая
  release-qualified macOS SDK с повторной сверкой SHA. Никакой фильтрации
  одинакового kind на этом пути нет; восстановление удалённой сессии этими
  локальными тестами не доказывается.

Flutter-команды выполнялись с `TMPDIR=/private/tmp/`. Native узлы остановлены,
runtime fixtures удалены; TCP-порты после stop повторно заняты тестом как
проверка освобождения. Окна/ввод и физические телефоны не затрагивались.

## Остаток

Нужен физический контроль смены default Network и звонка на доступном мобильном
канале. Смена Wi-Fi AP без смены Android Network, смена IP внутри прежнего
Network и все VPN-underlay варианты не объявляются покрытыми. Обход ограничений
провайдера не добавлялся. Пауза аудио NETCALL-01 не объявляется устранённой.

Изменение локальное, после выпуска 0.13.102; нового push или релиза нет.

## Проверка native-порта на Android 11

После коммита `bd064b8c` тот же production observer/state скомпилирован в
отдельный DEX. Проверены SHA исходников и точные байты переданного JAR.
Проверка выполнена на подключённом Android 11 под обычным UID существующего
QA-пакета с уже выданным ACCESS_NETWORK_STATE: без установки APK, запуска
Activity, открытия профилей или контейнеров. Flutter method codec настоящий;
вместо Dart engine используется тестовый messenger/sink. Это проверка native
порта и его системных разрешений, а не полного приложения.

Два предварительных запуска не засчитаны: самостоятельный ActivityThread
создавал тестовый контекст с атрибуцией пакета `android`, который не принадлежал
QA UID. Android закономерно отказал в регистрации. Исправлен только контекст
операторского теста — на пакет, принадлежащий фактическому UID; production-код
не менялся, новые разрешения не выдавались. Ошибки и cleanup сохранены отдельно.

Итоговый прогон получил реальные события:

| Событие | Категория | Локальная revision |
|---|---|---|
| Начальное наблюдение и method snapshot | offline | 0 |
| Включение Wi-Fi и подключение | wifi | 1 |
| Выключение Wi-Fi | offline | 2 |

Независимый системный dump показал число **активных** Network Requests для
единственного тестового PID: **0 → 1 → 0 → 0** — до запуска, во время подписки,
после onCancel при ещё живом процессе и после завершения. Исторические
REGISTER/RELEASE строки в подсчёт не входят. После onCancel Wi-Fi включён
повторно; новых событий в sink нет, handler registrations очищены при dispose.
Наблюдения содержат только category/revision, снимок через method channel
согласован с начальным состоянием, ошибок native-порта нет.

Процесс и собственный каталог удалены, исходное выключенное состояние Wi-Fi
восстановлено. Фокус окна телефона до/после одинаков; окна и ввод Mac не
затрагивались. Сводка без PID, UID, пакетов, адресов и raw dumps:
[device-check.json](device-check.json).

**Границы сохраняются:** на телефоне нет SIM. Wi-Fi A → Wi-Fi B без offline,
P2P/relay медиа, звонок и cellular handover этим прогоном не проверены.
NETCALL-01 по-прежнему открыт. Положительный результат native-порта не
переобъявляется физическим воспроизведением исходного дефекта.
