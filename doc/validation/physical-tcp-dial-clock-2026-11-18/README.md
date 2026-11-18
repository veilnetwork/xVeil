# NETCALL-01: захват с context и начало отдельного TCP-connect

**Физический захват получен, пауза звонка не объявлена исправленной.** На Poco
загружен подготовленный диагностический SDK и выполнен один idle-переход
Wi-Fi → мобильная сеть. Звонок, микрофон, Windows и Mac-приложения не запускались.
Полученных данных недостаточно для индивидуального связывания first flights
с серверными потоками: именно это установил строгий отбор, без принудительных
пар. В диагностику добавлена недостающая нижняя граница отдельного TCP-connect.

## Что действительно измерено

Использован отдельный Network Call QA с прежним frozen AOT и SDK baseline
`53fbbe34` плюс пять diagnostic-only source changes из
[предыдущей подготовки](../tcp-dial-context-2026-11-18/README.md). Это не проверка
всего текущего native HEAD или frontend. API/testnet/realStack, загрузка SDK,
точные установленные APK bytes и новый native admin socket проверены на телефоне.
Таблица slot → target получена из 73 снимков настоящих sessions; три числовых
слота имели по одной стабильной фиксированной цели. В захвате шесть успешных
основных transport connects, столько же first obfs4 groups с selected/complete,
нет событий успешного NAT/SOCKS fallback. Это операторская привязка ожидаемого
target, не отдельное криптографическое доказательство identity.

Калибровки CLOCK_MONOTONIC телефона и CLOCK_REALTIME Core прочитаны до и после
одного окна, через один reference CLOCK_MONOTONIC сборщика: по шесть проб на
каждом устройстве. Helper реально исполнился на Android, его SHA проверен.
Core SSH-каналы были уже готовы перед чтениями. Логи/PCAP начали собираться
раньше включения trace; PID QA сохранялся весь переход. Системный default
перешёл с Wi-Fi на cellular. Наблюдение после отключения Wi-Fi — 32 с.

| Наблюдение | Результат |
|---|---:|
| Логические contexts | 12 |
| Client starts, каждый с context | 158 |
| Contexts с наблюдаемыми сокетами | 6 |
| Сокеты после first group этих contexts | 152 |
| Complete server flows по Core | 62 / 44 / 54 |
| Из них без client payload bytes | 43 / 26 / 36 |
| Отдельно incomplete tuple groups | 20 / 14 / 18 |
| Однозначные временные пары | **0** |
| Client starts с несколькими кандидатами | **158** |

