# Смена сети не должна блокировать основной Dart-поток — 2026-11-05

Подтверждён ещё один механизм в пути NETCALL-01. В текущем SDK
`VeilClient.notifyNetworkChanged` использовал `Future(() { ffi(...); })`.
Это лишь переносило синхронный вызов на следующий оборот **того же** event
loop. Native FFI ждёт inline dispatch receipt от узла через `node_identity`;
у RPC есть 5-секундный deadline. Ожидание перед входом в RPC и время всей
процедуры этим числом не ограничиваются. Пока FFI ждал, Dart callbacks,
timers и UI не выполнялись. Это релевантно восстановлению управления звонком,
но не атрибуция всей ранее наблюдавшейся паузы аудио 12–20 с.

## Исправление

SDK `70478463`: вызов выполняется через `Isolate.run` и top-level worker.
Передаются только process-global opaque handle token, network kind и MTU.
Сам клиент с его `NativeCallable` не передаётся. Метод явно `await`-ит worker,
чтобы сохранить lifetime `Finalizable` owner до окончания native операции.
Native errors/code и владение строкой ошибки сохранены.

Успешное завершение по-прежнему означает receipt от узла, а не только enqueue
или запуск фоновой задачи. RPC, wire, authentication, retry/backoff и выбор
сети не менялись. Прежняя проверка closed client сохранена. Повторно
переподключать все сессии при каждом duplicate OS event исправление не заставляет.

## Проверки

1. Три новых SDK regression на прежнем коде дали assertion-red: success,
   native refusal и закрытие клиента во время ожидания. Тестовая C-библиотека
   отпускает вызов только после callback на исходном Dart event loop.
   Двухсекундный timed wait — защита от зависания теста, не порог качества или
   производительности. На старом коде callback не выполнялся до отказа native.
2. После исправления event loop сам отпускает ожидание. Проверяются отсутствие
   раннего завершения Future, аргументы, передача отказа, однократное освобождение
   native error и запрет второго вызова после close. Активный event handler с
   `NativeCallable` проверяет, что клиент не захвачен worker closure.
3. Полный SDK suite: **74 passed / 1 skipped**. Пропуск — прежний
   `AppHandle.openStream` integration case, требующий работающего daemon;
   он не зачтён. Scoped worker/stream/types ранее дали 24 passed.
4. xVeil control: **348 passed / без skip** — network reconnect, call service,
   network activity, audio recovery/pressure и P2P endpoint service.
   SDK и app scoped analyzer — без замечаний. C fixture также компилируется с
   `-Wall -Wextra -Werror`.
5. Standalone probe дополнительно собран в **Dart AOT executable на macOS**;
   все три native outcome проходят с тем же event-loop/receipt/error/close
   oracle. Это контроль host AOT, не Android/iOS release-сборка приложения.

## Настоящий native dispatch

`test/native/network_change_dispatch_live_test.dart` запускает настоящий
embedded node с публичной fixture-личностью, loopback listener и отключёнными
builtin seeds/meeting points. Два режима: pathname Unix socket и authenticated
loopback TCP с token sidecars. На каждом последовательно открываются пять
временных клиентов: Wi-Fi, cellular, offline, Ethernet, unknown; MTU различается.
У каждого также установлен event handler и есть положительный `nodeId` control.

После `await notifyNetworkChanged` клиент закрывается **без sleep/flush**.
Узел получил все **10** уведомлений с правильными kind/MTU, по одному; это
проверено по его собственному журналу. Новый клиент после серии работает.
**2 passed / без skip.** После stop TCP sidecars исчезли, оба TCP-порта удалось
повторно bind-ить, runtime-каталоги удалены; process group после Flutter отсутствует.
Этот прогон не задерживает реальный RPC: блокирующее ожидание отдельно доказано
управляемой C-границей. Сетевые сессии к удалённому собеседнику не создавались.

Первый live-прогон **не засчитан**: deferred runtime сохранил stderr logger,
а observer ждал файл из позднего config. Handler уже писал в stderr, но это
не выполняло oracle. После подтверждённого отказа observer собственный процесс
остановлен; четыре обнаруженных runtime-root проверены/очищены. При остановке
driver мог вернуть 0 при наличии `[E]`, поэтому следующий wrapper требует
также `All tests passed!`, отсутствие `[E]` и неизменность inputs. Исправленный
стенд запускает полный config сразу, с file logger и без начальных discovery
defaults. Тесты после него не содержат ECH/LAN discovery log markers.

## Происхождение и границы

Rust в этом раунде не менялся и не собирался. Native FFI — ранее
квалифицированный `b8647716`; Cargo.lock и SHA библиотеки совпали. Разница SDK
до `70478463` — только Dart wrapper и test fixtures в `flutter/veil_flutter`.
Embedded-node helpers, live test и SDK wrapper заморожены на время native suite.
Все Flutter-процессы запускались с `TMPDIR=/private/tmp/`; external target
подтверждён как отдельная от `/` файловая система.

Телефон сейчас отсутствует в ADB, физический Wi-Fi → mobile handover не
выполнялся. Уменьшение пользовательской паузы, слышимость речи, эхо и стабильность
на проблемном провайдере не объявляются проверенными. APM, packetization,
engine release pins и приложение на устройствах не менялись. Raw logs и
идентификаторы остаются вне репозитория. Push, релиза и изменений сидов нет.
