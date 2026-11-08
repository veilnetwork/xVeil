# NETCALL-01: проверка eager ordered readiness на Poco ↔ Mac

**SDK `e136c71f` физически квалифицирован, паузы звука не устранены.**
Два звонка с четырьмя реальными Wi-Fi ↔ Cellular переключениями дали
**6/6 успешных финальных окон**. В первом звонке native RX телефона стоял
**4822 мс** при продолжающейся отправке Mac. Новая packet/record-привязка
локализует этот эпизод между Core ingress и выбором транспорта к телефону.
Причина отказа на этом участке пока не установлена.

## Происхождение сборок и метод

Android FFI, Mac FFI и два Linux QA Core собраны из одного immutable
`e136c71f`. SHA каждого нового native artifact отличается от предыдущего
проверенного `5f194c38`; проверены 208 C exports, post-codesign SHA Mac,
фактическая mapped library, установленный APK, его signer/alignment и
неизменность остальных ZIP payloads. Dart/AOT, media engine, hidden-volume
и seeds заморожены; readonly observer имеет отдельное проверенное происхождение.
Это квалификация новой SDK в прежнем frontend, не выпуск новой полной сборки.

До звонков сохранены критерии: неизменные call ID/PID, валидированная целевая
сеть, relay-only media, растущий native RX counter и последние пять age-срезов
≤1000 мс на обоих концах. Паузы внутри успешного окна учитываются отдельно.
Каждый звонок содержит baseline, Wi-Fi → Cellular и Cellular → Wi-Fi; после
каждого переключения наблюдение продолжается 60 секунд. Источник — настоящие
микрофоны, ambient/DTX. Слышимость человеком и непрерывная речь не проверялись.

Подготовительная проверка record logger сначала отказала до первого аудио:
на свежем стенде ещё не было record events. Звонок тогда не запускался,
это не product failure и не пройденная квалификация. Live smoke перенесён
после первого устойчивого native audio baseline, **до handover**; на обоих
Core проверены реальные record events. После этого measurement/cleanup
harness зафиксирован и не менялся. Все 1111 SDK source hashes и 42 hashes
подготовленных helper-файлов сверены после двух звонков.

## Результаты

| Звонок / фаза | Финальное окно | Наибольший native RX age Poco / Mac |
|---|---|---:|
| Первый, Wi-Fi baseline | passed | 67 / 378 мс |
| Первый, Wi-Fi → Cellular | passed | **5302 / 2030 мс** |
| Первый, Cellular → Wi-Fi | passed | 1110 / 1036 мс |
| Второй, Wi-Fi baseline | passed | 52 / 366 мс |
| Второй, Wi-Fi → Cellular | passed | 1189 / 1277 мс |
| Второй, Cellular → Wi-Fi | passed | 236 / 503 мс |

Age-превышение само по себе не доказывает потерю речи: DTX может давать тишину.
Поэтому существенные эпизоды ниже дополнительно проверены по peer TX,
локальному collector и конкретным payload-RTP cells. Серия не A/B; ни ускорение,
ни регрессия относительно прошлого максимума 2,6 с причинно не объявляются.

## Подтверждённая пауза приёма на телефоне

В первом Cellular-окне после переключения, уже при работающем звонке:

- Host native RX Poco не менялся **4821,8 мс**, age достиг **5302 мс**.
- Восемь host-срезов отправителя строго внутри этого интервала дали
  **+63 native audio TX** на Mac.
- Семь независимых локальных срезов телефона строго внутри clock bounds
  содержат тот же неизменный native RX counter. Это не остановка ADB-наблюдения.
- Встречный путь продолжал работать: **27** phone-origin cells получили
  authenticated RTP receipt на Mac строго внутри той же паузы.

Строго внутри интервала найдена **81** Mac-origin payload-RTP cell с
source relay-send witness. Для всех 81:

