# Включение видео после ожидания должно принадлежать текущему звонку

2026-11-05. Подтверждён дефект `VeilCallMediaController.setVideoEnabled`.
Во время разбора ремонта маршрута найдена отдельная lifecycle-гонка;
атрибуция полной мобильной паузы NETCALL-01 ей не установлена.

## Воспроизведение на настоящем controller

Метод захватывал engine и Call до запроса camera permission, затем после
ожидания аудиомаршрута без проверки записывал старый Call в `_activeCall` и
мог запускать frame pump. Воспроизводитель использует production controller,
его настоящий start/stop и асинхронный аудиомаршрут, с тестовыми transport/engine
и MethodChannel для разрешения. Никаких production fault-switch или новых
тестовых параметров конструктора не добавлено.

| Условие | Старый код | Требуемый результат |
|---|---|---|
| Отбой после startVideo, до завершения audio-route await | upgrade возвращает true | false, завершённый звонок не восстанавливается |
| В той же точке начинается следующий звонок | следующий start возвращает false: старый Call перезаписал владельца | новый start успешен, старый upgrade отменён |
| Permission приходит после отбоя / нового звонка / того же ID у другого peer | одно обращение к уже disposed engine | ни одного обращения к прежнему или чужому engine |
| Permission приходит после замены engine в том же продолжающемся звонке | upgrade теряется | монтируется на новом engine ровно один раз |
| Здоровый текущий звонок | upgrade успешен, повтор не монтирует второй stream | то же; permission не мешает route repair |

Финальный oracle на исходном production-файле дал **6 assertion-red и
1 положительный control**. Это не тайминговая догадка: completers фиксируют
permission и вход в native mounting; их timeout — только deadlock guard.
В сценарии следующего звонка проверяется именно результат его start, а не
лишь отказ старой операции. Permission-channel случаи выполнены на macOS;
на host без Apple/Android API они явно skipped.

## Исправление

Разрешение ожидается вне существующей `CallMediaRouteOperations` очереди.
После него сверяются logical call ID и media identity. Mounting идёт через
`runForCall`, поэтому незаконченный ремонт завершается до выбора движка.
Движок выбирается **после** ремонта, а не из снимка до permission.

Внутри монтирования после audio-route и Android renderer awaits проверяются
media epoch, engine и logical owner. Отбой или новый звонок отменяют старую
операцию; они не дают ей опубликовать успех или заново запустить frame pump.
При успешном завершении обновляется актуальный Call, сохраняя более новые
намерения mic/camera/screen и маршрут.

Первый кандидат только отвергал сменившийся engine. Он закрывал obsolete
обращения, но оставлял потерю законного upgrade при same-call repair. Это
поймано отдельной проверкой и не вошло в финал: permission принадлежит звонку,
а native mounting — конкретному текущему engine. Положительный control также
выполняет настоящий `repairRoute` controller при удержанном permission и
требует вызова transport repair: одной надписи «repair pending» недостаточно.

## Проверки и границы

Финальный набор из восьми файлов: **333 passed / без skip** на этом Mac.
Он включает новые lifecycle случаи, call service, route operations, camera/
microphone intent, audio routing, permission screen и group media controls.
Analyzer двух изменённых файлов — без замечаний. Предшествующий расширенный
запуск с двумя несуществующими именами тестов не зачтён; список исправлен.
Промежуточные 56/332 повторные результаты не складываются с финальными 333.

Это controller/model квалификация, без реальной камеры, ADM или сетевого
handover. Android renderer await защищён production guard, но физическая
Android-квалификация этой точки не выполнена. Телефон отсутствует в ADB;
слышимость речи, NETCALL-01 и исходные жалобы Windows/Poco остаются открытыми.
Тестовые Flutter-процессы завершились; пользовательские приложения и
настройки устройств не менялись. Все запуски — `TMPDIR=/private/tmp/`.
Rust/C++/engine pins не менялись, native пересборки не было. Raw logs и
случайные media keys не добавлены в репозиторий; push, релиза и изменений сидов нет.
