# Стандартный порт не устранил нестабильность звонка

Продолжение [проверки failed writer](../failed-writer-shutdown-2026-11-07/README.md),
SDK `c6699c28`. Тот же QA-host, identity и obfs4/TCP endpoint перенесены на
свободный **TCP 443**. Production listener не менялся. Отдельный ограниченный
по времени Core получил только `CAP_NET_BIND_SERVICE`; DynamicUser сохранён.
P2P запрещён, public discovery и built-in seeds отключены.

Прежний qualified signed QA AOT/media/HVS сохранён; Mac и Android используют
проверенные c669 native libraries. После серии совпали 1533 SDK source inputs
и 19 файлов harness. Это контроль сетевого порта, не квалификация последних
Dart-изменений и не A/B-измерение ускорения.

| Вызов | Входящий | Пять fresh RX | Результат |
|---|---:|---:|---|
| Poco → Mac | 1,015 с | не достигнуты | FAIL до перехода внутри звонка |
| Mac → Poco | 0,543 с | 4,321 с | возврат Wi-Fi, 60 с, пять конечных fresh с обеих сторон |

Первый разговор начат после подготовки cellular. На телефоне capture/playout
запустились, но audio RX остался **0**; на Mac успели прийти 35 audio packets,
затем приём остановился. В логах обоих endpoints `livenessTimeout`, silence
24 с. Проверка baseline отказала; команда включения Wi-Fi **внутри этого
разговора не выполнялась**. Поэтому это не неудачный измеренный reverse
handover, а отсутствие устойчивого двустороннего baseline после подготовки
сети. Местные media repair сменили epoch: RX age -1 не принят за свежий звук.

Второй разговор выдержал обратный переход: максимальный наблюдаемый native
RX age после команды Wi-Fi — 1193 / 1534 мс (телефон / Mac). Человеческая
слышимость не проверялась. [Агрегаты и границы](summary.json).

В захваченном окне нет duplicate-session rejection, session violations/банов;
два существующих authenticated resume replacement сработали. Локальные
datagram admission/flush на Mac продолжались без зарегистрированного queue
drop. Это не доказывает доставку до другого endpoint.

Полный server PCAP скопирован с проверкой размера/SHA **до удаления**:
17 116 packets, 137 flows, 116 fresh SYN. У всех 46 flows с client payload
наблюдался server payload; начальный ответ не доказывает исправность всего
канала. Фильтр ограничен локальными IP сервера и QA endpoint, поэтому обычные
исходящие HTTPS-соединения сервера не входят в контроль.

**Вывод:** стандартный порт сам по себе не обеспечил устойчивый звонок.
Единственная причина прежнего сбоя не доказана, NETCALL-01 остаётся открытым.
Следующий захват — с transit diagnostics самого QA Core.

APK, настройки, P2P policy и прежний QA-контейнер восстановлены/сверены;
обычный APK неизменен. Свои app/logcat/Core/capture остановлены, runtime и
порты освобождены. Production PID, executable, config и NRestarts прежние.
Сырые логи, transport IDs и packet captures остаются в приватном cache.
Push/релиза нет.
