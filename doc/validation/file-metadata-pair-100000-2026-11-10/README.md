# Одно свежее чтение метаданных двух файловых хранилищ

## Подтверждённая лишняя работа

Свежие счётчики получателя на 100000 сообщений показали около 24000 чтений
header и столько же сегментов собственного device-журнала. До payload каждый
вызов отдельно запрашивал метаданные внешнего хранилища (`ondisk:`) и
внутреннего (`file:`) в одном settings namespace. Это удваивало metadata RPC.
Await времена перекрываются; их сумма не выдана за долю wall time.

Два parent assertion-red проверили количество обращений при правильных байтах:
обычная inline-пачка использует два metadata batch вместо одного; single header
использует отдельные get вместо одного batch. Снимок исходного regression
fixture сохранён в приватных evidence до добавления новых helper-тестов.

## Изменение

HVS запрашивает обе группы ключей через существующий `AsyncKvBatchReader`.
Один файл даёт два ключа, максимум восемь файлов — 16 ключей при прежнем
worker ceiling 64. Объявленная длина ответа строго проверяется. Captured
store/blob-directory/epoch проверяются после каждого await и после payload;
старый запрос не может продолжить чтение в новом контейнере.

AsyncFileStore получил in-call metadata handoff. Вектор и mutable bytes
пачки копируются до первого payload await. Декодирование, recorded-size
ceiling, first-failure order, streamed/legacy fallback и ограничение 64 payload
records на запрос остаются прежними. Caller всё ещё обязан читать метаданные
в нужной сессии и разрешить выбор хранилища: handoff не устанавливает авторизацию.
Хранилища без KV batch capability сохраняют прежний путь.

Свежие значения не запоминаются между вызовами. Payload перечитывается каждый
раз. Ни routing/auth cache, ни пропуск membership/revoke/host-floor проверок,
ни увеличение wire/page/byte budgets не добавлены.

## Проверки опасных границ

У действующего внешнего blob сохраняется приоритет, даже если неиспользуемые
inline metadata не читаются. Только при ошибке общего lookup повторно читаются
tier metadata. Без действующего внешнего варианта исходная ошибка возвращается;
при некорректной длине batch — немедленный отказ. Это не fallback на inline
payload при произвольной ошибке. Проверки жизненного цикла действуют и в этом
error path. Пустой/недоступный первый файл по-прежнему останавливает пачку до
чтения последующих payload, в том числе при повреждении ненужного хранилища.

Проверены максимум/duplicates/замена файла свежими данными, отсутствующий size,
underreported size, oversized record expansion, metadata refusal/truncation,
mutated list/bytes во время предыдущего payload и zero/negative budgets.
Native gate теперь удерживает именно завершённый metadata RPC и для batch,
и для ordinary get: после close/open запрос не обращается к новой личности.

**748 related checks passed / 1 skipped** в 50 файлах; пропущен явно включаемый
roster lifecycle probe, он не засчитан пройденным. Четыре предварительных
native checks проверили реальный worker, current manifests/payloads и lifecycle.
Analyzer двух production и двух изменённых тестовых файлов чист.

## Native A/B/A на 100000

Тот же четырёхпроцессный Mac/JIT стенд: три собственных устройства, два
источника, counterpart, настоящие FFI/ratchet/HVS и три изолированных Core.
Первые полные authenticated ответы источников получены до apply release.
Сравниваются только два production файла (HVS и AsyncFileStore); 1537 frozen
inputs, 1535 остальных неизменны. Native SHA и фактический mapping проверены.
CPU sampler/timeline выключены; compact progress poll 5 с одинаков во всех фазах.

| Метрика | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Apply release → финальная проверка, мс | 133789 | 133758 | 133675 |
| Release file → оба post-page inventory, мс | 130635,787 | 128165,257 | 130514,942 |
| Worker RPC calls | 178428 | 130880 | 178845 |
| Message / cursor / allocator commits | 782 / 784 / 394 | 782 / 784 / 394 | 782 / 784 / 394 |
| History apply callbacks | 200002 | 200002 | 200002 |

Worker requests стало примерно на 27% меньше. По passive witness этап
получения страниц завершился на 2,35–2,47 с раньше двух контролей (около 1,8%).
Однако общий критерий сходимости **не ускорился доказанно**: все три времени
около 134 с. Это не обещание такого выигрыша на Android/AOT и не измерение
экономии батареи. Количество header/segment loads слегка меняется из-за
in-flight sharing; уменьшение числа запросов не означает уменьшения числа
прочитанных KV keys или сокращения физической записи.

Во всех фазах ровно 100001 ожидаемых ID/body/status/canonical/order, оба cursor
и cold retention точны. На каждом источнике 391 logical page query, повторов
нет, application frame bytes по 54075350. Wire/census не обрезаны. Ошибка
проверки или пустые одинаковые выборки не принимаются за сходимость.

Candidate восстановлен и сверены source bytes. Cleanup проверил 36/37/36 PID
и 60/58/57 портов, своих живых процессов/listeners не осталось, runtime
каталоги удалены. Кеш остался 92 файла; новых kernel entries нет, суммарная
allocated delta около +55,95 МиБ. Сырые synthetic evidence — около 221 МиБ
вне Git, свободно около 147 ГиБ. Публичная summary содержит агрегаты.

Полная latency около 134 с, anti-entropy cadence, NETCALL и остальная
multi-device matrix остаются открытыми. Совместимость со старыми версиями,
Android/OEM, мобильный провайдер и production relay paths здесь не проверялись.
Push и релиза нет.
