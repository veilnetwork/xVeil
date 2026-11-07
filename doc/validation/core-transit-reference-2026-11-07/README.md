# Здоровый контроль с диагностикой QA Core

Продолжение [стандартного порта](../standard-port-control-2026-11-07/README.md).
Тот же SDK `c6699c28`, TCP 443, isolated obfs4 Core, P2P denied и frozen
qualified QA AOT. Добавлен `VEIL_RT_TRACE=1` в отдельный Core unit и Mac;
флаг проверен в окружении конкретного QA PID. Production logging не менялся.

| Вызов | Входящий | Пять fresh RX | После команды возврата Wi-Fi |
|---|---:|---:|---|
| Poco → Mac | 0,509 с | 4,174 с | 60 с, max native RX age 532 / 450 мс |
| Mac → Poco | 1,042 с | 9,351 с | 60 с, max native RX age 865 / 486 мс |

Оба разговора сохранили exact call ID и пять конечных свежих срезов на обоих
endpoints. В измеренном после перехода окне media epoch один, RX counters
не заменяют отсутствующий приём. Это цифровой приём, не проверка слышимости.
[Агрегаты](summary.json).

**Плохой случай не воспроизвёлся.** Эти два успеха не объясняют неудачу
предыдущего прогона, не доказывают влияние logging и не закрывают NETCALL-01.
Захват пригоден как здоровый reference.

В промежуточном снимке реального Core log: 1975 receive windows, 467 admission
windows, 0 зарегистрированных slow wire write / writer stall. Это счётчики
окон к моменту чтения, а не число потерянных/доставленных аудиопакетов.
Финальный Core log скопирован с SHA-проверкой; journal взят только по точному
systemd invocation этого QA unit.

Отдельно обнаружено ограничение настройки наблюдения: CLI по умолчанию
фильтрует `log` на `warn`, а `transport.tcp_trace.*` записывается через
`log::info!`. Поэтому одного `VEIL_RT_TRACE=1` недостаточно для этих TCP
строк, хотя прямые runtime receive/admission trace реально появились.
В этом захвате TCP trace rows **0**, это отсутствие инструментальных данных,
не нулевое число TCP-проблем. Для следующего QA-захвата требуется узкий
`RUST_LOG=warn,transport.tcp_trace=info` в том же отдельном unit. Глобальный
logger/production для этого менять не требуется.

Полный PCAP проверен до cleanup: 37 550 packets, 142 flows, 99 fresh SYN,
40 client-payload flows; у каждого наблюдался server payload. Фильтр исключал
несвязанные исходящие HTTPS-потоки. Это не end-to-end witness доставки.

1533 SDK source inputs и 18 harness inputs неизменны. APK/настройки/P2P и
старый контейнер восстановлены по SHA/readback. Свои процессы, Core, capture,
unit, runtime и порты убраны; production прежний. Добавленный app debug log
вынесен из bundle, strict codesign повторно проверен. В публикации только
анонимные агрегаты; сырые артефакты приватны. Push/релиза нет.
