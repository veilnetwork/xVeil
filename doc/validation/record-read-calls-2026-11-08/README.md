# Проверка receive budget в звонках Poco ↔ Mac

**NETCALL-01 открыт.** SDK `92cebc7e` проверен в двух отдельных звонках через
два изолированных Core, с четырьмя реальными переключениями сети. Старые
8,6 с не повторились. Зафиксирована другая конкретная пауза: native RX Poco
не продвигался ≥2666 мс, пока Mac продолжал выдавать аудиопакеты.

## Сборки и стенд

Android, Mac и оба Core собраны из одного чистого SDK `92cebc7e`. Снимок
source/config, build logs, mount identity внешнего target, форматы ELF/Mach-O,
SHA, подписи, загрузка dylib, фактические APK и `/proc/.../exe` сверены.
208 C exports сохранены. Android APK отличается только Rust FFI; AOT,
медиадвижок, HVS и seeds не менялись. Mac использует прежний immutable QA app
с явно загруженной новой FFI. Это не квалификация текущего Flutter frontend
по одному совпадению исходников.

У каждого Core проверен собственный advertise host; только явный сосед,
bootstrap/builtin seeds/PEX отключены. Production PID, бинарники и конфиги
проверены до и после. Все active media observations — relay, P2P запрещён.
План и harness зафиксированы до старта. Второй звонок — отдельный call ID
на тех же процессах. Это не A/B с прежним SDK или фиксированным маршрутом.

## Результаты

В каждом case window критерий окончания — пять последних samples с native
RX age ≤1000 мс и ростом RX counter в обоих направлениях. Все шесть окон
прошли; process/call ID внутри звонка сохранились, worker-stalled samples — 0.
Этот критерий не исключает паузы внутри окна. Речь, слышимость человеком,
эхо, непрерывная речевая нагрузка и mouth-to-ear не квалифицировались.

| Звонок / этап | Maximum native RX age Poco / Mac, мс |
|---|---:|
| 1: Wi-Fi baseline | 297 / 399 |
| 1: Wi-Fi → Cellular | 2867 / 1485 |
| 1: Cellular → Wi-Fi | 330 / 380 |
| 2: Wi-Fi baseline | 43 / 355 |
| 2: Wi-Fi → Cellular | 1205 / 1225 |
| 2: Cellular → Wi-Fi | 730 / 619 |

На Poco независимый локальный collector дал **530/530** успешных HTTP rows,
maximum request 270 мс, maximum sample-start gap 880 мс. Локальный native log
содержит все 2713 payload-RTP cell keys первого host log и второй звонок.

Во всех собранных endpoint/Core logs новый `read_timeout` **не наблюдался**.
Следовательно, физически проверена работа новой сборки, но сам новый timeout
в этих звонках не был свидетелем ремонта. Его срабатывание и изоляция child
доказаны компонентными/аутентифицированными TCP-тестами прошлого раунда.
Причинное устранение пауз этим изменением не объявляется.

## Точное сопоставление

Используются source RTP header witnesses, nonce/index и полные SHA opaque
cells, затем роль-нейтральные Core observations и authenticated endpoint RTP.
Реле не определяли тип аудио по epoch или содержимому. Сравниваются наборы
конкретных identities, а не только количества; source header duplicates — 0.

- **Poco → Mac:** 4432 source cells / 4439 packet witnesses. Для 4384 cells
  совпадают точные наборы Core ingress, Core selection к Mac и authenticated
  Mac receipt. Для 48 receipt не наблюдался: 33 без relay-queue witness,
  15 с таким witness. Это не доказательство NIC loss. Source sealing →
  handler-enter максимум 7,291 мс, → relay admission максимум 7,491 мс.
- **Mac → Poco:** 5009 source cells / 5033 packet witnesses; все 5009 видны
  на Core ingress, 4921 имеют selection именно к телефону. Для 4772 есть
  одновременно matching full received-cell hash и RTP headers. Ещё у одного
  есть совпавшие received RTP headers, но нет строки полного received-cell
  hash: он **не включён** в строгий набор. У 236 RTP receipt не наблюдался.
  Сами по себе эти отсутствия не названы доказанной потерей пакетов.

## Локализация паузы 2,7 с

Самая длинная неподвижность RX counter Poco лежит примерно в **21,4–24,1 с
после команды перехода на Cellular**, а не только в первоначальном handover.
В строгом внутреннем host-интервале native TX counter Mac вырос на 27.

Внутри этого интервала по времени source sealing найдены **45** конкретных
payload-RTP cells. Все 45 имеют Core ingress; только один имеет Core selection
именно к телефону и authenticated receipt. Остальные **44** не имеют такого
наблюдения отправки/приёма. Intermediate selection к другому Core не считается
отправкой к телефону. Дубли одного cell на двух путях не считаются новыми cells.

Это сужает данный случай до обработки между Core ingress и last-hop selection;
точная очередь, отказ или ветвь routing ещё не установлены. На одном Core в
перекрывающемся clock-bounded окне есть `independent_fifo_wait`: depth 66–68,
canonical writer capacity 0. Однако эта старая строка не содержала peer/session,
поэтому **нельзя доказанно приписать её именно очереди к телефону**. На другом
Core наблюдается новая сессия телефона. Точность межхостовых clock bounds
не позволяет выбирать причинный таймер по одному совпадению времени.

SDK `09b84565` добавляет peer prefix в существующий operator-only FIFO trace.
Это только диагностическая правка после физической серии: **12 writer-progress
tests passed**, без ignored, rustfmt/diff-check прошли. Звонки выше содержали
`92cebc7e`; новая строка в них отсутствует и задним числом не атрибутирует
старые события. Anonymous export/allowlist не расширялись.

Следующий шаг — проверить точную per-session очередь и воспроизвести блокировку
neutral transit за ordinary stream head. Политику ролей, WRR, квоты и wire hints
нельзя менять по одному совпадению. Отдельно остаются клетки с last-hop admission,
но без authenticated receipt; эта ветвь данным случаем не объяснена.

## Сохранность и завершение

Core archives и каждый файл проверены по SHA; journal tail и trace limits не
достигнуты. Raw cell/RTP metadata, адреса, identities и ключи остаются только
в private operator cache. Ошибка первоначального универсального join guard
выявила одиночный missing hash witness на Poco; ослабленный результат не
выдан за полный hash match, соответствующая категория вынесена отдельно.

Точные native logcat descendants остановлены до pull; логи сверены после
остановки. Collectors/keys/private directories удалены. Собственные Core,
observers, sockets, stage/config/state/unit/binaries убраны. QA APK, неизвестный
root QA container, основной APK, mic grant, сеть, stay-on, sampling property
и P2P choices восстановлены и проверены. Mac app завершён; после grace потребовался
SIGKILL, что не скрыто в private cleanup proof. Runtime/debug output убраны,
подпись app проверена. Production не менялся. Push/релиза нет.
