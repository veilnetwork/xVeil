# NETCALL-01: контроль перезапуска и независимые socket-пробы

## Результат

Текущая недоступность двух QA-Core на мобильной сети воспроизводится
**вне SDK и без передачи application payload**. Она не объясняется только
состоянием старого процесса или медиадвижка. Точка отказа в ОС/сети ещё не
установлена. Это не закрывает ранние обрывы/паузы уже работавших звонков.

Использованы те же полные AOT f36a472d и frozen native builds:
Mac c8f4929b, Android bbcd967a, два Core e974cebe. Runtime build, mappings,
APK/native SHA и bootstrap endpoints проверены; адреса и Core identities
в приватных данных. TCP transport, порт 443 и seed assets сохранены.
Новая SDK-валидация конфигурации 2f747ac0 в эти binaries не входила.

## Idle handover и полный перезапуск QA

Без активного звонка после Wi-Fi → Cellular в прежнем процессе за 45 с
новых аутентифицированных Core-сессий не наблюдалось. Возврат Wi-Fi в том
же процессе дал Core B/A примерно за 1,578 / 1,799 с.

Во втором переходе на +6,188 с запрошен force-stop именно QA: PID исчез,
тот же APK и профиль запущены вновь на остававшейся валидированной Cellular.
Native ready — около +16,847 с от cut. Runtime build, APK и личность
проверены. Ещё 45 с наблюдения и последующий readiness-gate не дали нужных
parent sessions. Relay-only звонок **не начинался**, его предусловие не
сложилось. Результат 1/0 (probe/cleanup) сохранён, не объявлен зелёным.
Оба Core при финальном сборе оставались active с теми же PID, NRestarts=0;
OOM в захватах не наблюдался. Ошибки readiness не были SSH-only отказом.

Старые и новые Android-коллекторы разделены, старые token/process groups
проверены и удалены. Подробности без идентификаторов:
[idle-restart-control.json](idle-restart-control.json).

## Контроль вне SDK

На отдельном повторе в том же QA окружении проверены прямые IPv4 TCP
connect к двум Core. TCP443 действительно принадлежал ожидаемым Core PID
до переключения и после мобильных проб, binary/production guards прошли.
Ни netcat zero-I/O, ни отдельный C probe не отправляли protocol greeting
или другие application bytes. Run-as выполнялся под UID QA, но это
**отдельный процесс/SELinux context**, не Socket.connect внутри Flutter.

| Проверка (к каждому Core) | Wi-Fi | Cellular |
|---|---|---|
| Системный netcat zero-I/O | 2/2 connect | 0/2 |
| netcat под UID QA через run-as | 2/2 connect | 0/2 |
| Отдельный native probe, стандартный MSS | 2/2 | 0/2, errno 111 |
| Тот же probe, MSS 1200 до connect | 2/2 | 0/2, errno 111 |
| Тот же probe, MSS 960 до connect | 2/2 | 0/2, errno 111 |
| Проверяемый HTTPS HEAD к example.com из shell / QA UID | 2/2 HTTP 200 | 0/2, curl 7 до TLS |

MSS-настройки менялись только на короткоживущих socket-пробах. Отказы
native connect пришли за 46–64 мс; это elapsed функции с scheduling,
не измерение сетевого RTT. Поле actual_mss на неустановленном сокете не
является согласованным MSS/измерением MTU. Этот опыт не проверяет передачу
полного payload при разных MTU и не обосновывает новый глобальный MSS.
HTTPS шёл без прокси с обычной проверкой сертификата; отключение TLS
verification не использовалось. Снимок ОС показывал INTERNET, VALIDATED,
NOT_SUSPENDED, NOT_RESTRICTED, NOT_VPN, но эти флаги не доказали доступность
конкретных серверов. После возврата Wi-Fi тот же процесс снова открыл Core
B/A около +1,691 / +3,086 с.

На Core B в расширенном clock-bound окне TCP-проб не наблюдалось ни одного
incoming SYN или исходящего RST; capture=received-by-filter=2524,
kernel drops=0, граница часов около ±28,7 мс. Это сужает отказ до места
раньше этого наблюдаемого Core-входа, не различая ОС, путь или внешнюю
фильтрацию. У A capture 1699 / filter 1712 при kernel drops=0: пробел 13
пакетов сохранён в отчёте, отсутствие SYN на A не объявляется полным
доказательством. Наблюдение не устанавливает причину прошлых TCP delivery
stalls после уже успешного handshake.

Read-only снимок после теста: Data Saver disabled, UID QA в обоих
battery-exemption списках, effective UID block NONE. Это не непрерывная
съёмка политики во время каждого отказа и не исключает все OEM/сетевые
правила. Владелец затем подтвердил: провайдер в этом месте использует
белые списки, открывается только часть разрешённых сайтов. Это согласуется
с независимыми отказами к Core/контрольному сайту, но не устанавливает
причину прежних пауз уже работавшего звонка. Нельзя утверждать отсутствие
доступа ко всему Интернету по трём проверенным направлениям.
Результаты: [socket-control.json](socket-control.json).

## Инструмент и гигиена

[android_tcp_connect_probe.c](android_tcp_connect_probe.c) — отдельный
диагностический executable, без вставок в приложение. Принимает числовой
IPv4, порт, MSS (0 = стандартный) и timeout_ms; JSON содержит только
стадию, код ошибки, MSS и elapsed. Source/binary SHA и compiler сохранены.
До сетевого опыта на loopback проверены три native MSS-режима, оба UID
netcat и настоящий отказ закрытого порта. Пять принятых соединений
передали ровно ноль application bytes. Timeout-ветка кода физически
не упражнялась. [probe-proof.json](probe-proof.json).

Оба стенда завершены: Core/app/коллекторы/свои порты остановлены, исходные
APK/QA root-container/permissions/сеть/properties восстановлены и сверены.
У отдельного probe удалены точный owner directory и executable; временные
ADB reverse и loopback listener тоже закрыты. Production PID/binary/config
не менялись. Socket-control driver 0/0 означает завершение контроля,
**не устранение NETCALL**. Push/релиза нет.
