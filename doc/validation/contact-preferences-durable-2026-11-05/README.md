# Durable публикация настроек контакта — 2026-11-05

База `09db8f6e`. Локально, без push/релиза, изменения сидов, APK/engine pins,
native ABI или добавления mailbox собственным устройствам.

## Подтверждённый разрыв

Локальные preference setters коммитили Contact и затем вызывали callback.
GUI callback создавал device event в фоне; при отказе или завершении до post
обязанность повторить публикацию отсутствовала. Простая периодическая догрузка
журнала не видит событие, которого в журнале никогда не было.

Два assertion-red на ordinary и worker/native HVS: setter сохраняет имя,
callback бросает исключение, после close/open настройка остаётся, но нет
сохранённого намерения публикации. Это подтверждение механизма, не доказанная
причина исходной недоставки звонков Windows ↔ Android.

## Изменение

`updateContactPrefs(queueForSync: true)` сохраняет contact и неизменяемый снимок
portable полей в **одном** KV commit. Снимок строится из результата transform; status и P2P в него
не попадают. Payload-функция перенесена в domain, bridge сохраняет её export.
Mirrored apply и device-local P2P не создают нового намерения публикации.

Существующий encrypted SETTINGS namespace: manifest, монотонный local floor
и части по 1024 байта, максимум восемь. Это не новый namespace и не KV value
поверх лимита 2048 B. Manifest проверяет длину, число частей, SHA-256, peer и
версию; случайный witness отличает заново созданное намерение после удаления.
Отказ/повреждение не подменяется пустым списком и не удаляет данные автоматически.
Удаление контакта убирает весь ограниченный диапазон частей, даже если manifest
не читается. Новая локальная запись заменяет старый снимок атомарно и удаляет
лишние хвостовые части после уменьшения payload.

GUI publisher запускается на boot/link, просыпается по callback и повторяет
работу периодически. Исходный timestamp не меняется от повторов. Handoff идёт
в проверенный committed device journal через существующий queue-only sender;
это durable replication admission, не свидетельство удалённой доставки.
ACK намерения выполняется по точному токену и не удаляет более новое изменение.
Если ответ ACK потерян, точная committed запись подавляет повторный post.
Произвольная более новая, но другая запись не считается exact-дубликатом.

Own outgoing echo получает токен local floor. Он проверяется в storage write
turn: публикация старого снимка не откатывает более новую локальную настройку.
Floor остаётся после ACK и переживает restart. Consent, устройство P2P и
обычные incoming-event gates не ослабляются. Publisher close останавливает
admission, присоединяется к handoff и оставляет незавершённое намерение на boot.

Ошибка публикации имеет статический kind `contact-preferences-sync` и generic
StateError. Имя, payload, peer, paths и исходный текст исключения в error journal
не записываются; тест с canary проверяет также анонимный JSON.

## Дополнительный replay и квалификация

Первый process-прогон прошёл шесть gates, но не новый boot-recovery: новый
preference event был в committed fold A, а Contact оставался прежним.
Квалификацией этот прогон не считается. Отдельная управляемая модель дала
assertion-red: задержанный status replay применял старые preferences напрямую,
в обход их LWW slot, после нового preference apply.

Status replay теперь ждёт только preference slot и повторно предлагает row
обычному gate. Он не ждёт собственную status-цепочку и не обходит порядок.
Unknown/closing contact, которому preferences не были применены, даёт deferred
apply вместо успешного watermark; после materialization тот же row можно
повторить. Три gate controls проверяют late replay, unknown→materialized и
ожидание одного slot при заблокированном другом.

В первом прогоне также были ошибки тестовой трассировки: отсутствовал parent
каталог evidence. Fixture создаёт его до открытия trace-файла. Эти ошибки не
считаются продуктовой находкой и не исключались из журнала неудачного прогона.
Ошибка переименования метода в отдельном unit-helper исправлена; компиляционные
отказы не засчитываются как baseline assertion-red.

Дополнительные controls: atomic write-before/write-after, lost ACK before/after,
original timestamp при unlinked/exception/false result, CAS против нового edit,
close во время handoff, 131 контакт с paging≤64, exact duplicate suppression,
исключение own-device contact, canary в анонимном отчёте. Ordinary/native controls
проверяют 20 крупных revisions, shrink/cleanup частей, неизменяемость snapshot
при incoming mirror, P2P без публикации, удаление контакта, token после ACK и
reopen, stale own token за storage admission gate. Новых случаев 29, из них
семь worker/native; baseline-red два + один управляемый replay-red.

Итоговые проверки: **151 scoped passed** (8 файлов), **700 diagnostic control
passed** (33 файла), **2071 broad passed / 3 conditional skipped** (112 файлов).
Skip не квалификация. Analyzer девяти lib и всего test чистый. Headless AOT
собран, `--help` завершился с exit 0; 581 выбранный input не менялся при сборке.
Это build/startup smoke, не headless network qualification.

Финальный process A/B/C на одном Mac прошёл **все семь gates**. Дополнительный
сценарий создаёт точное post-commit/pre-callback состояние через storage API
при остановленном A; это не утверждение о SIGKILL в произвольной инструкции.
После boot оба процесса показывают новый alias/archive, исходный preference
clock в device journal, сохранённые block и локальный P2P deny на B.
Driver/Flutter/cleanup: exit 0; 30 owned PID, 35 портов, ни живых процессов,
ни слушателей; runtime удалён. Все 1474 inputs и выбранные native SHA оставались
неизменными. В worker logs нет прежних PathNotFoundException трассировки.
Rust/native engines, сиды и телефоны этим шагом не менялись.

Повтор одновременно содержит правку replay и fixture trace. Поэтому единственной
причиной первого boot-таймаута не объявляется один из этих механизмов. Обход
ordering отдельно доказан управляемым regression, а итоговая GUI boot/handoff
граница прошла сквозной прогон на текущей реализации.

## Границы

Не заявляется атомарность между контейнером и отдельным committed group journal:
это повторяемая передача обязанности с CAS, а не общая транзакция. Полная
conflict/crash матрица, разные часы и ранжирование независимой TTL-политики
в конкурирующих full preference snapshots ещё требуют отдельной квалификации.
Старые правки без намерения публикации этим шагом не реконструируются.
Headless network publication и исходный физический Windows-репорт не закрыты.
