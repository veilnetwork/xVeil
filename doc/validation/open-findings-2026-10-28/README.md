# Открытые случаи — обновлено 2026-11-11

## Текущие приоритеты владельца

- **Задержка догрузки — backlog.** По указанию владельца дальнейшая оптимизация
  отложена до отсутствия других задач или новой жалобы. Она не объявлена
  исправленной. Последний retained native Mac/JIT контроль 100000 сообщений —
  примерно 103–109 с; незавершённый conditional-read кандидат снят из рабочего
  дерева и сохранён локально. Повторная A/B/A серия прервана, её частичные
  результаты не считаются квалификацией. Ниже остаётся исторический журнал;
  прежнее «latency активна» не отменяет этого решения.
- **Потеря доступа после сжатия — открытый пользовательский случай.** На
  реальной библиотеке два пространства с разными паролями пережили сжатие
  в обоих порядках; исходное повреждение не воспроизведено. Подтверждены и
  исправлены повторные записи одного пароля в списке, зависание окна при
  ошибке и выход системной кнопкой «Назад» без восстановления сессии.
  Физический Android-сценарий со второй личностью через «Начать заново»
  выявил потерю результата при redirect и исчезновение сборщика до rewrite;
  эти переходы исправлены. На Blackview обе личности и данные пережили
  сжатие и полный перезапуск процесса. Потеря доступа после перезапуска
  остаётся невоспроизведённой; Android crash во время rewrite ещё не проверен.
  Дополнительно исправлена попытка ручного сжатия автоматически вызвать unlock
  после завершившегося lock. Mac native SIGKILL до rename в трёх точках сохранил
  исходный контейнер и оба пароля. Следующий раунд подтвердил stale-open в
  авто-сжатии и возможность native rename вернуть файл после раннего unlink;
  добавлены lifecycle-guards, барьер перед wipe и очистка временных копий.
  [Доказательства и границы проверки](../compaction-maintenance-2026-11-11/README.md).
  На Blackview normal/cold и один process-kill до rename сохранили обе
  личности; UI-wipe удалил основной файл и реальный orphan. Исходное повреждение,
  потеря питания и остальные стадии crash не объявлены проверенными.
  [Проверки и границы результата](../compaction-two-spaces-2026-11-11/README.md).
- **Упрощение текстов:** справка по «?», краткие пояснения и раскрываемые
  подробности внесены в onboarding, storage, quick unlock, devices и discovery.
  Предупреждения об удалении личностей и раскрытии быстрого входа остаются
  видимыми; сертификат скрыт, одноразовость кода выделена красным и жирным.
- **Добавление/установка серверного узла по QR без SSH — следующая задача.**
  Нужны отдельные скрипты и защищённый канал управления с телефона; основной
  бинарник Veil менять для размещения скрипта не требуется. Новый поток пока
  не реализован и не выпущен.

## 2026-11-10: checkpoint-overlap кандидат отклонён после A/B/A

[Gate-проверки, native контроль и отрицательный результат](../history-checkpoint-boundary-100000-2026-11-10/README.md):
раннее освобождение conversation lane позволяло второму источнику идти при
удержанном cursor-write; shutdown и собственный durable checkpoint сохранялись.
Но на 100000 **103189→109044→103119 мс**, passive witness
**101455,349→103753,815→99693,066 мс**. Ускорения нет; кандидат и его тесты
убраны, текущий product/test код восстановлен. 206 tests относятся к кандидату.

Все 100001 строки exact/cold, callbacks/commits/wire counts сохранены;
1544 frozen inputs, native provenance/mappings/cleanup проверены. Перекрытие
apply с самой записью cursor нулевое; admission до/после неё probe не охватывает.
Следующий участок — последовательные metadata/payload RPC свежего чтения
журнала устройств, без кеша принятой авторизации. Latency остаётся открытой;
другие фронты без изменений. Это отчёт об отборе, не новый production fix.

## 2026-11-10: готовая позиция mirror не требует повторного ordering lookup

[Четыре parent-red и native A/B/A](../mirror-settled-order-100000-2026-11-10/README.md):
исходная или уже исправленная effective position совпадает с входящей —
повторная author resolution/point read не выполняются. Delivery repair и
нужная ordering correction сохраняют свежие чтения/admission; deletion race
проверена. Новый кеш не добавлен. 203 related passed, 0 skipped, analyzer чист.

100000: point reads **499747→399747→499747**, время
**108294→103755→108034 мс**; passive witness
**106194,923→102242,746→105725,350 мс**. Локальный выигрыш около 3,5–4 с;
все 100001 строки exact/cold, callbacks/commits/wire counts сохранены.
1544 frozen inputs, один production variant, provenance/mappings/cleanup
проверены; cache 92→92. Latency около 104 с остаётся открытой, другие фронты
статус не меняют. Без push/релиза; sibling mailbox не добавлялся.

## 2026-11-10: history ingress перекрывает до четырёх свежих проверок

[Две parent-red, bounded queue и native A/B/A](../history-inbound-parallel-100000-2026-11-10/README.md):
один медленный roster lookup больше не паркует все входящие history-кадры.
Четыре handler slots, FIFO waiters, прежние byte/frame caps и каждый свежий
admission сохранены. Page apply/cursor остаются последовательными по разговору.
169 history + 13 admission tests passed; отдельная focused-серия пересекается,
analyzer чист. Ошибочный mailbox-вариант теста исправлен и не засчитан.

100000: **118621→108555→118537 мс**; passive witness
**114110,520→103666,534→113753,552 мс**. В этой локальной серии около 10 с выигрыша;
все 100001 строки exact/cold, commits/callbacks/wire counts совпадают.
RPC ownDevices/kv.getBatch **23632→12654→23310** без кеша завершённого verdict.
1544 frozen inputs, один production variant, native provenance/mappings,
полнота raw traces и cleanup проверены. Старый page-profile порог не пройден
для B (692/782 при пороге 700), его не снижали; полное per-page разложение
не заявляется. Cache 92→92. Latency/NETCALL/остальная matrix открыты;
новые изменения без push/релиза, sibling mailbox не добавлялся.

## 2026-11-10: read-проверки устройств не двигают часы подписанных событий

[Пять parent-red, native A/B/A и полная трасса ожиданий](../device-admission-clock-100000-2026-11-10/README.md):
часы трёх admission-кешей и публикации cache timestamps переведены с mutation
counter на wall clock. 31000 чтений больше не расходуют 30-секундный lease;
rollback вызывает свежее чтение. Подписи, generation/revoke fences и новые
подписанные мутации сохраняют прежние проверки. 662 passed / 11 skipped,
analyzer чист; пропуски отдельно, без нового кеша авторизации.

100000: **124466→118678→124565 мс**, passive post-page witness
**120866,920→116782,112→121640,936 мс**. В этой локальной серии есть выигрыш;
универсальное ускорение не заявляется. Все 100001 строки exact/cold, оба
cursor, commits/callbacks и wire counts совпали. 1544 frozen inputs, один
production variant; provenance/mappings/cleanup проверены, cache 92→92.
Первый capped диагностический захват исключён; новые три трассы полны.
Latency около двух минут, NETCALL и остальная matrix открыты. Без push/релиза.

## 2026-11-10: повторный mirror не читает ту же строку дважды

[Cost regression, свежий профиль и native A/B/A](../mirror-point-read-100000-2026-11-10/README.md):
три parent-red, 208 related и отдельно 32 focused passed (серии пересекаются),
analyzer чист. Первое свежее point read используется и для наличия, и для
немедленного delivery-status; ordering после author-admission читает заново.

100000: point reads **599747→499747→599747**, все 100001 строки exact/cold,
оба cursor и 200002 callbacks сохранены; commits сообщений 391, cursor 784.
Время **123954→123687→123644 мс**: общего ускорения нет. 1544 frozen inputs,
один production variant, native provenance/mappings и cleanup проверены.
Кеш 92 entries, новых entries нет. Latency/NETCALL/остальная matrix открыты;
новые изменения без push/релиза, sibling mailbox не добавлялся.

## 2026-11-10: опубликованы Veil 0.11.49 и xVeil 0.13.96+115

[Проверки артефактов и развёртывания](../release-2026-11-10/README.md).
Порядок зависимостей соблюдён; hidden-volume остался на 2.7.0. Все шесть
production и три testnet-службы обновлены, конфигурации сохранены, независимые
health/DHT/проверки бинарников прошли. Звук Windows и биометрический вход
квалифицированы в описанных ранее границах. Латентность и оставшаяся матрица
сохраняют прежний статус. Жалоба на экран входящего звонка на заблокированном
Android снята с открытых по подтверждению владельца: всё работает нормально.
Это пользовательское подтверждение; новый стендовый прогон не выполнялся.

## 2026-11-10: звук Windows и биометрический вход квалифицированы

[Звук](../windows-audio-output-2026-11-10/README.md): явный «Системный выход»,
проверяемое переключение и исправленное освобождение ADM на COM-потоке.
Реальный DLL-контроль: 4 отказа до lifetime-правки, 4 прохождения после;
три полных цикла звонок/смена выхода/lock/unlock прошли. На окончательной
библиотеке владелец подтвердил живой голос в обе стороны Android ↔ Windows.
Старый отдельный `0xc0000409` этим не объявляется причинно объяснённым.

[Биометрия](../quick-unlock-independent-methods-2026-11-10.md): исправлена
зависимость настройки startup-входа от повторного ввода screen pattern;
35 тестов, физический вход без pattern после перезапуска с той же QA-личностью.
Владелец подтвердил один запрос при повторном lock/unlock. Исходное состояние
настроек автора жалобы неизвестно; оно не переобъявляется воспроизведённым.

Стенд остановлен, основные приложения и контейнеры не менялись. Подготовка
релиза описана [отдельно](../release-2026-11-10/README.md); публикация pending.

## 2026-11-10: page читает окно без полного слияния свежего архива

[Cost regression и native A/B/A](../history-page-window-100000-2026-11-10/README.md):
source при двух sorted runs сливал все 100000 строк перед каждой page.
Теперь свежий order scan + binary lookup в каждом run + bounded merge окна;
для произвольных раскладок — прежняя сортировка копии. Prefix/digest остаются
полными свежими снимками. Кеш авторизации/снимка или новый индекс не добавлен.
Parent **300273 timestamp reads**, candidate ≤101000 на реальном call site.

1082 related passed / 0 skipped, analyzer чист, 1540 frozen inputs / два variants.
Все 100001 строка и cold retention точны, оба cursor, callbacks/commits/wire
counts сохранены. Общая проверка **139095→133964→134346 мс**, passive inventory
**133328,659→130369,313→131451,491 мс**: ускорение всего пути не доказано.
IO/authorization/commit остаток около 190 мс после reply остаётся следующим
участком. Cleanup/provenance проверены; кеш 92 файла / около 9,5 ГиБ.
Latency/NETCALL/остальная matrix открыты. Push/релиза нет.

## 2026-11-10: read marker и shown clock не переходят между личностями

[Исправление и native 100000](../read-marker-session-100000-2026-11-10/README.md):
`markRead`/`setReadMarker` могли после await записать timestamp в другую личность
или понизить более новый marker. Общий принятый metadata turn привязан к store,
упорядочен по разговору и дренируется перед close/open/erase. Поздние client
read/shown/expiry callbacks остановлены; shown-clock RMW сериализован отдельно
от message scan, без найденного в intermediate candidate lock inversion.
Другой разговор продолжает работу.

12 storage + 5 client parent-red, отдельный assertion-red собственного lock
inversion; 21 focused / **1062 related passed, 0 skipped**, analyzer чист.
Оба native parent случая меняли marker B **1000→2000000**, оставляя marker A 0;
оба candidate сохранили B=1000 и A=2000000, все 100000 строк точны после cold
reopen. Provenance/current sources и cleanup проверены. Это не объяснение
исторических жалоб и не измерение ускорения. Кеш около 9,5 ГиБ, free около
147 ГиБ. Latency/NETCALL/остальная matrix открыты. Push/релиза нет.

## 2026-11-10: меньше повторных проверок manifest в own-device read

[Cost regression и native A/B/A](../routing-manifest-fold-100000-2026-11-10/README.md):
подпись одного manifest проверялась для каждой control row одного синхронного
routing fold. На 12 целях **14→2**, подписи строк и новое fresh чтение сохранены.
Межоперационный кеш авторизации не добавлен. Parent assertion-red; **785 passed /
0 skipped**, analyzer чист; финальный regression отдельно подтверждён JSON events.

100000: финальная проверка **133940→128700→133909 мс** с шагом опроса 5 с;
passive post-page inventory **129930,715→127463,272→131586,497 мс**.
Ускорение в одной локальной серии не обобщается на весь продукт. Все 100001
строка, оба cursor, cold retention, 200002 callbacks, commits и wire/page counts
сохранились. 1537 frozen inputs / один production variant; provenance/cleanup
проверены. Кеш 92 файла, новых entries 0; source snapshots сжаты со сверкой SHA.
Latency/NETCALL/остальная matrix открыты. Push/релиза нет.

## 2026-11-10: новый профиль получателя на 100000

[Диагностический native прогон](../history-receiver-profile-100000-2026-11-10/README.md)
на текущем `d3f7dd49`: **100001 точная строка**, оба cursor и cold retention
прошли; 200002 callbacks / 782 message commits. CPU capture — 96844 физических
samples после дедупликации/исключения конфликтов; покрытие/усечения и terminal
ошибка закрывшегося endpoint явно учтены. Это не A/B: 144199 мс с sampler не
сравниваются с прежними примерно 134 с без него.

Следующий кандидат — fresh own-device routing read, всё ещё проходящий через
bundle/message processing (24165 header/segment batch loads); его ненужность
и ускорение не заявлены. Синхронные durable commit тоже видны в native stack,
их гарантии не ослаблялись. Production-код не менялся. Cleanup 49 PID / 84 порта
чист; CPU evidence сжат 406,24→17,99 МиБ с SHA-проверкой, кеш около 9,5 ГиБ.
Latency/NETCALL/остальная matrix открыты. Push/релиза нет.

## 2026-11-10: меньше metadata RPC без кеша авторизации

[Проверка и native A/B/A](../file-metadata-pair-100000-2026-11-10/README.md):
свежие metadata двух файловых хранилищ читаются одним существующим worker batch,
затем применяются прежние payload/ceiling/first-failure guards. Максимум 16 ключей
для восьми файлов. Приоритет external tier, ошибки и session/erase guards
сохранены; metadata handoff владеет snapshot и не переживает вызов.

На 100000: RPC **178428→130880→178845**, passive post-page inventory
**130635,787→128165,257→130514,942 мс**. Общая сходимость **133789→133758→
133675 мс**: ускорения всего пути не выявлено. Все 100001 строка, оба cursor,
cold retention, message/cursor commits и wire/page counts сохранились.

Два parent assertion-red, **748 passed / 1 skipped**, analyzer чист, 1537
frozen inputs / два production variants, provenance/cleanup проверены.
Кеш 92 файла, новых kernel entries нет. Latency, NETCALL и остальная matrix
открыты. Push/релиза нет.

## 2026-11-10: физический scrub сохраняет актуальный point-patched fold

[Исправление и два native A/B/A](../message-scrub-fold-100000-2026-11-10/README.md):
успешная очистка без изменения логических IDs сбрасывала уже актуальный fold.
Новый 100000-row parent-red видит 100000 лишних range records. Для point
мутаций сохраняется warm fold, а пять bulk путей явно инвалидируют его;
неопределённый исход commit/scrub по-прежнему принудительно обновляет кеш.
Физический vacuum и durable cleanup obligation выполняются полностью.

Erasure fixture: **300027→27→300027** message range records, активные восемь
проходов **1838,679→903,984→1758,672 мс**, запросы/digest/bytes и 99996 точных
строк после cold reopen совпали. Выигрыш относится к этому участку.
Сквозная догрузка 100000: **133383→133702→133927 мс** — общего ускорения нет.
Все 100001 строка, оба cursor, cold retention, 200002 callbacks, message/cursor
commits и wire/page counts сохранились. Это не закрытие latency.

**709 passed / 1 skipped**, analyzer чист, 1537 frozen inputs в full-стенде,
один production variant, provenance/cleanup проверены. Кеш 92 файла, новых
kernel entries нет, свободно около 147 ГиБ. Anti-entropy cadence, NETCALL и
остальная matrix открыты. Push/релиза нет.

## 2026-11-10: void не попадает в другую личность и не дублируется

[Подтверждение и исправление](../void-session-100000-2026-11-10/README.md):
служебная запись занятого author/seq слота читала старый журнал до commit,
но не входила в принятый lifecycle turn. После open другой личности она
могла записать туда чужие метаданные. Два конкурентных повтора также создавали
два void одного слота. Два unit parent-red подтверждают оба механизма.

Чтение/idempotency/commit/patch теперь в существующей per-conversation/author
очереди. Maintenance ждёт всю принятую операцию, поздние вызовы отклоняются,
разные авторы не блокируют друг друга. ACK/auth/wire/mailbox прежние.
Native negative control: все 100000 канареек целы, но одна foreign void-запись
сохраняется после cold reopen. Candidate: **100000/100000**, foreign events
**0**, нужный void seq 2 находится только в исходном контейнере.

**700 passed / 1 skipped**, analyzer чист; native smoke всех четырёх lifecycle
операций на 512 строк, provenance/frozen inputs/cleanup проверены. Это
подтверждение storage API, не доказательство эксплуатации на пользовательских
данных или всей multi-device matrix. Кеш 92 файла / около 9,5 ГиБ; latency,
NETCALL и прочие проверки остаются открытыми. Push/релиза нет.

## 2026-11-10: erasure pages без лишнего UI ordering

[Проверка и native A/B/A](../erasure-rows-100000-2026-11-10/README.md):
ради двух erasure-страниц клиент сначала строил ненужный display order
всего разговора. Новый 100000-row parent-red показывает 100000 строк через
UI path вместо нуля. Использован существующий свежий detached row reader;
fallback/error, overlays, erasure/revoke/requested-key guards прежние.

Native 100000 / 32 разговора, восемь проходов: **2174,328 → 1824,236 →
2229,214 мс** суммарной активной локальной подготовки запросов. UI rows
**795990→0→795990**, 260 запросов / 94103 JSON bytes и их точные digest
совпадают. Все 99996 ожидаемых строк и четыре удаления сохранены после cold
reopen. Это не время всей догрузки и не ограниченное чтение только 400 строк.

**577 passed / 1 skipped**, analyzer чист, provenance/frozen inputs/cleanup
проверены; cache 92 файла / около 9,5 ГиБ. Весь разговор всё ещё читается
и сортируется; полный обход старой истории, latency, NETCALL и остальная
multi-device matrix остаются открытыми. Push/релиза нет.

## 2026-11-10: ротация старых чатов больше не пропускает страницы навсегда

[Подтверждение и исправление](../erasure-rotation-100000-2026-11-10/README.md):
общий round для выбора старого разговора и его страницы при общем делителе
периодов оставлял часть страниц непроверяемой. На ровно 100000 сообщений /
32 разговорах два из четырёх удалений не дошли после восьми проходов,
включая перезапуски MessagingService и native cold reopen.

Страница старого разговора теперь продвигается по числу его посещений.
Persisted round, запросы, throttle и admission/authentication/requested-key
границы прежние, лишнего I/O нет. Native parent оставляет 99998 строк;
candidate сохраняет ровно **99996/99996** ожидаемых строк, все четыре удаления
применены, дублей/лишних потерь нет. Это не ускорение полного обхода истории.

**576 related checks passed / 1 skipped**, 272 сочетания периодов в двух
фазах, analyzer чист. SHA/mapping native inputs и cleanup проверены;
cache 92 файла / около 9,5 ГиБ. Длительный полный обход, latency, NETCALL
и оставшаяся multi-device matrix открыты. Push/релиза нет.

## 2026-11-10: старое удаление не затрагивает другую личность

[Подтверждение и исправление](../message-erasure-session-100000-2026-11-10/README.md):
подготовка delete/clear/prune не учитывалась в drain перед сменой backing space.
После переключения старая операция могла переписать внутренний log slot
другой личности. Три unit parent-red теряют её тело; настоящий native negative
control сохраняет **99999/100000** строк. Это подтверждённый storage API-дефект,
не доказательство потери пользовательских данных в эксплуатации.

Вся принятая операция теперь входит в существующий write drain, включая
подготовку. Новые запросы после fence отклоняются; ошибки освобождают барьер.
Native delete/clear/prune: **100000/100000** точных строк второй личности
в каждом сценарии, удаление первой сохранено после повторного открытия.
**559 checks passed / 1 explicitly skipped**, analyzer чист. Native provenance,
неизменность inputs, восстановление candidate и cleanup проверены.
Кеш остался 92 файла / около 9,5 ГиБ. Wire/authorization/mailbox не менялись.
Latency, NETCALL и оставшаяся multi-device matrix открыты. Push/релиза нет.

## 2026-11-10: меньше durable publications при прежнем payload budget

[Исправление и native A/B/A](../history-cohort128-100000-2026-11-10/README.md):
prepared row ceiling **64→128**, прежние **1800 bytes/row / 115200 payload
bytes** проверяются до записи. Отказ крупного набора сначала разбивается
на части до 64, затем использует прежний ordinary fallback. Число одновременно
подготовленных строк выросло до 128; byte/page/admission bounds прежние.
Fresh admission, durable completion, erasure/revoke и cursor barriers сохранены,
резервы prepared-пути по-прежнему ограничены 256. Sibling mailbox/cache авторизации нет.

Два parent assertion-red; byte-boundary −1/0/+1 для posts/ordering, меньший
adapter, fault между частями и native cold restart. **400 passed / 0 skipped**,
analyzer чист. На 100000: **144,010 → 133,706 → 144,067 с** — около 7% выигрыша
в этом локальном JIT-сравнении; passive witness подтверждает сокращение этапа.
Message commits **1563→782→1563**, cursor commits/page/byte counts и 200002
callbacks прежние. Один дополнительный allocator commit в candidate учтён
отдельно. Все ID/body/status/order, оба cursor и cold retention совпали.

Отдельный SIGKILL после 50048 durable архивных строк: до сети сохранены они,
прежняя строка и оба точных cursor; только A вернулся и завершил 100001 строку,
ещё одно cold offline открытие сохранило результат. Это не все crash windows.
1532 frozen inputs, три production variants; candidate восстановлен, cleanup
всех прогонов прошли, cache 92 entries. Собственные CPU JSON сжаты losslessly.
Latency (~134 с), NETCALL-01, физическая/AOT квалификация и остальная matrix
остаются открытыми. Push/релиза нет.

## 2026-11-10: без временной политики — без лишней проверки каждой строки

[Исправление и native A/B/A](../history-unrestricted-100000-2026-11-10/README.md):
после свежего чтения политики не выполняется бессмысленный visibility walk
при выключенных TTL/retention и отсутствии read watermark. История остаётся
свежей и detached, active policy/revoke/consent/publication/cursor guards
сохранены; кэша авторизации или sibling mailbox нет.

Два parent assertion-red на 100000 строк; три проверки смены политики между
запросами. **331 passed / 0 skipped**, analyzer чист. Native:
**149,007 → 148,916 → 149,402 с** — устойчивое общее ускорение не доказано.
Все ID/body/status/order, оба cursor и cold retention совпали. Page/byte counts,
callbacks и message/cursor/allocator commits одинаковы, повторов нет.

1532 frozen inputs, один production variant, candidate восстановлен;
cleanup прошли, cache 92→92 без новых kernel entries. Следующий кандидат —
receiver apply/storage/checkpoint и ожидания между страницами. Latency,
NETCALL-01, физическая/AOT квалификация и остальная matrix открыты.
Push/релиза нет.

## 2026-11-10: SIGKILL посреди догрузки 100000 сообщений

[Новый native crash-сценарий](../history-mid-crash-100000-2026-11-10/README.md):
B остановлен внутри незавершённой 256-row страницы после 49984 durable строк,
не на чистой границе cursor. До сети после SIGKILL сохранены все эти строки,
прежняя строка и оба точных курсора. При возвращении только A восстановлены
все **100001 ID/body/delivered/canonical/order**, без пропусков и дублей;
ещё одно холодное открытие при offline всех источников сохранило результат
и оба cursor. Sibling mailbox не добавлен, production-код не менялся.

Два native smoke на 512 строк и полный сценарий прошли, **34 helper checks /
0 skipped**, analyzer чист. 1532 одинаковых frozen inputs, native provenance
сверена; owned процессы/порты закрыты, synthetic runtime удалён, cache 92 entries.
Первый wire capture оборван SIGKILL и не объявлен полным. Это локальный Mac/JIT
crash внутри страницы, не все fsync/ratchet/ACK windows и не Android/AOT.
Latency, NETCALL-01 и остальные пробелы matrix открыты. Push/релиза нет.

## 2026-11-10: 256 коротких строк в прежнем byte budget

[Исправление и native A/B/A](../history-page256-100000-2026-11-10/README.md):
потолок requested rows 128→256, byte ceiling 128 КиБ, 64 parts и admission
прежние. Подготовка/atomic publication по 64, fresh admission, revoke/visibility,
binding/erasure и durable cursor сохранены. Старым запросам меньшего размера
источник отвечает в их лимите; новый 256-cap требует обновления старого пира,
что входит в принятое владельцем исключение mixed-совместимости.

Два parent assertion-red; отказ четвёртой публикации оставляет 192 durable
строки и прежний cursor, restart завершает 256 без дублей. Byte-boundary,
revoke, sparse-prefix, edit, TTL, replay и cursor recovery проверены.
**321 passed / 0 skipped**, analyzer чист. Три неполностью перенесённых
ожидания тестов исправлены и перепроверены; production-guards не ослаблены.

На 100000: **194,961 → 149,155 → 194,606 с**; passive witness подтверждает
сокращение этапа. Native wire показывает rows **128→256→128** и страницы
**782→391→782** каждого источника, без повторов. Cursor commits **1566→784→1566**,
message/allocator commits и 200002 callbacks прежние; все данные и cold
retention совпали. Выигрыш около 23% относится к этому локальному JIT-стенду.

1532 frozen inputs, один production variant, candidate восстановлен; cleanup
всех фаз прошли, cache 92→92 без новых entries. Latency (~149 с), NETCALL-01,
физическая/AOT квалификация и остальная matrix остаются открытыми.
Push/релиза нет.

## 2026-11-10: settled delivered без повторного roster read

[Исправление и native A/B/A](../history-settled-delivery-100000-2026-11-10/README.md):
после already-delivered mirror без edit не выполняется повторная проверка
членства ради отсутствующей записи. Перед фактически нужной коррекцией
сохранены fresh admission и новое чтение строки; preview не используется
для записи. Publication/checkpoint, binding, revoke и durable guards прежние.
Parent assertion-red: 32 roster calls вместо 1. **314 checks / 0 skipped**,
включая native expiry; analyzer чист.

На 100000: **199,726 → 194,760 → 194,714 с** — общего ускорения не доказано,
passive witness также без улучшения. Roster calls **437509 → 237531 → 437643**,
worker RPC **262252 → 248384 → 261392**: подтверждено уменьшение работы.
Все ID/body/status/order, оба cursor и cold retention совпали. Page/byte counts
одинаковы, повторов нет; callbacks и message/cursor/allocator commits прежние.

1532 frozen inputs, один production variant, candidate восстановлен; cleanup
прошли, cache 92→92. Следующая проверка — ожидания между страницами и размер
порции при прежних byte/admission limits. Latency, NETCALL-01, физическая/AOT
квалификация и остальная matrix открыты. Push/релиза нет.

## 2026-11-10: пустой epoch material без повторной свёртки

[Исправление и native A/B/A](../history-empty-epoch-100000-2026-11-10/README.md):
оба epoch merge пропускают control fold только при пустых keys и обеих
коллекциях envelopes. Любой материал проходит прежнюю проверку, свежая
маршрутизация/revoke и durable barriers сохранены, кэша авторизации нет.
Два parent assertion-red, 750 related / 6 native passed, analyzer чист.
Старое cost expectation routing обновлено с двух folds на один на чтение;
native skip выполнен повторно с нужным fixture.

На 100000: **204,978 → 199,635 → 199,647 с** — общего ускорения не доказано.
`_acceptedControl` folds: **39257 → 4 → 39972**, callbacks/message/cursor
commits одинаковы. Полные ID/body/status/order, оба cursor и cold retention
совпали; страницы/объём одинаковы, повторов нет. RPC total не уменьшился,
разница одного allocator commit не атрибутирована.

1532 frozen inputs, один production variant, candidate восстановлен;
cleanup всех фаз прошли, cache 92→92. Следующий участок — чтения/apply/
сохранение и очереди получателя. Latency, NETCALL-01, физическая/AOT
квалификация и остальная matrix открыты. Push/релиза нет.

## 2026-11-10: потоковый CPU-профиль на 100000 сообщений

[Диагностика получателя](../history-receiver-cpu-100000-2026-11-10/README.md):
полный native-прогон и cold retention прошли для всех 100001 строк, обоих
cursor, статусов и порядка. Повторный захват — 35 chunks, около 240 из 242 с,
без достижения лимита; первый пустой захват отвергнут. Профиль указал на
повторные `GroupService.load` / own-device reads / epoch material; это
кандидаты проверки, а не доказанное устранение задержки. Production не менялся,
тайминг с sampler не сравнивается с сериями без него. Управляющий VM URL и
сырые стеки остаются приватными, приложение helper не импортирует.

23 обычные проверки прошли, VM integration явно skipped; opt-in 24 passed,
analyzer чист. Все 49 owned PIDs/94 порта проверены, runtime удалён. Latency
остаётся активной; push/релиза нет.

## 2026-11-10: резервирование ID для устойчивой пакетной догрузки

[Исправление и native A/B/A](../history-bulk-reservation-100000-2026-11-10/README.md):
durable reserve-before-ID сохранён. Успешные полные prepared-порции прогревают
отдельное окно 64→128→256; обычная политика 8→64, cold reset, fresh admission,
erasure guards, data/shard-marker commit и логические author sequences прежние.
Неиспользованный резерв может дать до 256 пропущенных внутренних ID после
перезапуска этого пути; сообщения и author sequences не пропускаются.

Parent census assertion-red (16 резервов на 1024 строки вместо ≤6).
**393 related passed / 0 skipped**, отдельно 19 native cohort checks,
analyzer чист. Ранние skips и ошибка чтения внутреннего ключа тестом исправлены
и перепроверены; отказ/uncertain reply/меньшая следующая запись/перезапуск
не дают преждевременной публикации или повторного использования выданных ID.

На 100000: **236,448 → 210,112 → 241,398 с**, allocator commits
**1564 → 393 → 1565** при прежних 1563 message / 1566 cursor commits.
Все 100001 строка, порядок/статусы, оба cursor и cold retention совпали;
wire объём одинаков, query retries нет. Общий worker RPC total не уменьшился.
Reply→next-query P50 снизился с 168–171 до 141–147 мс; latency ещё активна.

1531 frozen inputs, один production variant, candidate восстановлен;
все cleanup прошли, cache 92→92 без новых entries. Остаток — apply/очереди,
source scan, NETCALL-01, физическая/AOT квалификация и остальная matrix.
Push/релиза нет.

## 2026-11-09: адаптивная сортировка свежего snapshot

[Исправление и native A/B/A](../history-ordered-snapshot-100000-2026-11-09/README.md):
упорядоченный snapshot проходит линейную проверку, две sorted runs с меньшей
стороной ≤128 сливаются ограниченным буфером; остальное использует прежний
comparator sort. Кэша нет, freshness/visibility/edit/auth/durable gates прежние.

Независимый census во всех фазах подтвердил исходный append order: одно
новое сообщение перед 100000 архивных у обоих источников. Fixture не менялась
ради быстрого пути. Source controls assertion-red на parent, helper work bound
и cap/overlap/fallback проверены. **235 related passed / 0 skipped**, отдельно
16 native HVS, analyzer чист.

Время: **245,623 → 229,741 → 240,844 с**. Все 100001 строка, порядок/статусы,
оба cursor и cold retention совпали; wire объём одинаков, повторов queries нет.
Source query→reply P50 снизился с 87–89 до 78–81 мс. Выигрыш 11–16 с относится
к этому стенду; универсальное ускорение не заявляется. Reply→next-query всё
ещё ~167 мс, latency активна. Следующий участок — подготовка/apply/сохранение
на получателе и оставшийся полный свежий scan источника.

1531 frozen inputs, candidate восстановлен, все cleanup прошли. Cache 92→92,
новых entries 0. NETCALL-01, физическая/AOT квалификация и остальная matrix
без изменений; push/релиза нет.

## 2026-11-09: cursor lookup без повторного обхода префикса

[Исправление и native A/B/A](../history-cursor-window-100000-2026-11-09/README.md):
двоичный поиск в текущем отсортированном snapshot вместо from-zero filter;
не более 17 индексных чтений на lookup для 100000 строк. Единый wire order
milliseconds/ID устраняет расхождение для stores с submillisecond timestamps;
это воспроизведение contract fixture, не заявленный сбой живого HVS.
Fresh visibility/edit/auth/publication/durable gates и page/byte caps сохранены.

Parent order и linear-lookup controls assertion-red; **228 related passed /
0 skipped**, отдельно 16 native HVS, analyzer чист. Во всех native фазах
100001 строка и cold retention совпали, оба cursor завершены. Время:
**235,733 → 246,709 → 245,706 с** — **ускорение не подтверждено**.
Первый контроль содержал один повторный запрос; уникальные страницы и первые
reply parts учтены отдельно. Основная latency остаётся активной.

1531 frozen inputs, два production variants, candidate восстановлен;
все cleanup прошли, cache 92→92 без новых entries. Следующий участок —
повторное построение/сортировка snapshot и apply, без ослабления проверок.
NETCALL-01, физическая/AOT квалификация и остальная matrix без изменений;
push/релиза нет.

## 2026-11-09: разложено межстраничное ожидание на 100000 сообщений

[Stand work spans](../history-work-stages-100000-2026-11-09/README.md):
только test-наблюдатель, production не менялся. Полный native-кейс прошёл:
100001 строка и cold retention совпали, 200002 callbacks, 782 страницы каждого
источника. **235,512 с** — диагностический запуск, не доказательство ускорения.

1520 однозначных page intervals из 1564: P50 полный 164,566 мс; до первого
apply 33,614 мс, busy apply 50,364 мс, cursor write 14,947 мс. Медианы не
складываются; вложенные публикации не прибавляются к apply. 44 неоднозначных
интервала исключены. Cursor не объясняет всё ожидание; следующий участок —
очередь/подготовка до callback и сам apply, без ослабления fresh authorization.

**221 related passed / 0 skipped**, analyzer чист, native-кейс прошёл.
Work trace 1,09 МиБ, dropped=0/active=0; 1529 frozen inputs, cleanup 38 PID/
59 портов. Cache после старта driver 92→92, новых entries 0. Latency,
NETCALL-01, физическая/AOT квалификация и остальная matrix активны;
push/релиза нет.

## 2026-11-09: архив больше не строит ненужный экранный порядок

[Reader и native A/B/A](../history-row-reader-100000-2026-11-09/README.md):
optional чтение текущих rows обходит display projection; собственная raw
timestamp/id сортировка, visibility, before/after edit frontier и authorization
сохранены. Кэша не добавлено; UI и fallback stores не меняют поведение.
Parent source guard assertion-red, **352 related passed / 0 skipped**,
16 native HVS, analyzer чист; read hooks/race guards сохранены.

На 100000 сообщений **281,201 → 245,933 → 271,050 с**; все 100001 строки,
порядок, оба cursor и cold retention проверены. Display calls A/E:
890/909 → 91/113 → 885/906 при одинаковых 782 страницах на источник и
1563 message commits. Source query→reply P50 снизился с 144–157 до 86–96 мс;
reply→next-query остаётся ~167–169 мс. Latency ещё активна (~4 мин 06 с).

CPU profile оказался хвостом ~29–30 с, а не полным окном; из него не выводятся
проценты всего CPU/wall time. Полное сравнение выполнено без sampling,
с 1527 frozen inputs и проверенным cleanup. Cache 92→92, новых entries 0.
Физическая/AOT квалификация, NETCALL-01 и остальная matrix без изменений;
push/релиза нет.

## 2026-11-09: объём увеличен до 100000, полный native-кейс пройден

[Границы стенда и результаты](../history-100000-2026-11-09/README.md):
100000 уникальных архивных плюс одна прежняя строка, два независимых источника.
Итоговые IDs/тела/delivered/canonical positions/порядок и cold retention без
источников совпали полностью. Время **276,836 с**, 782 страницы каждого
источника, 200002 apply callbacks; потерь/дублей нет. Latency ещё активна.

Компактный progress observer не читает все сообщения при каждом опросе и
не может заменить полный oracle. Буферы только у test-наблюдателей подняты;
production limits, fresh authorization, публикации и запрет sibling mailbox
сохранены. **33 helper passed / 0 skipped**, отдельный native-кейс прошёл,
analyzer и privacy проверены. Cache 92→92, runtime/процессы/порты убраны.

Query→reply P50 около 147–149 мс, reply→next-query около 169–170 мс. Медианы
по четвертям не нарастали; следующий кандидат — повторный полный snapshot/
sort у источника, сначала с профилем на 100000. Сравнение с 10000 не является
causal A/B из-за другого observer/setup. Физическая/AOT квалификация,
NETCALL-01 и остальные пробелы matrix остаются. Push/релиза нет.

## 2026-11-09: линейный подсчёт byte budget вместо повторного JSON страницы

[Исправление и контроль](../history-page-encoding-10000-2026-11-09/README.md):
событие учитывается как quoted UTF-8 один раз; metadata и полный финальный
ответ проверяются прежним способом. Page/admission/auth/durable пределы
сохранены. Шесть exact-byte probes проходят на parent/candidate, ошибка
подсчёта +1 даёт две assertion-red. **266 passed / 0 skipped**, 16 native HVS,
analyzer чист.

На 10000 сообщений A/B/A **25,579 → 22,234 → 24,522 с**, число страниц (79
на источник) и message commits (157) одинаково. История 10000+1 и cold boot
проверены полностью. Passive post-page inventory witness также показывает
сокращение этапа без 1000-мс округления observer; это не метка UI convergence.
Source query→reply P50 102–106 → 73–76 мс; остаток apply/next-query и другие
ожидания ещё активны. Следующий запрошенный объём — **100000**.

Cache 92→92, новых entries 0, cleanup и приватность проверены; NETCALL-01,
физическая/AOT квалификация и остальная matrix без изменений. Push/релиза нет.

## 2026-11-09: 128 коротких событий на страницу, публикации остаются по 64

[Изменение и проверка на 10000 сообщений](../history-page-window-10000-2026-11-09/README.md):
bounded `rows: 128` сокращает последовательные запросы при прежнем пределе
128 КиБ/64 части. Каждая публикация по 64 по-прежнему проходит свежие проверки;
cursor сохраняется только после всей страницы. Проверены отказ второй
публикации, revoke, restart, неверные limits, byte budget и oversized records.
**260 passed / 0 skipped**, 16 native HVS, analyzer чист.

Native A/B/A: **33,552 → 25,584 → 34,990 с**, 157 → 79 → 157 страниц каждого
источника, 316 → 160 → 316 cursor commits; message commits неизменны (157).
Все 10000+1 строк и оба cursor проверены, cold boot без источников прошёл.
Это выигрыш локального Mac/JIT стенда; latency остаётся активной (~25,6 с),
физическая квалификация и дальнейшее разложение page-cycle ещё нужны.
NETCALL-01 и остальные пробелы matrix без изменений. Cache 92→92, новых
entries 0, cleanup проверен; push/релиза нет.

## 2026-11-09: bounded повтор ещё недоступных prefix hints

[Исправление и native-квалификация](../history-pending-prefix-2026-11-09/README.md):
источник сообщает optional mask только о ещё недоступных предложенных hints;
проверенные mismatches снимаются, неподходящая metadata включает plain-page
путь. Mask не разрешает запись/ACK/jump: source match, свежий local recheck,
current authorization и durable cursor остаются обязательными. Верхние границы
query/page/admission прежние; mailbox не включён.

Контроль **17 → 2 page-запроса**; old **3 assertion-red**, unbounded-retention
**2 assertion-red**. **245 related passed / 0 skipped**, 16 native HVS,
analyzer чист; проверены edits, revoke, отказ cursor commit, неверные masks
и снятие уже отвергнутых hints. Нативный архив 10000+1 сохранился полностью во
всех трёх фазах без дублей/пропусков, cold boot без источников прошёл.

Встречные ответы B→A/E: **6,12 → 1,11 → 6,43 МБ** application-frame bytes.
Это уменьшение лишней выдачи на данном стенде, не полный wire-трафик или
универсальный коэффициент. Основная догрузка **34,868 → 35,787 → 34,858 с**
при опросе 1000 мс: ускорение не доказано, latency остаётся активной. Следующий
участок — межстраничные ~127–138 мс до следующего query (включает приложение
и доставку), 316 cursor commits и более точный completion witness.

1525 frozen inputs, native SHA/mappings и cleanup проверены; kernel cache
92→92, новых entries 0 во всех фазах, место не чистилось во время измерений.
NETCALL-01 и остальная matrix без изменений; телефон/production не тронуты,
commit локальный unsigned, push/релиза нет.

## 2026-11-09: растущий источник — воспроизведение, прототип пока отложен

[Управляемая проверка](../history-growing-prefix-2026-11-09/README.md): клиент
отбрасывает подсказки после первой страницы, хотя источник может подтвердить
их позже. Модель 1024 известных строки + tail: parent **17 page-запросов**,
простое удержание hints — **2**. Проверены source/local edits, revoke и отказ
cursor commit. Native 10 000: все три запуска сохранили 10001 строку без
дублей/пропусков, но timing дисквалифицирован очисткой диска между фазами.

Простое удержание **не принято в product tree**: сначала требуется ограничить
повторное digest-сравнение отвергнутых подсказок. Измеренной CPU-регрессии нет;
это оставшаяся проверка кандидата. Нужен bounded retry только для ещё
недоступных источнику префиксов, без доверия к отрицательной метаинформации
как к разрешению записать/ACK/продвинуть cursor. Исходная история возвращена
к квалифицированному `ef64c976`; принята отдельная cache-правка ниже.
Догрузка и NETCALL-01 остаются активными. Push/релиза нет.

## 2026-11-09: рост Flutter kernel cache устранён в process-стенде

[Очистка и причина](../test-kernel-cache-2026-11-09/README.md): случайный hook-port
в dart-define создавал отдельный примерно 106-МиБ kernel для каждого worker.
Порт теперь runtime-параметр; общий compile opt-in, release/profile gate,
exclusive loopback и per-run key сохранены. Три native worker на разных портах
создали **один** новый cache entry, restart на гарантированно другом порту —
**ноль**; три запроса без ключа получили 401. Native mappings/SHA и cleanup
проверены. **228 final related passed / 0 skipped**, analyzer чист; cache native case
отдельно, не skipped.

По сообщению владельца очищены 1511 старых generated kernels — **156,16 ГиБ**;
после очистки свободно **158,83 ГиБ**. Сохранены свежие/открытые kernels,
исходники, .git, артефакты приложения и пользовательские контейнеры.
Изменение дисковых условий дисквалифицирует timing-сравнение текущей большой
серии; её проверки корректности истории остаются действительными. Остаточная
задержка и NETCALL-01 не объявлены закрытыми. Push/релиза нет.

## 2026-11-09: delivered-witness отклонён, измерена встречная выдача

[Исследование на 10 000](../history-delivered-witness-10000-2026-11-09/README.md):
прототип пропускал post-apply roster/read только после exact durable delivered
append. Прямая проба **64 → 0** лишних чтений; candidate **211 passed / 0 skipped**,
включая 16 native, analyzer чист. Native A/B/A **35,161 → 35,017 → 33,761 с**
не доказал ускорения, поэтому **прототип и новые пробы убраны**. Production
сохраняет квалифицированную правку `ef64c976`, пакет 64 и отдельный cursor.

Новый участок наблюдения: B принял **157/74/34 page-запроса**, ответы каждого
набора полностью получены A (не E); B параллельно работал источником истории.
A заранее имел полный архив. Связь request→parts проверена, связь с точными
message ranges и причинный вклад в общую задержку ещё не доказаны. Фоновая
встречная работа вариативна; totals callback/RPC не объявлены чистым эффектом
candidate. Следующий контроль — sparse inventory/prefix+tail и page-cycle
тайминги с сохранением fresh authorization и durability.

Все 10001 строки/статусы/порядок сохранились без источников, frozen inputs,
native SHA/mappings и cleanup проверены. Этот цикл оставляет только документы;
догрузка, NETCALL-01 и остальные открытые статусы сохраняются. Телефон/
production не затронуты; sibling mailbox выключен; push/релиза нет.

## 2026-11-09: публикация короткой страницы и архив 10 000

[Исправление и A/B/A](../history-page-publication-10000-2026-11-09/README.md):
подготовленная короткая страница публикуется пакетами до 64 вместо 16;
HVS и cohort разделяют один предел. Обычная живая очередь остаётся по 16,
encoded row ≤1800 байт, prepared payload ≤115200 байт, сетевые лимиты прежние.
Fresh admission/erase/teardown/durable completion/cursor guards сохранены.

**6 assertion-red; 202 related passed / 0 skipped**, включая 16 native HVS;
анализатор чист. Полная транзакция, удержанный commit, lost reply/reopen без
дублей и crossing-shard проверены; revoke/block/TTL/retention до публикации
запрещают все 64 строки. Между post/ordering семьями revoke оставляет только
предыдущую durable публикацию, курсор не продвигается.

Native A/B/A, 10 000 архивных + 1 прежняя: **48,760 → 34,874 → 49,729 с**,
message commits **625 → 157 → 625**, worker RPC **61668 → 32739 → 61760**.
Полные ID/тела/delivered/positions/порядок и boot без источников совпали;
1524 frozen inputs/native SHA/mappings и cleanup проверены. Ускорение около
29% относится к локальному Mac/JIT стенду, не Android/WAN. Источники seedятся
прежними 16-row пакетами вне timing, обе первые replies удержаны до apply.

**Догрузка остаётся активной:** 34,9 с; следующие кандидаты — 316 cursor
commits, allocator и свежие чтения, без приписывания им всего остатка.
NETCALL-01 и остальные статусы не изменены, полной crash/matrix квалификации
нет. Телефон/production не затронуты, sibling mailbox выключен; push/релиза нет.

## 2026-11-09: status no-op и архив 10 000 сообщений

[Исправление и большой стенд](../history-delivery-status-10000-2026-11-09/README.md):
duplicate outgoing mirror пропускает status API, если свежее чтение уже
подтвердило delivered; canonical-position adoption и repair старых состояний
сохранены. Сам API читает цель по chat+ID вместо общего списка, сохраняет
fail-closed/monotone/scoped/tombstone правила. Финальный старый-caller контроль:
6 assertion-red; **247 related passed / 0 skipped**, analyzer чист.

По запросу владельца fixture расширена до **10 000 архивных + 1 прежняя**.
Native A/B/A: все строки/порядок/delivered сохранились без источников;
status calls **10000 → 0 → 10000**, apply→сходимость **48,633 → 48,769 →
48,943 с**. Общего ускорения **нет**, задержка остаётся активной. Seed batching
по 16 находится вне timing; wire/census лимиты увеличены только в test support,
запуски подтвердили отсутствие обрезки. По 157 полных page replies от A/E;
следующий query после полного reply наблюдался примерно через 195–197 мс
в candidate (включая обработку B и доставку запроса, не CPU-only).
1524 frozen inputs/native SHA и cleanup проверены, candidate восстановлен.
NETCALL-01 и остальная матрица без изменений. Телефон/production не тронуты,
mailbox не включён; push/релиза нет.

## 2026-11-09: повторная control-свёртка внутри одного routing-read

[Исправление и сравнение](../history-routing-control-view-2026-11-09/README.md):
состав устройств и announcement-проекция используют одну уже вычисленную
свёртку того же свежего journal; состояния между чтениями не кешируются.
Два последовательных запроса: проверки каждой control-записи **6 → 4**,
чтения durable header **2 → 2**. Assertion-red на прежнем коде, **625 related
passed / 0 skipped** с native gates, analyzer чистый.

Native A/B/A на архиве 2000 строк: все 2001 строка сошлись и сохранились без
источников, оба cursor завершены, потерь/дублей нет. Время apply→сходимость
**11,369 → 11,369 → 10,160 с**: полного ускорения **не доказано**, догрузка
остаётся активной. Различается один production-файл, 1524 frozen inputs и
native SHA проверены; VM trace/sampling выключены во всех фазах. Candidate
восстановлен, процессы/порты/runtime очищены. Следующая измеренная лишняя
работа: 2000 вызовов status API при changed=0; исправление ещё не сделано.
NETCALL-01 и остальные статусы без изменений; телефон/production не затронуты,
push/релиза нет.

## 2026-11-09: pending contact reads и архив 2000 сообщений

[Исправление и квалификация](../history-contact-frontier-2026-11-09/README.md):
одинаковые незавершённые `getContact` разделяют один RPC только при неизменном
номере очереди конкретного worker. Любая другая команда/store/peer — барьер;
завершённые записи и consent-решения не кешируются. Red 32 → 1; удаление
frontier-barrier возвращает accepted после block и падает на фактическом
статусе. Native single/multi-space и неизменный file A/B/A проверены.

На полном native архиве 2000 сообщений с двумя источниками чтений контактов
**3260 → 1394 → 3255**, apply→сходимость **12,316 → 12,343 → 12,093 с**.
Все 2001 строка сохранились после cold boot без источников. Снижение RPC
подтверждено; общее ускорение **не доказано**, задержка остаётся активной.
Отдельный SIGKILL до apply двух полных ответов: возврат только A восстановил
все 2000 архивных + прежнюю строку; следующий boot без источников — 2001.
**241 related passed / 0 skipped**, analyzer чистый; normal A/B/A + crash —
4 native сценария отдельно. 1524 frozen inputs одинаковы во всех четырёх
запусках; native SHA, cleanup PID/портов и runtime проверены. NETCALL-01,
жалобы и остальная матрица статус не меняют. Телефон/production не затронуты,
push/релиза нет.

## 2026-11-09: лишние чтения контактной политики при догрузке

[Исправление и квалификация](../history-policy-observation-2026-11-09/README.md):
retention/TTL/read-clock используют одно свежее наблюдение контактной записи;
независимая проверка block после read-clock сохранена. В одной предкоммитной
проверке было 3/4 чтения, стало 2/2. Две assertion-red регрессии,
block/TTL/retention на границе commit и block внутри read-clock lookup;
отрицательный контроль без финальной проверки записывает 16 запрещённых строк.
**268 related passed / 0 skipped**, analyzer чистый.

Native A/B/E + C: SIGKILL B до применения двух полных authenticated ответов,
до сети сохранена одна прежняя строка и 0 архивных; возврат только A восстанавливает
512 архивных + 1 прежнюю, cold boot при offline A/E/C сохраняет все 513.
Точные ID/тела/delivered/positions/порядок совпали, дублей нет. Cleanup:
43 PID/62 порта, 1475 frozen inputs и native SHA проверены.
**Догрузка остаётся активной:** меньше storage-вызовов в указанной проверке,
но общего причинного ускорения этот crash-прогон не доказывает. NETCALL-01,
жалобы и остальные пробелы матрицы статус не меняют. Push/релиза нет.

## 2026-11-09: релиз и crash до применения двух ответов истории

Опубликованы [Veil 0.11.48](https://github.com/veilnetwork/veil/releases/tag/v0.11.48),
[hidden-volume 2.7.0](https://github.com/veilnetwork/hidden-volume/releases/tag/v2.7.0)
и затем [xVeil 0.13.95+114](https://github.com/veilnetwork/xVeil/releases/tag/v0.13.95).
Подписи/суммы зависимостей, семь media pins и 15 app assets проверены;
Android сохраняет прежнего signer. Его стандартная strip-обработка media
воспроизведена побайтно для трёх ABI. Артефакты прошли privacy gates.
Шесть production и три постоянных testnet-сида обновлены до 0.11.48:
конфигурации сохранены, автоматических рестартов нет, DHT-команды успешны.
История опубликованных refs переписана и проверена, но старые GitHub-объекты
по SHA остаются доступны; object GC не выполнялся по указанию владельца.

После релиза [проверен новый crash-момент](../history-overlap-preapply-crash-2026-11-09/README.md):
два полных authenticated ответа A/E уже получены B, первый apply удерживается,
архивных строк 0. SIGKILL B; A/E/C offline; до сети после restart сохранена
прежняя строка. Вернулся только A: все 512 архивных + 1 прежняя строка
сошлись по ID/телам/delivered/позициям/порядку без дублей. Следующий boot B
без источников сохранил все 513 строк до сети. 42 helper/oracle + один native
сценарий прошли без skip; 1471 frozen input/native SHA неизменны,
45 PID/65 портов очищены. Это Mac/JIT с release SDK и HVS, не полная матрица.
Production не менялся; послерелизная проверка остаётся локальной, без push.

**Активны:** остаточная задержка большой истории и NETCALL-01; расширенная
матрица по-прежнему квалифицирована частично. Текущая недоступность внешних
TCP/HTTPS у Poco на провайдере с белыми списками не приписывается SDK без
отдельных доказательств. Отложенные владельцем жалобы возвращаются при
повторном воспроизведении и не объявляются исправленными этим релизом.


Последнее исправление/проверка: [несколько свежих наблюдений relay-кандидата](../call-relay-candidate-warmup-2026-11-08/README.md).
P2P → relay сохраняет один открытый кандидат до трёх новых 600-мс challenge;
старые/просроченные ответы не засчитываются, P2P upgrade остаётся однократным.
Три assertion-red, 303 related passed / 0 skipped, analyzer чист. Два full
AOT f19b9b7b звонка пережили Cellular 120 с и возврат Wi-Fi 45 с без смены
engine epoch (1/1 и 3/3). Во втором Mac действительно выполнил observation
1/2/3: третья получила свежий matching reply за 167324 мкс и сохранила engine
при relay commit. **NETCALL-01 открыт:** позднее на relay после возобновления
RX был новый период отсутствия аудио до observed age 11449 мс; он не объявлен
ожиданием первичной квалификации. Не A/B, общее ускорение/слышимость не заявлены.
Окончательное восстановление телефона/production/стенда проверено; архив B
повторно скачан и проверен без restart, исходный cleanup failure сохранён.
Push/релиза нет.


Последняя физическая проверка: [возвращённый Poco, relay и P2P handover](../call-handover-current-aot-2026-11-08/README.md).
**NETCALL-01 открыт.** Первый звонок завершился на Mac по liveness timeout
(21 с тишины): приём после relay selection сначала восстановился 203 → 255,
затем остановился; оба Core закрыли сессии телефона по keepalive timeout.
Телефонный end принадлежит cleanup, порядок сверен с clock skew.
На новом стенде relay-only пережил Cellular 120 с и Wi-Fi 45 с, epoch 1/1,
max observed audio RX age 1153/2939 мс. Следующий P2P-звонок сохранился, но
max age 11844/5148 мс, engine epoch 3 → 5. За первые 10 с после cut 82 RTP
с payload всё ещё пытались уйти direct и не найдены на приёме Mac; relay
candidate не прошёл echo qualification, переключение произошло позже.
Причина отказа кандидата не установлена, 600-мс budget не объявлен корнем.
Оба клиента — runtime/mapping/installed-SHA verified full AOT 460d74e2;
последующий history-код этим не квалифицирован. Не A/B, слышимость не проверена.
Телефон и production восстановлены, собственные процессы/Core закрыты и
удалены; публичные summary без идентификаторов/адресов/raw logs. Push/релиза нет.


Последнее исправление: [64 события в byte-bounded own-history странице](../history-page-rows-2026-11-08/README.md).
128 КиБ/64 части и durable cohorts по 16 сохранены; 167 tests без skips,
analyzer чист. На archive A₁/B/A₂ с двумя источниками запросов 34 → 18 → 34,
encode-release→сходимость 4649 → 3775 → 4250 мс; все 512 архивных + одна
прежняя строка пережили boot без источников. Первые snapshot-only controls
исключены по нулю page queries. Финальный SIGKILL: 206 наблюдено, 253 durable
до сети после restart; возврат только A, все 512 сошлись, history retries 0.
Фикс подтверждён в ограниченном Mac/JIT архивном сценарии; **общая задержка
догрузки остаётся активной**. Старые decoders могут отвергать >32 rows,
совместимость исключена владельцем. Стенды очищены; push/релиза нет.

Последнее исправление задержек: [отсев JSON обычных mirror при поиске адресов](../history-routing-json-2026-11-08/README.md).
Два fresh routing lookup: 130 → 2 полных декодирования, без кэша authority
или body; escaped/duplicate keys и весь signature/fork/retention/revoke path
сохранены. Assertion-red, 639 related passed / 11 skipped, analyzer чист.
Native incoming history: 141 строка до SIGKILL и до сети после restart,
все 512 после возврата только A и при следующем boot без источников;
ID/тела/позиции/порядок/delivered совпали, дублей/history retries нет.
Общее ускорение не доказано; догрузка остаётся активной. 34 PID / 50 портов
проверены, стенд очищен; телефон/production не затронуты, push/релиза нет.

Последняя проверка: [Blackview и текущий AOT обоих клиентов](../blackview-current-aot-2026-11-08/README.md).
Poco забран владельцем; mobile-handover запуск отменён до установки/звонка,
его Core удалены. Blackview без SIM: два relay-only звонка, 10/10 fast ACK
за 0,201–1,580 с; при полном обрыве Wi-Fi на 5 с тот же звонок продолжился,
первый observed fresh RX через 4,328–4,907 с после команды включения Wi-Fi.
NETCALL-01 не закрыт: это не Cellular handover и не проверка слышимости.
Оба current Dart AOT подтверждены runtime guard/mappings; source auth строгая.
Final API call frames 0/0, total Outbox 1/0 (один P2P). Телефон восстановлен,
новый собственный QA удалён; приложения/Core остановлены и удалены,
production независимо сверено. Новых source-фиксов, push/релиза нет.

Положительная квалификация: [fast ACK с current profile AOT](../call-fast-ack-aot-2026-11-08/README.md).
Полный Mac App.framework действительно загружен: runtime revision/digest/mode
проверены до unlock, mapping и SHA AOT/FFI подтверждены. Mac 460d74e2,
Android c5677f38: relay-only call получил 5 fast receipts за 95–1198 мс;
для end ordinary receipts пришли через 3,2 с. Final API call queues 0/0;
crash/reopen не заявляется. Source authentication осталась строгой. NETCALL-01
пока открыт; следующим идёт handover на этих же бинарниках. Телефон/production
восстановлены, стенд закрыт; push/релиза нет.

**Коррекция Mac-стенда:** [AOT provenance](../call-aot-provenance-2026-11-08/README.md).
В b599/c567 физических сериях обновлялся Android AOT, но Mac продолжал
исполнять старый profile App.framework/App; свежий kernel игнорировался.
Current Mac Dart/JIT qualification отозвана. Native SHA/mapping и реальные
packet observations сохранены в уточнённой области применимости. Fast ACK
на паре двух обновлённых клиентов ещё не проверен; отсутствие новых gate
codes тоже объясняется старым AOT. Добавлена runtime compile identity в
аутентифицированный health, 21 tests и analyzer прошли. Следующий шаг —
пересборка целого profile framework и runtime guard до звонка. Push/релиза нет.

Последняя квалификация: [native ACK — отрицательный результат](../call-fast-ack-physical-2026-11-08/README.md).
На c5677f38 8/8 route transitions доставлены, но fast receipts 0; ordinary
ACK-return 8,188–48,085 с, до 32 copies. Relay-only control тоже без fast ACK.
Причина отказа новой ветки не установлена; proof/peer/frame/consent guards
не ослаблены. Добавлены числовые diagnostic gate decisions, enabled и disabled
117/117 отдельно, privacy guard и analyzer чист. Новый diagnostic-код ещё
не проверен физически. NETCALL-01 открыт: cellular max RX age 11,719 с Mac /
10,995 с Poco, engine epoch 1. Телефон/production/стенд восстановлены;
Dart cache сохранён для следующего захвата. Push/релиза нет.

Уточнение/исправление: [первые control arrivals и быстрый ACK](../call-fast-ack-2026-11-08/README.md).
Все 13 route transitions предыдущей серии впервые дошли за 20–3432 мс;
44 с — возраст поздних копий. Source/receiver frame sets совпали, dropped=0.
Подтверждён обратный участок: 0,923–44,319 с от receiver ACK log до sender
`delivered`, с 3–4 fast retries на transition. Added realtime call receipt
строго за provenance/consent/typed pending peer+frame guards; ordinary и
anonymous posture сохранены. 199+34 passed, 7+17 skipped отдельно. Новый
ACK-код ещё не проверен на телефоне; NETCALL-01 открыт. Push/релиза нет.

Последняя физическая серия: [новый frontend, Poco ↔ Mac](../call-route-physical-2026-11-08/README.md).
`b59970fb` проверен Android AOT / Mac JIT на замороженных native libraries.
Звонок Wi-Fi 30 с → Cellular 120 с → Wi-Fi 45 с сохранился, media epoch 1
на обоих endpoints. **NETCALL-01 открыт:** max native audio RX age на Cellular
7,202 с Mac / 4,838 с Poco, при возврате Wi-Fi 6,820 / 3,458 с. Не A/B,
ускорение не доказано. Поздний transportInfo до 44,067 / 34,291 с при queue/
handler 0 мс; место до Dart не атрибутировано. Все apps/collectors/test Cores
очищены, телефон/production независимо сверены; build-синтетика удалена.
Push/релиза нет.

Последнее исправление: [supersession call route Outbox](../call-route-outbox-2026-11-08/README.md).
Старые чистые transportInfo больше не повторяются после более нового durable
состояния того же звонка/адресата. Atomic byte/peer witness, ACK race,
неизвестный исход коммита, P2P withdrawal и ordered/extra-field guards покрыты.
185 related tests прошли, 7 skipped отдельно; native reopen 1/1. Физическая
проверка нового Dart выше; причинный эффект cleanup отдельно не измерен.
NETCALL-01 открыт. Push/релиза нет.

Последнее исправление: [датированный media-repair и P2P handover](../call-repair-freshness-2026-11-08/README.md).
Старый/повторный health больше не перестраивает медиа после нового
health/transportInfo; fresh и startup requests сохранены, local watchdog не
менялся. Четыре assertion-red, пять focused guards; 248 related tests без
skips, analyzer чист. Физическая проверка нового Dart — выше, без causal A/B.
**NETCALL-01 открыт:** на pre-fix call code с разрешённым P2P подтверждена
пауза по native audio RX age до 28,639 с на Mac / 9,924 с на Poco после
Wi-Fi→Cellular. Watchdog реагировал при 3,229 с, четыре relay candidates
не прошли qualification; были повторные P2P↔relay переходы. Причина отказа
кандидатов не установлена, matching late echo для 600-мс probes не доказан.
P2P не объявлен решением TCP-пауз, stale-repair фикс не приписан этому случаю.
Тестовые публичные reflectors проверены, production/телефон восстановлены;
изначальный TCP-only pre-call исключён. Push/релиза нет.

Последний физический NETCALL-01: [частые TCP snapshots](../sdk-fine-tcp-call-2026-11-08/README.md).
SDK `bbcd967a` добавляет отдельный bounded operator gate: 100 мс / 180 с /
8192 fine rows, default прежний; 13 Mac / 14 Poco / 19 journal tests прошли.
Звонок Wi-Fi→Cellular→Wi-Fi сохранился, но **NETCALL-01 открыт**: два RX plateau
1018–1026 мс. Девять audio cells / 18 copies поздно приняты; локальный
RTP→first write ≤3,872 мс, flush ≤0,439 мс. Для четырёх flow/plateau теперь
есть 4/4 и 2/2 sender snapshots строго внутри NIC DATA silences 1110–1360 мс:
ACK стоит, sent растёт, в первой паре растут retransmitted bytes; notsent=0
в выбранных снимках. Участок после передачи ядру телефона до capture Core
не разделён на ОС/модем/сеть; изменений окна аудио не обосновывает.
Телефон/стенд восстановлены, production отдельно сверено, raw данные private.
Новый installed APK byte-check не выполнялся; новая fine-диагностика видна
по QA PID, packaging/source guard прошёл. Push/релиза нет.

Последний контроль latency: [CPU/timeline и release HVS](../history-profile-control-2026-11-08/README.md).
Затраты `package:stack_trace` тестового раннера не приписаны production RPC.
Для текущей HVS собрана отдельная release library с proof; 5 native checks
прошли. На одном immutable fixture read A₁/B/A₂: 116,930 / 30,569 / 117,408 мс
(сжимаемые) и 153,594 / 69,652 / 155,436 мс (random), по 100 проходов.
Полный profiled crash/offline control: 512/512 retained ID/тела/порядок/
positions/delivered; после возврата только A 6257 мс против 6378 мс в frozen
profiled run, при разном остатке работы. **Общее ускорение не доказано,
догрузка активна.** Оба stand очищены; отдельный owned Rust target удалён,
release dylib с SHA сохранён для следующих замеров.

Последнее исправление: [state-free history и свежая проверка у записи](../history-publication-auth-2026-11-08/README.md).
После строк без edit/delivery correction убрана повторная roster-проверка;
синхронный pull/binding guard и свежие проверки у следующей записи/cursor
сохранены. Gate: assertion-red 16 blocked callbacks → 1 у checkpoint.
Revoke покрывает next row, last-row checkpoint и отказ state correction;
165 related tests прошли без skips, analyzer чист. Native A₁/B/A₂: трижды
512 входящих сообщений, SIGKILL/offline A/C, возврат только A и финальный
cold boot — все ID/тела/порядок/positions/delivered, без дублей/потерь.
Receiver median 242,616 / 213,815 / 222,853 мс, после `start(A)` 5219 / 5480 /
5584 мс; work volumes различаются. **Общее ускорение не доказано, догрузка
активна.** 1509 inputs, один production diff, одинаковые native hashes;
все процессы/порты/runtime очищены. Push/релиза/mailbox нет.

Последнее исправление: [state-free history без повторного lookup](../history-noop-read-2026-11-08/README.md).
Для сообщений без edit/delivery-state correction убраны лишние serialized
чтения после applier: два assertion-red 64→0, затем 159 related tests и
analyzer прошли. Warm lookup не обязательно делает RPC, снижения всего I/O
или общего причинного ускорения не заявляем. Access/durable/cursor gates прежние.
Native incoming-history: SIGKILL после 542 строк, до сети при offline A/C
сохранены 573, включая весь наблюдённый префикс. Только A вернулся — полные
2000 ID/тела/порядок/positions/delivered, без дублей и completed-history retries;
результат сохранился при повторном boot без источников. После `start(A)` —
20,446 с, 45 primary page replies, receiver median 245,192 мс. **Догрузка
активна**, не A/B. Первый fixture failure на 1999/2000 исключён и очищен;
oracle исправлен без ослабления полноты. Замороженный native `c6699c28`,
checkout `c8f4929b`; все PID/порты/runtime убраны. Push/релиза/mailbox нет.

Последний разбор NETCALL-01: [NIC gaps с минимальным host polling](../sdk-nic-gaps-2026-11-08/README.md).
108 matching copies / три authenticated TCP flows / 19 flow-plateau observations:
DATA не появляются в capture Core 1098–1430 мс, после прихода read ≤12,137 мс.
Четыре копии без read не сопоставлены. Длительной наблюдаемой sequence hole
в этих окнах нет; некоторые содержат ACK. **NETCALL-01 открыт:** источник
паузы между локальным write и capture Core не установлен. При 1-Hz TCP_INFO
строго внутри NIC silences осталось 17×1 и 2×0 snapshots — новых доказанных
sender counter deltas нет. Raw inputs совпали с manifests, новых stand jobs
не запускали, прежняя очистка сохранена. Push/релиза нет.

Последний раунд: [SDK-звонок с минимальным host polling](../sdk-tcp-progress-call-2026-11-08/README.md).
Новые FFI `c8f4929b`, неизменные frontend/media/HV; два Core `e974cebe`.
Звонок пережил Wi-Fi→Cellular→Wi-Fi. В 120-с Cellular interval host не
опрашивал телефон; запись шла локально. **NETCALL-01 открыт:** Mac RX age
до 1314 мс, Poco до 1391 мс; 10 plateau на Mac. Внутри них сформированы
56 audio cells, все сопоставлены с поздним authenticated RTP: это не только DTX.
RTP→first write ≤5,357 мс, 111/112 flush ≤0,612 мс после first write.
Для 64 копий matching Core read точно позже plateau; 4 read отсутствуют.
На одном audio TCP flow ACK стоит 1,29 с при sent/retransmission progress;
для альтернативы ACK продвигается, все паузы этим не объяснены.
Большие RTO старых standby sockets не приписаны аудио. Следующее — конкретные
flows/NIC capture; изменения окна аудио не обоснованы. Host ADB оставался
включён, причинный A/B не заявляется. Стенд/телефон восстановлены,
production независимо сверено, push/релиза нет.

Последний раунд: [TCP byte progress в SDK](../sdk-tcp-progress-2026-11-08/README.md).
Opt-in trace дополнена Linux/Android sent/acked/received/retransmitted bytes,
RTO retries/backoff и readback MSS/send-buffer/LOWAT. Короткие ответы ядра
оставляют неподдерживаемые поля `None`; wire/options/audio не менялись.
Красный echo на прежнем SDK; зелёные 12 тестов на Poco и 11 на Mac,
scoped Clippy, 19 journal tests и AOT privacy gate. Private counters/bindings
не попадают в анонимный экспорт. **NETCALL-01 открыт:** настоящий звонок
на новой FFI ещё не проверен. Следующее — минимальный host polling.
Телефонные fixtures удалены; APK/контейнер сохранены, push/релиза нет.

Последний раунд: [профиль сокетов SDK и контроль ADB](../sdk-socket-profile-control-2026-11-08/README.md).
Readback на Android/Linux подтвердил MSS ≤1200, send buffer 64 КиБ
(131072 Б в Linux), not-sent LOWAT 4096. Все 22400 кадров дошли без
skipped/missing/I/O errors; MSS телефона оставался 1188 Б.

**NETCALL-01 открыт:** при обычном host polling max RTT 1463 мс / gap
1157 мс; при остановленном host ADB в одной паре — 618 / 470 мс.
Default mobile network в native snapshots не менялась, питание/Doze стабильны.
Одна последовательная пара не разделяет радио, daemon и дополнительный
опрос; причинное ускорение не заявлено. После ADB observation failure
только незапущенный final Wi-Fi завершён отдельно с сохранением первой
invocation; завершённые jobs не перезапускались.
Локальный 64-КиБ/4-КиБ write control дал одинаковую not-sent очередь
4158 Б и все байты после drain: новое ограничение write size не обосновано.
Следующее — byte ACK progress/readback в opt-in SDK trace и настоящий
звонок при минимальном host polling. Product-правок нет; телефон/сервисы
восстановлены, production проверено, push/релиза нет.

Последний раунд: [TCP_INFO телефона и echo-серверов](../tcpinfo-path-control-2026-11-08/README.md).
Android 100–120-мс sampling, server counters/echo/log timings; USB-loopback
отличил application hold от продолжающихся ACK. Затем Wi-Fi/Cellular серия.
**Полное прохождение не заявлено:** первый Cellular 9018/9059 echoes,
два I/O failures и 541 пропущенная подача после закрытия каналов; второй
9600/9600. Строгий validator упал и сохранён; отдельный анализ учитывает хвосты.

**Подтверждено на native-контроле:** в 79/88 clock-safe server gaps ACK bytes
телефона не продвигаются, во всех 88 растёт TCP sent, в 82 — retransmissions,
в 44 — not-sent. Phone RTO до 3,876 с, not-sent до 11108 Б. На двух каналах
MSS 1348→48 Б перед отказом; причина закрытия не установлена. Это не 88
независимых сбоев и не NIC-доказательство конкретного хопа.
**NETCALL-01 открыт:** профиль измерителя отличается от SDK. У Veil уже есть
pre-connect/listen MSS 1200, send buffer 64 КиБ и not-sent LOWAT 4096;
числа default-socket control напрямую на приложение не переносятся.
Следующий шаг — проверенный readback этого профиля на обоих концах,
с подсчётом всей подачи/неполученных кадров, затем настоящий SDK при повторе.
Телефон/stand восстановлены, production независимо проверено. Product-правок,
push/релиза нет.

Последний раунд: [нагрузка при постоянных TCP/TLS-соединениях](../load-sweep-control-2026-11-08/README.md).
Четыре сохранённых соединения, 512 Б на кадр, частота 50/200 мс;
на Cellular по 45 с H/L/H/L и L/H/L/H, плюс Wi-Fi и loopback controls.
Все 18000 мобильных и 2000 Wi-Fi echoes получены, без дублей/пропусков.

**Подтверждено:** 4× снижение payload load (40→10 КиБ/с на направление)
не устраняет паузы: оба L первого прогона имеют silence 1,30–1,32 с,
при этом H второго прогона бывает здоровым (max RTT 631 мс), а следующий
H снова даёт max RTT 1625 мс. Частота кадров/байтовый объём меняются вместе;
радио/сеть во времени не зафиксированы. Причинного ускорения не заявлено.
36 power/network/process snapshots Awake/Doze ACTIVE, xVeil не запущен;
producer gaps соответствуют выбранному периоду, local write wait <14 мс.
**NETCALL-01 открыт:** параметры аудио/транспорта не менялись. IPv6 сейчас
недоступен на default mobile link и обоих тестовых серверах. Следующий
контроль — sender TCP_INFO; его Android ABI/счётчики и not-sent при реальном
loopback backpressure проверены отдельно, мобильного захвата пока нет.
Телефон/службы восстановлены, production проверено независимо; push/релиза нет.

Последний раунд: [TLS и одновременный TCP/TLS-контроль](../tls-path-control-2026-11-08/README.md).
Отдельный C executable, без SDK/app/контейнеров; два TLS-канала, затем
четыре одновременных TCP/TLS к тем же двум адресам. Loopback, injected
1100-мс pause, CA rejection и remote Mac smoke проверены до серий.

**Подтверждено:** TLS-only на Cellular дал 4800/4800 echoes, max RTT 486 мс,
но одновременный контроль воспроизвёл секундные паузы в обоих протоколах:
TCP max RTT 1487 мс, TLS 4309 мс; receive gaps до 1222/2754 мс.
Все 12000 echoes парной серии вернулись; producer gaps ≤60,5 мс,
local write wait ≤6,2 мс. Server application arrival gaps 1,17–2,75 с
при генерации соответствующих кадров через 49–50 мс; это не NIC/one-way.
В 32/33 выбранных raw gaps средние 80% также не содержат TLS echoes.
Парный тест удваивает payload load (40 вместо 20 КиБ/с на направление):
влияние нагрузки/числа flows не отделено, причинного A/B нет.
**NETCALL-01 открыт:** TLS не принят как универсальный обход; следующий
контроль — нагрузка при постоянном числе соединений. 37 power snapshots
Awake/Doze ACTIVE, APK/контейнеры не менялись; телефон/сервисы восстановлены,
production проверено независимо. Product-правок, push/релиза нет.

Последний раунд: [native TCP/UDP control без Veil](../native-path-control-2026-11-08/README.md).
Отдельный C executable под shell UID, 512 Б / 50 мс к двум тем же адресам;
SDK/app не менялись. Loopback, injected 1100-мс delay, один dropped UDP echo
и remote Mac TCP/UDP smoke проверены до пяти Wi-Fi/Cellular фаз.

**Подтверждено:** на Cellular и без SDK RTT TCP достигает 1,25–3,93 с,
receive gaps — до 2,93 с при producer gaps ≤62,3 мс и local write wait <5 мс
для TCP. Все 8400 TCP echoes серии получены. Wi-Fi до/после — max RTT
115/63 и 282/151 мс по двум адресам. Мобильный raw UDP: echoes 1/1200 и
2/1200; служба приняла только 4/3 валидных запроса. Это не квалификация
QUIC и не доказательство блокировки всего UDP или виновности оператора.
28 power snapshots Awake/Doze ACTIVE; screen-off/OEM и UID-policy этим не
закрыты. **NETCALL-01 открыт:** SDK не обязателен для этого класса задержек;
полный historical handover и все остальные SDK defects не объявлены закрытыми.
Следующий контроль — TLS на том же пути. Телефон/настройки восстановлены,
own services/files удалены, production независимо проверено; push/релиза нет.

Последний раунд: [NIC-разбор секундных TCP-пауз](../tcp-nic-pauses-2026-11-08/README.md).
Offline-разбор серии SDK `e974cebe`; product-код и сборки не менялись.
RTP/cell/record/binding chain связала 20 ссылок с 12 уникальными TCP flows,
из них 7 на участке Poco; выбранные flows имеют однозначные bindings и SYN
generations. PCAP/journal hashes повторно проверены, capture drops 0/0.
На всех нужных source writers с binding NODELAY включён, zero TCP window
в выбранных окнах не наблюдается.

**NETCALL-01 открыт:** в пяти 1038–1078-мс flats подтверждены TCP silence
примерно 1088–1156 мс на мобильном участке обоих Core, затем приход пачкой;
для одного частичного A-пути только 3/17 copies, он не обобщается на все cells.
Mac data packets продолжают приходить в середине этих интервалов. Другие
телефонные packets видны по краям, не доказывают работоспособность spare
всю паузу. TCP overlaps/SACK/DSACK не объявляются окончательной потерей.
Быстрые SDK/Core stages не объясняют эти интервалы. Остались ОС/ядро/модем
и промежуточная сеть; виновность конкретного провайдера не доказана.
Следующий контроль — ограниченный TCP/UDP поток без Veil с cadence и
Wi-Fi/Cellular проверкой. Серверы/клиенты не запускались, прежняя уборка
сохранена, raw metadata private; push/релиза нет.

Последний раунд: [замена ранее готового child и физический повтор](../ready-replacement-calls-2026-11-08/README.md).
SDK `e974cebe` исправляет потерю pending после отказа уже опубликованного
Ready child. Failed source selection инвалидирует stale readiness/framing
и сохраняет demand под одним pool lock, не затирая concurrent completion.
Красный тест, четыре local source priorities, настоящий encrypted frame
через spare без нового request и без продвижения timer. 720 session passed /
8 ignored; scoped Clippy и Android release check прошли.

Poco/Mac/два изолированных Core: **5/6 финальных окон**, максимальные
after-switch RX ages ≤1202 мс. Прежнего flat ≥1,5 с нет в этой серии;
не A/B, причинное ускорение не заявляется. **NETCALL-01 открыт:** отдельный
разбор подтверждает пять 1038–1078-мс flats на Cellular, включая один до
команды Wi-Fi. Внутри них сформированы 77 distinct RTP cells, все приняты
после соответствующего flat. Source seal→attempt ≤5,692 мс, Core
ingress→selection ≤0,644 мс, первый read→RTP ≤8,369 мс. Остаток —
локальная запись record→чтение на другом конце; конкретный хоп/ядро/сеть
пока не установлены. Следующий шаг — сохранённые socket bindings + NIC
capture. `independent_fifo_wait` не считается потерей NodeLogger logs.
Стенд и телефон восстановлены, production сверено независимо; push/релиза нет.

Последний раунд: [failed readiness probes и физический повтор](../ready-probe-calls-2026-11-08/README.md).
SDK `cca1204e` исправляет резервирование пустого ordered child при failed
publisher/sender probe; source и neutral transit используют симметричный
выбор. Существующий ownership и limits сохраняются; pending source demand
отделён от reservation, уведомления идемпотентны и защищены lease owner.
Красные тесты поймали periodic/selector пути и две промежуточные регрессии.
719 session passed / 8 ignored; Clippy и Android release check прошли.

Два звонка Poco ↔ Mac через два новых QA Core, четыре handover: **5/6
финальных окон**, первое мобильное failed по прежнему порогу 1000 мс.
**NETCALL-01 открыт:** во втором мобильном окне Mac RX flat 3158 мс,
phone TX +20 подтверждён независимым collector. Из 31 distinct source cell
только одна имеет две physical record copies (обе flushed, без remote read);
30 без regular attempt witness, все без Core ingress/target receipt в захвате.
Sparse source-pressure = 3 события / 20 aggregate drops, не per-cell attribution.
После первого validated Cellular остаются 2421 мс flat; готовность ОС не
приравнивается к готовности TCP. Следующий участок — готовность/lifetime
уже закреплённого child и оставшийся flush → no-read. Стенд и телефон
восстановлены, production независимо сверено; push/релиза нет.

Последний раунд: [record writer → TCP socket и физический повтор](../tcp-child-binding-2026-11-08/README.md).
SDK `b214219a` добавляет default-off operator binding через scoped writer
context и сохраняет socket ID от handshake. Shared cap, отсутствие plaintext/IP
в новых строках и исключение metadata из anonymous export проверены.
179 transport / 712 session passed, 8 ignored отдельно; Clippy, Android check,
19 journal tests и реальный AOT privacy gate прошли.

Poco/Mac/два изолированных Core: **6/6 финальных окон**, NETCALL-01 открыт.
RX Mac flat 3166/2620 мс с продолжающимся phone TX подтверждён независимым
collector. В первой паузе 32 source cells без regular record attempts; во
второй из 27 cells только 3 имеют 4 physical attempts. Source-pressure ветка
подтверждена sparse observations, не атрибутируется всем cells поштучно.
После первого observed validated Cellular остаётся 1505/1055 мс этих gaps;
готовность ОС не приравнивается к готовности TCP. Три physical copies связаны
с двумя TCP sockets; одна без наблюдаемого binding. Следующий приоритет —
source readiness и оставшийся periodic publisher, с сохранением отдельной
ветки local flush → no remote read. Свои стенды убраны, телефон и production
независимо сверены; push/релиза нет.

Последний раунд: [cold pool и физический повтор Poco ↔ Mac](../cold-prepare-calls-2026-11-08/README.md).
SDK `cb54608d` исправляет подтверждённую регрессию eager prepare: на полностью
пустом TCP child pool он больше не резервирует слоты до первого completion.
Красный компонентный тест сравнивает с контролем без eager publication;
после фикса реальный зашифрованный frame доставляется. 712 session passed /
8 ignored, Clippy и Android release FFI check прошли. Политика обычного
completion/timer allocation, ownership/FIFO/квот и wire сохранена.

Новые native builds Poco/Mac/двух изолированных Core: два звонка, четыре
handover, **6/6 финальных окон passed**. **NETCALL-01 открыт:** в первом
Cellular-эпизоде оба native RX стояли 10,811 с после наблюдаемой готовности
мобильной сети, при продолжающемся native TX. Во втором после validated
Cellular отдельно подтверждены ещё 10,206 с; максимальные 11,236 с до первого
validated-наблюдения с ними не склеиваются. Во втором post-validation flat
из 52 phone-origin cells у 26 есть по две locally flushed physical record
copies без Core read, у остальных 26 regular send-attempt witness отсутствует.
Компонентный фикс не объявлен решением этих пауз; следующий участок —
TCP child lifetime и local flush → remote read. APK/контейнер/настройки и
production независимо сверены, свои стенды удалены, push/релиза нет.

Последний раунд: [фактические queue outcomes и физический повтор](../queue-admission-calls-2026-11-08/README.md).
Core SDK `ae352464` добавил operator-only accepted/missing/closed/full по
конкретной opaque cell; FIFO/квоты/wire не менялись. Regression-red,
711 session passed / 8 ignored, Clippy/Android check, 19 journal tests и
AOT privacy gate прошли. Новые строки не входят в анонимный экспорт.

Два звонка с прежними immutable клиентами `e136c71f`: **5/6 финальных окон**.
**NETCALL-01 открыт:** подтверждены flat-интервалы до 13,83 с, с native TX
отправителя и независимым phone collector. В одном эпизоде 31 cell принята
в очередь/выбрана к телефону; 30 локально flushed, remote read не наблюдается.
В другом 95 phone-origin cells не видны на Core ingress, у большинства нет
regular send-attempt witness. Queue admission и доставка больше не смешиваются.
Media repair отмечен отдельными unknown/counter epochs, не склеенными в паузу.
Следующий участок — готовность/lifetime TCP child и flush → read. Собственные
стенды убраны, APK/контейнер/настройки восстановлены, production независимо
сверено; push/релиза нет.

Последний раунд: [физическая проверка eager ordered readiness](../warmed-ready-calls-2026-11-08/README.md).
SDK `e136c71f` собран и проверен на Poco/Mac/двух QA Core; два звонка,
четыре переключения, **6/6 финальных окон**. **NETCALL-01 открыт:** в первом
Cellular-окне native RX телефона стоял 4822 мс, Mac TX +63; семь локальных
phone-срезов подтвердили остановку, обратные 27 cells дошли на Mac внутри
интервала. Все 81 конкретная Mac-origin cell внутри паузы прочитаны обоими
Core, но target transport selection к телефону не наблюдался. Dispatch
занимал ≤423 мкс; точный исход queue admission/ветвь отказа ещё неизвестны.

Отдельные 1567 мс неподвижного RX Mac включают 15 phone-origin cells без
наблюдаемого Core ingress — это другой участок. Причинное ускорение/регрессия
не объявлены, 250-мс фикс не объявлен решением этих пауз. Следующий шаг —
per-cell фактические outbound queue outcomes на Core. Все свои стенды
убраны, APK/контейнер/настройки восстановлены, production независимо сверено;
push/релиза нет.

Последний раунд: [физическая трасса records и ordered readiness](../record-boundary-calls-2026-11-08/README.md).
На SDK `5f194c38` две серии Poco/Mac с двумя QA Core: 6/6 и 5/6 финальных
окон. **NETCALL-01 открыт:** внутри второго захвата RX Mac стоял 2613 мс
при продолжающемся native audio TX телефона (независимый local collector).
Из 29 source RTP cells внутри паузы у 27 нет transport-selection witness;
у двух четыре transport copies локально flushed, но Core read не наблюдался.
Локальный flush не доказывает NIC egress/remote ACK или сетевой drop.
Первая серия имеет неполный Core logger; повтор исправил и проверил реальное
покрытие. Полные IPC ages физически подтверждены.

SDK `e136c71f`: отдельно исправлено подтверждённое ожидание readiness уже прогретого ordered
child до следующего 250-мс тика: production prepare теперь использует прежний
publisher с сохранением ownership/live-parent guards. Regression-red на
виртуальных часах и доставка реального frame проходят; влияние этой новой
правки на физические паузы пока не квалифицировано. 710 session passed / 8 ignored,
scoped Clippy и Android release FFI check прошли. Свои стенды убраны,
APK/контейнер/настройки восстановлены, production прежний; push/релиза нет.

Последний раунд: [полные IPC timings и ordered record boundaries](../ordered-record-observability-2026-11-08/README.md).
SDK `f5a246ab` устраняет подтверждённый диагностический дефект: full-capture
не менял фиксированную выборку приёмных IPC ages раз в 50 клеток. Наборы
44/2319 и 59/3139 в прежнем захвате точно совпали с этой выборкой;
regression упал на sequence 2 до исправления. Default/cap/TTL/auth-boundary
сохранены. `26686d56` добавляет operator-only связь opaque cell → encrypted
ordered record → queue/write/flush/read/decode boundaries; Android получил
default-off property gates, raw metadata исключена из anonymous export.

Финально 199 IPC / 709 session / 177 transport / 76 util passed,
13 ignored отдельно; 19 journal tests и AOT privacy gate passed.
Android release FFI compilation check прошёл. **NETCALL-01 остаётся открыт**:
нового физического звонка/установки этих сборок ещё не было. Последний
физический результат — 5/6 финальных окон и остаточные паузы порядка 1,6 с.
Следующий шаг — свежие native builds и захват после transport selection
с проверкой покрытия нужной ветки. Сеть/квоты/FIFO/wire не менялись;
приложения и серверы не запускались, push/релиза нет.

Последний раунд: [физическая проверка keepalive/FIFO](../keepalive-calls-2026-11-08/README.md).
SDK `04584523` собран и проверен на Poco, Mac и двух изолированных QA Core.
Два звонка, четыре реальных handover: **5/6** финальных окон passed,
первое Cellular-окно failed по свежести RX на обоих концах. **NETCALL-01
остаётся открыт**: независимый телефонный collector подтвердил интервалы
неподвижного RX порядка 1,6 с при продолжающейся выдаче аудио источником.

На Core 0 `independent_fifo_wait`, все наблюдаемые source ingress имеют
target selection; внутри Core этот участок занимал ≤4,214 мс. Это не A/B
и не доказательство устранения прежних 2,7/8,6 с именно keepalive-фиксом.
Строгая packet-привязка: Poco → Mac 2319/2363 source cells имеют равные
наборы Core ingress/selection/authenticated receipt. Mac → Poco все 3223
имеют Core selection, 3139 — полную received SHA + authenticated RTP;
ещё один header-only witness не включён в строгий receipt-набор.
Ненаблюдаемые receipts не объявляются доказанными wire drops.

Следующий участок — конкретный child/попытка отправки после selection
и приём до dispatcher, плюс неполное timestamp-покрытие приёмной IPC-ветки.
Собственные стенды/процессы убраны, APK/контейнер/настройки восстановлены;
независимо проверено неизменное production. Source-код не менялся,
push/релиза и sibling mailbox нет.

Последний раунд: [собственный keepalive и нейтральная FIFO](../keepalive-neutral-2026-11-08/README.md).
SDK `04584523`: подтверждённый компонентный механизм исправлен — timer probe
больше не ставится перед нейтральными Forward в INTERACTIVE. Он остаётся
canonical TX probe; перенос на здоровый auxiliary child запрещён только
исходящим selector, приём не меняется. Сохранены relay FIFO/WRR, квоты и wire.
Дополнительно сохранена interactive urgency внутренних control queues при
батарейном накоплении/overflow, чтобы перенос не понизил их ниже bulk.
Regression-red, окончательно 708 session passed / 8 ignored; scoped Clippy,
Android FFI release check с параметрами приложения, fmt/diff-check прошли.

**NETCALL-01 открыт:** на момент компонентного раунда новая сборка ещё
не проверялась в физическом звонке; выполненный затем повтор описан выше.
Предыдущие 45 ingress / 44 без last-hop selection не приписаны этому
механизму доказанно. Следующий шаг — повтор на Poco/Mac/Core с session-bound
trace. Приложения/серверы в этом раунде не менялись; push/релиза нет.

Последний раунд: [новый receive budget в звонках Poco ↔ Mac](../record-read-calls-2026-11-08/README.md).
SDK `92cebc7e` физически проверен на обоих клиентах и двух QA Core: два
звонка, четыре переключения сети, все шесть финальных окон passed. Прежние
8,6 с не повторились; новый `read_timeout` в собранных логах не наблюдался,
поэтому причинное устранение пауз этим guard не объявляется.

**NETCALL-01 открыт:** на Poco RX counter стоял ≥2666 мс, Mac native TX +27
внутри интервала. Внутри этой паузы source sealing дал 45 конкретных RTP cells;
все видны на Core ingress, только один — в selection к телефону и authenticated
receipt. Для остальных 44 не установлена точная ветвь между ingress и last-hop
selection. На Core есть FIFO-wait/canonical-capacity=0, но без peer в старой
строке; связывать её с очередью телефона пока нельзя. SDK `09b84565` добавил
peer в operator trace (12 writer-progress tests); эта строка не присутствовала
в выполненных звонках. Сохранены WRR, роли/квоты, wire и anonymous allowlist.
APK/контейнеры/настройки восстановлены, свои стенды убраны, production прежний;
push/релиза нет.

Последний раунд: [срок сборки входящего TCP-блока](../record-read-budget-2026-11-08/README.md).
SDK `92cebc7e` устраняет подтверждённое неограниченное ожидание остатка
заголовка/тела ordered record. Существующий 200-мс receive budget начинается
с первого байта, не продлевается trickle или завершением сборки; истечение
закрывает только этот child с `read_timeout`. Пустой child остаётся пригодным.
Два виртуальных regression-red; после исправления host transport 176 passed,
session 704 passed / 8 ignored, Android component на Poco 19 passed.
Реальный authenticated obfs4/TCP-тест проверил sibling/canonical survival,
освобождение lease и новую доставку через replacement.

**NETCALL-01 открыт:** этот механизм не доказан как причина прежних 8,6 с.
Новая FFI в обычном звонке ещё не проверялась; ранее записанные звонки её
не содержат. На Poco запускался только отдельный native component test,
APK/контейнеры не менялись, свои процессы/файлы убраны. Push/релиза нет.

Последний раунд: [RTP и стадии отправки при handover](../audio-cell-join-2026-11-07/README.md).
Android получил operator sampling property для существующего подробного trace
(`b01c633b`); default/gates/wire/admission не менялись. `0c3715b6` дополнительно
сохраняет sparse default при non-UTF8 environment value. 74 util tests,
Android/aarch64 check и AOT anonymous-export gate passed. На телефоне физически
проверен `b01c633b`, Mac/Core — immutable `5d89beb5`; дополнительный invalid-input
guard физически не исполнялся.

Два звонка, шесть реальных переключений, восемь финальных case windows passed.
Прежние 8,6 с не повторились, maximum post-switch RX age Mac 1726 мс —
**NETCALL-01 открыт**, причинное ускорение не объявлено. По точным identities
3192 source payload-RTP cells: 3162 наблюдаются на Core и в authenticated Mac
receipt; эти наборы равны, а не только их размеры. Для 30 receipt не наблюдался:
у 22 нет relay-queued witness, у 8 он есть без наблюдаемого Core dispatcher
ingress; все внутри первых двух секунд после переключений. Судьба отдельных
transport copies и wire drop не доказаны.

Source sealing → handler-enter максимум 4,358 мс в новых случаях. Следующий
участок для admitted-but-unobserved — конкретный ordered child/transport/
обработка до dispatcher; старые 8,6 с этим не объяснены. Все QA процессы,
включая отделившийся logcat child, завершены; APK/контейнер/сеть/permissions/
sampling property/P2P восстановлены, production прежний. Push/релиза и sibling
mailbox нет.

Последний раунд: [проверка recovery-сборки на Poco](../confirmed-recovery-2026-11-07/README.md).
SDK `5d89beb5` собран для Android, Mac и двух QA Core, provenance/ABI/подписи
проверены. Три полных Cellular/QUIC-контроля прошли финальные проверки, прежняя
пауза 5,6 с не повторилась. В этой серии нет Core recovery events: это smoke
новой сборки, не доказательство причинного устранения ложной отмены replacement.
Две ранние попытки прервались из-за ADB при прежнем PID приложения; они не
засчитаны как product failures или успешная квалификация.

**NETCALL-01 подтверждён повторно:** в одном TCP-звонке Wi-Fi → Cellular
audio RX Mac стоял ≥8501 мс, age достиг 8598 мс. Внутри паузы native audio TX
Poco +36; это независимо подтвердили host samples и local phone collector.
На Core B — 34 phone-origin marker frames с TX witness к Mac, на Mac —
36 входящих marker frames. Один feedback packet однозначно прошёл до
authenticated receive за 71,269–120,997 мс внутри audio gap. Класс остальных
кадров и судьба недостающих audio payloads пока не установлены; epoch не
отличает feedback от RTP. Следующий участок — audio producer/send pump/
admission/выбранный carrier отдельно от работающей feedback-ветки.

Обратный Cellular → Wi-Fi прошёл без такой паузы; call ID/PID прежние.
Local collectors дали 291/291 и 300/300 успешных записей, после проверки
завершены, их private device directories/keys удалены. Все QA стенды убраны,
APK/контейнеры/сеть/permissions/P2P восстановлены, production прежний.
SDK source не менялся, push/релиза и sibling mailbox нет.

Последний раунд: [Cellular TCP / QUIC / TCP](../tcp-quic-cellular-2026-11-07/README.md).
Девять звонков Poco ↔ Mac, SDK `7d34e4e5` на обоих клиентах и двух QA Core,
без смены сети; все media relay. В QUIC-контроле RX Poco стоял ≥5458 мс,
age достиг 5621 мс, Mac native audio TX +73 внутри интервала. Core продолжали
пересылку; на отдельных соединениях к телефону росли expiries без confirmed
delivery. Конкретный audio lane ещё не привязан к этим соединениям. Это
**подтверждённая пауза без TCP**, а не доказательство преимущества транспорта.
8/9 финальных проверок свежести не отменяют паузу внутри прошедшего звонка.

Исправлен отдельный подтверждённый дефект: сырое число ACK frames позволяло
повторам откладывать recovery или отменять pending replacement. Теперь при
наличии confirmed-delivery counters нужны новые wire-ACKed Data packet
bytes/packets текущего epoch; reset/новый route только задают baseline.
Три регрессионных случая красные до правки; после неё 703 session +
173 transport passed, 8 ignored отдельно. Физическая серия была до правки;
её влияние ещё не квалифицировано. **NETCALL-01 остаётся активным.**

Попутно исправлена моя ошибка старого QA-стенда: Core B объявлял host Core A.
Прежние packet/RX наблюдения сохраняются, но не квалифицируют полноценный
discovery/failover корректной топологии. В новой серии own advertise/targets
проверены; production не менялся. Сверены 295 observation inputs и 63
harness-file hashes, все QA процессы/Core/порты/runtime убраны, APK/контейнер/
сеть/permissions/P2P восстановлены. Push/релиза и sibling mailbox нет.
Следующий шаг — физический повтор recovery-правки, затем handover в звонке.

Последний раунд: [подготовка оставшейся части history cohort](../history-cohort-window-2026-11-07/README.md).
Вместо отдельных волн по четыре подготавливается оставшийся бюджет той же
16-строчной публикации; уже staged rows учитываются. Два gate-сценария поймали
старое ожидание и overshoot промежуточного варианта; окончательный код прошёл
94 history + 15 retry tests, analyzer и native-проверки.

Три свежих snapshot-сценария дали полные 2000/2000 без дублей/потерь, но
не исполняли primary receiver history pages, поэтому не квалифицируют
ускорение этой ветки. Дополнительные candidate/control со SIGKILL B,
одновременно offline A/C и boot inspection до сети сохранили весь наблюдённый
префикс и финальные 2000 ID/тел/позиций/delivered. После возврата только A —
20,469 / 20,559 с; receiver-stage медиана 280,257 / 303,207 мс при разных
частичных историях и числе страниц. **Общее причинное ускорение не доказано;
догрузка остаётся активной.** В пяти native-сценариях source/native inputs
сверены, все процессы/порты/runtime закрыты; реальные профили и production
не затронуты. Push/релиза и sibling mailbox нет.

Последний раунд: [диагностика Poco и шесть переключений в одном звонке](../phone-close-cause-2026-11-07/README.md).
Phone/Core SDK `7d34e4e5`, Mac `c6699c28`; проверены Android ELF, 208 C exports,
неизменность остальных APK payloads, signer/alignment и реально установленный
SHA. До длинного звонка получен новый phone first-cause trace. Один call ID
сохранился 424,103 с при шести сменах Wi-Fi/Cellular; 745 срезов на каждом
конце после готовности без пропуска/регрессии RX counter. Строгих окон 7/9,
переходов 5/6: два финальных age-превышения на Mac — 1007/1103 мс.

**Паузы аудио остаются активными.** В отдельном Cellular-контроле без смены
сети после исходной готовности RX age Mac достиг 4061 мс: phone native TX
counter +44, Mac RX +0. Внутри консервативных окон Core нет наблюдаемого
phone-origin media Forward, встречный путь прогрессирует; на телефоне рядом
два partial expiry и endpoint source pressure. Это локализует фронт до source
admission/канала/транспорта перед Core observer, но не доказывает NIC egress,
wire drop или единственную причину. Прежние 9,6 с после handover не повторились;
**NETCALL-01 не закрыт**, нового причинного фикса/ускорения не объявлено.

Дополнительный offline-разбор того же захвата исправил поиск TCP-логов:
Android сохранял сообщения без имени Rust target. Внутри паузы — 15 kernel
snapshots на шести соединениях, queued до 29098 Б, notsent до 14423 Б,
kernel RTT estimate до 1,296 с, RTO до 4,064 с; на пяти соединениях очередь
и cumulative retransmissions выросли. Все шесть имеют TCP_NODELAY. Привязка
этих сокетов к PCAP по порту/времени не дала однозначных соответствий,
конкретный RTP/child ещё не атрибутирован. Это наблюдаемое TCP-давление,
не доказанная причина всей паузы и не новый физический прогон.

Следующее сопоставление по двум initial-flight byte counts и времени handshake
дало шесть различных однозначных flow (по три на Core), с независимой сверкой
всех TCP payload timestamps/directions/sequence/length через tcpdump. На пяти
flow подтверждены TCP sequence holes, пересекающие RX-gap: более поздний
payload приходит, cumulative ACK/prefix стоит 2,622–6,647 с. Шестой в своём
окне не имел client payload. Это **подтверждённый TCP head-of-line**, но ещё
не связь с конкретным RTP/source child и не доказательство причины ранних
пропусков. Порты через NAT не используются как равные; межхоповой crypto-proof
не заявляется. Исходные 27 входов прежние, новых физических прогонов нет.

Проверен отдельный флажок: native QUIC-сессии phone↔Mac существовали, но режим
медиа оставался relay, media-marker Forward напрямую не наблюдались; forced
relay flags исключают direct branch/получателя. Обход P2P media не подтверждён;
полная изоляция overlay/control в этом стенде не заявляется. Poco восстановлен
до отключения владельцем, Core/процессы/порты убраны, production прежний;
27 входов заморожены. Blackview с Wi-Fi доступен, в эту серию не входил.
Push/релиза и sibling mailbox нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [первая причина закрытия record channel](../record-close-cause-2026-11-07/README.md).
SDK `7d34e4e5` сохраняет типизированную первую причину до teardown; raw error
text не сохраняется. EOF, I/O failure, invalid record, partial expiry,
write timeout и owner/task close различаются; deadline 200 мс и протокол
прежние. 173 transport + 697 session passed, 8 ignored отдельно; rustfmt
и AOT privacy gate прошли. Core ELF/source/SHA/новые маркеры проверены.

Два Core с новой диагностикой, клиенты прежние `c6699c28`: два фиксированных
контроля и оба перехода в звонке прошли финальный контроль. Post-switch RX age
max — 816/1012 мс для Wi-Fi → Cellular и 1221/958 мс обратно. Внутри окон
вызовов наблюдались 19 закрытий к телефону: 6 partial expiry, 8 EOF, 5 read
errors, при сохранении приёма без прежней 9,6-с паузы. **NETCALL-01 открыт**:
это не A/B и не доказательство исправления; закрытие отдельного канала само
по себе недостаточно для атрибуции потери RX. Следующий шаг — та же QA-native
диагностика на телефоне и несколько переходов в одном длительном вызове.
Все QA приложения/процессы/Core/порты убраны, APK/контейнер/сеть/permissions/
P2P восстановлены, production прежний; 27 входов заморожены. Push/релиза и
sibling mailbox нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [два Core и смена сети внутри звонка](../dual-core-handover-2026-11-07/README.md).
Poco ↔ Mac, P2P denied, неизменные клиенты `c6699c28` и observational Core
`97dc1295`. Оба перехода реально выполнены: Cellular → Wi-Fi прошёл 60 с,
113/113 свежих RX-срезов на каждом конце; после Wi-Fi → Cellular была поздняя
пауза с RX age до 8548/9609 мс. **NETCALL-01 открыт.** Четыре фиксированных
контроля: три прошли, один не прошёл строгий финальный критерий из-за краткого
скачка возраста пакета, а не длительного обрыва. Первая попытка обратного
перехода остановлена до смены сети из-за предусловия; отдельный повтор не
заменяет этот отказ. Начальная фаза с потерей ADB исключена полностью.

Наблюдается работа пересылки между Core: из 262 совпадений opaque previews
только 81 проходит локальный порядок и единственность предшествующего ingress
на обоих Core; индивидуальная доставка телефону не доказана.
Старые `record plane closed` не различают несколько receivers
одного peer и причины закрытия. SDK `1572c22b` добавляет номер receiver и
path counters при включённом RT trace; поведения сети не меняет и физически
пока не проверен. 697 session passed / 8 ignored, rustfmt и AOT privacy gate
прошли. QA APK/контейнер/сеть/permissions/P2P восстановлены, оба тестовых Core
и все свои процессы/порты убраны, production прежний. 29 входов заморожены.
Push/релиза и sibling mailbox нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [разбор NodeId на пути догрузки](../node-id-hex-2026-11-07/README.md).
Убран 32-кратный substring/int.parse для обычного hex ID; legacy fallback,
ошибки и отдельное владение mutable bytes сохранены. 32768 ASCII cases плюс
Unicode/регистр/знаки проверены против прежнего decoder. 508 related passed /
11 skipped; analyzer чистый, два независимых mutation assertion-red.
В AOT A/B/A parser обычных ID примерно в 4 раза дешевле; **это не ускорение
всей догрузки**. Native A/B/C: 771/771 строка пережила SIGKILL и запуск без A/C;
после возврата только A все 2000 ID/тел/delivered/позиций/порядок сходятся без
дублей/retries и сохраняются при последнем cold boot без источников.
Наблюдаемое завершение после `start(A)` — 25,567 с при 5-с интервале parent
observer; миллисекундная разница с прежними прогонами не означает ускорения.
Last-part → next-query median 262,743 мс, подготовка страниц и device-journal
folds требуют дальнейшей работы. Native artifacts прежние (SDK `c6699c28`),
новый SDK source `37f6bb08` не пересобирался. 1509 frozen inputs, 34 PID и 51
порт проверены после cleanup. NETCALL-01 открыт, двух-Core проверка ждёт Poco.
Push/релиза и sibling mailbox нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [TCP first-flight join](../core-first-flight-2026-11-07/README.md).
Разобран прежний захват, новых звонков нет. Все 35 post-handover TCP socket
телефона однозначно сопоставлены с Core/PCAP; независимый tcpdump подтвердил
каждый flow. 11 handshake успешны; у 22 закрытых незавершённых — первые байты
приняты TCP Android, всё ещё unacked, `notsent=0`, retransmits 2–5; на Core
прочитано 0 и в PCAP payload отсутствует. Ещё 2 клиентских исхода не наблюдались.
Три post-close dial = шесть primary/backup socket с той же сигнатурой. Это
локализует **неудачный reconnect**, но не объясняет начало потери медиапотока.
Физический egress NIC телефона не захвачен; DPI/провайдер причиной не назначены.
**NETCALL-01 открыт.** Подготовлен двух-Core контроль и QA APK с неизменными
AOT/native/signer; только seed assets отличаются. Серверы проверены read-only,
QA не развёрнут, APK не установлен. Один Core без P2P не квалифицирует
production failover; Poco сейчас не виден ADB. Production/код прежние,
push/релиза нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [child-pressure и потеря Core после handover](../child-pressure-2026-11-07/README.md).
На Core — observational SDK `97dc1295`, клиенты/QA AOT неизменны (`c6699c28`).
Четыре вызова Poco ↔ Mac на фиксированных Wi-Fi/mobile прошли с 35-с контролем;
пять fresh RX — за 3,371–5,490 с. Переход Cellular → Wi-Fi внутри разговора
**не восстановился за 60 с**; call ID сохранился, hangup сделал стенд.
На телефоне новая Core session установилась, затем закрылась по keepalive
(примерно +14,114 с от команды Wi-Fi; probe age 9807 мс, genuine data age
5124 мс), далее три 10-с handshake без прочитанных байтов. Core pressure
windows **0**, поэтому новая неудача не атрибутируется прежнему child queue.
Почему перестали проходить данные/handshake, пока не доказано. Один Core,
P2P denied: production multi-Core failover и слышимость не квалифицированы.
**NETCALL-01 остаётся активным.**

Отдельно исправлен подтверждённый дефект повторного bootstrap join:
configured peer возвращал успех без redial, а настоящий synthetic ID pinned
relay позволял заменить operator-owned поля приглашением. Теперь bounded
retry использует сохранённую запись; configured/pinned защищены по source,
Rendezvous endpoint refresh сохранён. 8 focused и 818 runtime passed /
11 ignored. Старый код дал три queue assertion-red; fixture с настоящим
pinned ID — отдельный ownership assertion-red. Нового исправления в пяти
физических звонках не было; оно пока проверено тестами.
APK/контейнер/настройки восстановлены, собственные процессы/Core/capture
остановлены и удалены, production PID/binary/config повторно проверены.
Push/релиза и sibling mailbox нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [Core frame join](../core-frame-join-2026-11-07/README.md).
Четыре квалифицированных Poco ↔ Mac вызова на неизменной SDK `c6699c28`:
два Wi-Fi прошли, мобильный Poco→Mac вышел на пять fresh RX только за 22,651 с,
затем выдержал 35 с; следующий Mac→Poco **не появился за 45,305 с**.
Wi-Fi отключался между разговорами. В консервативной внутренней части
последнего окна 137 Mac-origin Forward реально получены Core и не имеют
Core TX witness; в обратном направлении 90/90 имеют Core TX и Mac RX.
Одновременно 44 pressure windows к Poco, queue depth до 176, retry 10 мс.
Это сужает фронт до egress/admission на Core, но отсутствие capture TX не
является доказательством drop; конкретные ветвь/канал и call-offer не
атрибутированы. **NETCALL-01 остаётся открытым.**

SDK `97dc1295` после серии добавляет только opt-in child-pressure snapshot:
free actor slots, actor/record bytes и completed/received counters; остальные
retry gates помечены `other`. Admission/таймеры/wire/cipher прежние.
697 session passed / 8 ignored; физического захвата с этим добавлением ещё нет.
Один преждевременный setup-call исключён; capture на Poco не объявлен
работающим. Ошибочный вывод о VPN отозван: parser совпал с `NOT_VPN`, raw
Transports подтверждает Wi-Fi. APK/контейнер/сеть/настройки восстановлены,
свои Core/capture/subscribers/processes убраны, production прежний.
Push/релиза нет. Предыдущие записи относятся к своим завершённым раундам.

Последний раунд: [routing announcement view](../routing-announcement-prefix-2026-11-07/README.md)
и [Poco baseline с TCP trace](../tcp-transit-detail-2026-11-07/README.md).
Для поиска собственного device address больше не проверяется весь чат после
объявления. В sovereign unchained журнале сохранены объявления и все raw
fork-slot варианты; linked prefix проверяется полностью прежним verifier.
Fresh header/ACL/cuts/clock/signatures сохранены, public state/records прежние;
legacy/encrypted/неправильная длина ключа используют полный путь.
33 focused, 651 related passed / 11 skipped, analyzer чистый. Baseline — четыре
assertion-red; девять mutations — десять assertion-red, без timeout.

Native A₁/B₁/A₂/B₂: во всех четырёх фазах 2000/2000 сообщений сходятся и
переживают SIGKILL, запуск без A/C, возврат только A и финальный cold boot.
Прямая цена linked lookup — 2 проверки из 66, unchained с потенциальным fork —
3 из 66. Но **общее ускорение не доказано**: финальный B₂ после `start(A)`
занял 25,681 с против 25,683/25,687 с controls; B₁ до последнего guard —
20,476 с. Объём догрузки/обратной работы различался. Median receiver stage
349,677/304,025/329,709/260,387 мс; догрузка остаётся активной.

**NETCALL-01 открыт.** Poco доступен, два вызова выполнены на отдельном Core
с рабочим узким TCP info logger. Оба baseline провалились **до** команды
смены сети: в первом Mac перестал принимать при растущем TX телефона,
во втором answer телефона не дошёл до dialing Mac. Handover не выполнен,
слышимость не проверена. Socket с большой TCP-очередью появился уже после
отказа второго сценария — причинная атрибуция отвергнута. Следующий участок —
source admission → Core → callback выбранного адресата. Сырые журналы приватны.
APK/контейнер/настройки восстановлены, свои процессы/порты/Core/capture убраны,
production прежний; push/релиза и sibling mailbox нет.
Предыдущие записи относятся к своим завершённым раундам.

Последний раунд: [history request wake](../history-request-wake-2026-11-07/README.md).
Подтверждён лишний backoff: ранняя presence занимает wake throttle, а валидный
обратный history-запрос не ускоряет уже ожидающий pull. В двух прежних сериях
один list повторялся через 16 с при работающем обратном обмене. Теперь
подготовленный ответ после fresh gates даёт отдельный throttled сигнал:
те же ID/cursor/attempts, минимум 2 с, 30-с throttle, прежние request leases.
Четыре baseline assertion-red и три независимые guard mutations без timeout;
142 passed / 1 skipped, analyzer чистый. Отзыв перед deferred retry соблюдён.

Native profiled A/B/C: после SIGKILL 751 наблюдавшаяся строка цела до сети
при offline A/C, затем только A возвращается; все 2000 ID/тел/delivered/
позиций/порядок сходятся без дублей/history retries и переживают ещё один
cold boot без источников. Начальный list повторился через 1,982 с вместо
прежнего 16-с интервала; отдельной native hook-записи нет, исключительная
причинная атрибуция/общий выигрыш скорости не заявлены. 25,683 с после
`start(A)` — один прогон с profiling. Между страницами median около 350 мс,
догрузка остаётся активной.

Исправлено перезаписывание профиля предыдущего boot в test worker: полный
CPU window 5444 samples / 40,513 с сохранён отдельно. Inclusive stacks указывают
на повторный validated device-journal view, canonical rows и crypto verdicts;
fresh authorization не убран. 1509 frozen inputs, 34 PID/57 портов очищены,
SDK/HVS/production прежние. **NETCALL-01 открыт**, Poco сейчас не виден ADB;
push/релиза и sibling mailbox нет. Предыдущие записи относятся к своим раундам.

Последний раунд: [служебные представления устройств](../device-protocol-view-2026-11-07/README.md).
Исправлены два подтверждённых дефекта: локальное скрытие прочитанных строк
забывало physical device address в protocol fold, а частые read-запросы
сдвигали логические write-часы и раньше времени применяли будущее событие.
Шесть регрессий, независимые красные mutations (3 value assertions + injected
setting failure; отдельно 2 clock assertions), 617 passed / 11 skipped,
analyzer чистый. Fresh authorization/journal load сохранены, UI скрытие прежнее.

Native A/B/C crash qualification: 623 наблюдавшиеся записи целы до сети при
обоих источниках offline; после возвращения только A все 2000 ID/тел/статусов/
позиций/порядок сходятся без дублей и history retries, затем переживают cold
boot без источников. 40,924 с после `start(A)` — один прогон, без причинного
вывода об ускорении. 1509 frozen inputs, 26 PID/29 портов очищены. Догрузка
по-прежнему активна; Android AOT для этих Dart-правок не квалифицирован.

**NETCALL-01 открыт:** [стандартный TCP 443](../standard-port-control-2026-11-07/README.md)
сам по себе не снял сбой. Один Poco→Mac не получил двусторонний baseline ещё
до перехода внутри звонка (phone RX 0, liveness silence 24 с); другой разговор
выдержал возврат Wi-Fi. [Следующие два с Core trace](../core-transit-reference-2026-11-07/README.md)
прошли по 60 с с конечным fresh RX на обоих endpoints. Это healthy reference,
а не устранение плавающего дефекта. Для TCP info-трассы следующему отдельному
QA unit дополнительно нужен узкий `RUST_LOG=warn,transport.tcp_trace=info`:
runtime trace появился, но CLI warn-фильтр не пропустил log::info TCP records.
APK/settings/runtime восстановлены, QA Core/capture убраны, production прежний.
Совместимость/production-сиды не менялись; sibling mailbox не добавлен,
push/релиза нет. Предыдущие записи ниже — результаты прежних раундов.

Последний раунд: [terminal writer shutdown](../failed-writer-shutdown-2026-11-07/README.md),
SDK `c6699c28`. После write failure/idle timeout убран повторный shutdown,
который добавлял до 5 с к reconnect. Три assertion-red проверки на прежнем
runner, 697 session tests passed / 8 ignored; doc ignored отдельно. На Poco
терминальная ветка реально сработала: timeout → close в одной миллисекунде
лога вместо прежних 5003 мс, затем новая session через 354 мс.

**NETCALL-01 остаётся подтверждённо открытым.** Из двух длинных Poco ↔ Mac
звонков первый прошёл минуту после возврата Wi-Fi; второй завершился через
25,32 с по `livenessTimeout` (silence 23/22 с) до команд отбоя теста. Старый
канал снят NetworkChanged, новый canonical не появился: два 10-с обфускационных
handshake timeout. Четыре primary/backup observations локально написали bytes,
но подходящие server capture flows не имеют payload; точка потери пока неизвестна.
Локальный media repair сменил epoch и обнулил RX, возраст -1 не принят за свежий
приём. Это не объявлено тождеством прежней отложенной жалобе «25 с».
Полный PCAP скопирован/проверен до cleanup, SDK/driver frozen, APK/settings
восстановлены, свои процессы/QA-Core убраны, production прежний. Следующий
контроль — свободный стандартный TCP-порт на том же QA-host. Push/релиза нет.

Предыдущие записи ниже относятся к своим завершённым раундам.


Последняя физическая квалификация:
[Poco ↔ Mac на SDK 4f441329](../binding-handover-2026-11-07/README.md).
Три платформенные native-сборки проверены, прежний signed QA AOT сохранён.
Четыре звонка без неожиданного отбоя, но **NETCALL-01 открыт**. Два Wi-Fi →
cellular внутри звонка: maximum observed native RX age до 1607 мс. Один
обратный cellular → Wi-Fi: 13314/12160 мс и нет пяти свежих конечных срезов
на обоих устройствах. Другой обратный переход быстрый. Устойчивые baseline
некоторых новых звонков требуют 22–41 с; это пять fresh samples, не первое аудио.
Driver `allCasesPassed` означает сохранность call state, не успех всего аудио.
Неполный PCAP после ошибки порядка cleanup исключён из packet-loss выводов;
полные endpoint/Core logs сохранены. Следующий участок — canonical/child
и primary/backup вокруг возврата Wi-Fi и холодного старта. APK/настройки
восстановлены по проверкам, свои процессы/порты/QA-Core убраны; production
прежний, push/релиза нет. Квалификация не закрывает историю/всю матрицу/звук Windows.

Последнее исправление NETCALL-направления:
[общее ожидание ACK дочернего канала](../ordered-binding-progress-2026-11-07/README.md),
SDK `4f441329`. Один заблокированный ACK прежде останавливал весь ordered
pool worker. Два финальных baseline assertions: 0 готовых вместо 1 и 1
начатый ACK вместо 8. Подтверждения теперь независимы при прежних proof,
lease, timeout и directional budget; retirement отменяет и join-ит flights.
Полный session: 694 passed / 8 ignored, один doc ignored отдельно; source и
test binary проверены, процессы завершены. **NETCALL-01 открыт:** на момент code-only проверки эффект
на физический звонок ещё не измерялся; новая FFI/APK тогда не устанавливалась.
На момент того раунда Poco не был виден ADB; Windows/телефон/production не менялись, push/релиза нет.

Последняя квалификация: [два одновременных native-источника истории](../history-multisource-2026-11-07/README.md).
A/E передали B полные authenticated ответы до снятия первого apply-барьера;
в этот момент архив B пуст. Затем оба cursor завершились, все 512 архивных
строк сошлись по ID/телам/delivered/позициям/порядку без дублей и history
ошибок. Все 513 строк с прежней историей сохранены после штатного restart B
до сети, когда A/E/C offline. Device-journal mirrors архива 0: проверен
own-history путь, без sibling mailbox. Production не менялся; 41 helper/oracle
tests и native process-test прошли. 1509 frozen inputs/native SHA неизменны;
38 PID/43 порта очищены. Это Mac/JIT и синтетический архив, не мобильный
handover/AOT/полная матрица и не измерение ускорения. Остаточная задержка
догрузки активна; Windows/Poco для физических проверок доступны по сообщению
владельца. Push/релиза нет.

Последнее изменение: [четыре подготовки own-history и безопасная очередь страниц](../history-preparation-2026-11-07/README.md).
Внутри страницы до четырёх независимых подготовок; input order, пачка ≤16
и fresh admission сохранены. Отмена отвергает поздний write boundary и
дожидается всех продолжений. Промежуточная параллельная версия показала
opposite-slot deadlock двух источников; пойман до commit и исправлен
последовательным apply страниц одного разговора. Другие разговоры независимы;
ошибка/отзыв первого источника не блокирует следующий. 103 tests passed,
пять mutations assertion-red без timeout. Native A/B/A: этап у получателя
535 / **337** / 523 мс; после `start(A)` до сходимости 46,024 / **35,818** /
46,032 с. В B/A2 по 1235 apply, 0 reverse encode; header RPC 1232 против 2121.
Все 2000 ID/тел/позиций/delivered сохранились после SIGKILL и финального boot
без источников. Два-source overlap здесь квалифицирован protocol unit;
следующая native-квалификация описана выше. Мобильный handover/AOT остаются
для проверки. Стенды очищены,
окончательный source восстановлен с runtime controls; SDK/HVS и production
прежние, push/релиза нет. Догрузка остаётся активной задачей.

Последнее изменение: [4-КиБ части own-device history](../history-page-slices-2026-11-07/README.md).
Один контрольный ответ требует 19 частей вместо 37; byte budget страницы
сохранён 128 КиБ отдельно от slice/count. Проверены точная граница, +1 байт,
decoded part 4097 байт и возможность исправить отвергнутый slot. Три cap
mutations assertion-red, 96 tests passed; fresh authorization не убран.
Native crash: 624 наблюдавшихся строки сохранились до сети (687 вместе с
in-flight), затем все 2000 ID/тел/статусов/позиций сошлись и пережили второй
старт без источников. Median part count 7 → 4, максимальный frame 5640 <6144.
После `start(A)` до сходимости 46,024 с против 51,241 с; условия/объём работы
различались, причинный общий выигрыш не заявлен. Следующий измеренный
интервал у получателя остался около 535 мс, основная задача догрузки открыта.
Стенд очищен, SDK/HVS и production прежние, push/релиза нет.

Последнее изменение: [меньше roster reads при подготовке истории](../history-local-encoding-2026-11-07/README.md).
Внутри полной текстовой страницы убраны 31 лишнее чтение device journal;
свежие проверки перед каждой сетевой частью и inline-content preparation
сохранены. Binding/close проверяются до и после каждого encoder, кэша прав
нет. 92 tests passed, baseline и final-authorization mutation assertion-red;
промежуточный пропуск inline-file gate пойман тестом и исправлен.
Native crash: 623 записи сохранились до сети после SIGKILL; затем все 2000
сошлись после возврата только A и пережили второй старт без источников.
После `start(A)` до сходимости 51,241 с против прежних 87,015 с; page reply
медиана 142,5 против 447,6 мс. Разные точки crash и объёмы повторной обработки:
общий выигрыш не является строгим A/B-результатом. Догрузка остаётся активной,
следующий интервал — обработка у получателя/переход к следующему запросу.
Стенд очищен; SDK/HVS, телефон и production прежние, push/релиза нет.

Последняя квалификация: [crash во время частичной догрузки](../history-crash-retention-2026-11-07/README.md).
B аварийно остановлен после 815 из 2000 сообщений. До сетевого старта
нового процесса сохранены все 815 ID, тела/delivered и 765 canonical
positions. При offline A/C остаток не появляется; после возврата только A
все 2000 строк, порядок и статусы автоматически сходятся. Повторный старт
B при снова offline источниках сохраняет все данные, проверено до сети.
34 oracle tests прошли, mutation missing-set assertion-red; production
не менялся. Это часть матрицы, не проверка каждой crash-стадии/суток offline.
Открыт измеренный остаток: весь сценарий 121,539 с, из них 87,015 с после
возврата из `start(A)` до сходимости. Page query→last part медиана 447,6 мс,
last part→next query 591,1 мс; причина темпа ещё не доказана. Следующий
разбор — повторные myOtherDevices/authorization reads, без снятия revoke gates.
Стенд очищен; SDK/HVS, телефон и production прежние, push/релиза нет.

Последнее изменение: [размер и byte budget history replay](../history-replay-batch-2026-11-06/README.md).
Приложение использует поддерживаемые durable-пачки до 64 событий вместо
консервативного default 25, с бюджетом подготовленных данных 32 КиБ.
Oversized строка остаётся целой; cadence, backlog, подписи и durable admission
сохранены. 48 replay + 5 group admission tests passed, analyzer чист.
Native A/B/A: **32,755 → 21,583 → 28,032 с**, окончательная byte-bound
версия — **21,373 с**. Все 2000 строк, порядок, позиции и delivered сошлись
без дублей. Group commit у получателя: 300/298 в контролях → 174 в финале;
это уменьшение повторной обработки журнала, не заявленное ускорение сети.
Разброс, 5-с опрос, JIT/loopback и свежие caches ограничивают перенос результата
на реальные устройства. Догрузка улучшена на стенде; mobile, crash/restart,
длительный offline и остальная матрица остаются для проверки. Стенды очищены,
SDK/HVS и production прежние; телефон не использовался, push/релиза нет.

Последнее изменение: [coalescing одиночных уточнений порядка](../ordering-coalescing-2026-11-06/README.md).
64 одновременных corrections требовали 64 commit; теперь ожидающие записи
одной пары conversation/provisional author объединяются в ограниченные
пачки (до 16 / 1800 байт). Close/erase дожидаются и последующего fold:
устранена воспроизведённая ошибка чтения уже закрытого storage после
успешной записи. First-winner, compare-and-adopt, erasure/admission,
raw positions, тела и статусы сохранены. Связанные suites 235 passed,
native 17 passed; skips нет. Native A/B/C: все 2000 строк, порядок,
позиции и delivered сошлись без дублей. Message commit census 429 → 360,
worker handler 8,612 → 7,462 с в закрытых FIFO-окнах. Общая догрузка
32,236 → 32,755 с: ускорения не заявляем, основной случай остаётся
открытым. Следующий участок — порции группового журнала и ожидание ingest.
Стенд очищен; SDK/HVS, телефон и production не менялись, push/релиза нет.

Последнее изменение: [растущий резерв внутренних message log ID](../message-log-reservation-2026-11-06/README.md).
Трасса разделила commit по фиксированным категориям: служебный учёт ID
занимал 250 транзакций / 4,876 с worker handler. Резерв начинается с восьми
после каждого открытия и растёт до 64 только после durable-сохранения.
Барьер выдачи ID, conversation seq и ratchet/authorization не ослаблены.
Контрольный тест на 256 сообщениях: прежний код — 32 записи резерва,
candidate укладывается в восемь; reopen, отказы, потеря ответа и capacity
проверены. Связанные suites 209 passed / 7 skipped; native 16 passed.
Native A/B/C: все 2000 строк, порядок, позиции и delivered сошлись без дублей;
полная сходимость наблюдалась за 37,860 → 32,236 с, count-complete почти
прежний (32,633 → 32,231 с). По одному прогону и опросу около 5 с общего
ускорения не заявляем. Census учёта ID: 253 → 42 commit; в закрытом
FIFO-окне — 250 → 41 и 4,876 → 0,830 с handler. Догрузка остаётся открытой:
наибольший измеренный остаток — запись сообщений и группового журнала.
Стенды очищены, SDK/HVS прежние, телефон и production не менялись;
push/релиза нет.

Последнее исправление: [master roster: изоляция, атомарный shrink и согласованное чтение](../roster-storage-lifecycle-2026-11-06/README.md).
Список личностей и SpaceKeys больше не переходят в следующий контейнер
из отложенного save/read и не восстанавливаются после erase. Уменьшение
списка публикует setting и удаление старой файловой копии атомарно; повреждённый
файл не заменяется по устаревшей тени. Optional cleanup после durable большого
файла остаётся best-effort, но повторяет попытку и для идентичных bytes.
База: 17 assertion-red в обоих backend; candidate 149 связанных passed /
1 native-only skipped и 29 native passed, включая настоящий child unlock
после file promotion/shrink/reopen. Analyzer чист, native fixtures удалены.
Полная storage/multi-device матрица и задержка догрузки остаются открытыми;
телефон, production и SDK/HVS не менялись, push/релиза нет.

Последнее исправление: [lifetime и порядок записей settings/profile/node config](../metadata-write-lifetime-2026-11-06/README.md).
Устранены запись значения A в следующий контейнер B, восстановление данных
после erase, перестановка сохранений и одинаковые параллельные транзакции.
База 15 assertion-red / 3 passed; candidate 205 связанных passed, native-набор
50 passed (26 native / 24 in-memory) и отдельный persistence smoke 1 passed.
В детерминированном burst 16 одинаковых сохранений дают одну транзакцию.
Все 2000 строк native A/B/C снова сошлись за 37,853 с без потерь/дублей;
основная задержка остаётся. FIFO-трасса показала около 23–24 с обработки
commit handlers в 42–43 с окне, но происхождение всех транзакций ещё не
разложено. Составные операции roster и других metadata требуют отдельной
lifecycle-проверки, не объявлены исправленными. Стенд очищен (22 PID / 33 порта),
SDK/HVS прежние, телефон и production не менялись; push/релиза нет.

Последнее исправление: [одно чтение контейнера при получении контакта](../single-contact-read-2026-11-06/README.md).
`getContact` больше не повторяет чтение записи для декодирования: 32 lookup
дают 32 namespace reads вместо 64, без кэша и изменения правил допуска.
База 1 assertion-red / 2 passed; связанные suites 181 passed / 24 skipped,
последующий запуск с HVS 48 passed без пропусков (наборы пересекаются).
Все 2000 сообщений на A/B/C снова сошлись по ID/порядку/позициям/delivered,
37,664 с до полного совпадения против прежних 38,065 с. Чтений контактов у B
5603 → 3219, но ускорение всей догрузки не доказано: по одному прогону,
около 5 с poll и разные caches/scheduling. Основная задержка остаётся.
Стенд очищен (22 PID / 34 порта), SDK/HVS прежние, телефон и production
не менялись; push/релиза нет.

Последнее исправление: [повторы own-device history и время жизни отправок](../own-history-retry-lifetime-2026-11-06/README.md).
Presence теперь будит существующий запрос с прежним ID/cursor, сохраняя
двухсекундный минимум и throttle; readiness возобновляет отложенную попытку.
Таймауты и смена bindings/roster больше не теряют учёт незавершённых отправок:
по одному запросу на sibling, до 32 запросов и отдельно до 32 ответов.
База: 8 assertion-red / 2 passed; candidate: 139 связанных тестов passed,
analyzer чист. Native A/B/C: все 2000 строк за 32,737 с, полный порядок,
позиции и delivered за 38,065 с, без потерь/дублей и повторов завершённой
истории. Это не A/B: общего ускорения и объяснения всех задержек не заявляем.
Стенд очищен (22 PID / 34 порта); SDK/HVS прежние, телефон отключён,
production не менялся. Большая история, остаток доставки и NETCALL-01
открыты; push/релиза нет.

Последнее исправление: SDK `b9b88bb7`, [пробуждение connector после operator unban](../operator-unban-wake-2026-11-06/README.md).
Трасса отделила 25–26 с ожидания соединений от дальнейшей доставки: admin-ban
стенд снимал запреты, но runtime не будил dial до следующего 30-с poll.
Теперь retained hint получает только нужный peer; остальные bans, pending
dials и admission gates сохранены. База 1 assertion-red, полный runtime
812 unit + 8 integration passed; 11 unit и 2 doc ignored отдельно.
На новой SDK первые межчастные соединения — 0,3–1,1 с; сходимость четырёх
устройств **13,070 с с trace / 13,396 с без trace**, против 35,568 с на базе
с trace. Все 17 строк, edit/delete, реакции, read position и restart B прошли.
Это исправление operator API: старые 35–45 с нельзя переносить на обычную
скорость приложения или считать причиной мобильных жалоб. Остаток доставки,
большая история и NETCALL-01 остаются открытыми. Стенды очищены, рабочие
реле/телефон не трогались, push/релиза нет.

Последнее исправление: [ранний сигнал о доступности до конца ACK-grace](../deferred-control-nudge-2026-11-06/README.md).
Durable-очередь больше не забывает ранний inbound: повтор запланирован на
конец прежнего растущего grace, без нового таймера и сокращения защиты от
лавины. База 2 assertion-red / 5 passed; связанные suites 45 passed,
expiry/races с настоящей HVS 45 passed (наборы пересекаются), analyzer чист.
Четыре прежних отказа durable-набора разобраны как ошибки fixtures/наблюдения:
после их исправления 42/42 на базе и candidate; ACK mutation снова assertion-red.
Native automatic-heal A/B/A: **45,455 → 37,344 → 42,350 с** до первой
сходимости. Во всех фазах 17 строк, delete/edit, реакции, read position и
restart B при offline A/C/D прошли; стенды очищены. Это свежие cache/identity
в каждой фазе, универсальное ускорение не заявлено. Ожидание догрузки
остаётся активным; телефон отключён, NETCALL-01 ждёт мобильной квалификации.
Production не менялся, push/релиза нет.

Последнее исправление: [direct-route retry после входящей активности](../message-route-up-nudge-2026-11-06/README.md).
Steady inbound больше не расходует cooldown события восстановления прямого
соединения; ожидающее сообщение освобождается от своей задержки до 24 с.
Повторные recovery notices ограничены, ACK/peer scope сохранены.
База: 1 assertion-red / 2 passed; candidate 3 passed, связанные suites 22 passed
(включая эти три), analyzer чист. В полном `durable_redrive_test.dart`
есть **четыре незакрытых отказа на базе и candidate**; весь набор не зелёный,
их причины вынесены в validation-запись, исправленными они не считаются.
Native regression на четырёх устройствах прошёл: 17 строк, edit/delete,
реакции, read position и restart B при offline A/C/D. Unban без join:
первая сходимость **45,455 с**, то есть задержка automatic recovery остаётся.
Эффект retry-фикса на этот симптом не доказан. Стенд очищен (28 PID, 35 портов),
телефон/production не трогались, push/релиза нет.

Последняя квалификация: [четыре устройства, live partition, edit/delete, реакции и read position](../multi-device-partition-2026-11-06/README.md).
Две личности A/B и C/D работают в изолированных половинах и сходятся после
healing; 17 ожидаемых строк без дублей, global delete побеждает edit, реакции
и read position согласованы. B сохраняет результат после restart при offline
A/C/D. Исправлен stand-only oracle: неизвестный одинаковый actor и дубли
device aliases теперь отвергаются; 5 unit passed, mutation assertion-red.
Сценарий повторён с усилением и отдельно без повторного join: unban alone,
первая сходимость **44,772 с**, затем 10-с устойчивость и offline-sources restart.
**Задержка auto recovery открыта:** около 30 с на B ещё не хватало восьми строк,
на C четырёх. Это доставка, не один stability wait; причина ещё не установлена.
Этой серией не проверены вся multi-device матрица, часы/сутки offline или звонки.
Все три стенда очищены, production/телефон не менялись, push/релиза нет.

Последнее исправление: [лишнее хэширование журнала при новой порции device-событий](../history-committed-selection-2026-11-06/README.md).
Для 25 свежих строк старый индекс хэшировал 1025 сохранённых, новый — 25;
точный SHA-256 membership и прежние auth/durable/lifecycle проверки сохранены.
На механически выделенном старом индексе 2 assertion-red / 4 passed, затем
8 focused passed; связанные suites 555 passed / 11 skipped, native run 12 passed
(наборы пересекаются), analyzer чист. AOT/native-SHA локальный A/B/A:
1,908 / 0,092 / 1,897 с на 80 повторов этапа, не всей догрузки.
На настоящем A/B/C 2000 ID/порядок/позиции/delivered сошлись без повторов:
38,091 с до и 32,842 с после, но poll около 5 с и по одному прогону — общего
причинного ускорения не заявляем. Догрузка остаётся активной. Оба qualified
стенда и ошибочный startup очищены; телефон/production не менялись, push/релиза нет.

Последняя квалификация: [полный NetworkChanged → reconnect → AEAD frame](../retirement-integration-2026-11-06/README.md),
SDK `bbeaf3a9` (новых production-изменений нет). Настоящий TCP/OVL1,
блокировка writer после handshake, настоящий MobileEventForwarder;
новый dial начинается без продвижения часов и после освобождения старого
транспорта. Новая регистрация/ключ/session ID и расшифровка wire-кадра проверены.
Удаление отмены writer даёт assertion-red; final runtime 811 unit + 8 integration
passed, пропуски отдельно. **NETCALL-01 открыт:** это локальный controlled
сценарий, не новая проверка Wi-Fi/cellular; Poco отключён пользователем.

Последний раунд: SDK `54c64c03`, [явный retirement и writer grace](../explicit-retirement-2026-11-06/README.md).
На прежней SDK `efe1c4ca` [прошли шесть Poco ↔ Mac звонков](../dead-writer-physical-2026-11-06/README.md),
три со сменой Wi-Fi/cellular/Wi-Fi. Пять финальных срезов RX свежие у обоих
концов, livenessTimeout нет, но возраст native RX достигал 12,512/13,140 с.
В одном разговоре media epoch сменился: непрерывность двигателя не заявлена.
Terminal keepalive → runner-ended теперь 1 мс, но явный network retirement
в одном случае всё ещё занимал 5002 мс. Этот отдельный барьер воспроизведён
на настоящем runner и исправлен с сохранением обычного drain: 2 assertion-red
на базе, 5 focused passed, полный session 692 passed / 8 ignored / 1 doc ignored.
**NETCALL-01 открыт.** Новая правка ждёт мобильной квалификации: Poco отключён
пользователем после законченной серии. QA/production восстановлены,
свои приложения и Core остановлены, push/релиза нет.

Последнее исправление: [writer drain после terminal keepalive](../dead-writer-grace-2026-11-06/README.md),
Veil `efe1c4ca`. После решения признать TX непригодным runner ещё мог ждать
graceful writer до 5 с; в сохранённом телефонном capture промежуток 5002 мс.
Настоящий runner воспроизводит эту задержку (1 assertion-red, normal-drain
контроль pass). После правки оба проходят: выход без продвижения часов,
transport закрыт, старая регистрация не блокирует reconnect. Normal/idle
drain и detector guards сохранены. Session 689 passed / 8 ignored / 1 doc
ignored; runtime 810 unit + 8 integration, FFI 397, пропуски отдельно.
**NETCALL-01 открыт:** эффект на мобильном звонке новой SDK ещё не проверен.
Приложения/реле не запускались, production не затронут; push/релиза нет.

Предыдущее изменение: [ограниченный backup obfs4](../obfs4-backup-2026-11-06/README.md),
Veil `dd6129b0`. Pending handshake через 1 с получает один запасной
transport-кандидат в пределах прежнего общего 10-с deadline; fast path,
обе auth-проверки, отмена и предел двух попыток покрыты. Transport
171 unit + 5 smoke + 2 doc; runtime 810 unit + 8 integration; FFI 397,
пропуски отдельно в отчёте. Diagnostic privacy: Dart 19 + Python 1.
Реальный Mac/FFI/embedded node прошёл controlled blackhole первого flow:
выбран backup, primary закрыт через 1,316 с, exact Mac transport active
на изолированном Core. **Poco исчез до установки; звонков на новой SDK нет.**
Это не A/B (другой QA host), не устранение зависания уже установленного TCP
и не закрытие NETCALL-01. Готовые обе FFI/APK сохранены; стенд очищен,
production прежний, push/релиза нет.

Предыдущее исправление: [потеря reconnect wake](../reconnect-wake-gap-2026-11-06/README.md),
Veil `aa51cc13`. Смена сети/gain между отказом dial и созданием retry-wait
могла теряться; обе ветки assertion-red на базе. Подписки теперь живут весь
проход connector, собственный gain не снимает refusal pause (отдельный
настоящий handshake и mutation-red). Runtime 810 unit + 8 integration passed,
11 unit / 2 doc ignored; FFI 397 passed / 11 ignored, отдельный child 1 passed,
5 doc ignored. **NETCALL-01 открыт:** [новая физическая серия](../reconnect-wake-physical-2026-11-06/README.md)
на этой SDK снова теряет звонок на Mac через 23,379 с после команды Wi-Fi off,
с `livenessTimeout` до cleanup. Два отдельных новых звонка прошли; после off
пять свежих двусторонних RX-срезов лишь за 18,397 с. Второй запланированный
network-cut цикл не выполнен. Два 10-с incomplete Read с unacked первой
TCP-посылкой остаются транспортным свидетельством, не полной атрибуцией.
QA/production проверены при очистке; push/релиза нет.

Предыдущий контроль: [handover с двумя QA-реле](../two-relay-handover-2026-11-06/README.md).
Тот же SDK `29ee0700`, изменены только QA seed assets. Оба клиента реально
active на обоих Core до звонка. Один Mac → Poco разговор пережил три цикла
Wi-Fi/cellular/Wi-Fi, media epoch 1 обоих не менялся, последние пять срезов
RX fresh. Положительный source admission наблюдался обоим Core; максимальный
native RX age до 1,397/4,566 с. Один transport timeout остался, но отбоя не
было. Это не A/B и не доказательство, что именно второй путь устранил паузу.
**NETCALL-01 открыт**: single-path и новый звонок после переключения этой
серией не закрыты. Следующий контроль — управляемая потеря QA-пути и
регрессия на возможную потерю reconnect wake между проверкой и ожиданием;
пока это кандидат, не новая подтверждённая причина. Оба стенда убраны,
production и основной APK не затронуты, QA/настройки восстановлены; релиза нет.

Последняя физическая проверка: [Poco obfs4 first flight](../poco-obfs-first-flight-2026-11-06/README.md).
NETCALL-01 **подтверждён и открыт**. Новый observer SDK `29ee0700` собран,
проверен и реально сработал на обоих клиентах. Первые два handover цикла
звонок сохранили; в третьем оба endpoint завершились по liveness timeout.
Canonical obfs4 ожидал 10001 мс: 171 байт приняты TCP, read 0, notsent 0,
unacked 1, четыре kernel retransmission. Outer timeout следует через 1 мс,
phone call-end — ещё через 4,786 с. Ожидание до socket write для этой попытки
исключено; конкретный участок ОС/модем/NAT/сеть не установлен. NIC реле быстро
отвечал на все 80 flow с client payload; точная привязка failed mobile flow
не доказана из-за NAT. Следующий контроль — несколько доступных QA-реле,
а не изменение аудиобуфера. Стенд убран, APK/настройки восстановлены,
production-код/сиды не менялись; push/релиза нет.

Последняя работа: [obfs4 handshake diagnostics](../obfs-handshake-diagnostics-2026-11-06/README.md).
NETCALL-01 **открыт**. В ещё одном Mac → Poco Wi-Fi/cellular/Wi-Fi разговоре
canonical obfs4 timeout не повторился, native RX age до 1,326/2,066 с;
разговор завершён стендом. Shell Android не даёт полный TCP_INFO через
netlink. Закрыт пробел SDK-диагностики: opt-in observer снимает стадию,
байтовые счётчики и live TCP snapshot до Drop handshake, с локальными ports
для сопоставления; после upgrade application I/O не учитывается. Таймеры,
аутентификация и wire не менялись. 161+5+2 transport checks, 19 privacy tests
и AOT artifact gate прошли. Новая диагностика ещё не установлена на Poco:
физический прогон использовал прежний SDK, причинного исправления паузы
не заявляется. Стенд удалён, APK/настройки восстановлены; push/релиза нет.

Последняя локализация: [Delivery handover: obfs4/TCP](../delivery-obfs-handover-2026-11-06/README.md).
NETCALL-01 **подтверждён и открыт**. В прежнем аварийном захвате dial
начинался сразу после Cellular notification; два последовательных obfs4
handshake ждали по 10 с. Версия ожидания старого runner для того случая
опровергнута. Новые три network-only цикла без obfs4 timeout; в одном
Mac → Poco разговоре timeout повторился один раз, native RX age до
14,7 с, но звонок пережил оба перехода и завершён стендом. На NIC отдельного
QA-Core все 107 flow с client payload получили первый server payload за
0,240–1,305 мс; 47 TCP flow без client payload. Связь конкретного flow с
failed dial пока только временная, не доказанная. Следующий контроль —
client TCP queue/INFO и local port непосредственно во время handshake.
Сборки прежние, production-код/таймеры/защиты не менялись; свой стенд удалён,
QA APK и настройки восстановлены, production не затронут, push/релиза нет.

Последняя физическая проверка: [Poco ↔ Mac, Delivery после смены сети](../poco-mac-delivery-reconnect-2026-11-06/README.md).
**NETCALL-01 подтверждён и открыт.** С разрешённым микрофоном Mac
двусторонний baseline прошёл. Первый Wi-Fi → cellular → Wi-Fi в разговоре
сохранил RX и media epoch обоих концов. Но следующий телефон → Mac сразу
после Wi-Fi off позвонил за 1,173 с и не получил двусторонний baseline за
50 с: Mac сначала принял 5 пакетов, затем RX стоял, rebuild не восстановил
приём. В обратном Mac → телефон после handover оба конца завершились по
`livenessTimeout`; потеря call state +22,975 с при validated cellular
через 1,254 с. Отбой предшествовал cleanup стенда, Core ещё был active.
Actual path — **non-onion Delivery relay** (`relay_send`), поэтому
`81436bd1` / private `PinnedRoute` этим прогоном не квалифицируется.
Native уведомление Cellular получено; следующий участок — parent session /
ordered child / Delivery после него, в том числе при уже отсутствующей TX.
Это новый handover-timeout, не доказанная причина старой 25-с жалобы.
QA APK/основной APK/старый QA-контейнер сверены по SHA, сеть/настройки
восстановлены, свои процессы и временное реле удалены; production прежний.
Слышимость человеком и A/B не проверялись. Push/релиза нет.

Последнее исправление: [private media и точная TX-регистрация](../private-media-tx-lifetime-2026-11-06/README.md).
ПОДТВЕРЖДЕНО и исправлено в Veil `81436bd1`: `PinnedRoute` ещё решал пригодность
по общему exit counter. Заменённая TX при ещё живом старом runner оставляла
старый route пригодным; поздний exit старого runner мог сбрасывать свежий.
Пригодность и probe сверяются с exact-registration самого circuit;
возраст/активность/confirmation/deadline и crypto не ослаблены.
Один baseline assertion-red, focused 1 passed, полный FFI 375 passed /
10 ignored, formatting чист. **NETCALL-01 открыт**: физического повтора
после этой правки ещё нет. Отправка телефона в локальную очередь во время
предыдущей RX-паузы подтверждена, доставка этих пакетов — нет.
Для следующего прогона нужны Poco с SIM и разрешение микрофона Mac;
при начале проверки ADB был пуст. Без push/релиза и изменений production-реле.

Последняя физическая проверка: [Poco → Mac через отдельный QA-Core](../poco-mac-resume-2026-11-06/README.md).
Оба клиента и QA-Core на `ade3130a`; P2P заранее запрещён. Первый двусторонний
baseline не прошёл: Mac ожидал системное разрешение микрофона. Последующий
принимающий Mac проверил направление телефон → Mac: validated cellular через
1,345 с, длительный интервал без fresh RX 18,458 с, пять свежих срезов начиная
с +22,319 с. Новый звонок после Wi-Fi off: incoming +2,243 с, окончание
пятисрезового baseline +18,113 с. Это пакетные метрики, не слышимость и не A/B.
На QA-Core три `session.resume_replace` с префиксом телефона и ноль dedup:
исправленная ветка допуска физически работает, **NETCALL-01 всё ещё открыт**.
Восстановление сопровождалось local media repair; следующий участок —
пригодность старого datagram-канала после resume, с разрешённым микрофоном Mac.
Попутно исправлен настоящий profile `/screenshot` crash на assertion-only
`debugNeedsPaint`: profile PNG после пересборки, 5 тестов, analyzer чист.
QA APK/основной APK/старый контейнер сверены по SHA, настройки и Wi-Fi
восстановлены, свои приложения закрыты. Отдельный QA relay удалён;
production PID/бинарник/конфиг/NRestarts прежние. Push/релиза нет.

Последнее исправление: [ticket resume и stale predecessor](../relay-resume-predecessor-2026-11-06/README.md).
ПОДТВЕРЖДЕНО и исправлено в Veil `ade3130a`: корректное возобновление no-row Leaf на Core блокировалось старой
TX-регистрацией; в relay-only окне сохранённой серии реле отклонили пять
подключений QA-префикса как дубликаты. Добавлена узкая замена только точного
predecessor из проверенного ticket после свежего ATTACH MAC; обычные дубликаты,
mesh/scheduled rows и более новый owner защищены. Тест дополнительно выявил,
что повторный session ID позволял late old guard удалить replacement.
Ticket resumption теперь получает свежий согласованный connection ID;
вывод directional keys и живой HandoffAttach сохранены. Старые версии не
квалифицируются по решению владельца; обе стороны resume нужно обновлять вместе.
Baseline допуска 1 assertion-red / 2 passed, отдельный ID guard 1 assertion-red;
полный контроль 1664 passed / 19 ignored. Подробные границы и агрегаты в отчёте.
NETCALL-01 **открыт**: нового физического замера после этой правки нет;
прежние 19–20 с auto и 10,3 с relay-only не объявляются устранёнными.
Владелец отключил Windows; следующий физический стенд — телефон ↔ MacBook.
Реле только читались; APK, основной контейнер/настройки телефона, engine pins,
production-сервисы, push и релиз в этом цикле не менялись.

Последнее исправление: [BootstrapJoin и повтор NETCALL-01](../bootstrap-join-dial-isolation-2026-11-06/README.md).
ПОДТВЕРЖДЕНО и исправлено в Veil `c65a8d0c`: добавление/повтор одного bootstrap
peer отменял in-flight dial других peer через общий network-change wake.
Production drain теперь использует per-peer refresh; настоящая смена сети
по-прежнему отменяет устаревшие попытки. Два baseline assertion-red; focused
13 passed; полный контроль 999 passed / 16 ignored (отдельно).
Три звонка Poco/Android 16 ↔ Windows QA прошли без неожиданного отбоя, но
NETCALL-01 **открыт**: при validated cellular через ~1,1 с fresh RX вернулся
через 18,943/20,044 с; при заранее запрещённом P2P — через 10,296 с.
Новый звонок сразу после Wi-Fi off: incoming 14,585 с, fresh RX 16,826 с.
Это native payload counters, не слышимость; маршруты не фиксировались, A/B нет.
Изоляция dial cancellation не объявляется устранением всей паузы.
Настройки/P2P-политики/QA APK восстановлены, исходный контейнер и основной
`.2` не менялись; свои процессы/task/runtime/туннели/порты закрыты.
Push/релиза и изменений сидов нет.

Последняя физическая проверка: [Poco Wi-Fi ↔ cellular](../poco-handover-recheck-2026-11-06/README.md).
NETCALL-01 повторился на текущем Android profile/AOT (`efdb4d0e`, SDK Dart
`70478463`) с фиксированным Windows QA. Оба звонка завершены командами стенда;
внутри первого native RX age достиг 16,8 с, fresh RX вернулся через 17,636 с
от отключения Wi-Fi. При возврате Wi-Fi age до 3,47 с. Новый звонок после
отключения Wi-Fi: incoming 7,319 с, первый fresh RX обоих концов 11,727 с.
Это RTP/состояния, не слышимость и не A/B. Восстановлены validated Wi-Fi,
прежние сетевые/awake настройки и QA APK по SHA; старый QA-контейнер и основной
`0.13.94-fingerprint.2` не менялись. Все процессы/task/туннели/порты закрыты.
В коде найден кандидат общего cancellation wake на BootstrapJoin, без red-test
и без причинной атрибуции физической паузы; production-код в этом цикле не менялся.
Владелец отдельно подтвердил работу отпечатка в обычном `.2`; этот дефект закрыт.
Push/релиза и изменений сидов нет.

Текущий шаг: [один запрос отпечатка](../android-single-biometric-2026-11-05/README.md).
Владелец подтвердил работоспособность `0.13.94-fingerprint.1`, но при холодном
входе нужны два касания. Android read переведён на свежий CryptoObject при
каждом входе, без отдельного LocalAuth и без plaintext-key cache plugin.
KeyInfo/strong-biometric policy, отмена/stop/dispose и поздние результаты
защищены. Два baseline-red, 80 Flutter tests passed, Kotlin gate smoke и
analyzer прошли. На Poco/Android 16
cold и warm open настоящего QA-контейнера прошли; владелец подтвердил по одному
запросу. Back/Home не выдали пароль; парольный fallback прошёл. Probe удалён.
Обычная `0.13.94-fingerprint.2` установлена поверх `.1`: исходная подпись,
те же native/assets, SHA/firstInstallTime/startup smoke проверены. После smoke
приложение остановлено; пользовательский контейнер не открывался.
Push/публичного релиза и изменений сидов нет.

Последнее исправление: [быстрый вход по отпечатку на Poco](../android-biometric-startup-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: запрет marker-less migration в secure-storage 10.3.4 блокировал
инициализацию нового биометрического namespace. Разрешён штатный путь с
сохранением strongBiometricOnly, AES-GCM и запрета reset. Три baseline-red;
75 связанных tests passed, analyzer чистый. На Poco/Android 16 отдельный QA
с настоящим отпечатком настроил запись и открыл настоящий encrypted-контейнер
после force-stop/start с новым PID. Отмена не выдала пароль; парольный fallback
и удаление настройки после перезапуска проверены. Biometric lockout снят
владельцем системным unlock, без обхода. Probe остановлен и удалён; основной
контейнер и xVeil 0.13.94 не менялись. Push/релиза и изменений сидов нет.
Затем по запросу владельца на этот Poco установлена обычная подписанная
`0.13.94-fingerprint.1` поверх прежней версии: release base + только этот fix,
те же native/сетевые assets. SHA, подпись, firstInstallTime и startup smoke
проверены; после smoke приложение остановлено. Настройка в реальном контейнере
остаётся за владельцем. Публикации релиза не было.

Последняя квалификация звука: [известный сигнал на Windows](../windows-receive-pattern-2026-11-05/README.md).
Жалоба на тишину остаётся открытой. В отдельном native stand опубликованная
и текущая media DLL приняли Opus по 20/40/60 мс и вывели все три заданных тона
в собственной Windows audio session; silence control остался тихим. Семь
qualified запусков, 10 tests oracle; source/binary SHA и cleanup проверены.
Это lossless receive/Windows ADM/session-peak квалификация, не реальный звонок,
телефонный захват, сеть или человеческая слышимость. Приёмный gain не менялся.
Windows task/processes/fake DLL удалены; пользователь разрешил работать без
телефона. Production code, pins, сиды, push и релиз не менялись.

Последнее исправление: [отмена группового запуска](../group-start-cancel-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: stop ожидал в очереди, а старый group start после permission/IPC
открывал peer channels и запускал capture. Поколение запроса теперь меняется
до ожидания очереди; late channel и ключи очищаются до допуска преемника.
18 baseline assertion-red / 6 passed; финальные 24 случая и контроль 420 passed
/ без skip, analyzer чистый. Same-call mute сохраняется; промежуточная потеря
intent поймана четырьмя red и исправлена. Это controller-квалификация на Mac,
не physical audio/Android FGS; исходные тишина и NETCALL-01 открыты. ADB пуст.
Native pins, сиды, push и релиз не менялись.

Последнее исправление: [отбой во время подготовки медиа](../media-preflight-cancel-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: после stop во время чтения prefs прежний start заново приобретал
network activity и оставлял grant удержанным; более поздние отмены допускали
лишние channel opens. Следующий start также пропускал незаконченное чтение
и терял сохранённый вход. Семь baseline assertion-red / восемь passed.
Post-await guards и общая Future чтения исправлены; контроль 373 passed / без
skip, analyzer чистый. Это controller/MethodChannel квалификация на Mac,
не Android FGS или физический handover. NETCALL-01/слышимость открыты, ADB пуст.
Native pins, сиды, push и релиз не менялись.

Последнее исправление: [lifecycle запуска аудио](../audio-start-owner-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: после ожидания выбора аудиоустройства или маршрута прежний start
обращался к disposed engine при stop, новом звонке и same-call замене engine.
Девять baseline assertion-red и три healthy control. Проверки epoch/engine/call
после await и до выбора устройства отменяют старую операцию; successor
успешно запускается. Контроль 345 passed / без skip, analyzer чистый.
Это controller-квалификация, не доказанная причина пользовательской тишины.
Windows SSH повторно доступна с авторизацией; ADB пока пуст.
Native/engine pins, сиды, push и релиз не менялись.

Последнее исправление: [lifecycle включения видео](../video-upgrade-owner-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: старый upgrade после audio-route await перезаписывал Call и
срывал следующий start; поздняя permission обращалась к disposed engine,
same-call repair терял upgrade. Шесть baseline assertion-red и один healthy
control. Permission теперь вне route queue, mounting выбирает текущий engine
после ремонта; post-await guards отменяют чужую/устаревшую операцию.
Финал: 333 tests passed / без skip, analyzer чистый. Это model/controller,
не физическая квалификация Android или атрибуция мобильной паузы/тишины.
Телефон в ADB отсутствует; NETCALL-01 и слышимость остаются открытыми.
Native/engine pins, сиды, push и релиз не менялись.

Последнее исправление NETCALL-01: [network-change worker](../network-change-worker-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: синхронное ожидание native dispatch receipt в `Future` блокировало
основной Dart event loop. Три regression-red; SDK `70478463` использует worker
с сохранённым completion/error/lifetime контрактом. SDK 74 passed / 1 skipped,
app control 348 passed, analyzer чистый. Настоящий embedded node принял все
10 временных уведомлений по Unix и authenticated TCP; stop/sidecars/порты
проверены. Первый неверный file-log observer не засчитан и очищен.
Физический mobile handover и слышимость не квалифицированы: ADB пуст.
Это снятый локальный механизм, не доказательство устранения полной паузы.
Rust/engine pins, сиды, push и релиз не менялись.

Последнее исправление: [чтение журнала звонков и граница личности](../call-journal-read-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: отказ namespace-read выдавался за пустой журнал, навсегда завершал
legacy migration без публикации и экспортировал ложный restore success.
Восемь ordinary/worker-native assertion-red; ошибка теперь передаётся caller,
миграция остаётся повторяемой. Экран показывает отказ и повтор. Ещё два UI-red
закрыли прежние строки при смене личности и contact lookup старого чтения в
новом storage. Scoped 67, consumer control 811 passed / 3 skipped, финальные
widget 5 passed; analyzer чистый. Process A/B/C с post-commit SIGKILL writer:
итоговая запись сохранилась и дошла обоим без дублей; 26 PID / 24 порта закрыты.
Отказ restore по-прежнему не блокирует свежие звонки; replay при недоступной
истории и исходная жалоба на звук этим не объявлены исправленными.
Push/релиза, изменений сидов, engine pins и own-device mailbox нет.

Последняя квалификация: [partition и revoke](../partition-revoke-recheck-2026-11-05/README.md).
Три native/process suite прошли: четыре устройства сошлись после split-brain,
edit/delete/reactions/read и cold restart B; отозванный B после получения
актуального документа C не доставляет новые звонки/сообщения и не скачивает
новый файл даже с известным content ID. Положительные controls сохранены.
Все процессы/порты закрыты, source/native SHA совпали. У файлового suite
после product pass повторена только cleanup-проверка из-за временной
недоступности внешнего диска. Полная матрица не объявлена пройденной.

Звук: [контролируемый стимул](../controlled-speech-2026-11-05/README.md)
через явно выбранный встроенный выход Mac, NS on/off/on в одном звонке.
Источник завершился, но временной рисунок речи на входе телефона и выходе
Windows не установлен; исходная жалоба и слышимость остаются открытыми.
Production gain не менялся. Windows SSH снова проверен и доступен.
Новых production-правок, push, релиза и изменений сидов в этом раунде нет.

Текущий шаг: [актуальный звук Windows ↔ Android](../current-audio-windows-android-2026-11-05/README.md).
Свежие DLL/ELF из текущего C++, все 107 API, source/binary guards. Два
принятых QA-вызова на Windows 11 + Blackview: наблюдение 39,905/81,450 с,
capture/playout=1 и RTP в обе стороны. Ненулевые цифровые уровни наблюдались,
но попытка речевого стимула не квалифицирована по timeline; слышимость
человеком не проверена. NS off/on через
UI Android достиг native без смены call/epoch, AEC/AGC сохранились.
Реальные UI-отчёты прошли allowlist/canary аудит: Android 251, Windows 289
событий; по два audioStart/callEnded. В Windows есть отдельный
TransportUnavailable из peer-sync, связь со звуком не установлена.
Исходный Poco/mobile случай и акустическое качество открыты. Engine release
pins ещё не обновлены. Стенд остановлен, задачи/forward/временные файлы убраны;
основные приложения, сиды, mailbox, push/релиз не менялись.

Текущий шаг: [порядок приветствия при повторах запроса](../contact-greeting-order-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: request не передавал сохранённый seq; undecided retries
перенумеровывали приветствие, resend терял timestamp. Реальный messaging/storage
воспроизводитель дал разный canonical порядок после accept. 10 assertion-red
(пять worker/native); новая передача сохраняет seq/timestamp, legacy retry —
первую локальную позицию. 14 новых случаев, 154 scoped и 940 diagnostic control
passed / без skip; analyzer чистый. Старые искажённые позиции не мигрируются,
физическая повторная квалификация последней правки не выполнена. Исходная
недоставка/звук этим не атрибутированы. Push/релиза и изменений сидов нет.

Текущий шаг: [Windows ↔ Android, контакты и сигнализация](../windows-android-signaling-2026-11-05/README.md).
Текущий Dart и свежие Veil/HVS: принятые контакты, текст и входящий UI
в обе стороны квалифицированы на Windows 11 + Blackview. Исходная Windows 10
жалоба и слышимость речи этим не закрыты; media не запускалась.
ПОДТВЕРЖДЕНО новое расхождение: одинаковые три ID/body/timestamp без дублей,
но старое приветствие стоит в разном месте канонической истории. Причина
на момент прогона была неизвестна; последующее локальное воспроизведение
и исправление request/retry описаны выше.
Реальные анонимные UI-отчёты прошли allowlist/canary аудит, errors=[].
Ошибки предусловий раннего стенда исключены. Приложения/задачи/forward
остановлены, профили сохранены. Push/релиза и изменений сидов нет.

Текущий шаг: [повтор звонка при допустимом skew](../call-replay-skew-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: finished cache истекал раньше полного admission window offer:
при +30 с на часах отправителя завершённый звонок снова звонил на +91–120 с.
Четыре assertion-red; cache теперь учитывает allowance. 306 scoped и
806 diagnostic control passed / без skip, analyzer чистый. Свежие звонки
сохранены. Это не атрибуция пользовательского ПК ↔ Android случая.
Новая Android QA-сборка с текущими FFIs запускается отдельно от основного
приложения; Windows FFIs собраны в изолированном каталоге. Физическая
сигнализация квалифицирована в записи выше. Замороженный release engine не соответствует
текущему C++: стенд ограничен сигнализацией, новая аудиочасть не проверена.
Push/релиза, сидов и mailbox собственных устройств нет.


Текущий шаг: [независимая версия disappearing policy](../contact-policy-convergence-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: поздний alias snapshot скрывал новую policy другого устройства
при live gate и fold; одинаковые identity/clock давали first-wins; одинаковый
wire ID разных policy позволял ACK одной снять другую. 6 baseline assertion-red
и 4 дополнительных wire-red до правки ID, всего 4 worker/native red.
Policy получает отдельный `contactUp/d:<peer>` key и исходный clock; metadata,
consent и P2P не меняются вместе с ней. Fold/gate/winner используют общий
детерминированный порядок. Publisher требует обе проекции и ограничен
32 snapshots / 64 events. ID внешней доставки различает TTL/read значения.
20 новых случаев (5 worker/native), 208 scoped, отдельная history suite 43,
719 diagnostic control, 2090 broad passed / 3 skipped; analyzer чистый,
headless AOT/--help прошёл. Native A/B/C: все 10 gates, actual compaction
удалила 10 signed rows, cold B сохранил policy; одинаковый clock с разными TTL
сошёлся. Cleanup 46 PID / 55 портов чистый, 1475 inputs/native SHA неизменны.
Offline archive projection, conflict timeline caption и полная матрица ещё
требуют проверки; физический Windows случай не закрыт. Сиды, APK/engine pins,
mailbox собственным устройствам, push/релиз не менялись.

Текущий шаг: [durable публикация настроек контакта](../contact-preferences-durable-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: после local commit отказ callback оставлял preference без
повторяемой публикации своим устройствам; два ordinary/native assertion-red.
Contact и immutable snapshot теперь коммитятся вместе, GUI boot/link/periodic
publisher передаёт исходную версию в committed device journal; CAS ACK не
снимает новую обязанность. Own echo сверяет durable floor внутри storage turn.
Отдельный replay-red: status materialization применял старые preferences мимо
их ordering slot. Replay теперь проходит через gate, unknown apply deferred.
151 scoped, 700 diagnostic control, 2071 broad passed / 3 skipped в 112 файлах;
analyzer чистый, headless AOT/--help прошёл. Финальный process A/B/C прошёл семь
gates, включая offline-created preference → GUI boot → B с тем же ts.
Cleanup 30 PID / 35 портов чистый, 1474 inputs/native SHA неизменны.
Первый новый boot-gate провалился и не засчитан; также исправлена запись
тестовой трассы без parent folder. Полная конфликтная/crash матрица и физический
Windows-репорт остаются открытыми. Own-device mailbox, сиды, APK/engine pins,
push/релиз не менялись.

Текущий шаг: [коллизия recipient/revision в доставке disappearing policy](../disappearing-recipient-outbox-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: ID из setAtMs/setBy был общим для разных контактов, а Outbox
ключуется глобально по frameId. При совпадении этих полей второй адресат не
получал durable обязанность доставки; два assertion-red (ordinary/native).
Теперь ID содержит адресата. Повтор того же recipient/revision дедуплицируется;
обе записи переживают reopen, настоящие inbound policy и ACK проходят,
чужой ACK не удаляет запись, повтор не дублирует marker. 141 scoped,
671 diagnostic control, 2042 broad passed / 3 skipped; analyzer чистый.
Это локальный storage/dispatch regression на трёх endpoint, не физический
reconnect/звонок. Старая несохранённая обязанность не восстанавливается.
Исходный Windows случай, durable публикация preferences и полная матрица
остаются открытыми. Blackview/сиды/engine pins/own-device mailbox не менялись;
push/релиза нет.

Текущий шаг: [атомарные настройки контакта и собственные старые проекции](../contact-preference-atomic-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: stale Contact DTO мог вернуть pending после accept, отменить
block/P2P deny/TTL/архив и воссоздать удалённый contact. 22 baseline assertion-red
на ordinary/worker-native HVS. Отдельно process A/B/C дважды показал потерю pin
при последовательных name → pin → archive на самом A; четыре модельных red
подтвердили собственный запоздавший echo. Чтение/transform/commit настроек теперь
сериализованы с consent writers; own echo проверяет локальный witness внутри
storage turn. Статус и device-local P2P не берутся из старого снимка.
Дополнительный carrier-verdict red закрыт: ошибка сохранения disappearing policy
не выдаётся за успешный durable приём. Финал: 46 новых случаев (23 native),
139 scoped, 669 diagnostic control, 2040 broad passed / 3 skipped в 109 файлах;
analyzer чистый, AOT/--help прошёл. Process A/B/C прошёл все пять boot/prefs gates,
включая cold B; cleanup 27 PID / 43 порта чистый, 1469 inputs/native SHA неизменны.
Исходный Windows ↔ Android случай этим не объяснён; SSH к Windows в этом цикле
недоступен. Crash-durable публикация preferences и полная conflict/crash матрица
открыты. Own-device mailbox, сиды, APK и release pins не менялись; push/релиза нет.

Текущий шаг: [кэш согласия после конкурентного block](../contact-consent-cache-2026-11-05/README.md).
ПОДТВЕРЖДЕНО: late accept-side effects и stale accepted reads разрешали
call/P2P control после завершённой блокировки, включая ordinary cache writer.
16 baseline assertion-red (восемь worker/native), два здоровых controls.
Кэш теперь требует актуальный per-peer witness; запись инвалидирует его
на входе и выходе, старый accept не прогревает кэш. 34 новых сценария включают
настоящий CallService FSM без media: blocked не достигает ringing.
151 scoped, 539 diagnostic control, 1985 broad passed / 3 skipped в 106 файлах,
analyzer чистый, headless AOT/--help прошёл. Process A/B/C прошёл три boot/handoff
gates; cleanup 24 PID / 42 порта чистый, 1468 inputs/native SHA неизменны.
Остальные writers/полная conflict/crash матрица ещё требуют проверки; исходный
Windows случай этим не объяснён (сценария block в репорте нет).
Mailbox для собственных устройств, push/релиз и сиды не менялись.

Текущий шаг: [durable решения о контактах своим устройствам](../contact-decision-sync-2026-11-05/README.md).
Подтверждено отсутствие повторяемой обязанности после сбоя callback: два
ordinary/native assertion-red. Статус, ordering floor и намерение синхронизации
теперь сохраняются вместе; boot/periodic publisher передаёт исходную версию в
committed device journal, CAS-ACK сохраняет новые решения. Late mirrors не
отменяют более новую локальную версию; linking не restamp'ит известную версию.
36 scoped, 505 diagnostic control и 1951 broad passed / 3 skipped в 105 файлах,
analyzer чистый, headless AOT/--help прошёл. Process A/B/C воспроизвёл durable
post-commit/pre-callback состояние и прошёл recovery + второй boot с тем же ts.
Teardown 25 PID / 41 порт чистый, 1467 inputs/native SHA неизменны.
Это закрывает указанную GUI boot/handoff границу; полная contact conflict/crash
матрица, другие writers контакта и исходный Windows случай остаются открытыми.
Mailbox для собственных устройств, push/релиз и обновления сидов не добавлены.

Текущий шаг: [атомарное первичное принятие контакта](../contact-accept-atomic-2026-11-05/README.md).
Подтверждён разрыв между локальным accepted и сохранением ответа: ошибка
Outbox оставляла принятый контакт без durable accept. Статус, contact index и
ответ теперь коммитятся вместе; потерянный ответ commit восстанавливается
только после полного readback. Dispose ждёт принятое действие, callback failure
не снимает обязанность ответить; анонимный `contact-accept` не хранит исходные
тексты/пути. 12 baseline assertion-red; финальные 20 ordinary/worker-native
scoped cases, control с diagnostics 440 passed, broad 1884 passed / 3 skipped
в 100 файлах, analyzer чистый. Headless AOT/--help и все пять process A/B/C
gates прошли; teardown 27 PID / 37 портов чистый, 1463 inputs/native SHA
неизменны. Локальная atomicity закрыта в указанных пределах;
crash-durable публикация решения своим устройствам и исходный Windows случай
открыты. Mailbox для собственных устройств не добавлен, push/релиза нет.

Текущий шаг: [ACK запроса после durable приёма](../contact-handshake-commit-2026-11-05/README.md).
Подтверждены ранние ACK/seen перед enqueue ответа, разрешение mailbox ACK по
таймауту/исключению и поглощение локального dispatch failure. Повтор запроса
теперь сохраняет шанс восстановления; carrier не удаляет незавершённую/ошибочную
копию. GUI/headless не ждут сетевой receipt после локальной обработки.
12 native/ordinary baseline red, 4 relay-verdict red и отдельный getContact red;
408 control с diagnostics/native HVS без skip, broad 1803 passed / 64 skipped
в 99 файлах, analyzer чистый. Headless AOT build/--help прошли; это не сетевой
прогон. Primary user accept status/outbox atomicity и исходный Windows случай
остаются открытыми. Mailbox для собственных устройств не добавлен, push/релиза нет.

Текущий шаг: [освобождение ingress после durable accept](../contact-handshake-ingress-2026-11-05/README.md).
Повторный request/reconnect от accepted contact держал ordinary inbox за первой
сетевой попыткой ответа (стандартное окно до 10 с); последующий ordinary call
signal не доходил до обработчика. Четыре old-code assertion-red, включая два
worker/native HVS. Ответ теперь ожидает только local enqueue и отправляется
через bounded/coalesced recipient queue; dispose присоединяет реальный send.
27 scoped прошли без skip; broad 1732 passed / 58 conditional skipped,
93 файла; 403 control с diagnostics/native HVS без skip, analyzer чистый.
Причина пользовательского ПК ↔ Android случая не установлена,
физического Windows повтора нет; общие ACK и первичное принятие не изменялись.
Mailbox/push/релиза нет.

Новый активный репорт: [ПК ↔ Android: запросы, звонки, registry](../user-pc-android-calls-2026-11-05/README.md).
По точному release-stack подтверждено чтение resume registry до unlock/при
закрытии контейнера; локально исправлено без удаления durable intent. Текст
неподтверждённого relay deposit больше не выдаёт его за отказ локального
сохранения. Недоставка подтверждений и звонков возвращена в активную очередь:
семь PC-вызовов остались dialing, медиадвижок не запускался; root cause не
доказан. Добавлены анонимные type/lane/disposition категории call control,
вместо вывода о WebRTC из одного счётчика arrivals. Windows стенда сейчас
недоступна; физическое воспроизведение этого пользовательского случая не
объявляется выполненным. Push/релиза нет.

Завершён [TTL после полного durable admission снимка](../device-snapshot-admission-2026-11-05/README.md),
коммит `ed6e65fc`: полный own-device transfer блокирует initial/retry до
асинхронной сериализованной проверки, не удерживая producer group lock.
Устаревший результат не разрешает новую concurrent admission, failure остаётся
fail-closed, dispose присоединяет проверку. 44 scoped passed без skip;
1508 passed / 56 conditional skipped в 85 файлах. Native A/B/C прошёл все
пять TTL/Outbox gates, 27 PID / 27 портов проверены, runtime удалён,
1459 frozen inputs и native SHA неизменны. Последующие transport/fragmentation
waits, policy/skew/legacy partials и общая latency/multi-device матрица открыты.
Mailbox для собственных устройств не добавлен.


Текущий цикл: [clock TTL после storage waits](../device-expiry-clock-2026-11-04/README.md).
Шесть old-code assertion-red подтвердили stale batch clock после policy/prune
awaits. Два дополнительных red в первом кандидате выявили canonical row без
tombstone после позднего prune. Теперь expiry использует свежий clock и при
refused marker сверяет собственный timestamp canonical row; свежая конфликтная
копия сохраняется. 28 scoped tests с явно заданной HVS (7 native / 21 ordinary)
прошли без skip; 1500 passed / 48 conditional skipped в 84 файлах, analyzer
helper + всего test чистый. Process A/B/C прошёл все пять TTL/Outbox gates:
raw roots, свежая доставка и cold B без A/C. Cleanup чистый — 27 PID /
28 портов, 1458 frozen inputs, runtime удалён, native SHA прежние.
Post-full-admission TTL, native transport waits, policy/clock и расширенная
матрица/общая latency остаются открыты. Mailbox/push/релиза нет.

Текущий цикл: [атомарный admission chunked snapshot](../group-transfer-admission-2026-11-04/README.md).
На прежнем sender восемь ordinary/native red подтвердили incomplete durable
копию (1/8 из 17 частей) при первой отправке/потере ответа. Теперь все logical
indexes публикуются вместе до live legs. Крупный payload соблюдает native cap
1024 log appends через staging без indexes и durable cleanup obligation.
Два дополнительных red поймали re-enqueue после TTL в первом кандидате;
initial sender теперь проверяет exact current row и не сохраняет её заново.
26 scoped native-backed/ordinary tests прошли без skip, 1495 passed / 43
conditional skipped в 84 файлах, analyzer lib inputs + всего test чистый.
Process A/B/C прошёл все пять TTL/Outbox gates, включая raw roots и cold B
без A/C. Teardown чистый: 28 PID / 29 портов, 1458 frozen inputs, native SHA
прежние, runtime удалён. Уже осиротевшие legacy partials не объявлены
восстановленными; transport/policy/clock, latency и остальная матрица открыты.
Mailbox/push/релиза нет.

Текущий цикл: [конкурентная очистка direct edits](../concurrent-outbox-expiry-2026-11-04/README.md).
Подтверждены stale/null lookup после tombstone, ранний success/потеря ошибки
при совместной очистке, сохранение старого тела при pre-enqueue retry и ранний
dispose. Локальная правка объединяет результат очистки, повторяет tombstone,
сохраняет queue age и присоединяет локальные операции при shutdown. Регрессия
промежуточного кандидата (TTL истекает во время последнего read) поймана двумя
red и исправлена проверкой clock после await. 33 scoped tests с явно заданной
native HVS прошли без skip; широкая серия 1463 passed / 30 conditional skipped,
analyzer чистый. Финальный direct-edit A/B/C прошёл все пять gates, включая
raw-root cleanup, cold startup и void ACK→новую доставку. Teardown чистый:
23 PID / 27 порта, 1456 frozen inputs, runtime удалён, native SHA прежние.
Остальные transport/partial/policy/clock и общая latency/матрица открыты.
Mailbox/push/релиза нет.

Последний шаг: [TTL после durable enqueue edit](../outbox-enqueue-expiry-2026-11-04/README.md).
По пять ordinary/native red подтвердили сохранение expired/deleted правки
при пропущенном live leg и позднюю sibling publication. После enqueue теперь
обязательный persisted guard; caller повторяет TTL до edit publisher.
Три age-red на обоих backend закрыты сохранением actual queue stamp при
bodyless replacement. Здоровая silent/TTL-off ветка и точный retry после
отказа replacement сохранены. 1454 tests / 21 skipped в 80 файлах, 15 scoped
с явно заданной HVS без skip, analyzer чистый. Snapshot A/B/C и direct-edit
void→durable ACK→fresh delivery прошли; cleanup 28/24 PID и 35/30 портов,
1455 frozen inputs в каждом, runtime удалены, native SHA прежние. Первый
direct прогон не засчитан из-за неверного first-raw-read oracle: запрос
опередил завершение async startup sweep на 47 мс. Проверка теперь ждёт
automatic cleanup в прежнем pre-30-с бюджете; UI projection проверен отдельно.
Остальные transport/early-ACK/parallel cleanup/partial/policy/clock skew и
вся матрица открыты; mailbox/push/релиза нет.

Последний шаг: [TTL во время edit commit](../edit-io-expiry-2026-11-04/README.md).
Шесть TTL shapes воспроизведены на прежнем product-коде; окончательная fixture
повторно дала 6 native assertion-red. После правки исходящие, входящие,
mirrored/reflected edits заново проверяют original post clock/tombstone после
записи. Expired edit не попадает в sibling publication; incoming ACK ждёт erase,
exact retry и peer void; reflected seq не становится authored slot. 1447 tests /
14 skipped в 79 файлах, 24 scoped с явно заданной HVS без skip, analyzer чистый.
A/B/C normal-path regression: 100 conflicting edits / cold retention / author
upgrade без C и без дублей; test/driver/cleanup 0/0/0, 40 PID / 52 порта /
1454 frozen inputs, runtime удалён, native SHA прежние. Более поздние publisher/
Outbox/transport ожидания, partial/policy/clock skew и полная матрица открыты.
Mailbox/push/релиза нет.

Последний шаг: [TTL при конфликте clocks зеркальных копий](../clock-conflict-expiry-2026-11-04/README.md).
Два настоящих red на FakeHv/native HVS подтвердили удаление свежих journal
mirror/edit из-за старой копии того же ID при живой canonical row. Helper
теперь признаёт удаление ID только по durable tombstone; иначе ретирует
только expired row. Queued filter сохраняет точные живые подписи, storage
cleanup и local seq floor проверены после reopen; обычное дальнейшее expiry
не отключено. 1438 tests / 5 skipped, 14 scoped с явно заданной HVS без skip,
analyzer чистый. Real-signer A/B/C: A сохранил живые rows после инъекции старого
clock, B догнал edit при offline C и сохранил его после restart без A/C;
дублей нет. Test/driver/cleanup 0/0/0, 24 PID / 26 портов / 1453 frozen inputs,
runtime удалён, native SHA прежние. Остальная clock-skew/TTL/transport и общая
матрица открыты; mailbox/push/релиза нет.

Последний шаг: [TTL внутри publisher и парной записи журнала](../publisher-ttl-boundary-2026-11-04/README.md).
Подтверждены post-publisher отправка истёкшего тела и сохранение expired mirror
при задержанном завершении atomic pair. Добавлены повторная проверка store,
тихий save/recheck/scrub до подтверждения device batch и точная TTL boundary.
Отдельные два red выявили обход через независимый key-share snapshot; его
запуск отложен до cleaned committed bundle, без сетевого ожидания в ingress.
Ошибка scrub не публикуется как успех, exact retry после восстановления
завершает очистку. Широкая серия 1437 passed / 4 skipped; финальные 6 targeted
с явно заданной native HVS без skip, analyzer чистый. Финальный fresh-file
A/B/C: две receiver byte-копии и две sibling metadata copies без дублей;
test/driver/cleanup 0/0/0, 18 PID / 21 порт / 1452 frozen inputs, runtime удалён.
Первая попытка с отсутствующим private evidence-каталогом не засчитана;
product между попытками не менялся. Другие transport I/O/partial/policy/clock skew
и полная матрица остаются открыты; mailbox/push/релиза нет.

Последний шаг: [TTL между append и публикацией](../store-ttl-boundary-2026-11-04/README.md).
Три red tests подтвердили выдачу expired post/offer в publication/send/notices,
если append завершался после TTL. Общий store теперь возвращает null после
сохранённого удаления; вызывающие ветки прекращают отправку/уведомление/fetch,
необъявленный streaming source закрывается. Ошибка удаления сохраняет exact
retry без ACK. Pending-delete double publication поймана и исправлена отдельно.
Финальная полная серия: 1432 tests / 3 skipped в 78 файлах; 78 targeted,
10 native cases и analyzer также прошли. Fresh A/B/C file regression: две receiver cold копии и две
sibling metadata copies без дублей, 18 PID/30 портов/1452 frozen inputs, все
стенды закрыты. Remaining: expiry внутри publisher/очередей, edit/transport I/O,
partial transfers/policy/clock skew и остальная матрица. Mailbox/push/релиза нет.


Последний шаг: [TTL входящих файлов и предложений](../media-ttl-2026-11-04/README.md).
Подтверждены и локально исправлены legacy сборка после TTL и регистрация/
автозагрузка full manifest/ref после отказа expired/deleted сообщению.
Время partial transfer фиксируется при первой meta, проверяется перед chunks;
сообщение получает durable bodyless expiry decision. Surface возвращает
результат допуска; handler прекращает unsolicited download. Shared CID не
удаляется/не блокируется глобально, свежий per-send ID работает. Claimed query
остаётся read-only; регрессия первого кандидата воспроизведена и исправлена.
Eventless hint не оживляет единственную истёкшую named строку. 1361 tests /
3 skipped, финальные 22 targeted и 6 native cases прошли. Native process A/B/C:
2 файла в обе стороны, две cold receiver копии байт-в-байт и две sibling
metadata copies без дублей; test/driver/cleanup 0/0/0, 18 PID/26 портов/
1450 frozen inputs, native SHA прежние. Первый oracle source-copy был ошибочен,
исправлен в тесте; продукт между попытками не менялся. Analyzer чистый.
Остальные async I/O,
partial persisted/download, source-NACK/policy/clock skew и полная матрица
ещё открыты. Mailbox для своих устройств не добавлен; push/релиза нет.


Последний шаг: [TTL входящего текста и правок](../inbound-ttl-2026-11-04/README.md).
Подтверждены и локально исправлены запись/публикация expired peer post,
повторная выдача held original при свежем retry timestamp, peer/mirrored edit
истёкшего target. Новая строка сразу становится bodyless tombstone, собственный
peer seq правки — void; ACK ждёт запись/scrub/required deletion publication.
Reflected/mirrored revision не превращается в authored slot. Ошибки оставляют
exact retry и доступны в анонимном отчёте. 1167 tests / 3 skipped, финальные
37 targeted, 8 native cases и analyzer чистые. Process A/B/C сохранил все пять
прежних gates TTL/edit/void ACK/новой доставки; 24 PID / 32 порта / 1447 frozen
inputs, runtime удалён, native SHA прежние. Это регрессия, не A/B latency.
Остальные body-bearing kinds,
async I/O expiry windows, partial transfers/policy/clock skew и полная матрица
остаются открыты. Mailbox/push/релиза/изменения APK или сидов нет.


Последний шаг: [TTL при прямой догрузке истории](../peer-history-ttl-2026-11-04/README.md).
Четыре красных теста подтвердили выдачу expired post/edit/file metadata и
own-echo при недоступном фоновом prune. Источники теперь фильтруют TTL; свои
slots становятся пустыми только после durable tombstone, чужие не подделываются.
После async ожиданий tail revalidated; ошибки доступны в анонимном отчёте.
Попутно подтверждён на архиве прежнего HEAD и исправлен потерянный reconnect
во время startup cleanup: явный запрос ждёт барьер, обычный cadence сохранён.
1153 tests / 3 skipped, финальные 25 targeted, 3 native cases и analyzer чистые.
Process A/B/C восстановил 100 правок через C при offline A, сохранил их после
restart и подтвердил авторской историей A при offline C; дублей нет.
Test/driver/cleanup 0/0/0: 40 PID / 56 портов / 1444 frozen inputs, runtime
удалён, native SHA прежние. Это регрессия сходимости, не замер ускорения.
Проверки ingress/partial-transfer/policy/clock skew и общая latency остаются
открыты. Mailbox для собственных устройств не подключался; push/релиза нет.


Последний шаг: [TTL при запуске и чтении](../startup-ttl-2026-11-04/README.md).
Исправлены подтверждённые startup timer gap, выдача expired rows/preview в UI,
обычный retry во время медленного prune и точное равенство TTL cutoff. Initial
cleanup coalesced/owned, dispose ждёт записи; текущие поздние group bindings
запрашивают проход, stale owner не может. Group defer не расходует network
backoff, call controls не блокируются; ordinary recovery cadence сохранён.
1044 tests прошли, 3 skipped отдельно; 15 native cases и analyzer чистые.
Process A/B/C: первый raw read C уже чистый через 9270 мс после запуска,
раньше старого 30-с timer; void ACK и новая доставка работают. Отдельный
own-snapshot A/B/C подтвердил retained state, raw-root cleanup и cold B без
A/C. Оба test/driver/cleanup 0/0/0; 24+26 PID / 28+24 порта / 1441 frozen
inputs в каждом, runtime удалены, native SHA неизменны. Это локальная
квалификация проверенных путей, не все I/O-failure/peer ingress/gap-fill,
policy/clock-skew/Android и partial-transfer границы. Mailbox/push/релиза/
обновления APK, движков или сидов нет.

Последний шаг: [TTL прямых правок в Outbox](../direct-edit-expiry-2026-11-04/README.md).
Подтверждены и локально исправлены сохранение/повторная отправка отдельного
edit body после expiry исходного post и ранний ACK входящего `voidSeq`.
Вместо правки сохраняется bodyless slot, legacy без seq удаляется exact-CAS;
scrub obligation, retry и исходный возраст очереди сохранены. 776 основных
tests прошли, 3 skipped отдельно; 14 native cases, analyzer и process A/B/C
прошли. В native roots после остановки нет прежней target edit/непустых orphan
payloads, void получил durable ACK и новая доставка работает. Cleanup: 24 PID,
30 портов, 1438 frozen inputs; runtime удалён. Первый process прогон не зачтён:
его финальный oracle не ждал первого фонового TTL sweep C после restart;
product code между повторами не менялся. Наблюдение остаётся: raw history C
очищается при первом 30-с периодическом проходе, немедленного sweep при start
нет; UI не проверен. Другие body-bearing kinds, неполные own-device transfers,
ожидания внутри transport/fragmentation и остальная матрица остаются открыты.
Mailbox/push/релиза/обновления APK, движков или сидов нет.

Последний шаг: [TTL payloads в durable Outbox](../device-outbox-expiry-2026-11-04/README.md).
Подтверждены и локально исправлены полные snapshot и компактные `mid`/`mh`
delta с expired mirror/edit bodies, включая chunked wire. Остальные raw signed
rows сохраняются; новая полная durable копия предшествует атомарной ретирации
старой, scrub retry и возраст очереди переживают reopen. 790 основных tests
прошли, 3 skipped отдельно; 10 native cases и analyzer чистые. Сквозной A/B/C:
raw native roots после остановки A без expired IDs/непустых orphan payloads,
живая setting row и новая доставка сохранены после restart, cold B без A/C
не воскресил сообщения. Test/driver/cleanup 0, 27 PID / 26 портов, 1434 inputs
и native SHA стабильны. Первый неудачный стенд поймал compact-delta пробел,
был очищен и не засчитан. **Не закрыты:** неполные durable transfers, другие
виды queued bodies, policy/clock-skew границы и остальная матрица.
Mailbox/push/релиза/обновления APK, движков или сидов нет.

Последний шаг: [очистка device journal по TTL](../device-journal-expiry-2026-11-04/README.md).
Истёкшие mirror/edit bodies, включая author heads, удаляются с сохранением
локального sequence floor; remote snapshot не может подменить этот floor.
Очистка включена в background sweep и admission device rows; отказы header,
segment deletion и vacuum имеют durable retry. Добавлен явный detach для
inventory guard; утечка `ownHistoryApplyPrepared` не подтвердилась — ordinary
setter уже очищал его. 627 основных tests прошли, 3 skipped отдельно,
7 усиленных journal cases прошли повторно, analyzer чистый. Native process A/B/C:
после очистки и restart A новая доставка B/C работает, старые journal и chat IDs
не возвращаются после cold restart B без A/C. Driver/test/cleanup 0, 28 PID /
33 порта проверены, runtime удалён, 1427 inputs и native SHA стабильны.
Остаются другие копии TTL — прежде всего transport Outbox — и непроверенные
политика/clock-skew границы. Вся TTL-матрица не закрыта; mailbox/push/релиза нет.

Последний шаг: [TTL при повторе журнала устройств](../mirror-expiry-admission-2026-11-04/README.md).
Подтверждён и локально исправлен admission уже истёкших incoming/outgoing
mirrors: до записи тела остаётся пустой durable tombstone с исходной позицией,
без remote-delete обязательств. 325 основных + 4 native tests прошли,
analyzer чистый. В отдельных A/B/C процессах B получил реальные истёкшие
journal entries, но не создал сообщения; после TTL-off и cold restart без A/C
они также не вернулись. Driver/test/cleanup 0, 24 PID / 25 портов проверены,
1427 inputs и native SHA стабильны. **Отдельно подтверждено и остаётся открытым:
тела сохраняются в подписанном device journal после TTL переписки.** Отказ
проекции не является их очисткой. Вся TTL/clock-skew матрица и общая latency
не закрыты; mailbox/push/релиза/смены APK и сидов нет.

Последний шаг: [живой partition и конфликт удаления](../partition-delete-convergence-2026-11-04/README.md).
На текущем продукте заново проверены A/C ↔ B/D при нулевых cross-сессиях,
конкурентных сообщениях, edit/delete, реакциях и прочтении. Старый oracle
покрывал только локальное удаление; добавлен «удалить у всех» с обязательным
расхождением до healing, точным составом итоговой истории и cold restart B
при остановленных A/C/D. Все проверки прошли: 16 новых ID ровно по одному,
общий порядок внутри каждой личности, ожидаемые 17/18 строки локальной ветки
и 17 у всех глобальной, реакции/read markers согласованы; состояние B сохранено.
Продукт не менялся, нового дефекта не найдено. Четыре исполнения/driver/cleanup
0/0, native SHA прежние, 1386 выбранных inputs стабильны; своих процессов и
listeners нет. Это выбранные сценарии 20/31/32 и сохранность после merge,
не вся матрица, не crash-cuts/TTL/clock skew и не замер общей latency.
Mailbox/push/релиза/обновления APK или сидов нет.

Последний шаг: [пакетное исправление позиций истории](../history-ordering-cohorts-2026-11-04/README.md).
Прежние per-row ordering commits заменены ограниченными пакетами до 16 через
тот же mirror merge; raw authorship, тело и экспортируемые sequence slots
не меняются. Фиксированный native A/B/A на копиях одного контейнера: 64 → 4 →
64 data commits, ожидание adapter-пути 1280 → 133 → 1139 мс. Это эффект участка,
не всей догрузки. 368 основных и отдельно 27 census/timeline проверок, 13 native
tests прошли; analyzer 15 inputs чистый. Первая сквозная серия прошла
функциональную проверку, но была отвергнута старым profiling gate: теперь
commit выполняется вне per-row Zone. Измеритель исправлен с реальным
publication/RPC witness, gates содержимого не ослаблены. Повторная серия:
B сохранил 1572 строки без A/C, от одного A восстановлены все 2000 ID/порядок/
positions/delivered без дублей и completed-history retries; retention прошёл.
Восстановление после готовности A — 31,395 с, не парный замер с предыдущими.
7 ordering batches; driver/cleanup 0/0, 29 PID / 39 портов / 1424 frozen inputs.
Mailbox/push/релиза/обновления APK или сидов нет; общая latency и матрица открыты.

Последний шаг: [пакетное применение собственной истории](../history-prepared-cohorts-2026-11-04/README.md).
Короткие новые строки проходят прежний mirror merge, приостанавливаются на
append и публикуются пакетами до 16. Для фиксированных 64 сообщений post
commits сокращены с 64 до 4; fsync/padding/churn не ослаблялись. Свежие
revoke/binding/visibility и начавшаяся очистка проверяются перед публикацией;
курсор ждёт durable запись и все продолжения. 203 проверки и 9 native tests
прошли, analyzer чистый. Sparse crash/reconnect: B сохранил 1847 строк без A/C,
затем от одного A сошлись все 2000 ID/порядок/positions/delivered без дублей и
completed-history retries; retention прошёл. После готовности A — 26,077 с.
Это не A/B с прежними 41,726 с (тогда B сохранил 1572): общего ускорения не
объявляем. Стенд закрыт: 31 PID / 42 порта / 1424 frozen inputs. Первый запуск
с отсутствующим evidence-каталогом не засчитан и отдельно очищен.
Mailbox для собственных устройств не добавлялся. Push/релиза/смены APK и сидов
нет; общая latency и расширенная матрица ещё открыты.

Последний шаг: [разложение native durable-коммитов](../native-commit-stages-2026-11-04/README.md).
На private instrumented HVS, без изменения продовой зависимости и протокола,
измерены этапы коммитов в настоящей sparse crash/reconnect серии. В процессе
восстановления B: 694 успешных native commits, 2776 sync calls; 9,845 из
10,283 с native body (95,7%) занял File::sync_all. Это доля native commits,
не всей догрузки и не только физического диска. Ни одного успешного commit
без padding/reuse не было: простое удаление «пустого» четвёртого sync здесь
не поможет и не внедрено. Следующий существенный участок — ограниченное
batch-применение истории с сохранением merge/revoke/session/cursor границ.
Контроль: 35 FFI, 40/40 worker RPC/handler, 6 parser/installer tests прошли;
checksums 45. После SIGKILL B сохранил 1572 строки без источников, затем от
одного A сошлись все 2000 ID/порядок/positions/delivered без дублей/повторов;
retention прошёл. 41,726 с после готовности A — не A/B с прежними 36,513 с
(тогда сохранено 1672). Стенд закрыт: 31 PID / 45 портов / 1420 frozen inputs.
Private target очищен. Библиотека помечена mustNeverShip; обычная не заменена.
Mailbox/push/релиза/смены APK и сидов нет. Latency и матрица ещё открыты.

Последний шаг: [native SHA-256 при проверке групповой цепочки](../history-chain-sha-2026-11-04/README.md).
Убрано повторное Dart-вычисление стандартного SHA-256 на native host; точные
protocol hashes и независимый domain-эталон сохранены. Membership/revoke,
свежий journal и последовательное применение строк проверяются по-прежнему.
На одном неизменном контейнере и VM-проверенных исходниках A/B/A: 441 → 413 →
445 мс за 40 материализаций 256 подписанных строк. 533 group/history/sync +
10 crypto/native проверок прошли, 3 skipped отдельно; analyzer чистый.
Sparse crash/reconnect сохранил 1672 строки без A/C, затем восстановил все
2000 ID/порядок/positions/delivered от одного A, без completed-history retries;
retention без источников прошёл. После готовности A — 36,513 с; прежние
41,827 с не парный контроль (тогда сохранено 1583 строки). Общая latency
остаётся открытой, главный handler-остаток — commits. Post-restart timeline
квалифицирован, два коротких/оборванных trace отвергнуты. Стенд закрыт:
31 PID / 42 порта / 1416 inputs, native SHA и зависимости неизменны.
Mailbox/push/релиза/смены APK или сидов нет.

Последний шаг: [повторное использование страниц индекса HVS](../log-index-reuse-2026-11-04/README.md).
Подтверждено и локально устранено повторное чтение одного leaf при exact-ID
группах: 33 → 2 chunk reads на 32 записях. Ограниченный cache живёт только
один вызов; guards/digest и свежесть сохранены. На одном неизменном
контейнере native A/B/A: 147 → 105 → 140 мс для сжимаемых данных,
187 → 137 → 172 мс для случайных, по 100 чтений. Это выигрыш компонента,
не всей догрузки. 664 core + 35 FFI + 6 native cases прошли, 2 ignored
отдельно; checksum 45/API/fmt/clippy/docs/analyzer чистые. Sparse crash/reconnect:
после восстановления без A/C сохранены 1583, затем от одного A получены все
2000 ID/порядок/positions/delivered, без дублей и completed-history retries;
retention без источников прошёл. После готовности A — 41,827 с, но прежние
31,299 с не являются парным контролем (тогда сохранено 1798 строк). Latency
остаётся открытой; текущий handler-остаток — commits и grouped reads.
Новый закрытый timeline после restart квалифицирован; два коротких/оборванных
capture отвергнуты и не используются. Стенд закрыт: 29 PID / 42 порта,
1413 inputs и native SHA неизменны. HVS target очищен. Mailbox/push/релиза нет.

Это список незакрытых случаев и ограничений проверки, а не утверждение, что
каждая прежняя жалоба воспроизводится в текущей сборке.

Последний шаг: [строгое разложение storage RPC](../storage-worker-timeline-2026-11-04/README.md).
Изменения только в test-fixture: VM trace реального single worker, ограниченный
независимый capture, проверка FIFO/потерь и приватная обработка. В закрытом
окне 42,996 с сопоставлены 10 912 RPC и 10 912 handlers; по 74 крайних spans исключены,
пропусков внутри нет. Grouped reads: 5,609 с await, 5,300 с внутри handler;
commit: 7,656 / 7,055 с. Одиночный metadata get: 5,373 / 0,266 с — значительны
время до начала обработки и возврат. Handler включает adapter/native работу;
fsync отдельно не измерен, inclusive waits не являются эксклюзивной ценой диска.
Сходимость sparse crash/reconnect — 2000 ID/порядок/positions/delivered,
сохранность после restart без A/C. После A ready — 31,299 с при другом объёме
восстановления и включённой диагностике; ускорение этим не объявляется.
98 тестов + отдельные native/CPU controls прошли, analyzer чистый. Два ранних
VM capture отвергнуты из-за пропусков, их предварительные числа не используются
как итоговая атрибуция. Все три стенда закрыты и teardown проверен.
Следующий участок — повторные свежие чтения журнала и durable apply; latency
остаётся открытой. В production lib/ изменений, mailbox/push/релиза нет.

Предыдущий шаг: [более полные bounded own-history pages](../history-page-window-2026-11-04/README.md).
Лимит сообщений в порции — 32 вместо 8, при прежних 128 КиБ / 64 частях,
admission budgets и актуальных проверках до/после apply. На 65 коротких строках
9 запросов сменились 3 (red/green). Ответ с 33 событиями отвергается до apply;
revoke на двадцатой строке останавливает порцию без checkpoint. 115 тестов прошли,
analyzer чистый. Зачтён sparse crash/reconnect: 1542 строки после SIGKILL,
95 поздних provisional за дырой; только A вернулся, все 2000 ID/порядок/positions/
delivered сошлись и сохранились без A/C. После A ready — 41,020 с; прежние
51,122 с не парный A/B, процента общего ускорения нет. Page queries 77 → 20
при 616 → 629 history-apply. Основной остаток — обработка/сохранение и свежие
проверки device journal; latency остаётся открытой. Первый новый native и
CPU-profile прогон не прошли sparse-предусловие и не зачтены как эта ветка.
Все три стенда закрыты и teardown проверен. Mailbox/push/релиза нет.

Предыдущий шаг: [ограниченное native-чтение exact-ID групп](../native-log-groups-2026-11-04/README.md).
Подтверждена повторная распаковка одного DataBatch внутри группового чтения;
HVS теперь использует ограниченный кэш только до возврата вызова. На одном
артефакте scalar → groups → scalar: 285 → 81 → 272 мс для сжимаемых данных;
через worker/FileStore 347 → 169 → 331 мс. Exact IDs, ранний отказ, digest на
каждой ссылке и свежесть между вызовами сохранены. 660 core + 35 FFI + 122 plugin
+ 621 xVeil тест прошли; 2 core ignored / 3 xVeil skipped указаны отдельно.
Все 4 native hash-контроля прошли. Полный sparse crash/reconnect восстановил
2000 ID/порядок/positions/delivered от одного A и сохранил результат без A/C.
После готовности A — 51,122 с; прежние 46,023 с не являются парным контролем,
объём обработки различается. Ускорение всей догрузки не объявляется;
latency остаётся открытой. Стенд закрыт и независимо проверен. Новый FFI-метод
требует совместной пересборки bindings/native artifacts всех платформ перед
публикацией; здесь проверена частная macOS-библиотека, ABI gate сохранён.
Mailbox/push/релиза нет.

Предыдущий шаг: [разложение own-history и отклонённое увеличение частей](../history-carriers-2026-11-04/README.md).
3-КиБ carrier вместо 2 КиБ не уменьшил число частей коротких страниц на native
стенде и не показал ускорения; production-изменение возвращено к исходному.
Новая атрибуция находится только в fixture. В зачтённом sparse crash/reconnect
прогоне все 2000 ID/порядок/positions/delivered сошлись и сохранились без A/C.
A подготовил 559 событий за 22 мс inclusive await; B применил их за 7,61 с,
в том числе 7,37 с в commit RPC. 1751 свежий own-device lookup на B — 23,88 с
inclusive await; это не эксклюзивное время, интервалы могут перекрываться.
Основной остаток находится между полным ответом и следующим запросом,
следующий участок — чтение и материализация device journal, отдельно durable
apply. Общая сходимость 46,023 с не объявляется ускорением: production-код
не менялся. Первый замер без sparse-предусловия не зачтён как эта квалификация.
12 тестов и analyzer прошли; все стенды закрыты, mailbox/push/релиза нет.

Предыдущий шаг: [проверка хеша ссылок журнала во всех путях HVS](../log-reference-hash-2026-11-04/README.md).
Подтверждены и локально исправлены пропуски проверки v2 commitment в exact
read, iterator cache hit и полном integrity walk. На одном синтетическом
контейнере прежняя библиотека провалила все три native-контроля; новая прошла
их и контроль корректных файлов, в том числе после очистки build target.
656 Rust-тестов прошли, 2 ignored; clippy/fmt чистые. Это подтверждение
контракта целостности, не доказательство внешней атаки или причины жалоб.
Совместный crash/reconnect прогон на новой HVS восстановил все 2000 сообщений
от одного вернувшегося A и сохранил их без A/C, с точными ID/порядком/positions/
delivered. Время после готовности A — 51,111 с; latency остаётся открытой.
Стенд закрыт и проверен. Исправление исходников и частная библиотека локальные;
публикации, engine pins и изменений production-реле нет.

Предыдущий шаг multi-device: [объединение ограниченных чтений журналов](../history-group-read-2026-11-04/README.md).
Контекстный замер подтвердил, что почти все payload RPC в данном окне B
начинались из own-device lookup. Метаданные и данные остаются свежими;
worker теперь объединяет exact-ID группы с отдельными byte ceilings и общим
лимитом 64 записей. Контроль не позволял перейти к следующему файлу при
отсутствующем/слишком большом предыдущем; остаток бюджета сохраняется между волнами.
579 тестов и один отдельно запущенный native case прошли. На двух native
crash/reconnect прогонах все 2000 ID/positions/delivered сошлись и сохранились
без источников. Время после возврата A: 51,213/51,221 с против контрольных
56,232 с при poll около пяти секунд; это не точная оценка ускорения в процентах.
Догрузка и расширенная матрица остаются открытыми. Стенды закрыты;
mailbox/push/релиза нет.

Предыдущий шаг: [замеры сохранения и повторных проверок подписей](../history-signature-work-2026-11-04/README.md).
Повторный no-op delivered не оказался главным тормозом: 505 вызовов на B
заняли 31 мс inclusive await; 87 реальных ordering repairs — 1747 мс.
Убраны повторные native hybrid signature checks точных crypto tuples, с
ограниченным digest-only кэшем; свежий журнал, членство и revoke проверяются
по-прежнему. 507 тестов и analyzer прошли. Два native crash/reconnect
кандидата корректны на всех 2000 строках, но общая сходимость после возврата A
осталась 56,328/56,242 с — ускорение всей догрузки не обнаружено. Большое число свежих
чтений сегментов остаётся следующим участком; общий latency-дефект не закрыт.
Стенды закрыты и проверены; mailbox/push/релиза нет.

Предыдущий шаг: [сокращение обхода при дыре и позднем хвосте](../history-sparse-prefix-2026-11-04/README.md).
Read-only snapshot показал, что B имел непрерывное начало и последние сто
сообщений с provisional positions, но не середину. Поэтому отказ полного hint
был корректным. Источник теперь выбирает самое длинное совпавшее начало из
максимум восьми проверяемых кандидатов; дыра и неверные позиции не пропускаются.
157 тестов прошли. Два native-прогона с обязательной sparse-копией после
SIGKILL: все 2000 ID/порядок/source positions/delivered сошлись и сохранились
после запуска без A/C, дублей/пропусков нет. Page B→A 251 → 76/73,
согласованность после возврата A 158,611 → 56,321/56,219 с на этом стенде.
Наблюдаемый неизменный счётчик неполной истории 102,388 → 5,110 с; poll около
пяти секунд. Остались доставка недостающих частей и около десяти секунд
ремонта metadata tail. Общая задержка догрузки и расширенная матрица не закрыты.
Mailbox/релиз не добавлялись, стенды остановлены; это Mac/JIT, не Android/AOT.

Предыдущий шаг: [подтверждение уже сохранённой части истории](../history-prefix-2026-11-03/README.md).
Локально добавлены content-проверка меньшего inventory, подтверждение сохранённого
начала и recheck inventory перед возобновлением старого page cursor. Четыре
красных контрольных условия исправлены; общая серия 153 passed. На native
2000 сообщений сохранность чистая в четырёх запусках. Но ускорение неустойчиво:
первый candidate восстановился за 41,003 с после возврата A, его повтор и
версия с resume-проверкой — за 148,314/148,422 с (контроль 153,866 с).
Поэтому общий latency-дефект **не закрыт**. В медленных случаях есть 100
repaired-ordering строк в конце истории; следующий шаг — read-only наблюдение
частичного worker snapshot во время плато, без предположения, что все уже
имеющиеся строки образуют непрерывное начало. Mailbox не добавлен.

Предыдущий шаг: [SIGKILL B при первичной догрузке 2000 сообщений](../history-initial-migration-crash-2026-11-03/README.md).
Три прогона: на диске до сети сохранились 1272/1597/1747 строк, в итоге все
2000 с точными ID/порядком/source positions и delivered, без дублей. В двух
прогонах B сначала вернулся без A/C, затем восстановился только от A;
после полного восстановления B удержал историю при новом запуске без A/C.
Это не получение новых данных из mailbox: модель live-only сохранена по
указанию владельца. Остаток **подтверждён**: после возврата только A повторный
обход уже имеющейся истории удерживал количество строк неизменным на
102,345/117,662 с. Wire второй серии содержит 251 уникальную page, это не
сетевая тишина. Исправлен отдельный пробел inventory: одинаковое содержимое
больше не скрывает несовпадение канонического порядка (`orderAuthor/orderSeq`).
Red/green и native oversized-record контроль прошли; большие crash-серии
предшествовали этому Dart fix. Длительный offline/revoke/split-brain и
инъекции crash на отдельных стадиях остаются неполностью проверенными.

Свежий звуковой цикл: [локально исправлены AEC/NS и первый capture](../call-audio-processing-2026-11-02/README.md),
[подтверждён и исправлен избыточный played PLC при jitter](../call-audio-jitter-2026-11-02/README.md).
Это исходники/стенды, без новых engine pins и релиза. Физические жалобы
Poco ↔ Windows не закрыты; видео при большом adaptive reserve ещё не квалифицировано.

[R31 проверен](../report31-2026-11-01/README.md): локально исправлены отзыв
устройства во время одиночного поиска сертификата, потеря peer-edit при отказе
device mirror, отсутствие timer-retry handover, заполнение локальной доли
discovery witness и принятие лишних байтов в PoW challenge. Зеркальный `failed` не переносится
на живую отправку другого устройства намеренно. Пять исправлений подтверждены
тестами; они не закрывают холодный OVL1, слышимость речи или физическую паузу
NETCALL-01. Повторно перечисленные старые опровержения сверены в таблице R31.

**Новые активные репорты после 0.13.94:**

- Телефон → Windows: нет звука. Подтверждён отдельный дефект кода — отказ
  микрофона обрывал рабочий приём; первоначальная локальная правка дополнена
  исправлением итогового результата настоящего media-controller. 211 тестов,
  включая красный контроль прежнего возврата. Причина пользовательского случая
  этим **не доказана**. На отдельном Mac ↔ Windows стенде P2P и relay обменивались
  аудио, Windows выдавал ненулевой выходной уровень; системный/app mute выключен.
  Это цифровые замеры, не проверка слышимости человеком. SDK Mac — явно
  зафиксированный старый контроль. [Подробности и границы](../receive-only-audio-2026-11-01/README.md).
  [Диагностика Windows](../windows-audio-output-diagnostics-2026-11-01/README.md)
  теперь сохраняет анонимные volume/mute и выбор default output отдельно во
  время звонка и при экспорте. Реальный экспорт после контрольного звонка
  проверен; 300 связанных тестов прошли. Это устранение пробела диагностики,
  не доказанное устранение отсутствия звука на Poco.
  Дополнительно подтверждено и исправлено [потерянное подтверждение управления
  микрофоном](../microphone-control-result-2026-11-01/README.md): отказ во время
  звонка больше не объявляется успешным, старый ответ не отменяет новый выбор.
  244 + 21 связанных теста прошли; причина исходного репорта всё ещё неизвестна.
  [Поздний ответ разрешения микрофона](../late-microphone-permission-2026-11-01/README.md)
  также больше не оставляет ложный mic-on после отказа: уведомляются UI и
  собеседник, старые поколения отбрасываются. 279 связанных тестов прошли;
  в том цикле физический звонок Poco → Windows на новой QA ещё не проверялся.
  Теперь [физический контроль](../call-handover-retry-2026-11-01/README.md)
  установил звонки и приём аудиопакетов обоими концами. Слышимость речи не
  квалифицирована: sampled Android input band был 0, ненулевой output может
  быть comfort noise. Пользовательская жалоба остаётся открытой.
- **NETCALL-01:** после Wi-Fi → мобильная сеть исходящий звонок телефона не
  появляется на компьютере. Подтверждено отсутствие OS network-change проводки
  в xVeil; локально добавлена, проверена тестами и сборками. В трёх физических
  вызовах после смены сети полная недоставка входящего не воспроизвелась;
  условие ровно одного активного узла отдельно не создавалось. При смене сети
  **внутри звонка подтверждена пауза audio payload до 12,4–14,7 с**, она остаётся
  активной. Дополнительно исправлен длинный backoff повторов call-control;
  130 связанных тестов прошли, current/current вызов установился за 5,31 с,
  причинное ускорение физическими сериями не доказано. [Шаги и учёт](../network-change-call-2026-11-01/README.md).
  [Следующий цикл](../late-capture-audio-recovery-2026-11-01/README.md) исправил
  потерю истории аудио при позднем первом capture-отчёте и потерю последнего
  реального свидетельства приёма при пересоздании медиадвижка. Прошёл 261
  связанный тест. До второго исправления один физический прогон сохранил
  звонок, другой завершился по liveness timeout; прежнее утверждение о двух
  успешных прогонах отозвано. Максимумы native age относятся к отдельным
  media epoch и не ограничивают полный перерыв звука. NETCALL-01 открыт.
  [Парный native-захват](../call-probe-endpoint-trace-2026-11-01/README.md)
  сохранил звонок, но перерыв audio RX остался. Две ранние candidate-клетки
  приняты локальными relay-очередями, соответствующий authenticated receive
  на Windows не наблюдался; поздняя квалификация получила ответ за 347 мс.
  Полнота console capture не доказана, сетевой дроп этим не установлен.
  [Проверка шести реле](../call-probe-first-hop-2026-11-01/README.md) добавила
  точную связь непрозрачных клеток с endpoint. В новом захвате одна ранняя
  клетка дошла только до IPC handler, следующая получила два local queue
  admissions; одна её копия локально отброшена как `child_unavailable`, другая
  прошла `budget_admit`. Соответствующий ingress на реле не наблюдался при
  наличии положительных контрольных совпадений. Это не доказывает сетевой
  дроп: следующий участок — фактический send и lifetime child до первого хопа.
  Реле возвращены к исходным настройкам, бинарники не менялись.
  [Разложение задержки call-control](../call-signaling-delay-2026-11-01/README.md)
  уточнило: прежние ~20 с до RX включали примерно 17 с ожидания ответа в
  dialing; это не 20 с запуска аудиодвижка. В новом вызове на одинаковой SDK
  с обеих сторон задержался уже offer (16,652 с), answer пришёл быстро.
  Отдельный активный звонок пережил переход, но fresh-RX проверку не прошёл.
  Исправлена потеря этапов звонка из анонимной диагностической истории;
  сам NETCALL-01 пока не устранён, условие одного узла не квалифицировано.
  [Следующий цикл](../network-notification-receipt-2026-11-01/README.md) исправил
  потерю локального NetworkChanged при закрытии временного FFI runtime:
  теперь SDK ждёт подтверждения dispatch по тому же IPC-соединению.
  Новый post-cut setup прошёл, active-handover завершился livenessTimeout
  примерно через 21,2 с; уведомление в этом захвате точно обработано, дальше
  наблюдались отказы/таймауты dial и позднее восстановление сессий.
  NETCALL-01 и жалоба о слышимости остаются открытыми.
  [Отмена старого dial](../pending-dial-network-change-2026-11-01/README.md)
  добавлена в connect-ветку; 785 runtime + 334 FFI теста прошли. В новом
  физическом цикле active call сохранился 40 с после переключения, но пауза RX
  осталась. Отдельная проверка линии описана ниже; это другой физический
  сценарий, не закрывающий мобильный handover.
- **NETLINE-01 — ПОДТВЕРЖДЕНО:** на свежем изолированном testnet
  `Mac — S1 — S2 — S3 — S4 — S5 — S6 — Blackview` не сошлось подтверждение
  контакта телефон → Mac и не появился входящий звонок до media при denied
  и при allowAll после перезапуска. Фактическая линия, клиентские привязки,
  native listeners и неизменность production проверены. Расширенная
  opt-in трасса связала 145 opaque witnesses по `телефон → S6 → S5 → S4`:
  на S5 они переходят в RecursiveRelay, на S4 дальнейшая отправка не видна.
  Модель настоящего dispatcher воспроизводит холодный барьер репутации 200;
  его не отключали. Исправлен пробел наблюдения обёрнутых кадров, **не вся
  доставка**. [Результаты и ограничения](../linear-testnet-2026-11-01/README.md).
  P2P media и полный шестисерверный media path ещё не квалифицированы.
  Тестовые службы/клиенты остановлены, production сохранён 6/6; push/релиза нет.
  [Следующий физический цикл](../cold-chain-delivery-2026-11-01/README.md)
  исправил возврат cold discovery/PoW и адресацию ordinary family-копий
  проверенному transport device с точным instance tag. Контакт сошёлся;
  два relay-звонка и один P2P-звонок прошли с fresh RX на обоих концах.
  Однако повторный входящий после перезапуска появился через **50,999 с**,
  сообщения тоже доходили с большой задержкой. NETLINE-01 остаётся активным
  по холодной доставке; полный провал звонка в новой серии не повторился.
  Эта Wi-Fi-линия не закрывает мобильный NETCALL-01 или слышимость Windows.
  [Очередной цикл](../route-miss-queue-2026-11-01/README.md) исправил serial
  route-miss HOL, потерю уже готового маршрута при регистрации waiter и расход
  backoff чужими уведомлениями. Три входящих пришли за 1,366–1,446 с после
  реального подключения к seed, но в третьем boot само подключение Mac → S1
  заняло **58,690 с**, первоначальный 45-с гейт провалился. Причина этого
  ожидания неизвестна; NETLINE-01 не закрыт. Независимый RX-контроль прошли
  два вызова; в первом на Mac age достигал 3443 мс. Старый green flag стенда
  не используется как доказательство непрерывного приёма.
  [Цикл QUIC lifetime](../canonical-quic-lifetime-2026-11-01/README.md)
  устранил удержание canonical transport после отмены handshake/выхода владельца
  сессии (три красных сценария, 789 runtime-тестов, положительный handoff).
  **Холодное подключение не исправлено:** в физической серии локальный
  трёхсекундный гейт достигался за 3,838–40,641 с; сервер не подтвердил все
  локальные гейты и сохранял старые canonical-сессии после закрытия клиента.
  Следующий участок — порядок остановки embedded runtime и фактический QUIC
  close; общая причина прежних 58,690 с по-прежнему не доказана.
  [Владение peer-задачами](../owned-peer-shutdown-2026-11-01/README.md)
  исправило другой подтверждённый дефект: шесть динамических путей отбрасывали
  JoinHandle, и active connector переживал node.stop. Красный TCP/OVL1-тест
  проверяет удалённый EOF; 790 runtime-тестов прошли. В восьми Mac-запусках
  после stop сессия отсутствовала уже при первом серверном опросе, в том числе
  при текущем SDK на обоих концах. **Холодный handshake остаётся открытым:**
  current/current дал 13,764 с до двустороннего наблюдения в одном boot и
  2,822–3,046 с в трёх; первый содержал OVL1 timeout 10 с. Это не A/B/A и не
  закрытие полной шестисерверной линии или мобильного handover.
  [Стадии OVL1 и hint-refresh](../handshake-refresh-2026-11-01/README.md)
  выявили лишнюю отмену незавершённой попытки по неизменившемуся peer-hint;
  она исправлена с красным тестом, 791 runtime-тест прошёл. Трасса локализует
  оставшиеся timeouts до первого входящего QUIC application stream после HELLO,
  но не доказывает сетевой дроп. В двух сериях по шесть boot задержки сохранялись
  (до 40,031 / 24,922 с); causal speed-up не заявляется. Один запуск прерван
  из-за SSH observer reset и не засчитан. NETLINE-01 и NETCALL-01 остаются открыты.
  [Трасса до первого OVL1](../quic-first-stream-2026-11-01/README.md) теперь
  различает TLS и ожидание первого QUIC stream. Для трёх server connection,
  сопоставленных с QA Mac по ciphertext samples, TLS прошёл за 64–84 мс, затем
  STREAM RX оставался нулевым до 10-с timeout. В шести boot пять достигли
  двустороннего ACTIVE, один не достиг за 80 с; ускорение не заявляется.
  В одном успешном boot удалённая строка сохранилась в окне 6,212 с после lock;
  это не доказательство продолжающейся работы клиента, причина открыта.
  NIC-захват попал на два быстрых boot и не атрибутирует медленные. Все test
  services, бинарники, trace flags и процессы после проверки восстановлены;
  production сохранён 6/6. Следующий захват должен застать timeout на NIC
  и учитывать GRO/GSO.
  [NIC и send-error цикл](../quic-nic-send-errors-2026-11-01/README.md) застал
  медленные попытки: у двух однозначно сопоставленных Mac-потоков на NIC S1
  видны Initial/Handshake, но нет 1-RTT до timeout; положительные server
  samples найдены 45/45 RX и 46/46 TX с учётом coalescing. Исправлено
  завышенное обещание UDP send-счётчика: он означает API admission, а скрытые
  ошибки ОС теперь наблюдаемы при RT trace. В трёх медленных boot таких
  ошибок не было. Два запуска через opaque loopback UDP proxy также медленные;
  proxy видит и отправляет short-header datagram, но это не доказывает их
  приём внешним интерфейсом. Задержка остаётся, конкретный OS/network-фильтр
  не установлен. Все процессы и тестовые службы остановлены, исходные
  бинарники/конфиги восстановлены, production неизменён 6/6. Ускорение и
  устранение NETLINE/NETCALL не заявлены.
  [Совмещённый proxy/NIC-контроль](../quic-proxy-nic-control-2026-11-01/README.md)
  теперь сравнил все datagram одной и той же попытки: 29/28 short-header
  успешно переданы proxy в UDP socket ОС, но 0 найдены на NIC сервера;
  однозначный успешный контроль дал 110/110 datagram. Граница — до серверной
  обработки, включая Mac kernel/сеть до сервера; конкретный фильтр не доказан.
  Три запуска через известный obfs4/TCP endpoint того же S1 прошли за
  1,515–1,534 с от ready, с проверкой транспорта на обоих концах. Это не
  automatic fallback и не закрытие полной линии/мобильного handover. В цикле
  не менялся код доставки; все пять приложений и стендовые процессы завершены,
  исходные бинарники/настройки восстановлены, production проверен 6/6.
  [Обновление learned standby endpoint](../standby-advertisement-refresh-2026-11-01/README.md)
  отдельно исправляет старый alternate, остававшийся после нового непустого
  объявления без пригодной замены. Ручная настройка, другие peers и семантика
  пустого TLV сохраняются. Red: 0/3; green: session 683 passed / 8 ignored,
  runtime handshake 22 passed. Hot-standby по умолчанию выключен; его здесь
  не включали. Связь с физическими QUIC-паузами не доказана, automatic TCP
  fallback не добавлен; NETLINE/NETCALL остаются открытыми.
- **Быстрый вход по отпечатку на Poco — исправлен локально:**
  [воспроизведён отказ инициализации нового namespace, исправлен и проверен
  на Poco](../android-biometric-startup-2026-11-05/README.md). Настройка и
  открытие encrypted-контейнера после перезапуска прошли с настоящим отпечатком;
  отмена, парольный fallback и удаление проверены. Это отдельный QA-контейнер,
  пользовательский не менялся; новый релиз ещё не опубликован.

Исходные два репорта также остаются открытыми. Первоначальный отказ ОС установить отдельное QA
на Poco преодолён: новый изолированный профиль создан обычным onboarding,
QA-узел достиг `ready`, физические результаты описаны выше. Пользовательские
данные сохранены; после физических переходов исходные сетевые настройки
телефона восстановлены.
Исторические отложенные жалобы ниже не переобъявляются исправленными; звук
вернулся в активную работу именно после нового сообщения владельца.
Нового push/релиза этих изменений нет.

**Изменение приоритета:** по прямому указанию пользователя совместимость со
старыми версиями отложена и не считается условием релиза: оба реальных
пользователя обновятся. [Ограниченная native-проверка смешанного оверлея](../mixed-overlay-2026-10-30/README.md)
зафиксировала неполную доставку в двух старых/новых составах и полную доставку
на 12 текущих узлах. Ограничение сохранено в учёте; исправления совместимости
не планируются в активной очереди. Старые упоминания обязательной mixed-проверки
ниже отражают прежний приоритет.

[Новый цикл resolver](../resolver-walk-cancellation-2026-10-30/README.md): подтверждена
и устранена утечка блокировок/диагностического счётчика при отмене поиска
сертификата; 751 runtime-тест прошёл, 11 ignored. Её связь с прежней недоставкой
не доказана. Кандидат с параллельным поиском документа и списка устройств прошёл
тесты, но ухудшил холодную доставку в трёх native-прогонах относительно трёх
исходных; он исключён из итоговых правок. Длительная доставка остаётся открыта,
ускорение на текущей сборке не заявляется.

Рабочая очередь до новых репортов о звонках:

1. **Активно:** длительная доставка и синхронизация на текущих версиях.
2. **Следом:** оставшаяся multi-device матрица, длительный offline,
   revoke / split-brain / crash. Непройденные проверки не считаются дефектами.

[Межпроцессные partition/crash проверки 2026-11-01](../native-partition-crash-2026-11-01/README.md):
на четырёх native-процессах прошла сходимость двух разделённых половин сети
(16 сообщений, реакции, read, правка и локальное удаление; первое полное
наблюдение через 20,084 с). Отдельно прошёл SIGKILL отправителя после send API,
его возврат, доставка C/B и повторный запуск B без дублей. В crash-тесте исправлен
ложный критерий: ждать C до возвращения единственного сохранённого источника.
Production-код не менялся; это два конкретных host-native сценария, не вся
матрица/все crash-cut и не повторный замер медленной догрузки. В том цикле
Poco→Windows/смена сети не проверялись из-за заблокированного основного
контейнера. Теперь на отдельном QA-профиле выполнены ограниченные проверки
звонков, описанные выше; основной контейнер не менялся.

[Пакетная выдача истории 2026-11-01](../device-history-durable-batch-2026-11-01/README.md):
подтверждено, что history replay ждал отдельного сохранения каждой строки,
не давая существующему дренеру объединить их. Теперь до 25 событий передаются
одной порцией с прежним durable-результатом, порядком, отменой и backlog gate.
Контроль на одном storage: 25 отдельных сохранений → одно на порцию; это счётчик
fixture, не число native fsync. 483 passed, 3 skipped, analyzer чист.
Исходный межпроцессный прогон не успел подготовить 2000 строк B за 360 с;
кандидат получил все 2000 за 237,149 с с совпавшими ID/порядком. Затем B offline
минимум пять минут, C выключен перед возвратом B: все 100 исходящих копий на B
за 10,419 с от ready / 20,941 с от запуска. После возврата C совпали все 2100
ID/порядок, без дублей. Один host-native прогон, не Android/AOT и не сравнение
с прежними 106 с. Задержки остаются активными: хвост из 25 старых сообщений
временно отсутствовал при пустом Outbox контрольных кадров и пришёл позже.
Стенд/порты закрыты,
контейнеры удалены; без push/релиза.

[Конечный статус старой истории](../history-terminal-status-2026-11-01/README.md):
в предыдущем native-прогоне B сделал 9640 попыток повторить 1968 сообщений,
по которым A уже получил ACK. Mirror терял исходный delivered/failed и
создавал повторную работу из завершённой истории. Codec/applier и compaction
исправлены без переноса времени сообщения и отключения pending retries.
521 passed + 1 compaction passed, 3 skipped, analyzer чист. В новой native-серии
все 2000 исходных сообщений появились на B как delivered за 77,949 с; попыток
повторить их нет за весь прогон. Это два отдельных прогона, не A/B/A.
После пяти минут offline B получил новые 100 при offline C за 10,316 с от ready;
итоговые 2100 ID/порядок на A/B/C совпали без дублей. В том прогоне подтверждён
остаток: 375 попыток повторить 96 из новых 100, с более ранними ACK на A.
Его последующее исправление/проверка описаны ниже; старые цифры не переписаны.
Стенд/порты
закрыты, контейнеры удалены; без push/релиза. Poco виден в ADB, контейнер
по-прежнему на экране пароля; его данные/настройки не менялись.

[Порядок прихода delivery и mirror](../mirror-status-arrival-2026-11-01/README.md):
подтверждён и исправлен `delivered`, терявшийся до появления строки или во время
append. Отдельное ограниченное окно receipts своих устройств сохраняет раннее
подтверждение, задаёт initial status/завершает позднюю запись и прекращает retry
после ожидаемой подготовки. Обычный orphan ACK собеседника не получает этого
права; подтверждения не отражаются обратно. 579 + 2 дополнительных теста прошли,
3 skipped, analyzer чист. Native: все 2000 старых delivered-строк за 72,610 с;
после пяти минут offline B — все 100 новых ID **и статусов** за 10,522 с от ready
при offline C. Повторов новых копий 0 (ранее 375), после полного наблюдения
доставки также 0;
итоговые 2100 ID/порядок сошлись без дублей. Это один host/JIT-прогон, не
Android/AOT, не A/B/A и не ретроспективное доказательство причины всех 96 старых
событий. Механизм закрыт и текущий native-сценарий проходит; прежняя медленная
догрузка на Android ещё не переизмерена, полная матрица остаётся неполной.
Стенд остановлен, контейнеры удалены; без push/релиза.

[Point lookup при mirrors/mutations](../message-point-lookup-2026-11-01/README.md):
убраны полные проекции/сортировки разговора ради одного message ID. На 100
зеркал с 2000 старыми строками: 100 view-вызовов / 204 950 строк → 0 / 0,
100 точечных lookup; tombstone, авторство и разговорные границы сохранены.
259 связанных тестов и отдельные 5 native-контролей прошли. Native A/B/A:
2,131 → 1,893 → 2,072 с только для применения 100 зеркал, не сквозной доставки.
В отдельной host/JIT миграции 2000/2000 ID/порядок A/B/C сошлись, все delivered
на B, повторов старой истории 0; полное наблюдение за 77,121 с от link.
Сквозное ускорение не доказано; прежние 72,610 с — другой прогон. SDK/CLI
контроль `f7a4fb97` заморожен: это квалификация Dart, не накопленного SDK.
Migration-only не выполняет пятиминутный offline; полная матрица остаётся
неполной. Проверены выход 15 собственных PIDs, освобождение 14 портов,
удаление контейнеров и неизменность 565 файлов прогона. Без push/релиза.

[Конкурирующие mirror-копии](../mirror-apply-race-2026-11-01/README.md):
исправлена гонка read/append одной пары conversation/message ID: два post в
сыром журнале и затирание более позднего delivered первой записью sent.
Сериализация ограничена активной работой одного ключа, ошибка освобождает
повтор, смена binding/dispose отменяет ожидающую работу. Зачтённый red 3/2;
276 связанных тестов и итоговые 10 concurrency/census проверок прошли.
На текущем SDK `eb644a83` начальные 2000 ID/порядок A/B/C сошлись за
103,068 с, все delivered на B, старых retry 0. Ускорение не установлено;
добавлен test-only профиль append и namespace RPC, не production-пробы.

[Retirement ACK в Outbox](../outbox-ack-retirement-2026-11-01/README.md):
исправлен stale RAM-кэш после успешного commit с потерянным ответом:
одиночный ACK теперь использует ту же all-or-none reload-политику, что batch.
Соседние ACK одного peer объединяются до 64 без таймера; enqueue/read и
другой peer сохраняют границы очереди. 107 связанных + 5 native проверок.
Native A/B/A 64 ACK: 64/1/64 retirement commits, 1064/27/1105 мс; это не
сквозной speed-up. Начальная миграция 2000 строк на том же текущем SDK:
A₁ 103,068 с / B 72,220 с / A₂ 77,309 с, все ID/порядок/delivered совпали,
повторов старой истории 0. Повторный baseline также без хвоста на 1976 строках:
исчезновение прежней паузы нельзя присвоить правке. 568 frozen-файлов A₁/A₂
совпали, от кандидата отличается один production-файл. Стенды/наблюдатели
остановлены, контейнеры удалены, кандидат восстановлен. Догрузка остаётся
активной; объединение message append в том цикле ещё не реализовано. Без push/релиза.

[Пачки message append](../positioned-message-batch-2026-11-01/README.md):
до 16 соседних небольших записей одного conversation/author с готовыми seq
сохраняются атомарно, максимум 1800 encoded bytes на запись. Локальная выдача
seq и fragmented-путь сохраняют отдельные ходы; durable completion,
shard-маркеры, close/erase fence и проверки выше storage сохранены.
192 связанных и 10 native проверок прошли. Native A/B/A 128 сообщений:
128/8/128 data commits, 2,354/0,246/2,400 с. Initial migration на текущем SDK
и одинаковых native-библиотеках: A₁ 72,220 с / B 51,548 с / A₂ 77,953 с;
2000 ID/порядок/delivered совпали, retry старой истории 0 во всех фазах.
Message-log commits B: 2001/432/2147. Проверено равенство 568 source-файлов
A₁/A₂ и единственного изменённого production-файла B. Выигрыш квалифицирован
для этой local/JIT-серии, не Android/AOT или всех путей доставки. Первоначальная
ошибка collector в учёте чужих/повторно занятых портов исправлена; независимые
проверки PIDs, портов, удаления контейнеров и восстановления кандидата прошли.
Догрузка ещё активна: остаются 51,5 с и служебные записи. Без push/релиза.

[Надёжность и пачки Outbox enqueue](../outbox-enqueue-batch-2026-11-01/README.md):
исправлены скрытая durable-строка после потери ответа commit, поздний снимок
изменяемых bytes и отказ уже принятого enqueue при close/erase. Соседние
enqueue одного peer объединяются до 8 записей/32 КиБ encoded payload;
sync-response сохраняет bounded-порцию до initial-send jobs. 238 связанных,
10 retention, 21 ordering и 19 native проверок прошли; native A/B/A на 64
кадрах: 64/8/64 data commits, 1,590/0,269/1,665 с. Сквозного ускорения нет.
Первый обратный контроль провалил немедленный порядок после полного количества;
его не записали в green. Observer теперь ждёт ID/порядок/delivery и opt-in
проверяет эффективные исходные позиции. В повторной одинаковой паре прежний
код/кандидат сошлись за 51,422/51,349 с, все 2000 delivered, старых retries 0.
Постоянное расхождение прежнего snapshot не доказано и не объявлено исправленным.
Проверены остановка процессов/портов, удаление контейнеров и provenance библиотек;
телефон/Windows/production не менялись. Догрузка и остальные активные случаи
остаются открытыми. Без push/релиза.

[Профиль файловой подготовки и догрузки](../file-write-profile-2026-11-01/README.md):
кандидат объединения свежих metadata-read **отклонён**: native A/B/A уменьшил
metadata RPC 256/160/256 для 32 пар, но не ускорил 1,165/1,206/1,200 с при тех
же 64 commits. Production-файлы восстановлены. Пассивный test-only учёт разделил
file-call и вложенные RPC, с фиксированными метками и privacy/reset проверками.
В новом native/JIT прогоне все 2000 ID появились за 46,372 с, но 75 provisional
позиций ещё отличались; за 51,503 с все они приняли исходный ordering-overlay,
порядок и delivered сошлись без retries. Это подтверждённое временное состояние
текущего прогона, не объяснение задним числом прерванного старого.
На отправителе 498 header-load и 459 segment-batch-load; следующий кандидат —
повторное чтение журнала, не доказанная сетевая задержка. Scope-ожидания
перекрываются и не суммируются как критический путь. Стенд/контейнеры/порты
закрыты, production не менялся; push/релиза нет.

[Общее незавершённое чтение сегментов](../joined-segment-read-2026-11-01/README.md):
исправлен повтор первых волн поздним параллельным load для точно того же header.
Разделяются только незавершённые JSON-записи, не принятый bundle/authorization;
save/purge/shutdown и write-timeout bypass сохранены. Red на прежнем коде:
первые восемь сегментов читались дважды. Дополнительный red поймал собственный
край timeout-view, исправленный до финальных проверок. 400 passed / 3 skipped,
analyzer чист; native A/B/A 12 пар: 240/132/240 payload RPC,
0,708/0,358/0,686 с, одиночный путь без лишних чтений. Сквозной A/B/A:
51,503/46,649/72,408 с, все 2000 ID/порядок/позиции/delivered сошлись, старых
message retries 0. Устойчивое ускорение всей догрузки не доказано: на обратном
контроле 25 промежуточных сообщений оставались недогруженными при уже полученных
более поздних; count=1975 наблюдался с 46,854 по 62,187 с, причина неизвестна.
Оба baseline совпали по всем 568 frozen-файлам, у кандидата изменён только
GroupService; библиотеки одинаковы. Стенды/контейнеры/порты закрыты,
production-серверы/телефон/Windows не менялись; push/релиза нет.

[Пакетные metadata-чтения](../group-segment-batch-read-2026-10-31/README.md):
убраны отдельные worker round trips для metadata каждого сегмента; порции до
8 файлов/128 КиБ на файл, без исключения payload и проверок. Native A/B/A:
на 20 чтений journal из 9/18 сегментов metadata RPC 400/760 → 120/160 →
400/760, payload RPC неизменны; локальное время лучше примерно на 3%, не
доказательство ускорения доставки. 638 passed, 3 skipped, analyzer чист,
5 native safety passed; native 4/4 всем 12. В новой A/B/C серии все 100
сообщений появились на B до возврата C, первое полное наблюдение 106,071 с;
после возврата C совпали ID/порядок, без дублей. Это квалификация сценария,
не причинное сравнение скорости: маршруты/backlog/состав кадров отличаются.
Сквозные задержки остаются: dispatch wait до 87,9 с, save до 8,22 с, group gate
до 4,70 с. Стенд закрыт, исходный QA APK восстановлен; без push/релиза.

[Чтение файла при смене личности](../file-read-session-2026-10-31/README.md):
при разборе load подтверждён отдельный дефект границы сессии. Старый read после
ожидания metadata мог заново взять `_as` уже открытой другой личности и вернуть
её файл/диапазон/размер/наличие. Четыре read API теперь привязаны к исходному
store/tier/поколению обслуживания; close/erase или смена tier отвергают поздний
результат. Чтения остаются параллельными, дополнительных RPC/коммитов нет.
Пять красных unit-контролей на базе; 8/8 итоговых сценариев. На двух настоящих
worker-backed контейнерах старый код 0/2, новый 2/2; полный scoped-набор
663 passed, 3 skipped, native-набор 5 passed, analyzer чист. GUI/передача чужих
данных по сети не воспроизведены и не заявляются. Это исправление изоляции,
не доказательство ускорения догрузки. Без push/релиза.

[Цепочки ключей устройств](../group-writer-partition-2026-10-31/README.md):
устранён повторный обход canonical-истории для каждого scope/author; строки
распределяются один раз в пределах свежепроверенного чтения. Формат ключей,
подписи, независимые цепочки, cut/fork и ACK сохранены, межчтительного auth-cache
нет. Контроль старый/partition/partition+hex/старый: на 128 строк / 16 ключей
обращения к ключам 2560/512/512/2560 при неизменных проверках всех 128 строк.
633 passed, 3 skipped, analyzer чист; две native-проверки подписей и 4/4 всем
12 узлам прошли. Это сокращение локальной работы, не доказательство ускорения
полной синхронизации. Физическая серия 100 сообщений / минимум 5 минут offline:
при online A/offline C на B только 78/100 к 291,632 с после готовности. После
возврата C итоговые 100/100 на всех трёх совпали по ID/порядку, без дублей;
причинная роль возврата C не доказана. Независимое восстановление в 300-с окне
не прошло, задержки остаются активными: ordinary dispatch wait max 206,4 с,
chunk wait max 33,2 с, 100/107 ingest без новых notification-строк. Это не
разрешение пропускать проверки: byte-identical дубли не доказаны. Следующий
участок — повторная обработка старой истории и save/load. Стенд закрыт, исходный
QA APK восстановлен, порты освобождены. Без push/релиза.

[Файловые метаданные](../file-metadata-reads-2026-10-31/README.md): устранены
повторный запрос manifest внутри одной операции и чтение прежнего payload,
когда длина замены уже отличается. При возможном no-op байты по-прежнему читаются
и сравниваются. Worker A/B/A: на 300 no-op manifest RPC 600/300/600, body RPC
300/300/300; при resize коммиты неизменны. Шесть красных контролей на базе,
617 passed, 3 skipped, 6 native passed, analyzer чист; native 4/4 всем 12.
Это локальное сокращение I/O, не доказательство ускорения полной догрузки.
Телефон/реле не менялись, SDK прежний. Без push/релиза.

[Приём составного snapshot](../group-chunk-ingress-2026-10-31/README.md):
на трёх текущих Dart-клиентах подтверждено ожидание после транспортного callback,
до 66,7 с за старыми group-delta. Фрагменты теперь имеют отдельную одну
последовательную полосу с прежним общим admission-бюджетом, проверками и ACK
после apply; мутации GroupService остаются сериализованными по группе.
Три красных контроля на прежнем core; 755 passed, 3 skipped, analyzer чист,
native 4/4 всем 12 без дублей. В физической серии 20/20 догрузились до возврата C,
первое полное наблюдение 31,510 с; chunk wait max 9,38 с, обычный wait max
18,8 с. Сравнения скорости A/B нет, вся задержка не закрыта. Следующий участок —
повторная обработка старых delta, чтения/save, group gate и холодный старт.
Стенд закрыт, исходный QA APK восстановлен, QA-проб в продукте нет. Без push/релиза.

[Очередь source после ACK](../group-source-retirement-2026-10-31/README.md):
подтверждена лишняя отправка ожидающих group-sync кадров, которые уже были
подтверждены другой копией, включая повтор Outbox. Retirement теперь отменяет
соответствующие ожидающие задания; активные отправки не обрываются, полная
durable-копия после поштучного ACK сохраняется. Четыре красных контрольных
сценария на старой проводке; 701 passed, 3 skipped, analyzer чист. Native-стенд
доставил 4/4 сообщения всем 12 узлам ровно один раз, узлы/порты освобождены.
Вклад лишних отправок в минутную догрузку не измерен; сквозное ускорение не
доказано, активный дефект задержек остаётся открытым. Без push/релиза.

[Раунд file maintenance/save](../file-maintenance-2026-10-31/README.md) при
аудите gate подтвердил отдельную гонку: queued file/piece/delete могли пересечь
close/open другой личности, а незавершённая запись — восстановиться после erase.
Close/erase теперь дожидаются принятых файловых операций и отказывают новым во
время обслуживания; job привязан к прежней storage session. Три красных теста
на базе, пять итоговых unit-сценариев, два реальных native worker-backed reopen
теста; 513 scoped + 94 identity/app-controller/on-disk проверки прошли, analyzer
чист. GUI-переключение с активной сетевой загрузкой не квалифицировано.
Догрузка **10/10** при online A/offline C завершилась до возврата C, но первое
полное наблюдение заняло **63,876 с**: ускорение доставки не заявляется.
В этой серии gate median <0,1 мс, max 256 мс, прямой file-store commit RPC max
115 мс; общая save-стадия max 1,36 с. 61 byte-identical no-op по два байта
тратили время на чтения, источник пока не определён. Постоянный многосекундный
file gate не наблюдался; прежние пики 3,32 с этим не объяснены. Следующий участок
— ожидания до ingest, Outbox/retry и общие worker RPC. Стенд закрыт, QA APK
восстановлен, product не содержит QA-таймеров, SDK прежний. Без push/релиза.

[Раунд ingest/freshness](../group-ingest-freshness-2026-10-31/README.md) убрал
лишнее хеширование неизменной истории для определения новых уведомлений:
в красном тесте 120 старых строк давали 180 лишних canonical-вызовов, теперь 0.
Проверки подписей/цепочек/форков и durable apply сохранены; gap-fill и повтор
snapshot не дублируют события. В двух физических сериях все 22 сообщения
восстановились на B при online A и offline C до возвращения C, но полное
наблюдение **64/91 с** не показывает сквозного ускорения. На кандидате 22/26
кадров без новых уведомляемых строк; это ещё не доказательство exact duplicate.
Save и его ожидания достигали **3,32 с**, чтение под gate также остаётся дорогим.
Следующий участок — storage gate/чтения/commit и атрибуция повторной работы.
432 scoped + 11 targeted проверки и native-стенд 4 сообщения всем 12 прошли;
analyzer чист, стенд закрыт, QA APK восстановлен, SDK прежний. Без push/релиза.

[Раунд verdict-кэша](../verdict-cache-digest-2026-10-31/README.md) исправил
воспроизведённый cache hit для некорректных длин Ed25519 ключа/подписи;
текущие сетевые обработчики уже проверяли длины, удалённый обход не доказан.
SHA-256 через существующий native ABI уменьшил стоимость ключа кэша в AOT
микрозамере на 38–55%, но ускорение полной доставки не доказано. 404 scoped
теста и 6 дополнительных targeted проверок прошли, analyzer чист.
На трёх устройствах 103/103 сообщения в итоге сошлись с одинаковыми ID/порядком
без дублей; **догрузка остаётся медленной**: 24/100 и 0/3 ранних за 120,934 с,
A online, C offline. Полная сходимость достигнута после возврата C, поэтому
независимое от C восстановление не доказано. Приём 100 исходящих занял
175,186 с — хуже предыдущей отдельной серии; это не контролируемое сравнение.
Малый контроль отправителя старая/новая/старая дал 366,5/308,5/276 мс без
устойчивой регрессии или ускорения; контроль чтения на Android также не показал
общего выигрыша. Следующий участок — ingest/merge/save/ratchet/ACK и очереди,
а не объявление cache-оптимизации решением всей задержки. Исходный QA APK
восстановлен, стенд закрыт, данные сохранены; SDK не менялся, push/релиза нет.

[Физическая квалификация текущих клиентов](../physical-delivery-multidevice-2026-10-31/README.md):
Mac A + Android B одной личности, Mac C другой. Шесть online-сообщений и двадцать
одновременных отправок A/B сошлись без дублей; итог всех серий — 129/129 у каждого
с одинаковыми ID и порядком. **Подтверждена медленная догрузка:** после пяти минут
offline B расширенный наблюдатель за 120,178 с увидел 19/100 накопленных сообщений
и 0/3 ранних; A online, C на этом участке offline. Позднее история сошлась уже
после возврата C — прохождение сценария без C этим не доказано. На телефоне
несколько секунд уходят внутри обработки отдельной device-group записи;
CPU-профиль выделил обходы/проверку истории и вычисление ключа verdict-кэша.
Причина всей задержки не установлена, исправление не заявляется. Следующий
участок — чтение/валидация/сохранение/ACK на большой истории с контролем стоимости
диагностики. APK и native SHA проверены; Mac Runner/плагины оставлены прежними,
Android profile/AOT с логированием; A/B скорости и Windows/mobile-provider нет.
Сценарий crash посреди sync не выполнен: к попытке уже были все сто сообщений.
Процессы/порты/forwards очищены, исходный QA APK восстановлен по SHA, данные
профилей сохранены. Без push/релиза; остальные пункты матрицы остаются открытыми.

[Полосы обычных повторов](../message-retry-peer-lanes-2026-10-31/README.md)
сняли последовательное ожидание разных контактов: до четырёх conversation jobs,
порядок внутри адресата сохранён. После timeout незавершённый send удерживает
адресата до фактического settlement; pause/dispose перепроверяются после await.
Возрастное завершение не пропускается из-за занятости. Семь красных сценариев
на прежнем коде; итоговые 320 тестов прошли, 0 skipped, analyzer без замечаний.
Пойманная собственная регрессия coalescing (повторный flush ждал чужую запись
журнала) устранена с сохранением прежнего быстрого выхода. В контрольном опыте
трёх native-узлов при удержанной первой отправке старая ветка не доставила
второму контакту за 15 с, новая — примерно за 218 мс. После release оба получили
ровно по одному сообщению с ожидаемым текстом; обе временные пары очищены.
Это искусственный endpoint gate и локальный TCP, не физическая скорость мобильной
сети и не multi-device матрица. Остаток — group/cold-path ожидания и физическая
квалификация; прежние control/mailbox cadence и backoff не менялись. Без push/релиза.

[Независимые повторы обычных сообщений](../message-retry-control-independence-2026-10-31/README.md)
сняли подтверждённую блокировку: весь conversation retry ждал окончания control
Outbox, включая медленное чтение и live-leg deadline до 10 с. Теперь оба job
запускаются независимо, общий проход ждёт оба даже при ошибке. Gate-тесты
воспроизвели отсутствие обычной отправки на прежнем коде; 309 проверок прошли,
0 skipped, analyzer без замечаний. Native regression: 4 сообщения всем 12 без
дублей, teardown чист. Это не A/B скорости и не доказанная причина прежних
53/114,9 с. Внутри conversation job обслуживание разных peer ещё последовательное;
ceiling/cadence/backoff control и mailbox не менялись. Отдельная оптимизация
повторного чтения file metadata исключена: в трёх A/B четвертое сообщение каждый
раз было медленнее, хотя чтений меньше. Product `file_store.dart` возвращён к базе.
Без push/релиза; затем по плану остаётся multi-device матрица.

[Раунд атомарного snapshot + резерва](../ratchet-snapshot-reservation-2026-10-31/README.md)
реализовал найденную возможность убрать отдельную транзакцию после сохранения
новой sending chain. Snapshot, marks и очистка хвоста коммитятся вместе;
floor — после commit и anchor attempt, с проверкой владельца и живых цепей.
Отказы/потерянные ответы, rotation/supersession/close во время записи,
whole-entry budget и native reopen проверены. 286 тестов прошли, 0 skipped;
analyze без замечаний. В трёх локальных native A/B-парах медианы четырёх
сообщений всем 12: **4141/2932/2383/2874 → 3707/1579/1714/2359 мс**;
native commit **1381 → 1095**, отдельные резервы **302 → 55** (медианы).
24 сообщения у всех 12 ровно один раз, процессы/порты очищены. Не каждый
индивидуальный замер быстрее; это ограниченный Mac/JIT/TCP стенд, не проверка
телефона или multi-device. Остаток — group handling и холодный native путь.
Без push/релиза.

[Раунд ratchet I/O / anchor retry](../ratchet-io-anchor-retry-2026-10-31/README.md)
подтвердил пропуск anchor attempt после потерянного ответа успешной записи
резерва: retry выдавал floor из fresh disk marks при `wrote=false`.
Теперь attempt обязателен перед permit и в этом случае; held-anchor gate
проверяет запрет native seal, warm cache не делает лишних попыток. 255 unit /
security + 4 native ABI прошли, 0 skipped. Два native stand: 8 сообщений всем
12 без дублей. Это не заявляется ускорением. Профиль: 300 отдельных reservation
writes и 409 snapshot writes; 303 новых sending-chain id, 0 расширений
наблюдавшейся цепи. Для 246/300 резервов подходящая цепь уже была в предыдущем
сохранённом snapshot. Следующая проверка — атомарное сохранение snapshot и
его резерва (ещё не реализовано), с прежними commit/anchor/permit гарантиями.
Долгая доставка и multi-device матрица остаются открытыми. Без push/релиза.

[Раунд готового ratchet-резерва](../ratchet-reservation-queue-2026-10-31/README.md)
подтвердил gate-тестом блокировку уже обеспеченного отправления чужим I/O.
Активный native guard теперь допускает read-only reuse durable marks до
этого gate; новые позиции/цепи всё ещё требуют записи и native floor.
Закрытие, ротация, sibling, исчерпание и held anchor проверены; legacy без
native guard сохранил сериализацию. 254 unit/security + 4 native ABI прошли.
В трёх A/B медианы всем 12 **4392/4195, 2839/2449, 2087/1746,
2644/2661 мс**: первые три меньше, четвёртая не улучшилась. P95 всей
популяции reserve выше во всех B; улучшение хвоста и универсальное ускорение
не заявляются. Отдельный probe poll 200→20 мс не дал общего улучшения,
исключён; production poll 200 мс сохранён. В 12 stand все 48 сообщений у
всех 12 без дублей. Остаток — начальный checkpoint/I/O и хвостовые очереди,
затем multi-device матрица. Без push/релиза.

[Раунд атомарной очистки](../group-atomic-retirement-2026-10-31/README.md)
объединил полное удаление небольшого заменённого сегмента с публикацией header.
Hints ограничены 64 ops вместе с metadata/GC; streamed/on-disk/крупные файлы
остались прежнему cleanup. Descriptor и обязательные повторы сохранены,
отказ commit и потеря ответа на успешный commit проверены. 668 тестов
приложения + 3 native file-store прошли на финальных исходниках, 0 skipped.
В шести native stand все 24 сообщения у всех 12 ровно по одному разу;
group-file commits **180 → 144 (−20%)**. Медианы A/B **4282/4301,
2454/2373, 2005/2115, 2629/2738 мс** не показывают общего ускорения.
A/B изолирует planner; HVS prefilter одинаков в обеих фазах. После hardening
legacy metadata ещё 8 сообщений прошли в двух functional stand (всего 32);
финальный stand не считается сравнением скорости. Остаток —
холодный handoff→callback и очереди/preflight/обработка следующих копий.
Долгая доставка и multi-device матрица остаются открытыми. Без push/релиза.

[Раунд локального wake](../authorization-local-wake-2026-10-31/README.md)
добавил пустое IPC-уведомление о новой verified revision. Оно запускает
checkpoint, но не заменяет durable ACK. Burst объединяется; I/O failure,
missed hint, late bind и close проверены. 171 Dart + 2150 основных Rust +
3 native security прошли, 18 Rust ignored отдельно. В трёх native B реально
получены по 64 hints (A: 0), но медианы A/B **4223/4259, 2471/2607,
2063/2406, 2838/2721 мс** не показывают общего ускорения. Финальный stand
с часовым тестовым backstop прошёл; production backstop остаётся 1 с.
В девяти запусках все 36 сообщений у всех 12 ровно по одному разу.
Долгая доставка остаётся открытой; peer notification не объясняет весь остаток.
Без push/релиза.

[Раунд checkpoint хоста](../authorization-checkpoint-batch-2026-10-31/README.md)
убрал commit на каждый независимый документ авторизации: теперь whole-document
пакеты ограничены 64 ops, ACK остаётся после всех commit. 146 тестов и 3 native
прошли, 0 skipped. В трёх парах те же 64 chunk ops потребовали **40–41 вместо
64 commit**. Холодная медиана всем 12: **4440 → 4067 мс**, последующие медианы
чаще медленнее; общего ускорения не заявляем. Дополнительный прогретый A/B/A
равномерной регрессии не подтвердил. В девяти запусках все 48 сообщений у всех
12 ровно один раз. Отдельный тест с виртуальными часами воспроизвёл **999 мс**
ожидания polling-only checkpoint при мгновенном store. Уведомление о pending
revision добавлено следующим раундом выше; периодический backstop 1 с сохранён.
Без push/релиза.

[Раунд лишней перезаписи header](../group-cleanup-header-2026-10-31/README.md)
подтвердил очистку уже выполненного descriptor при повторе той же истории:
это стоило двух лишних commit на группу. Опубликованный descriptor и реальные
retries теперь учитываются отдельно; удаления не отложены, failed deletes
повторяются, restart и сохранность истории проверены. 483 теста прошли,
0 ignored. Во всех трёх native A/B-парах group-file commits **244 → 180**,
все 24 сообщения у всех 12 ровно один раз. Медианы первой видимости по четырём
сообщениям A/B: **4254/4450, 2828/2248, 2251/2115, 2710/2753 мс**.
Устойчивое ускорение всей доставки не доказано; cold send/host checkpoint и
остальные секунды обработки остаются в активной очереди. Без push/релиза.

[Раунд доставки 2026-10-31](../delivery-dht-budget-2026-10-31/README.md): точно
сопоставлен отказ DHT-лимитера с timeout запроса ключевого документа. Убраны
одновременные дубли одного document walk; общий повтор фоновых запросов исключён,
один ограниченный повтор оставлен только для ключевых данных. В чередовании
трёх native-контролей и трёх кандидатов медиана первого сообщения всем 12 узлам
составила 8638 / 7995 мс; все четыре сообщения каждого прогона без дублей.
Отдельный прогон финальной библиотеки после защиты поздней локальной публикации
дал 9150 / 2903 / 2614 / 2742 мс. Устойчивое ускорение итогового дерева не доказано;
холодные ожидания и причины всех потерянных веток ещё не устранены.
Отпечатки запросов остаются только
в явно включаемой приватной трассе, не в анонимном отчёте.

[Следующий раунд reload/DHT](../reload-live-dht-2026-10-31/README.md) подтвердил
потерю собственного ключевого набора: публикация выполнялась до замены DHT,
а при той же личности пропускалась совсем. Теперь она идёт в новый экземпляр.
Два теста воспроизвели дефект; 769 runtime-тестов прошли, 11 ignored.
В трёх native-кандидатах все 12 узлов имеют собственные doc/registry/cert ещё
до первой отправки; в контролях — 4–6. Медиана первой доставки 8449 / 7858 мс,
все сообщения без дублей. Многосекундная задержка остаётся открытой; отдельно
выделены фоновые self-rendezvous lookup в сети без onion-реле.

[Раунд inbound carrier](../inbound-carrier-budget-2026-10-31/README.md) убрал
поиск собственных ads при явно неспособных к onion transit подключённых соседях.
В трёх A/B-повторах такие query frames сократились с 1776–1792 до нуля,
медиана первого сообщения всем 12 — с 8126 до 5297 мс, без дублей/пропусков.
39 FFI stream-тестов прошли. Неизвестная или новая relay-capability запускает
обычный поиск; отдельно все девять leaf установили подтверждённые inbound
circuit через три локальных Core-реле. Холодные 4,5–5,3 с ещё остаются открытыми.

[Раунд пригодных DHT-кандидатов](../dht-eligible-selection-2026-10-31/README.md)
подтвердил ещё два механизма: отказавшиеся обслуживать DHT узлы занимали K-слоты
до фильтрации, а fallback публикации повторно включал их через активные сессии.
Четыре красных теста воспроизведены; 202 DHT + 286 dispatcher + 770 runtime
прошли, 11 ignored отдельно. Отбор теперь применяется перед K; Public-only,
half-set cap и допуск неизвестных capabilities сохранены. Финальная библиотека
доставила 4/4 сообщения всем 12 без дублей как в all-DHT составе, так и при
3 Core + 9 non-DHT leaf; inbound circuit подтверждены у всех девяти leaf.
Ускорение не заявляется: это функциональные проверки разных ролей.
Разложение прежних трёх carrier-трасс показывает первый callback через
247–284 мс и 4–5 наблюдаемых пересылок к последним получателям. Их задержка
4,5–5,3 с не объявлена устранённой: все 12 тогда обслуживали DHT, а размещение
ключевых реплик и накопление ожиданий по пути требуют отдельной работы.

[Раунд сессионной публикации](../session-replication-2026-10-31/README.md)
подтвердил ожидание первой публикации за shared Notify/poll и задержку новых
реплик полным debounce. Добавлены buffered session events и bounded досылка
собственных публичных записей новым TX-регистрациям через прежнюю фоновую
очередь; неизвестные capabilities допускаются, явные отказы DHT сохраняются.
Пойманный тестом replay прежней записи после локальной замены исключён до
финальной серии. 1931 тест прошёл, 24 ignored отдельно. В трёх строгих A/B
финальной библиотеки медиана первой доставки всем 12: **5369 → 4495 мс**;
таймауты ветвей поиска реплик, связанных с app send: 80/80/52 → 0/0/0.
До первого post у всех собственных doc/registry/cert уже есть удалённые копии.
Следующие сообщения не показали устойчивого ускорения. Отдельные 3 Core +
9 non-DHT leaf доставили все четыре сообщения, inbound circuit готовы у девяти
leaf, но в этой топологии остаются 34 app-triggered replica timeout, три
сопоставлены с sampled refusal. Остаток: несколько секунд распространения,
native seal/host checkpoint и молчащие DHT-ветви частичной топологии. Затем —
multi-device матрица. Без push и релиза.

[Раунд повторных DHT-запросов](../recursive-duplicate-budget-2026-10-31/README.md)
подтвердил списание per-peer/service budget для уже обработанных копий, которые
затем отбрасывались dedup. Добавлен только read-only unexpired-ID peek до
admission; все неизвестные ID по-прежнему ограничены до decode, численные
лимиты 5/s, burst 20 сохранены, приоритетов нет. 1934 Rust + 13 диагностических
тестов прошли, 24 ignored отдельно. В трёх A/B состава 3 Core + 9 non-DHT leaf
медиана первой доставки **7362 → 4471 мс**, но общая проблема остаётся:
replica timeout 30/42/27 против 29/25/38, последующие сообщения не имеют
устойчивого общего выигрыша. Все 28 сообщений семи стендов дошли всем 12 без
дублей, teardown проверен. В all-DHT первый callback 125–512 мс, тогда как
отдельные receiveGroupFrame занимают до 2063 мс; следующий разбор — локальный
apply/постановка пересылок и их связь с первой видимостью. Интервалы включают
дубли/перекрытия и не суммируются в критический путь. Телефон/production-реле
не менялись; push/релиза нет, multi-device матрица ещё впереди.

[Раунд одного journal view](../group-held-view-2026-10-31/README.md) убрал
повторное чтение manifest и admission-state при compact data-delta. Под group
gate восстановление, общая политика допуска и merge используют один полностью
загруженный bundle; scoped pending ceremony сохраняет исходную проверку hash.
Собственный пропуск этой границы пойман тестом и исправлен до коммита.
448 тестов с native XVSB/XVRC прошли без skipped, targeted analyze чист.
В финальной серии native receive читает журнал **2–3 раза вместо 4–5**;
восьмёрка новых регрессий включает revoke, concurrent write, read failure,
отсутствующий segment и pending ceremony. Ускорение всего пути **не доказано**:
медианы четырёх сообщений 4355/2924/2388/2922 → 4326/2368/2641/2969 мс.
В точном финальном frontend дополнительно проверен smoke после lint-only
правок. Все сообщения семи зачтённых стендов видны всем 12 ровно один раз,
teardown проверен. Следующий шаг — связать конкретную копию сообщения с
durable enqueue, фактическим transport-send, native callback и первой
видимостью; средние интервалы всех повторов критический путь не заменяют.
SDK/телефон/реле не менялись, push/релиза нет. Multi-device матрица впереди.

[Раунд fanout и пути копии](../group-fanout-path-2026-10-31/README.md) подтвердил
блокировку остальных адресатов медленным/отказавшим первым callback. Data-delta
теперь допускает четыре callback на один broadcast, продолжает здоровых после
ошибки и присоединяет активные работы перед возвратом ошибки. Пакеты/filters и
control fanout прежние; wire-order не обещается, inverse delivery сходится.
472 проверки прошли без skipped. На шести native стендах все 24 сообщения
появились у всех 12 ровно один раз, все процессы закрыты. Для 24 критических
путей появилась точная неперекрывающаяся атрибуция по copy/body tokens.
Общего ускорения пока нет: медианы 4516/2204/2402/3118 →
4425/2520/2037/2889 мс. В последующих сообщениях native handoff→callback
суммарно 5–185 мс, обработка группы до следующего шага 714–1885 мс,
queue/preflight 196–792 мс. Холодный native участок 1371–2461 мс ещё требует
разбора resolve/authorization; внутри group apply предстоит отделить запись
header/segments от остальной работы. SDK/телефон/реле не менялись,
push/релиза нет; multi-device матрица не квалифицирована.

**Сняты с активной очереди до нового воспроизведения:** неожиданное завершение
звонка около 25 с, 120-секундная недоставка предложения новой личности, паузы
файлов после reconnect и исходная жалоба «33%». В последующих проверках обрыв
25 с не повторялся, предложения приходили быстро, последние две прерванные
передачи завершились в прежних stream. Это решение о приоритете, **не доказанное
устранение первоначальных причин**. Прежние события, трассы и готовая диагностика
сохраняются; при повторении случаи возвращаются в разбор. Нижележащие записи
об их активности описывают предыдущие циклы и не меняют эту очередь.

Метки подтверждённости (2026-10-30):

- **ПОДТВЕРЖДЕНО** — симптом зафиксирован на стенде либо механизм воспроизведён
  тестом. Это не означает, что доказана причина исходной жалобы или что симптом
  воспроизводится на каждой последующей сборке.
- **ЖАЛОБА** — сообщение пользователя без независимого подтверждения именно
  этого случая. Это не утверждение, что проблемы нет.
- **ОГРАНИЧЕНИЕ** — поведение старого формата/сохранённых данных подтверждено
  кодом и тестами; отдельно отмечается, что уже исправлено для новых передач.
- **НЕ ПРОВЕРЕНО** — отсутствует квалификационный прогон; само по себе это
  не обнаруженный дефект.

| Случай | Отметка | Граница подтверждения |
|---|---|---|
| TTL device-фильтра после ожиданий policy/prune | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННЫХ ГРАНИЦАХ** | Свежие cutoff/clock, canonical expiry проверяется по собственному timestamp; tombstone повторно подтверждается, свежий clock-conflict не удаляется. Ordinary/native gates, TTL-off/clock rollback/cold reopen прошли. Post-admission и полная policy/skew матрица не закрыты. [Проверка](../device-expiry-clock-2026-11-04/README.md). |
| Неполная новая queued snapshot-копия при прерванном admission | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННОМ ПУТИ** | Полный index set публикуется атомарно; staged payloads имеют cleanup obligation, lost reply оставляет определённый logical image. Ordinary/native failure/reopen/max-size и TTL controls прошли. Старые partials без полной source-копии не восстанавливаются. [Проверка](../group-transfer-admission-2026-11-04/README.md). |
| Конкурентная очистка queued edit после TTL | **ПОДТВЕРЖДЕНО И ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННЫХ ГРАНИЦАХ** | Совместные вызовы ждут результат/scrub, pre-enqueue retry очищает уже сохранённое тело, dispose ждёт локальные работы; tombstone и clock проверяются после чтений. Ordinary/native gates и direct-edit A/B/C прошли. Вся transport/partial/policy/clock матрица не закрыта. [Проверка](../concurrent-outbox-expiry-2026-11-04/README.md). |
| TTL после ожидания enqueue / без live leg | **ПОДТВЕРЖДЕНО И ЛОКАЛЬНО ИСПРАВЛЕНО** | Persisted expiry guard обязателен после queue commit; caller не публикует expired edit. Bodyless replacement сохраняет actual age, ошибка cleanup не скрывается; legacy no-seq discard и cold retry проверены. Native gates/raw roots и два process сценария прошли. Сохранённый старый last-seen моделирует offline, реальные сутки и transport waits не квалифицированы. [Проверка](../outbox-enqueue-expiry-2026-11-04/README.md). |
| TTL при завершении записи правок | **ПОДТВЕРЖДЕНО И ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННОЙ ГРАНИЦЕ** | Own/peer/mirror/reflected paths проверяют original TTL/tombstone после edit commit. Required publication не получает expired body; failed incoming erase не ACK, exact retry сохраняет peer void и не создаёт authored reflected slot. Native gates/cold roots и real-provider 100-edit A/B/C regression прошли. Поздние publisher/transport ожидания ещё открыты. [Проверка](../edit-io-expiry-2026-11-04/README.md). |
| TTL: старый clock копии при живой canonical row | **ПОДТВЕРЖДЕНО И ЛОКАЛЬНО ИСПРАВЛЕНО** | Отказ unseen-expiry marker больше не считается удалением всего ID; сохраняются fresh mirror/edit, удаляется только старая копия. Native old-segment cleanup / cold floor, exact queued rows и real-signer A/B/C с offline recovery прошли. Смена системного времени и вся clock-skew матрица не квалифицированы. [Проверка](../clock-conflict-expiry-2026-11-04/README.md). |
| TTL внутри required publisher / atomic journal completion | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННОЙ ГРАНИЦЕ** | После publisher повторяется expiry guard; device post ждёт save/recheck/scrub, включая независимый key-share. Failed cleanup не ACK/notice/snapshot; exact retry и свежая отправка проходят. Native paired-commit / cold floor и широкая регрессия прошли. Остальные async snapshot/transport/partial/policy границы не закрыты. [Проверка](../publisher-ttl-boundary-2026-11-04/README.md). |
| TTL после append до публикации | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННОЙ ГРАНИЦЕ** | Строка, истёкшая во время append, удаляется до onMessageStored; nullable результат останавливает wire/notification/autofetch. Unit/native gates, scoped author slot, точный retry и fresh A/B/C прошли. Внутри уже запущенного publisher/редакций/transport I/O ещё не квалифицировано. [Проверка](../store-ttl-boundary-2026-11-04/README.md). |
| TTL входящих файлов и предложений | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННЫХ ПУТЯХ** | Legacy meta/chunks/query используют исходный clock и durable expiry; full manifest/ref прекращают unsolicited fetch после отказа surface. Claimed query read-only; свежий ID того же content работает. 6 native cases и fresh A/B/C file regression прошли. Mid-I/O, уже начатые shared downloads/partial transfers и legacy egress NACK остаются вне этой квалификации. [Проверка](../media-ttl-2026-11-04/README.md). |
| TTL входящего текста и правок | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННЫХ ПУТЯХ** | Истёкшие обычный post, duplicate и peer/mirrored edit больше не записывают/публикуют новое тело; tombstone/peer void и required publication предшествуют application ACK. Unit/native отказ/точный retry и cold reopen прошли. Другие media kinds и дальнейшие async I/O окна не квалифицированы полностью. [Проверка](../inbound-ttl-2026-11-04/README.md). |
| Прямые queued правки после TTL и ранний ACK void | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННОМ ПУТИ** | Тело edit оставалось и повторно передавалось после expiry. Теперь exact replacement на bodyless seq slot либо локальный discard для legacy; ACK void только после durable apply. Native raw roots и process A/B/C прошли. Transport/fragmentation после handoff не квалифицированы. [Проверка](../direct-edit-expiry-2026-11-04/README.md). |
| TTL ранее сохранённой строки после cold restart / UI / retry | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННЫХ ПУТЯХ** | Initial sweep теперь немедленный и owned; UI list/preview скрывают expired body независимо от prune, ordinary retry проверяет TTL/tombstone, exact TTL boundary физически удаляется. Native C первый raw read чистый до старого timer; raw worker/close и own snapshot A/B/C прошли. I/O-failure recovery всего массива, native handoff/fragmentation и peer gap-fill/ingress не квалифицированы полностью. [Проверка](../startup-ttl-2026-11-04/README.md). |
| Истёкшие тела в queued собственных snapshot/delta | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО ДЛЯ ПОЛНЫХ КОПИЙ** | Старые payloads оставались после очистки journal. Complete canonical transfers теперь переписываются с сохранением живых rows и durable recovery. Native raw-root и A/B/C прошли. Неполные persisted передачи и другие wire kinds ещё не закрыты. [Проверка](../device-outbox-expiry-2026-11-04/README.md). |
| Сохранение истёкших тел в журнале устройств | **ПОДТВЕРЖДЕНО, ЛОКАЛЬНО ИСПРАВЛЕНО В ПРОВЕРЕННОМ ПУТИ** | Из текущего принятого device journal удаляются expired mirror/edit bodies с сохранением local sequence floors и retry scrub. Native A/B/C проверил очистку, restart автора, новую доставку и cold retention B без источников. Другие transport-копии и весь TTL/clock-skew ещё не закрыты. [Проверка](../device-journal-expiry-2026-11-04/README.md). |
| Предложение файла Mac → новая личность Android | **СНЯТО ДО ПОВТОРЕНИЯ; прежнее событие подтверждено** | На SDK `76d9db45` предложение не появилось за 120 с. На SDK `5c392c4c` в отдельном свежем QA-профиле первое предложение видно за 0,894 с, четыре файла целы. Причина старого случая не доказана, relay-family путь конкретного предложения не атрибутирован; одна серия не закрывает исходный случай. [Новый прогон](../family-delivery-stages-2026-10-30/README.md). |
| Паузы файлов после reconnect | **СНЯТО ДО ПОВТОРЕНИЯ; прежние паузы подтверждены** | SDK `08b67a6e` снимает блокировку готовой outbound-альтернативы молчащим кандидатом; красный gate-тест воспроизвёл старый scheduler. На Blackview/Mac оба 32-МиБ файла после обрыва продолжились в прежних stream, SHA совпали; devlogs без payload-idle/attempt failures. Неподвижный prefix 14–15 с включает radio-off 8–9 с и возврат сессий 5–7,5 с; payload возобновился около первого нового session.open или через ~0,7–1,3 с. Это два наблюдения, не A/B и не закрытие первоначального «33%». [Последняя серия](../outbound-confirm-recovery-2026-10-30/README.md), [прежняя локализация 10-с ожидания](../stale-rto-recovery-2026-10-30/README.md). |
| Долгая доставка и синхронизация | **ПОДТВЕРЖДЕНО на прежних стендах** | Длительные ожидания измерены, несколько механизмов воспроизведены и исправлены. Полной проверки оставшихся задержек на последней сборке нет; старые времена не выдаются за её показатели. |
| Неожиданное завершение звонка около 25 с | **СНЯТО ДО ПОВТОРЕНИЯ; событие подтверждено, причина неизвестна** | На стенде записано 25,094 с; сигнал Android предшествует команде отбоя скрипта на 0,709 с в часах телефона. Это не просто жалоба. В новых relay/onion/P2P звонках на SDK `08b67a6e` (180/180/90 с) и двух дополнительных P2P звонках около 100 с не повторилось. Микрофоны выключены; это не проверка речи. Связь с исправленным кэшем liveness или Android permissions не доказана. [Первичная фиксация](../call-terminal-cause-2026-10-28/README.md), [повтор и Android находки](../android-first-call-permissions-2026-10-30/README.md). |
| Старые осиротевшие групповые передачи | **ПОДТВЕРЖДЁННОЕ ОГРАНИЧЕНИЕ по коду/тестам** | Частичный legacy ACK мог удалить payload-копию. Новый отправитель исправлен; автоматическое восстановление уже осиротевшего старого хвоста отсутствует. Это не доказательство утраты логической истории. |

В новом [раунде Android permissions](../android-first-call-permissions-2026-10-30/README.md)
исправлены подтверждённые механизмы первого звонка: преждевременный отказ второму
из параллельных запросов CAMERA/RECORD_AUDIO; отсутствие повторного запуска typed
microphone service после первого grant; потеря stop во время незавершённого start;
отсутствие захвата камеры после позднего grant. На отдельном profile/AOT QA
последний механизм воспроизведён до исправления, затем видео и отображение кадров
идут в обе стороны, обе OS-подсказки реально подтверждены, typed service работает.
278 Flutter и 9 Kotlin проверок прошли. Это не доказательство причин исторических
жалоб на Windows/тихий звук; в той серии слышимость и поздний запуск аудиозахвата
не проверялись.

Следующий [раунд позднего микрофонного grant](../android-late-microphone-grant-2026-10-30/README.md)
физически воспроизвёл отдельный mediaStartFailure: при mic-on preflight истекал
раньше ответа ОС, открытие записи без grant завершало звонок. Исправлен временный
capture gate без изменения пользовательского mute и таймаутов. После исправления
звонок active до grant, затем Mac принял 1187 audio RTP за 90-секундную серию;
отдельный 40-секундный повтор сохранил mute, выбранный во время prompt, с нулевыми
audio RTP. Видео работало в обе стороны. 310 Flutter тестов, FFI refusal/retry
и AOT privacy gate прошли. Слышимость/громкость речи и причина исторического
25-секундного события остаются не установленными. В анонимной диагностике
сохраняются только OS permission категории ожидание/отказ/grant.

Уточнение сохранения сертификата Android: прежняя классификация занятого
Save/Continue **снята**. В повторе с QA-only стадийной трассировкой файл точно
совпал с показанным сертификатом, native callback и Dart finally завершились,
а «Готово — дальше» после прокрутки реально перевела onboarding на следующий
этап. Отсутствие `focusable` не означает `disabled`; прежний драйвер нажимал
скрытую кнопку и переоценил симптом. Производственный export-код не менялся.
Это не атрибуция старых пользовательских жалоб других платформ.

В SDK `21fe5130` дополнительно устранён [барьер публикации готового входящего
circuit](../inbound-confirm-publication-2026-10-30/README.md): подтверждения
открытого набора больше не ждут друг друга последовательно, одновременно не
более восьми. Красный тест воспроизвёл удержание второго готового кандидата;
проверки поколения сессии и retirement сохранены. В том цикле физической
повторной квалификации файлов не было: телефон был недоступен по ADB. Случаи 120 с / «33%» остаются открыты.
Повторное чтение старой трассы уточнило: четыре медленных family resolve к
новой личности вернули по одному сертификату; нулевые миллисекунды seal/admission
не доказывают отсутствие выполнения этапа.

Повторный [физический прогон на Poco и Mac](../family-delivery-stages-2026-10-30/README.md)
теперь завершён на SDK `5c392c4c`, включающем inbound-фиксы: 4/4 файлов целы.
В SDK также добавлены проверяемые исходы guards/seal/source admission семейной
отправки — 197 IPC-тестов прошли, 5 ignored отдельно. Новая личность получилась
через настоящий onboarding с production-PoW, прежний QA-контейнер сохранён.
Сырые журналы шести реле прочитаны без изменения серверов. В окне найдены 132/1
строка Missing к тестовому телефону; связь с конкретными повторными DATA всё
ещё не установлена. Новые покадровые unknown-записи — ACK после retirement;
старые 343 события этим не атрибутируются. Приложения закрыты, QA APK/профиль и
сетевые настройки восстановлены. Это native-only проверка с замороженным UI,
а не релизная квалификация всего текущего дерева.

В следующем [цикле поклеточного наблюдения](../circuit-cell-reconnect-2026-10-30/README.md)
добавлена отдельная opt-in feature без изменения wire/приоритетов реле. Контрольный
файл ожидал первую проверенную часть 35,464 с; причина подготовки не установлена.
После физического захвата найден и исправлен другой подтверждённый механизм:
поздний выход superseded runner делал непригодным circuit новой TX-сессии.
Связь с прежними паузами не заявляется. Прошли 747 runtime / 671 session / 331 FFI
тестов; 11 / 8 / 2 ignored отдельно. Все шесть временно диагностированных реле
возвращены на исходные loaded SHA, QA APK/настройки восстановлены, приложения
закрыты. Запушенных изменений и релиза нет.

Следующий [прогон возвращённого Blackview](../ffi-route-registration-2026-10-30/README.md)
квалифицировал `4de50051` физически, а затем выявил пропущенных потребителей
старого close-counter в FFI. SDK `9421b3e8` переводит их на свидетель конкретной
TX-регистрации и не карантинит новое соединение за отказ старого handle.
391 FFI-тест прошёл, 11 ignored отдельно. После фикса оба 32-МиБ файла с обрывом
целы, но пауза остаётся; устранение пользовательского случая не объявляется.
QA APK/настройки восстановлены, основной клиент не менялся, ratchet не откатывался.

В SDK `ed902b70` исправлен и [RTO-путь восстановления](../stale-rto-recovery-2026-10-30/README.md):
поздний callback старой регистрации больше не удаляет свежую замену, а устаревший
запасной circuit не разрешает карантин единственного пригодного пути. Два красных
сценария воспроизведены; 392 FFI-теста прошли, 11 ignored отдельно. Новые файлы
целы, но пауза остаётся. По калиброванной серии значительная часть ожидания —
возврат сессий; отдельно найден последовательный 10-с confirm исходящего
кандидата перед быстрой альтернативой. Это следующий механизм для исправления.

В SDK `08b67a6e` исправлен [следующий измеренный механизм](../outbound-confirm-recovery-2026-10-30/README.md):
подготовка/confirmation исходящих кандидатов теперь независимы в пределах двух
попыток; готовый путь публикуется сразу. Отмена сохраняет прежний grace и не
трогает опубликованный sink. 395 FFI-тестов прошли, 11 ignored отдельно.
На последней физической серии нет прежнего 20-с payload-idle и перезапуска stream;
переносить это наблюдение на исходного пользователя/провайдера пока нельзя.
Остальные активные случаи и отложенные жалобы не объявляются исправленными.

Новый [Android-репорт о длинном runtime-пути](../android-long-runtime-2026-10-30/README.md)
подтвердил другой механизм: adopted storage превышает Unix SUN_LEN, узел не
стартует. Выбор authenticated loopback TCP по фактической длине пути локально
исправлен и проверен unit + host-native тестами. Исходный Android с adopted
storage не проверялся. Отдельный `download-resume-read / StateError` из JSON
остаётся **ЖАЛОБОЙ с неизвестной причиной**: прежний обработчик скрывал реальный
класс ошибки. Новая анонимная диагностика различает неполный registry, FormatException
и файловый errno; данные не стираются и не подменяются пустым registry. Связь
с ошибкой запуска узла не доказана; для повторения нужен новый отчёт.

Смешанные бинарники, смена состава во время работы и оставшаяся multi-device
матрица помечаются **НЕ ПРОВЕРЕНО**, а не «подтверждённый дефект».
Отказы publisher slots и `Missing` на реле наблюдались, но сами по себе не
доказывают причину недоставки конкретного предложения/диапазона stream.
Старые 343 unknown-кадра нельзя считать атрибутированными по нескольким
поздним ACK из последующих серий.

Отложенные жалобы — **сняты с активной очереди по указанию пользователя**, а не
объявлены исправленными. Возвращаемся к ним при следующем упоминании; для новых
диагностических сборок проверены механизмы сбора данных, описанные в
[проверке диагностического покрытия](../diagnostic-deferral-2026-10-30/README.md).

| Отложенная жалоба | Какие данные запросить при повторении | Что пока не доказано |
|---|---|---|
| Windows 10: односторонняя доставка | Анонимизированные отчёты обоих концов: nativeSendFailed, transportFailed/Received, retries и messageAcknowledged, версии зависимостей | Физического Win10-воспроизведения нет; исправленный interface pin не объявляется причиной жалобы. |
| Windows 10: нет звука; тихий звук в наушниках/на компьютере | Отчёты обоих концов после звонка: audioStart, результаты запуска capture/playout, mute, грубые диапазоны уровня входящего/исходящего аудио, payload/RX/worker; на Android также категория маршрута, системный mute и громкость разговорного потока | Автоматические счётчики не измеряют слышимую громкость/разборчивость и не доказывают конкретную неисправность драйвера. |
| Windows 10: возврат к onboarding со старым контейнером | Отчёт до перезапуска: этап отказа onboarding, preferenceStoreFallback, класс ошибки и числовой OS-код; без текста исключения/пути | Исходный сценарий пользователя не воспроизведён физически. Защита существующей личности и отказ записи настроек уже исправлялись отдельно. |
| Длительное «засыпание» Android / другие OEM | Отчёт после возврата: lifecycle, backgroundService, снимки фактической foreground-службы/wake lock, Doze, power save, exemption и background restriction | Исправление кнопки службы подтверждено; исходное длительное OEM-засыпание не доказано. После убийства процесса журнал утрачен — пустой отчёт не доказывает отсутствие сбоя. |

Событие завершения звонка около 25 с сохраняет отметку подтверждённого,
но **по новому решению пользователя снято с активной очереди до повторения**,
как 120-секундная недоставка предложения и файловые паузы. Причины не объявлены
устранёнными. Ограничение старых групповых хвостов и пробелы multi-device
квалификации сохраняются. Совместимость старых версий отложена отдельно.
Нижележащие описания — история проверок; текущий порядок работ задан в начале
сводки: доставка/синхронизация, затем multi-device матрица.

В локальной ветке устранён подтверждённый риск повторного использования ключа
после параллельных отправок и аварийного восстановления. Проверка резерва теперь
атомарна с расходованием ключа. [Механизм и проверки](../ratchet-publication-2026-10-29/README.md).
Исправление ещё не опубликовано; установленный пользовательский релиз его не
содержит.

Дополнительно устранён подтверждённый пропуск копии для устройства через реле,
когда другое устройство той же личности имеет прямое соединение:
[смешанная доставка](../mixed-family-delivery-2026-10-29/README.md).
Регрессионный тест воспроизвёл дефект прежней нативной отправки. Исправление
прошло тесты с обработчиком реле, но смешанный маршрут на физическом стенде
пока не получен: оба устройства установили прямые сессии. Это не доказывает
устранение всех причин долгой синхронизации или репорта Windows/Android.

В текущем цикле также устранены неправильный канал запросов/ответов каталога
моделей и подмена адреса контакта адресом отдельного устройства. Категории
диагностики звонков, P2P и каталога теперь разделены; нулевые счётчики звонка
до реального вызова проверены на трёх клиентах. [Исправление и проверки](../control-inventory-routing-2026-10-29/README.md).

Объединение каталогов устройств одного контакта также исправлено: прежняя
строка сохраняется после второго ответа, дубли не добавляются, общий результат
ограничен 32 строками. Одновременно исправлены запуск обработчика без посещения
настроек, пределы вопросов во время ожидания и продолжение рассылки после
закрытия личности. 430 тестов прошли в обоих режимах диагностики; настоящий
диалог на C показал разные каталоги A/B вместе и без дублей. [Проверки](../model-inventory-merge-2026-10-29/README.md).

Независимая проверка нового анализа подтвердила [несвязность группового
распространения](../group-overlay-connectivity-2026-10-29/README.md) и отдельный
обрыв пересылки компактных дельт между участниками без парного контакта.
Оба механизма локально исправлены. Важные уточнения к анализу: пересылка
между участниками существует; уже семь участников могут иметь одностороннюю
достижимость при k=5, даже без разделения на две слабые компоненты. Теперь
прошёл и [локальный TCP-стенд 12 native-узлов](../group-overlay-native-2026-10-29/README.md)
с настоящими подписями, зашифрованными контейнерами и сохранением ratchet.
Все узлы находятся в одном процессе на одном Mac; группа legacy без
membership-epoch шифрования. Четыре сообщения из обеих половин дошли всем
один раз в каждом из трёх прогонов. Разные устройства/процессы, смешанные
версии и изменение состава во время рассылки ещё требуют проверки.
Остальные гипотезы нового анализа не переводятся в доказанные причины
пользовательских жалоб только на основании совпадения таймаутов или
отсутствия программного усиления звука.

В следующем цикле устранено [последовательное ожидание документа и сертификата
уже известного устройства](../certificate-prefetch-2026-10-29/README.md).
Запросы перекрываются, проверка актуальности и durable authorization barrier
сохранены. 732 runtime-теста и 326 FFI-тестов прошли; 11/2 ignored не считаются
пройденными. На локальном 12-узловом стенде потерь и дублей нет. Общее ускорение
доставки и устранение остальных пауз не доказаны; несколько разрешений ключей
всё ещё занимали более шести секунд. Дополнительно исправлена проводка самого
стенда: сохранение peer authorization теперь подключено как в приложении.

Дополнительно устранены [пустое ожидание DHT-ответа при полном отказе очередей
и отложенная очистка отменённого lookup](../recursive-query-admission-2026-10-29/README.md).
735 runtime-тестов и 326 FFI-тестов прошли, 11/2 ignored учтены отдельно.
Это касается в том числе получения записи onion-реле при создании stream;
причина прежних файловых пауз этим не установлена. Там же уточнены утверждения
разбора о sender-мьютексе и восстановлении уже удалённых legacy-частей.

В следующем цикле воспроизведена и устранена [потеря обратного пути последнего
ACK после EOF](../stream-close-linger-2026-10-29/README.md): прежний драйвер
завершался до повтора потерянного финального ACK. Новый ограниченный ответчик
не задерживает EOF; 166 stream-тестов и 326 FFI-тестов прошли, 2 FFI ignored
учтены отдельно. Десять baseline-передач и четыре передачи новой библиотеки
Mac/Android завершились с верным SHA-256. Паузы внутри файлов ещё остаются:
в новой серии до 5,04 с между проверенными частями и до 6,81 с до первой.
Во всех 17 срезах внутри этих загрузок Android был Awake, с активным приложением
и Doze ACTIVE; системная экономия батареи выключена. Обычное засыпание не
объясняет эти паузы. Поведение с погашенным экраном и OEM-экономия Wi-Fi этим
не исключены; первоначальная жалоба на «засыпание» остаётся открытой.

При продолжении разбора исправлены [обход правил выбора handshake-маршрута
и задержанное освобождение места завершённым stream](../circuit-admission-2026-10-29/README.md).
Запасная ветка больше не выбирает первый circuit в обход карантина, лимита
и привязки получателя; публикация нового пула во время выбора перепроверяется.
Недостаток предыдущего `63bcc1c9` тоже устранён: ответчик последнего ACK
сохраняет путь подтверждений, но освобождает Bulk active-slot сразу после
двустороннего завершения. Поздняя очистка не уменьшает счётчик следующего
stream. Прошли 167 stream-тестов, 326 FFI-тестов с обычными флагами и 383 FFI-теста
с circuit fixtures; 2/11 ignored учтены отдельно, профили не складываются.
Четыре физических передачи с новой SDK при лимите одного активного Bulk stream
на circuit Mac завершились с верным SHA-256. В этой серии локальное ожидание
carrier на Mac до 2 мс, но между проверенными частями остались промежутки до
3,03 с; сравнения скорости с прежней сборкой при одинаковых условиях нет.
Это не доказательство устранения всех причин прежних 3,55 с или зависания на 33%.

Далее устранено [последовательное ожидание документа неизвестной личности
после остальных объявлений](../stream-preparation-2026-10-29/README.md).
Ранний кандидат начинает только bounded read; полное сравнение реплик и
durable authorization остаются обязательными. Новый тест воспроизвёл прежнее
ожидание без числовых порогов. Прошли 738 runtime-тестов, 169 stream-тестов
и 326 FFI-тестов; 11/2 ignored учтены отдельно. Добавлены раздельные числовые
замеры подготовки и endpoint inbox, без изменений очередей/таймаутов/relay QoS.
В новой серии пять файлов в каждом направлении дошли целыми, но максимальный
промежуток между проверенными частями достиг 15,61 с. Mux inbox на обоих
клиентах не переполнялся; все 49 зарегистрированных relay-shed срезов за то
же окно нулевые. Длительные resolve относятся к объявлениям, не к directory
в этой серии; это не объясняет все паузы после начала передачи. Оценка RTT
потока Mac → Android достигала 6,03 с. Конкретный участок ожидания DATA/ACK
после локального принятия отправки ещё не установлен, случай 33% остаётся открыт.

Следом исправлено [применение устаревшего окна из запоздавшего ACK](../ack-window-order-2026-10-29/README.md).
Старый нулевой ACK больше не закрывает окно после более свежего продвижения;
недопустимый ACK ещё не отправленных байтов также не меняет окно. Старые SACK
и equal-ACK window updates сохранены, ACK не прореживаются. Три сценария упали
на прежнем движке; после правки прошли все 174 stream-теста и 326 FFI-тестов
(2 FFI ignored отдельно). Десять новых передач Mac/Android завершились с
правильными SHA-256, однако промежуток между проверенными частями достиг
18,92 с. В периодических Established-срезах нулевого окна не наблюдалось;
исправленный условный дефект не объявляется причиной этих пауз. На Android
появились 343 `unknown` cells в mux; принадлежность активным или уже закрытым
stream пока не установлена. Причины остановки на 33% и длинных пауз остаются
открытыми, новое ускорение не доказано.

В следующем цикле подтверждено и устранено [накопление очереди самим BBR
на медленном канале](../bbr-queue-drain-2026-10-29/README.md): позднее включение
shaping, чрезмерная нижняя граница окна и замена базового RTT задержкой собственной
очереди. В контролируемом FIFO A/B/A установившаяся очередь на длинном профиле
уменьшилась со 120,856 с до 0,382 с при том же полном времени передачи и без
потерь/RTO. Начальная холодная очередь всё ещё достигала 4,194 с. Прошли 183
stream-теста и 326 FFI-тестов (2 ignored отдельно). Native A/B/A на одной
последовательности локальных реле передал 4 МиБ целыми за 7,205 / 6,634 / 7,206 с
payload-времени. Это не проверка публичного маршрута Android и не закрытие «33%».
Дополнительно уточнена метрика прежних 18,921 с: это промежуток между проверенными
256-КиБ частями, внутри которого непрерывная позиция stream продвинулась на
329 257 байт; называть весь промежуток полной сетевой тишиной неверно.

Далее в Veil `524112a2` устранены [перезапись свежего ACK-window запоздавшим
DATA, отсутствие обновления после возобновления чтения и ложный fast retransmit
от чистых window updates](../flow-window-reopen-2026-10-29/README.md). На прежнем
движке упали 11 проверок этих механизмов; в окончательном варианте прошли 197
stream-тестов и 326 FFI-тестов (2 ignored отдельно). Настоящий async driver
в модели возобновляет отправку без ожидания persist вместо прежних 10 с
виртуального времени. Все 16 сочетаний старого/нового движков сохранили байты
и EOF в обе стороны, включая потерю обновления окна. **Однако часть смешанных
профилей медленнее old/old**: в модели до 13,872 с против 4,237 с при потере
обновлений. Это новый явно учтённый остаток совместимости, а не заявление об
общем улучшении смешанных версий. На физическом маршруте эта правка ещё не
проверена; прежняя жалоба «33%» остаётся открытой.

Следующий цикл подтвердил и устранил [обучение BBR на ожидании закрытого
приёмного окна](../bbr-flow-limited-2026-10-29/README.md), Veil `6d33974d`.
Счётчик доставки и прежняя оценка сохраняются; rate checkpoints больше не
пересекают период запрета отправки получателем. Новый тест упал на прежнем
коде, после правки проверены и нормальное повторное обучение, и сохранение
seed/защиты от устаревшего ACK. Прошли 199 stream-тестов и 326 FFI-тестов
(2 ignored отдельно). В модели A/B/A задержки двух смешанных профилей с
потерей открытия окна сократились с 13,872 до 8,431 с и с 5,935 до 1,251 с;
повтор A вернул прежние значения. Все байты и EOF сохранены в 16 профилях,
new/new не изменился. **Часть смешанных ожиданий persist остаётся**, а исходный
физический случай «33%» по-прежнему не закрыт.

В Veil `9f2456d1` исправлено [ложное объявление отвечающего полного получателя
мёртвым при отказе принять persist-байт](../persist-replies-2026-10-30/README.md).
Нулевой ACK не подтверждает byte, но обычные потери больше не начисляются
отвечающей probe-попытке; повторные ответы не продлевают таймер. Молчание и
обычные DATA сохраняют прежние retry-лимиты. Реальный async driver с полным
эмулированным получателем прежде получал `TIMED_OUT` после трёх ответов;
теперь переживает 39 отказов, передаёт все 256 байт после открытия и закрывается
по EOF. Прошли 207 stream-тестов и 326 FFI-тестов (2 ignored отдельно).
Это не квалификация физического маршрута и не исправление всех persist-ожиданий.

Отдельно подтверждено превышение `recv_window` в неизменённом RxState: 80
unread bytes при окне 64 и 4096 out-of-order bytes при окне 128 для перекрывающихся
пакетов. Приватные красные probes этого этапа не считались пройденными тестами.

В Veil `3bea8780` [приёмный byte-limit локально исправлен](../receive-capacity-2026-10-30/README.md):
граница движется только с чтением приложения, перекрытия хранятся однократно,
SACK-обещания и возможность заполнить head-gap сохранены. Проверены 54 000 шагов
независимой bitmap-модели, 216 stream-тестов и 326 FFI-тестов (2 ignored отдельно).
Два настоящих драйвера пережили две секунды полного буфера и 39 отказанных проб,
затем передали все 2048 байт и закрылись без потерь. В 16 коротких mixed-профилях
A/B/A байты, EOF и числовые результаты не изменились. При длительном нулевом окне
старый отправитель без `9f2456d1` может завершиться по своему retry-лимиту:
проверка раскатки должна учитывать обновление отправляющей стороны. Исходный
физический случай «33%» и другие причины файловых пауз остаются открытыми.

В новой [физической серии текущей SDK и проверке warm target](../file-byte-progress-2026-10-30/README.md)
пять файлов по 3 МиБ в каждую сторону Mac/Android дошли с правильными SHA-256:
медианы 6,848/7,595 с. Native-prefix больших входящих stream продвигался между
срезами не реже 769 мс, RTO-событий и endpoint inbox drops не наблюдалось.
Телефон на Wi-Fi; сравнения при одинаковом маршруте нет, прежний «33%» не закрыт.
Отдельно воспроизведён и исправлен неправильный прогрев пути к личности вместо
устройства, фактически отдающего файл; reconnect теперь прогревает устройства
разных файлов одной личности отдельно. Прошли 85 Flutter-тестов и 127 Python
проверок анализаторов. Физическая серия предшествует новой Dart-правке и не
является доказательством её ускорения. Холодная подготовка до 3,5 с остаётся.

Далее устранено [отсутствие pacing прогретого stream до первого живого RTT](../warm-first-flight-2026-10-30/README.md).
Сохранённая оценка полосы теперь применяется с первой DATA-отправки, также без
cached RTT. Два теста воспроизвели прежний выпуск 60/64 сегментов вместо заданной
пачки из четырёх. Прошли 218 stream-тестов и 326 FFI unit-тестов; 2 unit ignored
и 5 doctest ignored учтены отдельно. В 16 модельных профилях A/B/A байты/EOF,
время и число cells сохранены; очередь warm-профиля без RTT сократилась с 1000
до 319 мс. Физической проверки новой библиотеки нет. Cold-очередь 4,194 с и
очередь до 16,069 с при сильно завышенном seed после ухудшения пути остаются:
полное устранение файловых пауз не заявляется. Уменьшение initial window до
10 MSS отклонено по измеренному ухудшению быстрых высоколатентных профилей.

В следующем цикле устранено [удержание завышенного cache hint при пригодном
текущем delivery clock](../provisional-seed-2026-10-30/README.md). В модельном
overseed-профиле очередь уменьшилась с 16,069 до 6,819 с, максимальный flight —
с 514566 до 219625 Б; полное время передачи не изменилось. Первый кандидат
замедлял быстрый высоколатентный профиль более чем вдвое и отклонён. Финальная
проверка различает регулярный ACK clock и паузы между underfilled flights;
в 50 профилях A/B/A все байты/EOF сохранены, время не выросло, cold-контроли
не изменились. Прошли 221 stream-тест и 326 FFI unit-тестов, ignored отдельно.
Начальная очередь до 6,819 с и неоднозначные ACK-пути остаются; это не физическое
закрытие прежнего «33%».

Отдельно исправлена [привязка ML-KEM сертификата к запрошенному экземпляру](../cert-slot-binding-2026-10-30/README.md):
подписанный сертификат другого устройства больше не участвует в выборе самой
свежей записи нужного DHT-слота и не попадает оттуда в кэши. Четыре регрессии
воспроизвели дефект; прошли 742 runtime-теста и 326 FFI unit-тестов, ignored
отдельно. Физическая проверка текущих Dart/SDK до этого исправления дала один
целый файл Mac → Android за 7,906 с, но предложение обратного файла не появилось
на Mac за 120 с; загрузка ещё не начиналась. Причина обратной недоставки и её
связь с сертификатами не доказаны. Новое исправление пока не проверено физически;
общие жалобы односторонней доставки и «33%» остаются открытыми.

Устранено [последовательное ожидание сертификатов устройств семейства](../family-cert-concurrency-2026-10-30/README.md).
В синтетическом реестре из 16 экземпляров настоящий resolver с валидными локальными
записями и молчащей репликой прежде не завершался за source budget 30 с; с четырьмя
одновременными walks завершает все 16 за 18 виртуальных секунд. Лимиты каждой
реплики, подписи и freshest-wins сохранены; одновременность DHT повышена в пределах
прежнего глобального cap. Три регрессии воспроизвели дефект; прошли 745 runtime
и 326 FFI unit-тестов, ignored отдельно. Это стадия поиска, не сквозная отправка;
причина недоставленного физического предложения файла пока не доказана.

В [повторной физической серии с SDK `df6edab1`](../family-send-stages-2026-10-30/README.md)
все десять файлов Mac/Android сошлись по SHA-256. Медианы загрузок Android → Mac /
Mac → Android — 12,138 / 9,075 с, максимум — 37,042 с; предложения видны максимум
за 2,117 / 3,724 с. Прежние 120 с недоставки не повторились, но A/B и атрибуции
сертификатным правкам нет. Добавлена диагностика времени resolve/seal/admission
семейной ветки, прежде показывавшей нули при неудаче. В этой серии медленная
family-ветка не воспроизведена; RTO до 10 с остаются. Крупный native Rx-prefix
продвигался между наблюдениями не реже 1375 мс; промежутки записей проверенных
частей не объявляются сетевой тишиной. QA APK восстановлена по SHA, приложения
закрыты. Все причины «33%» и односторонней доставки остаются незакрытыми.

Дополнительно исправлено [замкнутое ожидание anonymous C-close при работающем
read](../anon-close-read-2026-10-30/README.md): token удалялся, но Arc читающего
вызова удерживал writer и не давал отправить FIN. Теперь writer освобождается
независимо от reader, без синхронного ожидания занятого mutex и потери принятых
данных. Два настоящих C-теста воспроизвели дефект; прошли 328 FFI unit-тестов
и 13 выбранных driver integration-тестов, ignored отдельно. Обычный xVeil
wrapper уже вызывал `finish()` перед `close()`, поэтому причина физических
хвостовых RTO и «33%» этим не доказана. В прошлых logs выделены три stream с
восьмибайтовым хвостом/FIN и retry limit; у одного также был более ранний bulk RTO.
Доставка этих хвостов и возврат ACK ещё требуют отдельной атрибуции.

В `07802a08` устранено [удаление маршрута до ответного FIN после read handoff](../eof-handoff-fin-2026-10-30/README.md).
На настоящем стенде предыдущая SDK приняла восемь байт и FIN, но вышла без
собственного FIN/linger; правильные повторы попали в уже снятый mux route, peer
дошёл до retry count 6. Два независимых от сети теста воспроизвели это, включая
потерю первой копии финального ACK. Courtesy FIN теперь проверяется после освобождения
read-buffer. Прошли 223 stream и 328 FFI unit-тестов, ignored отдельно. После
исправления 10/10 файлов сошлись по SHA, все 20 endpoint-завершений имеют
подтверждённый FIN и linger, unknown counters нулевые. Максимум загрузки в этой
серии — 12,668 с, но сравнение скоростей не контролирует маршруты. Закрыт этот
механизм хвостового таймаута; другие bulk-ожидания и все причины «33%» не закрыты.

Следом исправлено [игнорирование RTT поздней первой доставки в RACK](../rack-delivery-rtt-2026-10-30/README.md):
Поздняя первая доставка ранее отправленного сегмента теперь обновляет допустимый
RTT, не сдвигая send frontier назад. Прежде быстрый старый RTT мог преждевременно
запустить retransmit/cwnd cut.
Три регрессии упали до правки; прошли 226 stream и 328 FFI unit-тестов, ignored
отдельно. В 60 модельных профилях A/B/A нет новой потери байтов/завершения:
59 завершены целыми в обеих версиях, один одинаковый reset по retry budget при
20% потерь не засчитан как пройденный. Скорость меняется неодинаково; без BBR
один профиль с потерями/jitter замедлился с 9812 до 12108 мс. Затем на Mac/Android
по Wi-Fi проверены 14 файлов по 3/32/64 МиБ, все SHA-256 совпали, все 28 endpoint
завершились с FIN/linger и снятием маршрута. Три наблюдаемые ProbeRTT завершились
внутри примерно секундных интервалов наблюдения; sampled RTO и mux drops не видны.
64-МиБ передачи заняли 111,366/96,820 с. Начальный driver-интервал 5506 мс с
продвижением лишь на четыре байта пока не атрибутирован. Контроля старой SDK
на тех же маршрутах нет: причина прежней 49-секундной загрузки и всех «33%»
по-прежнему не доказана. QA восстановлена по SHA, свои приложения закрыты.

Затем устранены [закрытие проверенного source handle перед повторным open имени
и принятие замеченной смены stamp](../verified-serve-handle-2026-10-30/README.md).
Регрессия прежнего durable serve действительно отправила байты подменённого
файла под старым CID; новая выдача сохраняет проверенный handle. Два теста
упали на прежнем production-коде; прошли 131 связанный тест и 11 целевых
проверок (десять повторных, одна дополнительная), без сложения счётчиков. Полный hash, verdict cache и
авторизация сохранены. Начальная проверка источника завершалась на 6,219 с
после старта API, но её начало не измерено; сокращение всего ожидания 5,5 с
не заявляется. Обычная выдача с этой Dart-правкой затем прошла
[физическую проверку](../current-dart-physical-2026-10-30/README.md); атаки
подмены на устройствах отдельно не воспроизводились.

Далее исправлен [обход политики папки через живой файловый источник](../live-source-policy-2026-10-30/README.md).
После отказа durable-проверки stream мог читать RAM handle; datagram не
переоценивал делегированное разрешение. Политика теперь сохраняется вместе с
источником даже при ошибке persist и проверяется вокруг чтения. Изменённый
fallback требует совпадения CID; независимая сохранённая копия и действующий
личный источник с исчезнувшим picker path продолжают работать. Снимок mutable
roots также берётся до первого await, чтобы отзыв не снимал маркер делегирования.
Девять из десяти сценариев упали на исходном коде, все десять прошли после
исправления; это не девять независимых дефектов. Прошли 158 связанных
и 28 API-тестов. Физическая обычная выдача затем проверена; гонки с отзывом fileRoots
на устройствах и закрытие всех прежних файловых жалоб ещё не доказаны.

В datagram fallback устранено [освобождение слота по общему 50-секундному
таймауту при продолжающейся передаче](../datagram-serve-lifetime-2026-10-30/README.md).
Прежний Future.timeout не отменял задачу: повтор запускал параллельное чтение,
а поздняя подготовка повторно отправляла payload. Также read, вернувшийся после
начала dispose, больше не публикует bytes. Три сценария упали на исходном коде,
два контроля уже проходили; после исправления все пять прошли. Общий прогон —
163 теста. Это доказанный дефект datagram-выдачи, не доказанная причина всех
«33%» или пауз анонимного stream. Физический короткий fallback затем проверен;
граница 50 секунд на устройстве ещё не пересечена.

[Текущий Dart `7a225483` проверен на Mac и Blackview](../current-dart-physical-2026-10-30/README.md):
четыре stream-файла (3/64 МиБ в обе стороны) и один datagram-fallback файл
1 МиБ целы, все SHA-256 совпали. Восемь stream endpoint FIN/EOF/linger
завершений корректны; endpoint mux дропов не зафиксировано. При этом малый
Mac → Android поток имел sampled consecutive RTO 2; причины прочих задержек
не закрыты. Первая автоматическая очистка сценария ошиблась и потребовала
отдельного восстановления; после него и второго прогона исходный QA APK,
настройки, процессы и порты проверены. Это не проверка отзывов grant на
устройствах, не физический тест 50-секундной границы и не закрытие всех «33%».

Далее исправлено [удаление полной opted-in копии отдельными legacy ACK](../mixed-group-slice-acks-2026-10-30/README.md).
Новый отправитель сохраняет все payloads до ACK каждого индекса, затем удаляет
их атомарно. Модель legacy receive/ACK проходит повторную сборку после рестарта;
потеря RAM-прогресса отправителя также сохраняет полную копию. Шесть сценариев
упали на исходном коде и прошли после исправления; общий прогон — 221 тест.
Это не запуск старого бинарника и не восстановление bytes старого `a:0` хвоста,
физически эта Outbox-правка ещё не проверена.

В Veil `ea7e8388` исправлен [одноразовый pin исходящих интерфейсов Windows](../windows-interface-refresh-2026-10-30/README.md).
Новые сокеты обновляют default-интерфейсы нужных семейств; свой штатный Wintun
не становится новым underlay, unknown/recycled pin отвергается. Нулевой pin
действительно сбрасывает прежнюю socket option. Прошли 72 util и 11 helper
host-тестов, два doctest ignored отдельно; host/Windows clippy и компиляция
Windows runtime с production-seeds и helper прошли. Реальные Windows API/смена
сети ещё не запускались; отдельный Winsock regression test только скомпилирован.
Это устранённый механизм, не доказанная причина пользовательского Win10-случая.

Устранена [потеря сохранённого запроса при отказе открыть файл назначения](../download-destination-retry-2026-10-30/README.md).
Null из opener раньше считался завершением; теперь сохраняет намерение и
использует обычный ограниченный backoff/parking. На baseline null-сценарий
красный, исключение — зелёный контроль; после правки оба восстанавливаются.
Прошли 100 связанных и 2 native-storage теста, включая реальный reopen
контейнера и явную отмену. Это не восстановление OS-grant и не атрибуция «33%».

Устранена [гонка задержанного открытия назначения auto-resume](../resume-opener-ownership-2026-10-30/README.md).
Старый sink больше не возвращает прежний путь после нового запроса/очистки и
не начинает чтение после dispose. Identity token отделяет старую подготовку
от новой, включая finally и поздний отказ. Четыре варианта были красными,
отмена без нового запроса была зелёным контролем; после правки прошли 108
связанных и 3 native-storage теста. Настоящий файловый sink закрывается после
закрытия настоящего контейнера, намерение переживает reopen. Это не квалификация
всех гонок payload после передачи sink и не атрибуция исходного «33%».

Защищена [подготовка четырёх download entry points после передачи sink](../download-preparation-ownership-2026-10-30/README.md).
После отмены/clear/замены ожидающий storage callback больше не возвращает старый
path/mode и не отправляет reoffer. В исходной матрице 10 красных и 2 зелёных
контроля; теперь прошли 124 связанных и 3 native-storage теста. Отдельно
сохранён новый pending sink с тем же path при ошибке cleanup старого. Dispose
возвращает noOffer устаревшей подготовке, сохраняя быстрый shutdown, abort позднего
stream и durable intent. Payload-worker/local-export races и исходный «33%»
этим целиком не закрыты. QA Android AOT и Mac JIT из `48a2d436` собраны с проверкой происхождения; физическая серия ещё не выполнена.

[Текущий Dart `48a2d436` проверен физически](../file-reconnect-physical-2026-10-30/README.md):
четыре файла Mac ↔ Android, включая 32 МиБ с разрывом radio на треть размера,
дошли с SHA-256. После разрыва получены 66,177/104,656 с и интервалы проверенных
частей 21,262/39,158 с. В обоих случаях текущая попытка завершена по Dart
payload-idle 20 с; новый stream открыт через 0,580/0,902 с и продолжил с
проверенного offset. Почему старая circuit не восстановилась до timeout, ещё
не доказано. Четыре unknown-кадра этой серии атрибутированы после retire старых
streams. QA APK/настройки восстановлены, процессы/порты проверены. Это не
закрытие исходного Win/Android репорта и не квалификация мобильного провайдера.

[Контроль сессий circuit и ремонт после reconnect](../circuit-session-repair-2026-10-30/README.md)
теперь согласованы между runtime, исходящим и входящим пулами. Свидетель
поколения сохраняется до build, известная потеря первого хопа запускает
избирательный ремонт входящих регистраций. Первая физическая серия дала
4/4 SHA, но только одно из двух прерываний восстановилось без нового stream;
обнаружен и исправлен собственный недостаток cooldown: reconnect теперь
разрешает повторную попытку до истечения 30 с. Повторная серия дала ещё
4/4 SHA, но в одном из двух прерываний снова понадобился новый stream.
После reconnect старый получатель 17 измерений держал 26 426 байт за дырой
при неизменном префиксе. Недоставка конкретного диапазона до payload-idle
остаётся открыта. Это не атрибуция исходного «33%» и не доказательство
общего ускорения.

[Устранён барьер запуска входящих feed](../inbound-feed-barrier-2026-10-30/README.md):
поздний circuit больше не остаётся без обработчика, пока ранний ждёт подтверждения
до 10 с. Красный/зелёный тест с явным gate и реальным framed SYN, 366 FFI tests
passed (10 ignored). По старым серверным журналам выявлены отказы последнего
участка к телефону при отсутствующей сессии; точной связи клеток со stream ещё
нет. На замене Android согласование контакта прошло, но предложение файла не
было видно за 120 с — скачивание не началось, поэтому физическая квалификация
новой правки на файлах пока не выполнена. Этот отдельный случай и холодное
восстановление маршрутов остаются открыты. Старые QA данные/APK восстановлены,
приложения закрыты; реле не менялись.

| Случай | Подтверждённость | Текущий статус |
| --- | --- | --- |
| Предложение файла Mac → новая личность Android | **ПОДТВЕРЖДЕНО на прежнем стенде; в новой серии не повторилось** | На SDK `76d9db45` предложение не появилось за 120 с. На SDK `5c392c4c` в отдельном свежем QA-профиле первое предложение видно за 0,894 с, четыре файла целы. Причина старого случая не доказана, relay-family путь конкретного предложения не атрибутирован; одна серия не закрывает исходный случай. [Новый прогон](../family-delivery-stages-2026-10-30/README.md). |
| Длительная доставка сообщений, подтверждений и синхронизации | **ПОДТВЕРЖДЕНО на прежних стендах** | Подтверждено. Устранены ожидания исходящего ACK внутри последовательной входящей обработки: [после сообщения](../post-receipt-queue-2026-10-28/README.md) и [после снимка группы](../group-receipt-queue-2026-10-29/README.md), а также [лишние повторные уплотнения журнала](../device-compaction-margin-2026-10-29/README.md). Закрыт [обход локального сохранения фоновым повтором и дозапросом](../outgoing-mirror-retry-2026-10-29/README.md). [Профиль CPU и A/B/A](../journal-hash-work-2026-10-29/README.md) подтвердили лишнее хеширование: три локальные записи занимают 6,19 с вместо 8,48/8,44 с, выигрыш около 27%. Устранено ожидание первоначальной сети [в ответе на дозапрос истории](../group-sync-response-2026-10-29/README.md), обычный путь публикации сохранён. Убрано [дублирование ещё не начатых сохранений ratchet](../ratchet-flush-queue-2026-10-29/README.md): шесть ожидающих запросов обслуживает один свежий снимок, принудительные барьеры сохранены. В последнем обычном шифрованном прогоне с Veil `4857bebc` все 18 сообщений видны к 53,0 с, очередь частей синхронизации пуста к 114,9 с. После холодного открытия на A/B/C совпали истории из 1775 записей и их порядок; подтверждения исходящих сохранены. Ранее с Veil `f031513a` получены 50,9/119,1 с, история и подтверждения сохранились после холодного старта. Эти сетевые прогоны не являются контролируемым сравнением; ускорение доставки и отсутствие регрессий скорости не доказаны. Убрано [повторное декодирование JSON параллельными читателями одного сегмента](../segment-json-sharing-2026-10-29/README.md): в одном A/B/A на телефоне суммарное время трёх локальных записей сократилось на 4–12%, число CPU-сэмплов с JSON-разбором — на 43–47%. Локальные записи всё ещё занимают секунды; декодирование и построение ключа проверки остаются заметными в CPU-профиле. Устранены [отправки по уже снятому снимку Outbox и преждевременный отсчёт паузы/проверки молчащего узла](../outbox-flush-invalidation-2026-10-29/README.md): 159 тестов, включая 13 новых. Устранена [блокировка готового повтора здоровому адресату одним зависшим узлом и захват всех мест backlog первого адресата](../outbox-peer-lanes-2026-10-29/README.md): 262 теста, включая шесть новых; общий лимит 16 и прежние таймауты сохранены. Дополнительно устранено [наложение повторов после таймаута ожидания](../outbox-late-send-2026-10-29/README.md): занятость адресата сохраняется до фактического завершения операции, оставшийся backlog ждёт следующего прохода. Прошли 256 тестов, включая три новых, воспроизведших дефект на прежнем коде. Это ограничение относится к повторам Outbox, не ко всем отправкам. Дополнительно устранено [ожидание первых сетевых отправок при пересылке принятой дельты](../group-overlay-native-2026-10-29/README.md): обработчик ждёт durable enqueue, затем освобождает входящую полосу; локальные исходящие сохраняют прежний sender. Регрессионный тест воспроизвёл блокировку на прежнем коде. Ускорение сетевой доставки не доказано; повторы пакетов наблюдались в предыдущих прогонах, остальные причины задержек ещё не устранены. |
| Самопроизвольное завершение звонка на телефоне примерно через 25 с | **ПОДТВЕРЖДЕНО событие, причина неизвестна** | Причина не доказана. Пользователь не трогал телефон; прежняя классификация как ручного завершения отменена. Последующие трёхминутные звонки и возврат P2P прошли. В новом прогоне C → A/B отдельно проверены ответы на Android A и Mac B, оба вызова оставались активны три минуты под нагрузкой 54 сообщений; окончательная сборка также прошла минутный звонок. Это не доказывает исправление исходного случая. [Новый прогон](../control-inventory-routing-2026-10-29/README.md). [Диагностика завершения](../call-terminal-cause-2026-10-28/README.md), [возврат P2P](../relay-to-p2p-return-2026-10-28/README.md). Дополнительно устранён [подтверждённый сценарий ложного таймаута из-за устаревшего кэша медиастатистики](../call-liveness-snapshot-2026-10-29/README.md): 258 тестов с диагностикой и без неё, четыре новых сценария CallService воспроизвели дефект на прежнем коде. Новая Dart-сборка установлена на Mac/Android. В контролируемом физическом опыте с остановленным периодическим кэшем старый код завершил звонок через 20,187 с с `livenessTimeout`, несмотря на рост приёма движком; новый оставался активен все 64,872 с наблюдения и обновлял кэш свежей проверкой. Обычный двухминутный вызов с ответом на Android A при online B также прошёл; один hangup на A дошёл до C с причиной `remoteSignal`. Причина старого естественного завершения через 25 с по-прежнему не доказана. |
| Длительные паузы/низкая скорость файлов через анонимный stream | **ПОДТВЕРЖДЕНО, включая актуальный native SDK** | В [актуальной серии SDK `5c392c4c`](../family-delivery-stages-2026-10-30/README.md) 4/4 SHA верны; после обрыва воспроизведены статичный prefix 15,468 с и payload-idle 20 с с автоматическим продолжением. Старые данные ниже относятся к прежним сборкам и не являются A/B. Устранён [подтверждённый выход без ответного FIN после read handoff](../eof-handoff-fin-2026-10-30/README.md), из-за которого терялся маршрут финальных подтверждений; 10/10 файлов и все 20 FIN/linger завершений проверены на исправлении. Остальные причины bulk-ожиданий остаются открытыми. Докачка после возврата источника проверена. Места ожидания данных/ACK и больших RTO ещё не установлены полностью; закрытие всех причин жалобы «зависло на 33%» не доказано. [Проверки восстановления и ограничения](../source-crash-file-resume-2026-10-26/README.md). В новом [прогоне без звонка](../file-pause-baseline-2026-10-29/README.md) файл 3 МиБ дошёл на Mac за 90,2 с и на Android за 158,1 с, с промежутками между записями проверенных частей до 22,8/48,3 с соответственно; наблюдаются out-of-order данные и RTO до 10 с. Это не устанавливает участок потери/задержки DATA или ACK и не закрывает дефект. В Veil `77070335` локально устранено [игнорирование подтверждений повторов при обнаружении потерянных повторов](../rack-repair-receipts-2026-10-29/README.md): 158 stream-тестов и 304 FFI-теста прошли. [Новая сборка проверена файлами Mac/Android](../rack-file-physical-2026-10-29/README.md): обе загрузки целы, 65,9/34,8 с. Контролируемого сравнения маршрутов нет; на Android до первой проверенной части прошло 24,8 с, на Mac между частями оставались паузы до 13,2 с. Все причины пауз не закрыты. В Veil `d19923f5` устранено [голодание просроченных таймеров при непрерывном входящем потоке](../stream-driver-timers-2026-10-29/README.md): 161 stream-тест и 326 FFI-тестов прошли. Новая сборка `d19923f5` установлена и прошла загрузку 3 МиБ с проверкой SHA-256: Android 23,7 с, Mac 50,7 с. В этих прогонах остаются ожидание первой части до 6,9 с и промежутки между последующими записями до 7,65 с; контролируемого сравнения маршрутов нет. |
| Старые незавершённые групповые передачи | **ПОДТВЕРЖДЁННОЕ ОГРАНИЧЕНИЕ по коду/тестам** | Для нового opted-in отправителя [legacy per-slice ACK больше не разрушает полную копию](../mixed-group-slice-acks-2026-10-30/README.md); проверено повторное получение после рестарта в legacy ACK-модели. Старые queued `a:0` передачи, уже удалённые payloads и произвольный старый ACK до durable apply этим не исправлены. Старые осиротевшие хвосты автоматически не восстанавливаются; физические смешанные бинарники ещё не проверены. [Исходная совместимость](../group-transfer-commit-ack-2026-10-28/README.md). |

Отдельно остаются незавершённые проверки: вся матрица из 63 сценариев, длительный
offline на часы/дни, физические revoke/split-brain/crash-сценарии и ручное
подтверждение записи сертификата системным диалогом macOS. Непройденная проверка
сама по себе не является обнаруженным дефектом.

Уточнение восстановления старых `grpc:`: частичная сборка в
`messaging_replication.dart` хранится в RAM и до полного `_deliverGroupFrame`
не создаёт запись/дыру журнала. Нельзя считать, что обычный gap-fill увидит
её незавершённые transport-части. В текущем legacy-пути частичные ACK выдаются
после полной успешной доставки бандла; их наличие само по себе не доказывает
потерю логической истории. Уже осиротевший хвост Outbox и недостающая история —
разные случаи. Ранние версии с ACK до durable apply требуют отдельного разбора;
безусловный ACK отсутствующих частей не добавлен.

Отсутствие источника исходящего сообщения при одновременном offline A и C и
отсутствии заранее сохранённой копии для B исключено из дефектов по согласованной
модели хранения. Возврат с реле на проверенный P2P и большие анонимные тексты
проверены отдельно и не перечислены как открытые дефекты.

## 2026-11-01: admission синхронизации без удаления очереди

[Подтверждён и исправлен автоматический purge при насыщении очереди](../replication-cap-retention-2026-11-01/README.md).
Частично принятая передача сохраняет полную исходную копию до ACK/возрастной
очистки; cap по-прежнему запрещает добавление. 91 scoped + один native тест,
2000/2000 process-истории сошлись за 51,453 с, retries 0. Это не доказательство
устойчивого ускорения или единственной причины прежней дыры из 25 сообщений.

## 2026-11-01: новые Android/UI-репорты

[Файлы, окно звонка на блокировке и обмен контактом](../android-file-call-ui-2026-11-01/README.md).
Исправлены app-private export больших вложений и непойманные начальные ошибки
сохранения; отказ доступа получает отдельное сообщение. Для plaintext-download
сохранён прежний resume sink, добавлен явный export в выбранное место.
На native-стенде Blackview подтверждён отдельный дефект: обновление daemon
notification не открывает full-screen Activity. Подготовлен отдельный incoming
alert и call-only экран с прежними capability/session барьерами. Это ещё не
физическая квалификация полного медиазвонка xVeil. Есть проверка/настройка FSI
для Android 14+, вкладки контакта и инструкция Debian + nginx. При проверке
последней найден и исправлен отказ парсера WS/WSS от стандартных 80/443; гайд
использует 9443 до выпуска правки.

Новые жалобы на эхо/шум/пропуски речи Poco mobile ↔ Windows Wi-Fi остаются
активными; AEC/NS, render-reference и jitter/packetization требуют отдельного
разбора. Старые отложенные случаи этим не возвращаются без воспроизведения.

По дополнительному запросу владельца call-only экран получил скруглённые
кнопки, статус, локальное имя и аватар (инициал при отсутствии). Caller-data
передаются отдельно в RAM и привязаны к текущему session; в анонимную
диагностику/notification intents они не добавляются. Размер QR по уточнению
владельца сохранён — 180 logical px.

## 2026-11-02: software AEC/NS и локальный переключатель

[Подтверждено отсутствие включения AEC/NS в прямых Call-путях](../call-audio-processing-2026-11-02/README.md).
Render-reference уже проходил через реальный AudioTransportImpl. Включены AEC
и NS, добавлен live-переключатель NS с локальным зашифрованным сохранением и
rollback. 333 scoped Flutter tests, 4 FFI checks, реальные APM/DSP и native
control smoke прошли. В обычной локальной dylib нет test-hook экспортов.
Это локальное исправление механизма: новые engine pins ещё не выпущены,
физическое эхо/шум Poco ↔ Windows и пропуски речи остаются активными до проверки.
Старые deferred-жалобы и остальные сетевые/матричные фронты статус не меняют.

Продолжение звуковой проверки: подтверждена и устранена гонка первого capture
до загрузки сохранённого выбора NS. Добавлены фактические признаки AEC/NS/AGC2
в native snapshots и числовой allowlist диагностики, включая проводку group.
[Подробности и проверки](../call-audio-processing-2026-11-02/README.md): 337 scoped
тестов с включённой диагностикой, AOT privacy gate и native control smoke.
Физическая проверка Poco ↔ Windows не выполнена: Windows не ответила на SSH;
исходные звуковые жалобы сохраняют активный статус, pins ещё не обновлялись.

## 2026-11-02: дополнительные пропуски речи при джиттере

[Real Opus/NetEq воспроизвёл пропуски без сетевого удаления пакетов](../call-audio-jitter-2026-11-02/README.md).
Устранены слишком низкий target cap и несогласованное расходование jitter
reserve в hard/age-only catch-up; исправлен packet headroom перед acceleration.
На фиксированной трассе jitter 0–200 мс played PLC для 40-мс пакетов 1160 → 0 мс;
при повторяющихся 250-мс задержках 4350 → 580 мс. Цена — больший jitter buffer
только при соответствующих измерениях, не постоянная добавка всем звонкам.

Прошли 108 decoder runs, дополнительные seed-пары, recovery/controller,
обычные direct/group controls, PCM pair и изолированный group codec/mixer.
Подробно задокументирован конфликт периодических tone markers с AEC/NS:
гейты не ослаблены, DSP выключен только в codec-fixture. Анонимная диагностика
теперь сохраняет bounded native jitter target; 32 tests и AOT privacy gate прошли.
Исходная слышимость/эхо, NETCALL-01 и совместная проверка видео на плохом jitter
остаются открытыми; эти прогоны не были физическим звонком или выпуском.

## 2026-11-02: заполненный jitter reserve не должен удерживать видео

[Исправлена несогласованность аудиобуфера и видеополитики](../video-jitter-reserve-2026-11-02/README.md).
Заполненный измеренный reserve больше не считается лишней перегрузкой;
для компенсированного jitter разрешены только ограниченные causal-ACK пробы.
Неполные данные, потери и рост очереди сохраняют запрет. 481 тест и analyzer
прошли; A/B/A-модель и AOT совпали. Локальный native-прогон показал движение
VP8, но общий tone-RMS гейт не прошёл и не объявляется зелёным. Физическая
слышимость и высокоджиттерное видео остаются открытыми; pins/релиз не менялись.

## 2026-11-02: реальный codec-контроль и ожидаемые аудионаправления

[Разобран красный tone-гейт и выполнен controlled-jitter прогон](../video-jitter-native-2026-11-02/README.md).
Замкнутый AEC-контроль воспроизвёл подавление одинаковых тестовых тонов;
codec-only режим явно отделён от production DSP и речевого smoke. На паузах
250 мс/с текущая политика сохраняет audio continuity и движение VP8, прежняя
удерживает видео на 1 FPS. Общий прежний 200-мс гейт в impairment остаётся
красным; ни звук в реальной комнате, ни Poco/Windows этим не квалифицированы.
Попутно исправлено удержание jitter-probe при намеренно одностороннем аудио:
нужны измерения всех ожидаемых направлений. 506 tests, analyzer и native
controls прошли, source/binary provenance сохранено; pins/релиза нет.

## 2026-11-03: ступенька media-time и изменение target не равны росту очереди

[Исправлен ещё один механизм снижения видеолимита](../video-growth-2026-11-03/README.md).
Передаётся версия receiver report с timing target; рост подтверждается также
raw RTP-time, чтобы уменьшение target или старое постоянное отставание не
создавали ложную перегрузку. 525 policy/controller + 19 diagnostic tests,
native compound parser, loader/provenance controls и AOT gates прошли.
В повторном controlled-jitter прогоне queue-pressure не повторился; снижения
по persistent-video-loss остались. Полный прежний 200-мс гейт красный, физическая
слышимость/качество не квалифицированы; pins/публикация не менялись.

## 2026-11-03: padding-loss больше не считается потерей изображения при точном TWCC

[Разобраны persistent-loss снижения видео](../video-padding-loss-2026-11-03/README.md).
Сопоставление пакетов подтвердило padding-only потери в середине owned-loopback
прогонов. Добавлена bounded per-peer классификация по существующему TWCC с
консервативным RR fallback; исходные отчёты GCC/NACK не изменены. Реальная
payload-потеря, поздний repair, чужой SSRC, replay и unknown/expiry проверены.
В новом native-прогоне ложных persistent image-loss событий нет, обе стороны
достигли и удержали разрешённые 60 FPS; actual decoded counters около 20–21 FPS
с учётом разгона. Полный прежний 200-мс гейт красный, слышимость/экран на Poco
и Windows не проверены. Pins, релизы и статусы остальных фронтов не менялись.

## 2026-11-03: успешный сосед больше не отменяет чужие dial

[Подтверждена и исправлена ошибочная проводка connectivity-gain](../connectivity-gain-dial-2026-11-03/README.md).
Успешный handshake одного peer посылал отмену незавершённых подключений остальных,
хотя сеть не менялась. Теперь gain будит ожидающие повторы отдельным сигналом;
реальный network-change сохраняет отмену dial. Попутно поймана и устранена
регрессия первого кандидата с wake до первого poll. 797 runtime tests прошли,
11 ignored отдельно; встроенный FFI прошёл feature-check. На текущем Android
нет SIM, физический mobile handover не выполнен. Пауза NETCALL-01 и холодный
QUIC остаются активны; причинное ускорение и общий фикс не заявляются.
Push/релиза, установки на устройства и обновления реле не было.

## 2026-11-03: очередь предыдущей порции должна быть видна history backpressure

[Исправлена граница завершения history batch](../history-replication-admission-2026-11-03/README.md).
Bulk replay теперь ждёт local save и durable replication admission через
queue-only sender; live single posts остаются фоновыми. Gate-тест подтвердил
прежний ранний success. 490 tests прошли, 3 skipped отдельно, analyzer чист.
На одном frozen-native A/B/A все 2000 ID/порядок/позиции/delivered сошлись:
56,690 / 46,323 / 51,445 с. В B нет логированных отказов очереди, в A₂ один;
конкретный прежний пропуск 25 строк с конкретным отказом не связан. Повторные
чтения в B не уменьшились, устойчивое сквозное ускорение не заявляется. Догрузка
остаётся активной, Android/offline матрица не квалифицированы. Стенды закрыты,
кандидат восстановлен; push/релиза, установки на устройства и обновления реле нет.

## 2026-11-03: независимые адреса у параллельных routing-запросов

[Исправлено разделение изменяемых байтов адресов](../device-routing-isolation-2026-11-03/README.md).
Новый список результата не копировал `NodeId.bytes`: один caller мог изменить
цель другого caller того же незавершённого чтения. Красный тест подтверждён на
исходном коде; теперь каждый результат владеет своими ID. 494 tests прошли,
3 skipped отдельно, analyzer чист; после сужения diff повторены 8 routing tests.
Отдельный кандидат переиспользования журнала для delta не включён: native
A/B/A на 2000 строк дал 41,298 / 46,527 / 46,359 с, без сквозного выигрыша.
Во всех фазах ID/порядок/позиции/delivered сошлись без потерь и повторов; отдельный
native-прогон copy-only исправления не выполнялся. Миграция остаётся активной,
статусы остальных фронтов не менялись. Собственные стенды закрыты, runtime
контейнеры удалены; push/релиза, установки на устройства и обновления реле нет.

## 2026-11-03: старый explicit-список не расширяет текущую аудиторию delta

[Подтверждён и исправлен stale `onlyTo`](../delta-target-revalidation-2026-11-03/README.md):
список, полученный до revoke, обходил актуально прочитанный состав и доходил
до sender callback после удаления sibling. Теперь override пересекается с
текущими кандидатами и собственными устройствами. Это дефект приложения;
сетевой обход native floor или реальная утечка по сети не доказаны. Три
адресных регрессии, **497 tests / 3 skipped**, analyzer чист. Native-миграция
2000 сообщений сошлась без потерь/дублей/повторов за 46,442 с, ускорение не
заявляется. Полная revoke-матрица этим прогоном не проверена.

[Добавлен приватный CPU-профайлер только для стенда](../history-cpu-profile-2026-11-03/README.md).
Профиль источника подтвердил повторную работу при local authoring и проверке
журнала; асинхронные ожидания ещё требуют декомпозиции. Прежнее короткое
окно B до adoption не принято за профиль миграции; исправление сбора после
перезапуска квалифицировано отдельной серией 100/100. Все стенды закрыты,
процессы/порты проверены, runtime-контейнеры удалены. Прочие дефекты и пробелы
матрицы сохраняют статус; push/релиза и обновлений устройств/реле нет.

## 2026-11-03: durable-запись не дополняется полной pacing-паузой

[Изменён интервал bulk history replay](../history-cadence-2026-11-03/README.md).
С backlog admission время durable append входит в минимальный интервал порции:
40+150 → 150 мс, 500+150 → 500 мс на виртуальных часах. Room gate, лимиты и
барьеры сохранены; host без admission оставляет прежнюю паузу. Ошибка append
отменяет таймер. **502 tests / 3 skipped**, analyzer чист. Native A/B/A на
2000 строк дал 46,342 / 41,533 / 46,271 с до полного ID/порядка/позиций/delivered;
один цикл и 5-с опрос не дают универсальной оценки ускорения. В B одна
промежуточная полная выборка ещё имела иной порядок/позиции, затем сошлась.
Финальных потерь, дублей и повторов завершённой истории нет. Догрузка всё ещё
медленная. Следующий кандидат — несовпадение registry и transport адресата
при проверке backlog у linked-источника; поведенческого подтверждения пока нет.
Frozen-native SDK здесь старый контроль, не квалификация последних transport
правок. Стенды закрыты, процессы/порты проверены, runtime-контейнеры удалены;
push/релиза, установки на устройства и обновления реле нет.

## 2026-11-03: history-room проверяет реальную очередь master

[Подтверждён и исправлен обход backpressure у linked-источника](../history-room-routing-2026-11-03/README.md).
Registry IDs не совпадали с actual delivery targets: проверялся identity alias
либо пустой список вместо очереди master-устройства. Цикл теперь использует
`addressableOwnDevices`, перечитывает адреса после ожидания и проверяет отмену
после lookup. Широкие 506 tests / 3 skipped, 5 focused routing checks (с новым
sovereign-вариантом) и analyzer прошли. Native-контроль подтвердил: при 135
кадрах в памяти и durable storage прежний цикл возвращался без queue check,
исправленный проверял нужную очередь и ждал до отмены. Два ранних запуска с
ошибочным предусловием стенда не засчитаны; все стенды завершены и очищены.
Это исправление контроля очереди, не измеренное ускорение 2000-строчной
догрузки. Цена актуального routing lookup и остальная матрица требуют следующих
проверок. Старый frozen-native SDK не квалифицирует последние transport-правки.
Push/релиза, установки на устройства и обновления реле нет.

## 2026-11-03: квалификация большой истории и пяти минут offline

[Проверен текущий Dart после history-room фикса](../history-offline-qualification-2026-11-03/README.md).
На трёх OS-процессах начальные 2000 ID/порядок/позиции/delivered сошлись за
35,994 с после link; это один прогон, не доказанное ускорение. B отсутствовал
без процесса примерно 301,2 с; перед его возвратом C был остановлен, A остался
online. Новые 100 сообщений восстановились на B за 5,322 с после ready
(16,244 с от запуска) с точными ID/порядком/source positions и delivered.
Усилен oracle позиций, native-сценарий прошёл без skip. Старая история по
ID/порядку сохранилась. Одна retry до наблюдения общего delivered=100, ноль
после; логических дублей не наблюдалось. Это частичная host/native матрица,
не обеих источников offline, не crash/длительный offline/Android. Замороженный
старый SDK не квалифицирует последние transport-правки. Стенд завершён,
24 собственных PIDs и 33 порта проверены, runtime-контейнеры удалены.
Push/релиза, установки на устройства и обновлений реле не было.

## 2026-11-03: частичная догрузка переживает SIGKILL получателя

[Проверен crash B после получения 250 из 1000 сообщений](../history-receiver-crash-2026-11-03/README.md).
C уже stopped, A остаётся online. После перезапуска B восстановил все 1000
ID/тела/порядок/source positions и delivered без дублей; затем сохранил их
при ещё одном запуске без A/C. Полный observer читает live storage целиком,
короткий native-preflight проверяет различие автора на peer и own-device.
Два ранних запуска с ошибками oracle не засчитаны. Полная квалификация
прошла; 122,101 с включает догрузку и аварийный перезапуск, ускорение не
заявляется. Догрузка большой истории остаётся активной. 23 собственных PIDs
и 33 порта проверены после завершения, runtime-контейнеры удалены.

[Владелец повторно сохранил запрет own-device mailbox](../multi-device-policy-2026-11-03/README.md).
Недостающая история требует доступного держателя; одновременный offline всех
источников — граница модели v1. Это не отменяет требований локальной
сохранности и сходимости после возврата источника. Соответствующий mailbox
guard-test прошёл. Crash отправителя, revoke/split-brain, длительный offline,
Android/AOT и последние transport-правки этой серией не квалифицированы.

## 2026-11-03: byte budget страниц own-device history

[Подтверждено и исправлено отклонение страницы по суммарному размеру](../history-page-byte-budget-2026-11-03/README.md).
Восемь сообщений могли не помещаться в 128 КиБ; повтор строил тот же ответ
без продвижения. Теперь отправляется префикс по фактическому UTF-8 размеру
вложенного JSON с курсором последней включённой строки. Лимиты и проверки
авторизации/TTL не расширялись. На прежнем коде оба новых набора получили
0/17, после фикса — 17/17 с точными данными/позициями/status, включая
переупорядоченные части. Отдельно проверен restart с byte-limited cursor без
повторного apply префикса. 115 tests / 0 skipped, analyzer чист. Это не
измеренное ускорение короткой истории; одна строка, сама превышающая бюджет,
по-прежнему требует отдельного решения. Mailbox для own-device не используется.

## 2026-11-03: crash источника при первичной публикации истории

[Проверен возврат A после SIGKILL во время linking/backfill](../history-source-crash-2026-11-03/README.md).
C stopped до linking. Перед crash у A наблюдались 47/1000 mirrors и durable
served-marker, у B — 0 проверочных строк; после возврата A все 1000 дошли B
с точными ID/телами/порядком/позициями/delivered, без дублей. После следующего
запуска B без A/C история сохранилась. 82,513 с включает запуск A; ускорение
не заявляется. Fold A после восстановления содержит 72 mirrors; 47 — не
атомарный с SIGKILL снимок. Гипотеза невосстановимой потери текстов из-за
ранней served-отметки этим сценарием не подтверждается, production marker не
менялся. Две попытки с ошибками наблюдателя/порядка linking не засчитаны.

Crash произошёл до финального подтверждения adoption B. Прерывание источника
после подтверждённого linking, остальные типы данных и полная crash/revoke/
split-brain матрица этим тестом не закрыты. CLI/FFI — старый frozen-native
контроль. Все стенды завершены и очищены; в финальном проверены 23 собственных
PIDs и 26 портов. Push/релиза и обновления устройств/публичных реле не было.

## 2026-11-03: одна большая строка не блокирует own-history cursor

[Подтверждён и исправлен одиночный oversized event](../history-large-record-2026-11-03/README.md).
Red test получал 1/3 строк: большое событие блокировало и следующую строку.
Теперь событие передаётся порциями по 64 КиБ при прежнем page cap 128 КиБ;
cursor сдвигается после полного digest/position/expiry/auth validation и
durable apply. Частичные байты только в RAM, record cap 1 МиБ, общий новый
budget 4 МиБ. 153 tests / 0 skipped, analyzer чист, включая restart, смену
ревизии, TTL, digest failures, memory-credit reuse и обе стороны revoke.

Native A/B/C: три строки подготовлены через live storage вне device journal,
средняя 160015 байт. При C offline B получил 3/3 с точными данными/позициями/
status, сохранил их после запуска без A/C, дублей нет; journal A остался с 0
проверочных mirrors. 40,792 с включает запуск B, ускорение не заявляется.
Строки подготовлены искусственно, естественная compaction этим не проверена.
Старый frozen-native SDK, 21 собственный PID/22 порта проверены, runtime
контейнеры удалены. Для нового operation нужны обе обновлённые стороны;
legacy compatibility владельцем исключена из release gates. Остальная
медленная догрузка и матрица остаются в работе; mailbox/push/релиза нет.

## 2026-11-03: ready-notice убирает ожидание следующего history tick

[Исправлены запуск после поздних bindings и отмена нового pull старым roster-read](../history-ready-notice-2026-11-03/README.md).
Production host сообщает readiness после own/peer document reads; смена owner
сбрасывает флаг. Ранний reconnect не обходит документный барьер. Nudge не
снимает cooldown завершённых peers, fallback остаётся 30 с. Два прежних
поведения подтверждены red tests, итоговые 161 tests / 0 skipped и analyzer
прошли.

На native A/B/C контролях три строки, включая 160015 байт вне device journal,
полностью совпали и сохранились на B без A/C. Времена от запуска B:
**41,019 / 25,604 / 40,852 / 25,445 с** (старый / промежуточный / старый /
окончательный). Ready B занимает 9,3–9,7 с; первая строка после ready —
30,6–30,7 с в старом и 14,8 с в кандидатах. Это малый сценарий, не доказанное
ускорение большой миграции. Остаточные 14–15 с и причины ранних недоставок
активны; retry-подобные записи без op/call-ID не объявлены полной атрибуцией.

Все стенды закрыты, native/HV SHA и source manifests сверены; финальные
31 PID и 20 портов проверены, runtime-контейнеры удалены. Старый frozen-native
SDK не квалифицирует последние transport-правки. Mailbox/push/релиза нет.

## 2026-11-03: начальный history-запрос доходит, задерживается ответ

[Новая трасса и отдельный фикс жизни исходящего запроса](../history-reply-route-2026-11-03/README.md).
Два красных теста подтвердили отправку history-запроса после detach/замены
его host во время чтения локального device ID. Добавлены проверки текущих
owner/pull/request после ожиданий; 164 tests / 0 skipped, analyzer чист.

SDK `8dac85ce` пересобран в отдельном external target и проверен физически
на native A/B/C. История вне device journal: 3/3 точных строк, включая
160015 байт, дублей 0, B сохраняет их при запуске без A/C. Две текущие серии
дают первую строку через 14,764 и 6,752 с после ready; меньший результат не
объявляется причинным ускорением нового guard или SDK.

Пассивное сопоставление запросов показывает: первый inventory приходит A
примерно за 0,6 с; ранняя попытка ответа начинается сразу, но B видит ответ
лишь после повторов на 6,5 или 14,5 с. Старое direct-соединение к тому же
устройству закрывается keepalive до успешного повтора — кандидат, не полная
покадровая атрибуция. `live send` означает начало вызова, не native admission.
Недоставка начального ответа остаётся активной на текущем SDK.

Временная ошибка private evidence directory не засчитана; корректные прогоны
прошли штатный oracle и cleanup. Финально 23 PID/20 портов проверены, процессы
закрыты, runtime удалён, источники/native SHA сверены. Mailbox собственных
устройств по указанию владельца остаётся отключённым. Push/релиза нет.

## 2026-11-03: полученный SHUTDOWN завершает именно свою сессию

[Подтверждено и исправлено игнорирование остановки peer](../history-shutdown-session-2026-11-03/README.md).
Узел уже отправлял `Detach(SHUTDOWN)`, но получатель освобождал только gateway
attachment и оставлял runner/очередь до EOF или keepalive. Теперь после
расшифровки и обычного dispatch завершается только получившая уведомление
сессия. Остальные detach/migration причины сохраняют прежнее поведение;
owner-checked teardown не изменён. Новый encrypted-wire тест красный на
прежнем коде; итог — 1601 Rust tests passed, 20 ignored отдельно.

Native A/B/A с одинаковыми 1400 Dart/dependency/fixture hashes и HV:
первая строка после ready **14,764 / 11,731 / 14,822 с**, все три строки от
запуска B **26,810 / 22,429 / 25,982 с**. По 3/3 точных строк, без дублей;
B сохраняет их после следующего запуска без A/C. Новый shutdown-handler
наблюдался в кандидате, однако первый ответ всё ещё ждал 11,353 с: начальная
задержка **остаётся открытой**, одна старая сессия не доказана как её полная
причина. Следующее измерение должно связать начало локального вызова с
результатом native admission; соседние 11–20-с send-записи без payload size
и request-ID не объявляются теми же ответами.

SDK `af221389` + тестовое усиление `fbf524e1` локально; старые native artifacts
сохранены до пересборки и побайтно проверены для обоих контролей. Все стенды
закрыты, PID/port checks 24/26, 22/25, 25/19 чисты; runtime удалены. Большая
миграция, Android/AOT и остальная multi-device матрица этой серией не закрыты.
Mailbox собственных устройств, публичные сиды, push/релиз не затрагивались.


## 2026-11-03: ожидание history-ответа за старой source-очередью

[Новые стадии трассировки и два подтверждённых исправления lifetime](../history-reliable-credit-2026-11-03/README.md).
`send_reliable` теперь прерывает ожидание чужого занятого кредита при закрытии
своего ingress. При замене регистрации outbox распознаёт конец канала owner,
а не только явное retirement-сообщение; принятый prefix сохраняется, pending
suffix не переносится в преемника. Новые тесты красные на прежнем коде,
проверяют настоящие registry/runner/waker без таймеров. Коррекции fixture и
ожидания pending suffix описаны отдельно; первая неуспешная серия не зачтена.
Итог второго исправления: **1805 Rust passed / 25 ignored**, doctest отдельно
0/1; privacy AOT gate 1 passed.

Native source wait измеряется от разбора IPC до handler. Ответ 420 байт на
текущем SDK ждёт **6400 мс** до handler, сам handler менее миллисекунды,
relay admission accepted. В A/B/A (baseline содержит первое credit-исправление)
первый ответ от открытия probe B **11,083 / 7,086 / 6,474 с**: последний контроль быстрее
кандидата, причинное ускорение не объявляется. Owner-retirement на A в окне
кандидата не наблюдался; очередь закрылась по keepalive timeout, поэтому
новый owner-фикс не объявлен причиной устранения остатка. Начальная задержка
остаётся активной: нужно связать жизнь конкретного старого runner с очередью,
в которой стоят блокирующие direct admissions.

Шесть native-прогонов — 3/3 точных строк в каждом, включая 160015 байт вне
device journal; дублей 0, сохранность B без A/C подтверждена. Это Mac/JIT,
не большая миграция или Android/AOT. По каждому прогону сверены 1400 frontend/
test/dependency hashes и native/HV; SDK build сверяет 1524 tracked files,
lockfile, features, SHA и отличающий кандидата бинарный маркер. Все runtime,
PID и listener cleanup завершены. SDK `28283933`/`dac463b6` и диагностика
`74a2478c`/`4e28b87f` локально. По явному решению владельца mailbox для своих
устройств остаётся отключённым. Push/релиза и изменений публичных сидов нет.


## 2026-11-03: остановка узла отменяет и входящий session-runner

[Новый воспроизведённый дефект и квалификация](../history-inbound-stop-2026-11-03/README.md).
Listener хранил только handshake-wrapper, который ожидал второй spawned
JoinHandle. При node.stop wrapper отменялся, а runner с сокетом оставался
жив. Дефект подтверждён реальным TCP/OVL1-тестом: после stop remote EOF не
приходил. Обычный и on-demand listener теперь ожидают сам session-future;
отмена узла уничтожает runner/SessionGuard/permit вместе. Публичный spawn API,
wire, authentication, лимиты и timeout сохранены. Новый тест красный/зелёный,
полная runtime-серия **798 passed / 11 ignored**; SDK `54277f42` локально.

На текущей библиотеке первый history-list ответ дважды пришёл через
**0,691 / 0,681 с** от открытия probe B, source wait **67 / 18 мс**, handler меньше
миллисекунды. Но сохранённый старый контроль тоже дал **0,724 с**, поэтому
универсальное причинное ускорение не заявляется. Первая строка кандидатов
всё ещё через **6,758 / 7,211 с**, все три записи от запуска B через
18,354 / 18,299 с; это не закрытая задержка миграции.

Повтор уточнил следующий участок: один и тот же page-request виден на A
на +2,881 с как **claimed**, затем +6,882 с как **signed**; ранний кадр правильно
не проходит history provenance gate. Нельзя приписать всю паузу Dart-очереди
до отправки. Следующая проверка — native seal/route и TX первой попытки против
успешного повтора, с сохранением authenticated gate. Само наличие claimed
не доказывает, почему его породил отправитель; причина активна.

Три новых native-прогона — 3/3 точных записей, включая 160015 байт вне device
journal, без дублей и с сохранностью B после запуска без A/C. Заморожены те
же 1400 frontend/test/dependency файлов; SDK build проверяет 1524 tracked
files, lockfile, features, binary SHA/новый символ и HV. Все стенды закрыты,
по 22 PID, 21/22/22 порта проверены, runtime удалены. Android/AOT, большая
миграция и расширенная матрица не объявлены завершёнными. Mailbox для своих
устройств не добавлялся; push/релиза и изменений публичных сидов нет.


## 2026-11-03: локальный сертификат проверяется до первого ratchet-open

[Исправление и большой контроль миграции](../history-receive-cert-2026-11-03/README.md).
Кэши сертификатов и receive-keys ограничены независимо. При сохранённом
сертификате и утраченном receive-key cached warmer восстанавливал ключ
слишком поздно — после первого open, уже оценённого Claimed. Теперь direct
и terminal Forward передают точную sender-instance в синхронный revalidator
до open. Current floor, срок/отзыв и прежний cert verifier сохранены; claims
не авторизуются сами собой и сетевого ожидания в ingress не добавлено.
Cache miss остаётся на прежнем bounded warm/retry пути. SDK `b8647716` локально.

Два red/green теста direct/relay, итог **1242 passed / 11 ignored** в dispatcher,
e2e и runtime. Ошибка первого direct fixture не зачтена, исправлена и описана.
Малый native-кандидат получил signed page на +0,929 с от probe B, первую
строку через 1,143 с после API ready; старый контроль тоже быстрый, поэтому
универсальное причинное ускорение не объявлено.

**Временные базы уточнены:** wire `+N с` считается от open B-probe (он запускается до API
ready), а parent first-row/complete измерения — отдельная шкала. Неверные
подписи первого ответа в двух предшествующих отчётах/этой сводке исправлены;
исходные raw evidence и интервалы source_wait/handler не менялись.

Два полных actual A→C seed+link-B прогона по **2000 сообщений**: новая native
**35,885 с**, сохранённая предыдущая **36,092 с** до первой наблюдаемой полной
согласованности после linkProcesses. Poll около 5 с, уже 22 строки на первой
выборке; это не точное время от QR или первого history-кадра. В обоих совпали
ID/порядок/source positions, все delivered; invalid snapshots и повторы уже
доставленной истории 0. Ускорение bulk не показано. B: 243 message-log commits
в обоих, other 703/711; пересекающиеся RPC awaits нельзя суммировать как
exclusive disk time. Следующая квалификация матрицы — crash B в середине
большой догрузки; она и prolonged offline/partition этим циклом не закрыты.

Четыре новых native-стенда закрыты, runtime удалены, проверены PID/ports
22/21, 22/28, 18/22, 18/19. Сверены 1400 frontend/test/dependency hashes,
SDK 1524 tracked files/lock/features и native/HV SHA с новым binary symbol.
Это Mac/JIT, не Android/AOT. Mailbox собственных устройств остаётся отключённым;
push/релиза и изменений публичных сидов нет.


## 2026-11-05: контактные политики и ownership оффлайн-архива

[Проверка и исправления](../contact-policy-archive-2026-11-05/README.md).
Новые архивы передают independent policy с исходным clock, создают отсутствующий
контакт до его полей; offline registry ждёт этот slot, live ingress не менялся.
Экран выбирает активную identity вместо physical device ID. Чужие архивы
отвергаются; старый архив именно своего устройства допускается по отдельно
захваченному доверенному local ID, без разрешений по claims архива/сети.

Scoped **76 passed**, diagnostic control **790 passed / 38 файлов**, analyzer
чистый, AOT build/help пройден. Process A/B/C: **13 gates**, импорт с A offline,
новый контакт, newer alias/block/local P2P, repeat и cold B. Пять других
unconfirmed appliers не выданы за подтверждённое применение всех данных.
48 PID/54 порта проверены, runtime удалён; 1476 frozen inputs/native SHA
неизменны. Android/Windows и старый порядок архивных rows не квалифицированы.

[Пользовательский репорт ПК ↔ Android](../user-pc-android-calls-2026-11-05/README.md)
не объявляется решённым: на старой версии семь calls остались dialing до старта
медиа. Повторный SSH check — timeout; физический Windows прогон недоступен.
Локальные исправления premature download-resume read, relay-deposit текста и
handshake/consent уже описаны отдельно. Mailbox своих устройств не добавлен;
push, релиза и обновления публичных сидов нет.


## 2026-11-05: экспорт настроек использует raw-key контракт хранилища

[Воспроизведение и исправление](../archive-settings-storage-2026-11-05/README.md).
Подтверждена потеря сохранённых настроек: `settingsKeys` возвращает `set:*`,
а exporter ожидал логические имена и поэтому пропускал их. Четыре assertion-red
(preview/export × ordinary/native HVS). Исправлен единый reader preview/export;
снимается ровно один `set:` prefix, иные key families остаются вне переноса.
Общий Storage API, GC и импортные allowlists не менялись. Round-trip double
исправлен по настоящему контракту вместо маскировки дефекта.

**63 passed / без skip**, в том числе два worker/native cases с сохранностью
после cold reopen; analyzer чистый. Canary-проверки raw bookkeeping,
локальных параметров и key material пройдены. Native source/artifact пины
неизменны, временные контейнеры удалены. Это настройки encrypted Storage;
SharedPreferences-only/UI controllers и физический Windows звонок не
квалифицированы. SSH Windows по-прежнему timeout. Push/релиза нет.


## 2026-11-05: ранний сигнал звонка не теряется без consumer

[Исправление и process-квалификация](../call-consumer-admission-2026-11-05/README.md).
Ordinary/realtime прежде ACKed и запоминали frame ID до проверки наличия
call handler; поздний handler уже не получал повтор. Два assertion-red на
прежних production files, 2 green на восстановленном кандидате. Теперь общий
handoff сохраняет новую копию для retry/carrier, а уже доставленные дубли
по-прежнему подтверждаются. Consent/provenance/ratchet gates не ослаблены.

Scoped **83**, diagnostic/native-HVS control **792 passed / без skip**,
analyzer чистый. Process A/B/C: пять положительных exact-call сценариев
(onion, обе online, cold B, A offline, B→C и B joins ringing), terminal reason
из свежей анонимной диагностики и одна durable journal row. Шесть snapshots
проверены по allowlist, dropped 0. 1478 frozen inputs, native SHA неизменны;
24 PID/33 порта проверены, runtime удалён. Медиа/слышимость не проверялись.

**Новый открытый случай:** после cold B старый отменённый call кратко вернулся
в ringing и снова завершился cancel (около 10 мс состояния, exact ID проверен
в private signal trace). Этот дополнительный terminal event не скрыт под
пятью прошедшими новыми вызовами. Нужна отдельная проверка durable finished-call
replay; исходный Windows репорт не атрибутирован, SSH недоступен. Push/релиза,
обновлений сидов и mailbox для собственных устройств нет.


## 2026-11-05: durable finished-call state восстанавливается до приёма

[Исправление повторного звонка](../call-history-replay-2026-11-05/README.md).
Старый отменённый call возвращался в ringing после cold B, потому что cache
не переживал restart. Четыре assertion-red на real provider/live inbox (два
native HVS) и два other-peer positive controls. Restore retained journal теперь
предшествует подключению call consumer; early frames остаются для retry,
outgoing setup ждёт этот же barrier. После forked answer также сохраняется
stable identity: отдельный пятый assertion-red подтвердил hot alias-вариант.

Diagnostic control **802 passed / без skip**, analyzer чистый. Native process:
контролируемый authenticated sibling replay того же logical call ID дошёл до B
и был отвергнут без callState/terminal перехода. Пять свежих call scenarios
тоже проходят; A/B/C terminal counters 2/5/5, лишнего B больше нет. Шесть
report snapshots по allowlist, dropped 0. 1479 frozen inputs, native SHA
неизменны; 25 PID/33 порта проверены, runtime удалён. Push/релиза нет.

Ограничения: требуется сохранившаяся journal запись; существующий fail-open
контракт чтения журнала не менялся, полный crash/clock-skew набор не заявлен.
Windows снова отвечает и authenticated SSH выполнен; приложение там не
запущено. Предстоит физический ПК ↔ Android прогон, исходная жалоба пока открыта.


## 2026-11-08: уже допущенный direct peer после relay recovery

[Механизм и проверки](../call-direct-admission-reuse-2026-11-08/README.md).
Повторный endpoint refresh больше не предшествует проверке уже допущенного
answering device после recovery. Snapshot не заменяет свежие admission,
consent и native route proof. 308 related tests, 0 skipped, analyzer чистый.
Два полных AOT Poco ↔ Mac звонка прошли Wi-Fi → Cellular → Wi-Fi; новая ветка
выполнена на обоих концах. Max observed audio RX age на Cellular: 7049/5303
и 16555/13176 мс (Mac/Poco); во втором звонке один Mac rebuild и три среза
без native counters. Это не A/B и не закрытие NETCALL-01. Второй захват
показывает сохранение direct sender до поздней relay qualification; причину
раннего отказа кандидатов ещё предстоит установить. Все own apps/Core закрыты,
артефакты/настройки восстановлены, production не изменён.
В старом AOT захвате четыре конкретных RTP точно сброшены локально как
`child_unavailable` и не получены Mac; причина недоступности независимых
каналов ещё не установлена. NETCALL-01 открыт; SDK/HV не менялись.


## 2026-11-08: deferred relay retry просыпается при восстановлении overlay

[Доказательства и проверки](../call-relay-reconnect-wake-2026-11-08/README.md).
Для 18 cells прежнего Poco-захвата есть быстрый local handler, но нет relay
queue до открытия сессий около +13 с. CallService теперь использует переход
sessionCount 0 → positive как повод повторить уже отложенный кандидат, не как
доказательство пригодности маршрута. Гонка события с in-flight проверкой
покрыта; одно событие не запускает параллельную попытку, hangup/dispose защищены.
317 related tests + 6 provider/history (включая native HVS), analyzer чистый.
Физика pending; первый TCP payload в ранних flows не подтверждался ACK, и
причина этих сетевых отказов остаётся открытой. Push/релиза нет.


## 2026-11-08: асимметричный исходящий путь оставался без relay retry

[Разбор AOT отказа и исправление FSM](../call-relay-reconnect-wake-2026-11-08/README.md).
Один новый вызов прошёл полный handover; второй сам завершился на Mac с
livenessTimeout около +21,84 с после выключения Wi-Fi. Gate не пройден;
артефакты/настройки восстановлены, production неизменён. Новая wake-ветка в
этой серии не выполнена; source/provenance guards проверены, A/B нет.

Подтверждён кодом и red-тестом следующий механизм: cooldown был только датой,
без таймера, поэтому при свежем входящем аудио уже запрошенный relay переход
мог остаться без повторов. Добавлен один отменяемый retry на 5 с, ожидание
занятого native repair и защита старого таймера от нового звонка. 321 related
passed, без skips; analyzer чистый. Физика версии с таймером pending.
NETCALL-01 и новое событие завершения остаются активны; старый 25-с случай
не объявляется объяснённым. Push/релиза нет.


## 2026-11-10: совместное свежее чтение device journal, 100000 сообщений

[Механизм и native A/B/A](../device-bundle-read-100000-2026-11-10/README.md).
Собственный device journal больше не требует отдельных header/segment запросов:
сохраняются только bounded имена файлов, все байты и проверки свежие. При
новом header, stale/missing/oversized hint действует обычный путь; после shutdown
нет позднего fallback. Parent cost assertion-red; три focused guards и
1085 related passed, 0 skipped, analyzer чистый.

Native 100000: RPC получателя **130449 → 81221 → 129412**, примерно −37–38%.
Общее время **128723 → 128688 → 128851 мс**, ускорение не доказано;
latency остаётся открытой. Все 100001 строки exact/cold, по 391 странице
на источник без повторов, обязательства durable commits не сокращались.
1540 frozen inputs, один production variant; cache 92 entries без прироста,
около 146 ГиБ свободно. Стенд остановлен, PID/listeners и runtime проверены,
снимки сжаты без потерь. Push/релиза и sibling mailbox нет.


## 2026-11-10: одна durable publication короткой 256-row страницы

[Механизм, A/B/A и SIGKILL](../history-cohort256-100000-2026-11-10/README.md).
Prepared row ceiling 128→256 при прежних 1800/115200 byte budgets;
отказ делится на упорядоченные половины до 64. Admission/durable completion,
revoke/TTL/erase, CAS и page cursor barriers сохранены. 1276 passed / 0 skipped,
два assertion-red, native HVS 256/failure/lost-reply/cold checks; analyzer чистый.

Native 100000: message commits **782→391→782**, общее время
**128507→124859→129054 мс**. Независимый post-page witness сокращён
на 1,700–2,831 с; точный универсальный процент не заявляется. Все 100001
строки exact/cold, оба cursor источников завершены, дублей/потерь нет.

SIGKILL перенесён после атомарной записи выбранной страницы, до её cursor:
выбранная row 50080 оставила durable prefix 50176 и прежние два cursor.
Cold B без источников сохранил их; один источник восстановил все 100001
строки без дублей, повторный cold reopen подтвердил результат. Это один
crash window, не вся матрица. Код/пины совпадают с B сравнения; стенды закрыты.
Latency около 125 с и NETCALL открыты. Cache 92 entries без прироста,
свободно около 145,6 ГиБ. Нет push/релиза и sibling mailbox.


## 2026-11-10: bounded fresh history windows и исправление setup-метрики

[Механизм, фиксированный setup, native сравнения и SIGKILL](../history-window-index-100000-2026-11-10/README.md).
Обычная unrestricted page читает текущий fold через индекс ключей, не полный
архив на каждую страницу. Fresh policy/rows, overlays, close/erase epoch,
point-delete invalidation и fail-closed ошибки сохранены. 1342 passed,
0 skipped; два assertion-red и собственный deletion-mutant guard.

Seed больше не зависит от production cap: оба источника подтверждают 1563
успешных setup-публикации 64/last32 для 100000 строк. В прежних cap-отчётах
помечена ошибочная метка seed64 и отозвана изолированная latency-атрибуция;
exact/cold/crash результаты сохраняют силу. Новый пятифазный cap-контроль
держит setup постоянным, меняет только один production-файл. Индекс отдельно
проверен native A/B/A и SIGKILL после publication до checkpoint; все девять
прогонов проверили exact/cold состояние, cleanup и provenance.

Общая latency всё ещё открыта. По новому указанию владельца после этого
цикла приоритет — звук телефон → Windows 11, затем релиз после исправления
и проверки. В данном цикле push/релиза нет, sibling mailbox не включён.