Это все соответствующие TCP flows данного окна; число без payload не
превращается в число потерь аудио или доказательство принадлежности каждому
из них именно телефону. Два complete server flows не получили native candidate.
Счётчики tcpdump: captured 894/847/981, received-by-filter 926/865/989,
reported kernel drops — 0/0/0. Они **не доказывают полноту регистрации всех
сетевых пакетов**: определения received/drop и учёт ещё не прочитанных из kernel
пакетов зависят от capture backend ([libpcap pcap_stats](https://github.com/the-tcpdump-group/libpcap/blob/master/pcap_stats.3pcap)).
Границы захвата и неизвестные потоки сохранены, path loss из нулей не выводится.

## Почему потребовалось ещё одно измерение

`connect_context` намеренно живёт у родителя и наследуется auxiliary. Его время
начала слишком раннее для вспомогательного сокета, открытого спустя секунды:
старый отбор допускал все более ранние server SYN данного Core. Уточнение часов
само по себе это окно не сужает. Это установленный пробел инструмента, а не
найденная причина паузы медиа.

Теперь gated `tcp_connect_started_us` снимается перед `connect_tcp_stream`
**отдельно** у primary, отложенного backup и каждого auxiliary factory connect.
Значение присутствует уже в первом `tcp_handshake ... outcome=start` и остаётся
при следующих observation этого сокета. Это нижняя граница вызова connect,
включая подготовку/resolve внутри него, а не timestamp SYN на NIC. Для текущих
фиксированных IPv4 целей она позволяет значительно сузить допустимое окно;
единственность будущего сопоставления заранее не обещается.

Gate выключен — чтение часов не выполняется; позднее выключение по-прежнему
гасит observer. У server/legacy observation поле может оставаться None. Нет
новой таблицы, фонового task, socket option, ID на wire, изменения backup delay,
transport timeout, PSK/handshake, admission, parent proof или медиаприоритета.

Нормализатор переносит Some-clock как `dial_start_ns`, с учётом microsecond
precision. Анализатор использует его вместо раннего origin родителя, отвергает
connect позже observation/раньше своего context и сохраняет консервативный
fallback для старых записей. Сокет без context тоже остаётся потенциальным
конкурентом в своём физически допустимом интервале. Старый parent origin может
быть до калибровки, если собственный connect целиком покрыт текущими часами.
Прямого join портов через NAT и жадного назначения по порядку строк нет.

## Проверки

- Новый native witness сначала упал на прежнем коде: отсутствовал physical
  pre-connect clock. Первый запуск с ошибочным module filter выполнил ноль
  тестов и **не** засчитан как red; исправленный filter выполнил один тест,
  упавший именно на отсутствии поля.
- Реальный obfs4 control: молчащая primary, успешная delayed backup, независимый
  auxiliary через тот же factory. Все три start имеют собственные часы внутри
  наблюдаемых границ; backup clock позже primary observation, child clock после
  явного начала его factory. Полезные байты в обеих ветках проходят без изменений.
- Весь veil-transport: **185 unit + 5 integration + 2 doc-tests passed**,
  без ignored. Ещё **8 runtime checks passed**: dial wiring, canonical/auxiliary
  resume, unknown-leaf admission, network retirement. Это host qualification.
- **56 Python-проверок passed**: 24 candidate, 18 normalizer, 6 queue timing,
  8 shaper timing. Старый parent origin воспроизводит неоднозначность; новые
  независимые socket starts разделяют причинно разнесённые synthetic flows.
  Некорректные часы отвергаются. Это не мобильное доказательство доставки.
- **25 Dart-тестов passed**; один artifact harness прошёл в двух настоящих host
  AOT-режимах. Имя нового поля и числовая canary не попали в анонимный JSON.
  Это не AOT-квалификация приложения на Android.
- Clippy release/tests с `-D warnings`, Rust formatting, whitespace и privacy
  gates прошли. Проверки не расширяли allowlist.

## Следующий probe и восстановление

Следующий Android probe собран в отдельном worktree и отдельном внешнем target:
тот же baseline `53fbbe34` и пять diagnostic-only файлов, теперь с physical
connect clock. Все остальные AOT/Flutter/media/storage/assets сохранены
побайтно; 217 C exports и signing certificate совпали, PT_LOAD ≥16 КиБ,
zipalign/signature и loader dependencies проверены. Три diagnostic markers
найдены в выбранном SDK, source SHA до/после сборки совпали. Проверка raw SDK
после маскирования **только прежних exact allow-substrings** независимо проверила
literal и regex правила; archive-policy тоже прошла. Правила не менялись.

Первый стенд полностью восстановлен перед повторным отказом обычного ADB: QA заблокирован
и остановлен, точный прежний QA APK возвращён, Wi-Fi снова выключен, mobile
остался включён, helper и owned ADB-forward удалены. Основной APK до/после
совпал по SHA. Все три capture и три SSH clock процесса завершены/reaped;
сервисы, конфиги и бинарники Core не менялись.

Перед установкой следующего probe обычный ADB снова не находил Poco.
Прежний вывод об исчезновении USB отозван: использовался неподдерживаемый
profiler-раздел, см. продолжение ниже. Эта установка
**не начиналась**. Сохранены APK/SDK, private provenance и исходные захваты;
собственные worktree/Android target убраны, освобождено около 1,63 ГиБ. Общий
release cache не удалялся. Нужен повторный idle-захват с per-socket clock и
immediate-mode capture; затем — физический звонок. NETCALL-01 не закрыт.

## Продолжение

[Следующий probe выполнен на Poco](../poco-physical-dial-capture-2026-11-18/README.md).
Обычный ADB не находил transport при реально подключённом USB; отдельный сервер
восстановил доступ. Уточнён отбор per-socket candidates, прежняя USB-диагностика
исправлена. Основной дефект звонка остаётся открытым.
