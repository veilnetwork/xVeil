# Подпись manifest проверяется один раз на routing fold — 2026-11-10

## Подтверждённая лишняя работа

Свежий receiver CPU profile на 100000 выделил own-device routing read.
`_readOwnDeviceAddresses` загружал и проверял manifest, затем
`_validControlFor` повторно проверял **тот же manifest для каждой control row**
в одном синхронном `foldControlLog`. Подпись самих строк — отдельная проверка.

Cost regression на 12 связанных устройствах: **14 manifest verifications → 2**
на одно чтение адресов. Parent assertion-red наблюдает именно 14 вместо 2;
это не ожидание таймера и не вывод по сетевому разбросу. Подпись каждой control
row по-прежнему проверяется ровно один раз в этом fixture.

## Изменение и границы доверия

После fresh load manifest проверяется ещё раз перед синхронным fold. Только
этот fold получает полученный verdict в `_validControlFor`; между получением
и использованием нет await. При следующем read проверка выполняется заново.
Другие call sites используют прежний обычный verifier. Legacy/Space routing
сохраняет прежнюю ветку. Не добавлены сохранённый routing view, межоперационный
кеш авторизации, обход row signatures/shape/ACL или новый способ доверять пиру.

Новый тест проверяет два последовательных чтения, отказ terminal grant,
отказ ранней строки с сокрытием её всего suffix, отказ manifest и восстановление
после снятия отказа. Вердикт предыдущего вызова не даёт адрес при следующем.
Существующие revoke-overtaking-read, смена master announcement, dispose,
мутация caller-owned NodeId и fresh storage failure входят в related suite.

**785 checks passed / 0 skipped**, 11 файлов; native XVSB/XVRC и HVS cases включены
через проверенные библиотеки. Финальный regression отдельно прошёл на
восстановленном candidate; его регистрация и success проверены JSON reporter.
Analyzer production/test файлов: 0 issues. Промежуточное ожидание теста, что
отказ первой grant скроет только одного члена, было неверно: sequence gap
закрывает suffix. Fixture исправлен; production chain rule не менялся.

## Native A/B/A на 100000

Четырёхпроцессный local Mac/JIT стенд: три устройства одной личности,
два authenticated источника истории и отдельный counterpart. Настоящие FFI,
ratchet, hidden-volume и три изолированных Core. CPU/timeline sampling выключены.
Короткий smoke по умолчанию не увеличивался: большие прогоны используют
`XVEIL_E2E_HISTORY_OVERLAP_ROWS=100000` без случайных Dart defines.

1537 frozen inputs; **один production variant**, остальные 1536 идентичны.
Фактически загруженные native libraries и их происхождение проверены.
Candidate восстановлен, все source hashes повторно сверены.

| Метрика | Parent A₁ | Candidate | Parent A₂ |
|---|---:|---:|---:|
| Apply release → финальная проверка, мс | 133940 | 128700 | 133909 |
| Release file → оба post-page inventory, мс | 129930,715 | 127463,272 | 131586,497 |
| Worker RPC | 130743 | 131090 | 130417 |
| History callbacks | 200002 | 200002 | 200002 |
| Message / cursor / allocator commits | 782 / 784 / 394 | 782 / 784 / 394 | 782 / 784 / 394 |

В этой серии candidate завершился раньше обоих контролей. Финальная проверка
опрашивается каждые 5 с: разницу около 5,2 с нельзя целиком считать выигрышем
самой обработки. Passive witness без такого опроса показывает **2,47–4,12 с**
раньше завершившийся этап получения страниц (около 1,9–3,1%). Это одна A/B/A
на Mac/JIT, не обещание устойчивого общего ускорения, Android/AOT или батареи.
RPC не уменьшились; их небольшой разброс не выдаётся за отдельное улучшение.
Долгая догрузка **остаётся открытой**.

Во всех фазах 100001 точная строка: ID/body/delivered/canonical/order;
пропусков/дублей нет, оба cursor завершены. Cold retention проверен после
остановки всех источников до включения сети получателя. На каждом источнике
391 logical page query, повторов нет; application bytes по 54075350 во всех
трёх фазах. Census/wire не обрезаны. Пустые равные выборки не принимаются.
Сохранены durable commit, prepared batch caps, ratchet и visibility/revoke
barriers. Sibling mailbox не включался. Это не проверка всей multi-device matrix.

## Очистка и приватность

Каждая фаза проверила выход своих PID, отсутствие своих listeners и удаление
runtime roots; binaries/HVS/SDK неизменны. Кеш во всех фазах **92 файла**,
новых kernel entries 0; суммарная allocated delta около −1,94 МиБ.
Кеш около 9,5 ГиБ, свободно около 146 ГиБ. Source snapshot evidence сжат без
потерь: 113,80 → 5,08 МиБ, SHA-256 проверен до удаления исходных JSON.
Сырые IDs, VM/transport endpoints, пути и журналы остаются вне Git;
публичный summary содержит агрегаты. Push/релиза нет.