1. Обе source copies имеют локальные flush и соответствующие Core reads:
   **81/81 на каждом Core**. Full opaque SHA связывает их с теми же cells.
2. На Core A наблюдается дальнейшая отправка к Core B; все эти **81 records**
   также прочитаны на Core B. В сумме Core B принимает 162 входа этих
   payloads — напрямую и через соседа. Это не 162 логических аудиоклетки.
3. Нет наблюдаемого `transport_selected` к телефону или authenticated
   target RTP receipt для этих 81 cells.
4. Парные synchronous dispatch границы на A занимают максимум **96 мкс**,
   на B — **423 мкс**. Обработка не зависала внутри dispatcher на все 4,8 с.

Следовательно, в этом конкретном эпизоде первый участок Mac → Core доставил
данные, а frontier находится **до выбора последнего транспорта к телефону**.
Это не доказательство конкретного `Missing`, `Closed`, Full, dedup или
route-miss: нынешняя opaque trace не несёт фактический исход queue admission
и ветвь отказа dispatch. Входы/выходы сами по себе этого не различают.
Успешный flush по-прежнему не считается remote ACK; здесь отдельно есть
remote `read_complete` для первых участков.

В том же первом переключении найден и другой эпизод: RX Mac стоял
**1567 мс**, native TX телефона продолжался. Внутри него 15 phone-origin
source cells с relay-send witness не наблюдались на Core ingress; у них
нет record-send-attempt witness. Это другой участок пути; его нельзя
объяснять выводом о 81 Mac-origin cells.

## Покрытие всего захвата

Poco → Mac: 4126 source cells; одна без relay-send witness. **Точные наборы**
Core ingress, target selection и строгого authenticated RTP receipt равны
и содержат **4083** cells. Остальные отсутствующие observations не объявлены
доказанными wire drops.

Mac → Poco: 6164 source cells, 6164 Core ingress, 6069 target selections и
5941 строгий RTP receipt. Поэтому эта серия не является полным прохождением
доставки каждого исходного audio payload, несмотря на шесть финальных окон.

На Core сохранены 138979 и 138057 journal lines, tail limit не достигнут;
record/opaque trace limit markers не наблюдались. Stage-агрегаты относятся
только к сопоставленным observations и не заменяют отсутствующие границы.

## Что проверено и что дальше

Ранее `e136c71f` прошёл regression-red, **710 session passed / 8 ignored**,
scoped Clippy и Android release FFI check. Новый физический прогон проверяет
работоспособность сборки в звонках/переключениях. Отдельный 250-мс readiness
дефект исправлен; причиной пауз в 1,6/4,8 с он этим прогоном не доказан.

Следующий шаг — bounded per-cell observation фактического исхода постановки
в outbound registry на Core: accepted / missing / closed / full, с привязкой
к той же opaque cell и адресату. Затем повтор захвата должен отличить отказ
маршрута/регистрации от принятых, но не выбранных queued frames. Anti-abuse,
ownership, FIFO, квоты и авторизационные барьеры ради этого не ослабляются.

## Гигиена

Все собственные приложения, observers и collectors завершены, их PID/ports,
runtime и device directories/keys проверены. Mac потребовал SIGKILL после
grace; это явно учтено. QA/основной APK и старый QA-контейнер совпали по SHA
с исходным состоянием; permissions, properties, Wi-Fi/mobile, stay-on и P2P
восстановлены. Изолированные QA Core/observers остановлены до выгрузки,
затем удалены их unit/config/binary/state/runtime/stage. Production
PID/restarts/binary/config дополнительно сверены с исходным baseline.

Архивы выгружались bounded chunks с проверкой prefix SHA, полного archive
и каждого member; cleanup не зависел от завершения долгой выгрузки.
Rust builds использовали проверенный внешний mount и watchdog; все build
процессы завершены. Raw IDs, адреса, hashes и RTP metadata остались только
в private capture. Push/релиза и sibling mailbox нет.
