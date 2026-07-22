# Сообщества (`Space`) поверх veil

Статус: архитектурное решение после ревизии кода 2026-07-22. Исходный
продуктовый промпт о сообществах используется как список сценариев, а не как
готовая серверная/SQL-схема.

## 1. Главный выбор

`Space` заменяет автономные каналы, но не пользовательские групповые чаты.
Существующий `manifest + CONTROL-LOG + per-author log + epoch keys + XOR
anti-entropy` переиспользуется как сетевое ядро обоих сценариев, однако wire
kind и пользовательская семантика разделены: групповой чат не является Space.

В пользовательском интерфейсе остаются:

* личные и групповые чаты — в разделе «Чаты», вне `Space`;
* сообщества — верхнеуровневая сущность;
* текстовые и голосовые каналы — только вложенные разделы сообщества;
* публикации — отдельная лента сообщества, не сообщения каналов.

Пользовательский групповой чат имеет group-wide журнал сообщений и собственный
маршрут. Отдельно от него будущая ACL-группа внутри Space означает лишь набор
участников для назначения ролей и не имеет своей ленты или навигации.

## 2. Что означает «авторитетная проверка» без сервера

У veil нет центрального сервера, которому можно доверить ACL. Поэтому каждая
реализация узла обязана одинаково проверять подпись, причинность, membership
epoch, разрешение автора и область действия:

1. перед сохранением входящей записи;
2. перед её ретрансляцией;
3. перед выдачей сообщения, поста или медиа через API/content serve;
4. перед локальной мутацией из UI, REST или фоновой задачи.

Невалидная запись не сохраняется, не ретранслируется и не отображается.
Скрытие элемента UI не является проверкой прав. При неоднозначном состоянии
узел действует fail-closed.

## 3. Сетевой состав Space

```text
signed SpaceManifest
        │
        ├── signed SpaceControlLog
        │     membership · roles · channels · policies · moderation · epochs
        │
        ├── channel logs
        │     per-author messages · reactions · media references
        │
        ├── SpacePost logs
        │     публикации общей ленты, отдельно от channel messages
        │
        └── content-addressed MediaObject
              encrypted pieces · manifests · holder discovery
```

Активные участники — распространители информации сообщества. Их
авторизованные устройства хранят и раздают подписанные объекты, которые им
разрешено иметь. Обычные сообщения и реакции идут по уже реализованному XOR
overlay: каждый участник синхронизируется с `k` ближайшими участниками, а
anti-entropy восстанавливает пропуски. Control entries и новые epoch envelopes
могут использовать более надёжный bounded fanout, поскольку потеря отзыва
доступа опаснее лишнего трафика.

Подписчик публичной ленты может кэшировать и раздавать только публичные
подписанные `SpacePost`/`MediaObject`. Подписка не превращает его в участника и
не даёт channel/control/epoch данных.

## 4. Канонические сущности v1

### `SpaceManifest`

Неизменяемый, подписанный владельцем genesis:

* `space_id` (сохраняет существующий `group_id` при миграции);
* ключ genesis и владелец;
* имя, описание, avatar/cover content ids;
* видимость: `public`, `private`, `secret`;
* discovery: включён только для `public`/`private`, никогда для `secret`;
* дата создания и версия протокола.

Изменяемые имя и описание не переписывают genesis. Они публикуются
типизированными `SpaceControlEntry`, а актуальное состояние получается fold'ом.
Видимость в текущей версии остаётся неизменяемой частью genesis: переход между
`public`/`private`/`secret` меняет правила discovery, распространения и доступа
к ключам, поэтому требует отдельного атомарного transition/rekey-протокола, а
не обычного изменения поля. Manifest подписан. Group-chat manifest остаётся
отдельным kind/форматом и не повышается до Space автоматически; преобразование
возможно только как явное действие владельца с отдельным пользовательским
подтверждением и безопасной миграцией данных.

### Участие и подписка

Участие остаётся частью signed control log. Сетевые состояния v1:

* `active`;
* `suspended`;
* `left`;
* `banned`.

`pending` — локальное состояние заявки/приглашения до появления принятой
подписанной control entry. Это не даёт доступа и не распространяется как
действующее membership.

Приглашение — отдельный небольшой durable frame между уже принятыми контактами,
а не предварительный Space snapshot. Оно содержит случайный id, `space_id`,
inviter/invitee, предлагаемую роль, срок и минимальные display metadata. В нём
нет control-log, roster, сообщений, content ids и epoch envelopes; для
`secret` не передаётся даже название. Получатель хранит proposal в
hidden-volume и явно отвечает accept/decline. Accept сам ничего не разрешает:
inviter повторно проходит текущий `SpaceAcl`, публикует обычный подписанный
`addMember`, ротирует membership epoch и только затем отправляет snapshot.
Новый Space материализуется на принимающем узле лишь когда локально есть
принятое неистёкшее приглашение, а валидный folded log содержит grant этому
узлу от того же authenticated inviter. Unsolicited snapshot от контакта
отклоняется. Durable transport ACK для proposal/decision отправляется после
завершения локального persistence, а не до него.

`SpaceSubscription` — отдельная локальная запись пользователя плюс подписанный
публичный feed cursor. Она не входит в membership log и не получает ключей.

### Каналы

Канал создаётся `SpaceControlEntry` и всегда содержит `space_id`. В v1 нужны:

* текстовый канал;
* голосовой канал;
* категория и порядок;
* archive/default;
* политика истории новых участников;
* собственный optional ACL/epoch override.

Состояние текущего звонка не входит в channel record. `VoiceSession` и её
участники — подписанные короткоживущие presence/call frames с TTL; после
завершения остаётся только журнал вызова/модерационный след, если это разрешено.

### Публикации

`SpacePost` — отдельный подписанный тип с content blocks и ссылками на общую
`MediaObject`. Он не кодируется как сообщение канала. Базовая общая лента —
стабильный `(published_at, post_id)` cursor и хронологический порядок.

Реакции переиспользуют один подписанный per-author reaction log, но цель
обязана иметь namespace `message` или `spacePost`. Legacy reaction V1/V2
считается только `message`; новые public V3 и encrypted V4 не позволяют
одинаковому `<author>:<seq>` сообщения и публикации схлопнуться в один LWW
ключ. В private/secret Space target, emoji и namespace находятся внутри
membership-epoch ciphertext, а версия V4 связана с AEAD AAD. Реакция
принимается и раздаётся только для существующего видимого root; immutable
tombstone прекращает её выдачу и запрещает новые toggle, сохраняя signed rows
как локальное audit/fork evidence.

### Правила

Правила сообщества — последовательные неизменяемые `SpaceRulesVersion` внутри
подписанного control-log, а не изменяемое поле профиля. Каждая версия хранит
полный текст, отдельную краткую сводку, автора, время публикации, время
вступления в силу и точную предыдущую версию. Только effective owner публикует
следующую версию; конкурентная stale-версия детерминированно отклоняется.

Принятие правил — отдельная подписанная участником control entry. Fold хранит
последнюю принятую версию и дату для каждого участника. После публикации новой
версии старое принятие остаётся audit evidence, но статус становится
`requiresAcceptance` до нового явного действия. Сводка никогда не заменяет
выдачу полного текста в UI/API.

### Модерация и неизменяемый аудит

Модерация сообщества — `ControlEntry` v8 в том же подписанном control-log,
а не локальный флаг интерфейса. `SpaceModerationAction` фиксирует вид действия,
цель, область, причину, время, необязательный срок и точную ссылку
`<author>:<seq>` на сообщение или публикацию. Отзыв — отдельная подписанная
`SpaceModerationRevocation`; исходная запись никогда не переписывается.

Ограничения вычисляются `SpaceAcl` в момент причинной операции: отдельно для
сообщений, публикаций и voice session. Ban удаляет участника и запускает ту же
epoch-ротацию, что и обычный отзыв membership. Подписанный unban только снимает
запрет на будущий consent/invite и не возвращает членство либо старые ключи.
Moderator delete исключает контент из выдачи и из достижимых media grants, но
оставляет signed row и действие как audit/fork evidence.

Этот wire разрешён только для `Space`: пользовательские групповые чаты
сохраняют прежний лёгкий roster-control и остаются в «Чатах». Для
restricted/secret channel moderator delete пока fail-closed, поскольку
помещение открытого channel id в общий control-log раскрыло бы скрытую область.
`SpaceModerationAppeal` определён как доменная форма, однако заблокированный
узел не может безопасно писать в member-only control-log; отдельный
rate-limited proposal transport и UI остаются последующим слоем.

## 5. Права без преждевременной сложности

В первой миграционной версии сохраняются проверенные роли `owner`, `admin`,
`member`. Проверки переводятся в единый `SpaceAcl` и используют области
`space/category/channel/posts/moderation/members/settings/encryption/storage`.

Формат допускает будущие подписанные role definitions, но произвольные
иерархии ролей и member-groups не вводятся до появления реального сценария,
которого не покрывают три роли. Это сокращает поверхность self-escalation и
конфликтов при распределённом fold.

Правила v1:

* explicit deny выше allow;
* владелец сохраняет защищённые `manage_members`, `manage_roles`,
  `manage_settings` и `transfer_ownership`;
* нельзя менять последнего владельца без атомарной передачи владения;
* нельзя назначать или изменять роль равного/более высокого ранга;
* нельзя повышать себя;
* проверка привязана к `policy_version`/causal prerequisite, поэтому две
  конкурентные мутации дают один и тот же результат у всех узлов.

## 6. Видимость и шифрование

### Channel-scoped ACL и граница настоящего secret mode

Текущий Space control log и ключ membership epoch реплицируются всем участникам
пространства. Поэтому фильтр в API или UI не является channel ACL: получатель
всё равно увидит подписанный channel payload и сможет расшифровать сообщение
общим ключом пространства. Режим `restricted` вводится только двумя связанными
примитивами:

* зашифрованный channel-control subtree, не раскрывающий название, описание и
  ACL неавторизованному участнику;
* отдельный channel epoch key с индивидуальными envelopes только для устройств,
  которым разрешён доступ, и атомарной ротацией при отзыве ACL/membership.

`ControlEntry` v5 несёт только opaque encrypted channel-control revision:
название, описание и sorted ACL находятся внутри AEAD. Отдельный channel epoch
descriptor использует `channel_id` как cryptographic scope, а ML-KEM envelopes
доставляются только авторизованным устройствам. Получатель принимает весь
набор sealed envelopes лишь при наличии валидного envelope самому себе; после
этого он может быть полноценным P2P-распространителем control/key material для
остальных держателей канала, не узнавая их закрытых ключей.

Сообщения restricted text-channel используют отдельный wire v3 и AEAD AAD,
связывающий `space_id`, `channel_id`, channel epoch и signed headers. Snapshot,
delta и отдельный `cg` anti-entropy vector фильтруются по channel recipient
proof. Отзыв ACL создаёт новый key/envelope set; предыдущий scope перестаёт
материализоваться сразу, поэтому промежуток до rekey закрыт, а не продолжает
писать старым ключом. Текущие owner/admin всегда входят в ACL V1 и могут
выполнить отзыв; member-groups для этого не создаются.

Настоящий `secret` остаётся fail-closed. Opaque revision в общем Space control
chain пока раскрывает факт обновления, автора, время, ciphertext length и число
получателей. Поэтому UI/API не позволяют создать `secret` и не называют
`restricted` скрытым. Для secret нужен отдельный indistinguishable encrypted
subtree/transport, не участвующий в общем per-author control chain.

Restricted V1 поддерживает только text. Media, reactions и voice используют
space-wide serve/call primitives и потому блокируются до появления их
channel-scoped wire/grant; входящие попытки также отклоняются на узле.

Скрытость и конфиденциальность различаются, но серверный режим из исходного
промпта к veil неприменим.

Поддерживаемые режимы контента:

* `publicSigned` — содержимое открыто, но подпись и ACL публикации обязательны;
* `privateE2ee` — отдельный channel/space epoch key, envelopes на каждое
  авторизованное устройство;
* локальное at-rest шифрование hidden-volume действует всегда и не считается
  сетевым E2EE.

`secret` Space не публикует manifest/discovery record в DHT. Его genesis
передаётся capability-like приглашением по уже защищённому контакту. Узел без
membership не получает названия, каналов, списка участников или content ids.

Исключение, бан и отзыв channel ACL закрывают будущий доступ сменой эпохи.
Уже полученный plaintext невозможно гарантированно стереть с чужого устройства;
UI и документация не должны обещать обратное.

Пороговый `k-of-n` не смешивается с epoch rotation и не входит в Space v1.

## 7. Хранение и удаление

В распределённой сети нельзя гарантировать глобальное физическое удаление.
Разделяются:

* локальный cache/history budget устройства;
* signed retention hint сообщества для добросовестных реплик;
* tombstone/crypto-revocation, прекращающие нормальную выдачу и будущую
  расшифровку;
* локальный archive/pin.

Фоновая очистка удаляет локальные unreferenced encrypted blobs идемпотентно.
Публичная или уже расшифрованная копия может сохраниться у недобросовестного
узла — это явная граница модели, а не скрытый дефект.

`deleted` сначала является подписанным tombstone и локальным recovery window.
После window устройство удаляет свои данные. Глобальное доказуемое стирание не
заявляется.

## 8. Что из исходного промпта не входит в ядро v1

| Требование | Решение для veil |
|---|---|
| SQL-таблицы и серверная БД | Заменяются подписанными логами и hidden-volume bundle/index |
| Серверная авторизация | Детерминированная проверка каждым ingest/serve/API узлом |
| Серверное шифрование | Удалено; есть hidden-volume at rest и publicSigned/privateE2ee on wire |
| Универсальная система ролей и групп | Формат расширяемый, v1 использует owner/admin/member |
| Гарантированное глобальное удаление | Невозможно; tombstone, прекращение serve, key rotation и локальный GC |
| Recommendation campaigns | Не часть протокольного ядра; вернуться после Space/feed v1 |
| Алгоритмическая лента | Не вводится; только хронологический cursor |
| `k-of-n` | Отдельный будущий протокол, не обычная политика Space |
| Appeals UI | Доменный audit reference можно зарезервировать, UI после moderation core |

## 9. Миграция автономных каналов без поглощения групповых чатов

1. `SpaceManifest` и `GroupManifest` могут временно использовать общий Dart
   container/type-alias ради совместимости, но `kind/isSpace` проверяется на
   каждой доменной границе, в API и UI.
2. `GroupService` пока обслуживает общий transport/store, но выдаёт раздельные
   `listGroups` и `listSpaces`; это не означает равенство сущностей.
3. Новые сообщества сразу получают owner-signed `SpaceManifest`.
4. Групповой чат остаётся группой. Возможное преобразование в сообщество —
   отдельная будущая операция владельца, никогда не boot-миграция.
5. Автономный legacy channel получает Space только после проверки владельца и
   назначения. Нельзя создавать фиктивного владельца.
6. `/groups` и `/group/:id` сохраняются для групповых чатов; `/spaces` и
   `/space/:id` обслуживают только сообщества.

Повторный запуск миграции обязан быть no-op. Сообщения, media content ids,
epoch envelopes и per-author sequence не меняются.

## 10. Порядок реализации

1. Signed `SpaceManifest`, явная граница kind и раздельные Group/Space списки.
2. Единый `SpaceAcl`, используемый control fold, post/message mutation,
   content serve и API.
3. Nested channel manifest/control entries и миграция автономных каналов.
4. `SpacePost` + member feed/subscription/cursor; затем отдельный публичный
   distribution/discovery слой для подписчиков без membership.
5. Навигация «Сообщества»/«Лента» после появления реальных данных.
6. Moderation/audit, retention worker и расширенные роли по фактическим
   сценариям.

Каждый этап заканчивается unit + migration + two-node/device verification.
Матрица обязательной проверки: macOS, физический Android и iOS Simulator;
camera/background/push проверяются дополнительно на физическом iOS.

## 11. Состояние реализации

Первые пользовательские вертикальные слои реализованы 2026-07-22:

* wire/storage manifest v3 (`xveil.space`) подписывается genesis-владельцем;
* `GroupManifest` является временным alias общего wire-контейнера, но group
  chat и Space различаются по kind и никогда не смешиваются в выдаче;
* `createGroup` создаёт group-wide чат, `createSpace` — сообщество;
* создание в UI и `/v1/spaces` принимает название, описание и genesis-
  видимость; публичное Space пока не становится discoverable автоматически,
  потому что безопасный public holder/discovery-протокол ещё не реализован.
  Дальнейшее описание меняется owner/admin через подписанный
  `setDescription` в том же control-log и читается единым fold'ом в
  GUI/headless/API; отдельного profile-store нет;
* boot anti-entropy не преобразует групповые чаты; явный owner-only conversion
  protocol отложен до отдельного пользовательского сценария;
* ingest подписанного Space запрещает immutable-root fork и downgrade;
* `SpaceAcl` централизует базовые права v1, control fold проверяет точное
  совпадение `policy_version`;
* каналы — типизированные подписанные дети `Space` в том же control-log;
  автономного channel manifest/store не существует;
* новый Space атомарно получает стабильный default text channel; сообщения
  подписывают `channelId`, а ingest неизвестного канала закрыт по умолчанию;
* `fromJoin`/`since` проверяются при локальной выдаче, а одинаковый неразрешимый
  timestamp закрывается в пользу запрета. `full` не обещает новому участнику
  старую E2EE-историю: доставка прежних epoch keys ещё не реализована, поэтому
  фактический доступ может быть только строже политики;
* UI заменил верхнеуровневые «Каналы» на «Сообщества», сохранив групповые чаты
  рядом с личными в «Чатах»;
  текстовые каналы открывают channel-scoped сообщения, а голосовые запускают
  отдельную ephemeral voice-session v2, где signed `channelId` проверяется как
  существующий активный voice channel. Состояние сессии не записывается в
  `SpaceChannel`; legacy group-wide call v1 остаётся только совместимостью;
* `/v1/spaces` и `/v1/groups` являются разными API-проекциями общего
  transport/store и возвращают только свой kind;
* новые `ControlEntry` используют wire v2: непрерывный per-author `seq` и
  `prevHash` точного предыдущего подписанного row. Legacy v1 читается без
  переподписи, но после первого v2 downgrade обратно в v1 запрещён;
* операции `mute/remove/ban/leave` в Space используют `ControlEntry` wire v3 и
  подписывают `SpacePostBoundary` — точный `(seq, hash)` терминал публикаций
  отзываемого поколения. Это отдельная версия: canonical bytes уже
  развёрнутого v2 не менялись;
* distinct valid same-seq control rows считаются equivocation: обе ветки и их
  suffix fail-closed, а не выбираются по arrival order или hash lottery.
  Anti-entropy control vector передаёт `(seq, headHash)`, поэтому разошедшиеся
  реплики обмениваются fork evidence даже при одинаковом high-water; локальный
  writer не строит новые ACL-операции поверх обнаруженного fork;
* `SpacePost` является отдельным подписанным per-author журналом, а не
  сообщением канала. Legacy public v3 и encrypted v4 rows продолжают нести
  отсортированный causal frontier без переподписи. Новые public v5/encrypted
  v6 rows вместо линейного списка подписывают один hash переиспользуемой
  `ControlEntry` v4 `checkpoint`; encrypted hash входит в AEAD AAD;
* редактирование и удаление публикаций не переписывают прежний row. Public V7
  и membership-encrypted V8 добавляют подписанные `publish/edit/delete` и
  author-local `targetSeq`; операция и target входят в canonical bytes и V8
  AEAD AAD. Fold показывает один `SpacePostView`: id, дата и cursor берутся из
  исходного root, контент — из последней валидной revision. Tombstone
  необратим, убирает root из Space/общей ленты и из `referencedContentIds`, но
  signed rows остаются fork/audit evidence. Edit-of-edit, missing root,
  повторный delete и resurrection закрывают suffix; локальный writer также не
  продолжает такую семантически неверную цепь. Обычный sparse XOR delta и
  gap-fill распространяют revisions/tombstones между участниками без нового
  transport/store;
* checkpoint — подписанный no-op существующего control-log, поэтому он
  автоматически наследует per-author hash-chain, fork quarantine, compaction
  evidence и `(seq, headHash)` anti-entropy. Его payload фиксирует до 4096
  sorted unique control-heads и Merkle-root этого набора. Любой действующий
  участник может зафиксировать наблюдаемый cut, но checkpoint ничего не
  разрешает сам: узел заново fold-ит точные leaves, проверяет членство автора
  checkpoint, его predecessor, historical `SpaceAcl` и `policyVersion` автора
  публикации. Неизвестный, tampered или forked checkpoint закрывается;
* при первой публикации checkpoint и post сохраняются атомарно и отправляются
  одним delta. Неизменившееся поколение ACL переиспользует тот же checkpoint,
  поэтому каждый последующий post имеет O(1) causal metadata. Потерянный
  checkpoint восстанавливается обычным control gap-fill до приёма зависимых
  постов. Publisher сначала проверяет checkpoint своей предыдущей публикации,
  затем не более восьми свежих кандидатов и при необходимости создаёт новый:
  hostile/stale checkpoint backlog не превращает интерактивный publish в
  квадратичный полный перебор;
* публикации идут тем же sparse XOR delta + sync-vector/gap-fill путём, что и
  прочие объекты Space. Подмена, разрыв цепочки и same-seq equivocation
  проверяются до показа. Две distinct valid same-seq ветки карантинят обе и
  suffix автора; fork evidence сохраняется при compaction и расходится через
  `(seq, headHash)` sync-vector, а не исчезает по hash lottery;
* реакции сообщений и публикаций используют тот же подписанный журнал,
  compaction и sparse XOR anti-entropy. Typed public V3/encrypted V4 разделяют
  namespace целей; V4 держит target/emoji в ciphertext и domain-separates AAD
  от legacy V2. Ingest авторизует автора и видимый root после применения posts
  из того же delta; удалённая публикация больше не выдаёт и не принимает
  реакции. Space/общая лента и GUI/headless REST используют один fold;
* отзыв публикации не переписывает историю: causal rows до подписанного
  boundary остаются видимыми другим действующим участникам, stale-frontier row
  после boundary хранится только как evidence и не попадает в feed. Legacy
  revoke без boundary скрывает такую историю fail-closed; новый `unmute/add`
  начинает отдельное поколение полномочий;
* ссылки публикаций используют общую content-addressed `MediaObjectRef`, а
  content serve разрешает только реально достижимые из валидного Space данные;
* `SpaceSubscription` хранится локально и не меняет membership. Участник может
  отключить Space в общей ленте, уведомления и рекомендации; это не отзывает
  участие и не выдаёт дополнительные ключи;
* общая «Лента» объединяет доступные публикации без алгоритмического
  ранжирования, дедуплицирует их и использует стабильный подписанный cursor
  `(publishedAt, spaceId, author, seq)`. Состояние прочтения и счётчик новых
  публикаций отделены от channel-message unread;
* UI заменил нижний раздел «Хранилище» на «Ленту», а «Хранилище» перенесено в
  основное меню. Публикации Space доступны из самого сообщества; REST/OpenAPI
  получили `/v1/spaces/posts`, `/v1/spaces/subscription` и `/v1/feed`;
* правила сообщества используют `ControlEntry` v7: immutable последовательные
  версии и отдельные signed acknowledgements участников сходятся через тот же
  P2P delta/gap-fill. Экран внутри Space показывает полный текущий документ,
  историю и re-accept banner; GUI/headless REST routes `/v1/spaces/rules` и
  `/v1/spaces/rules/accept` читают и мутируют тот же авторитетный fold;
* модерация сообщества использует `ControlEntry` v8: предупреждения,
  scoped publish/message/voice restrictions, mute/timeout, temporary/permanent
  ban, moderator delete и отдельные signed revocations образуют неизменяемый
  audit. Серверный `SpaceAcl`, message/post выдача, media reachability и voice
  FSM используют один time-aware fold. Экран и REST/OpenAPI
  `/v1/spaces/moderation` показывают тот же журнал; обычный `Group` отвергает
  этот wire и остаётся групповым чатом;
* экран «Участники и настройки» читает roster из effective `GroupState` и пишет
  rename/invite/remove/mute/role/leave через `GroupService`; invite сначала
  проходит отдельный consent flow, а membership mutation после accept — через
  существующий подписанный `ControlEntry`. UI-проверка `canApply` не заменяет
  авторитетный fold. Space-native REST/OpenAPI routes members/name/leave
  подключены к тем же callbacks, что и временные legacy aliases. Настройка
  репликации использует существующий XOR neighbor count и описана пользователю
  как число авторизованных участников-распространителей. Последний владелец не
  может выйти;
* передача владения — один `ControlEntry` v6: прежний effective owner атомарно
  становится admin, target-member становится единственным owner и unmute.
  `SpaceManifest.owner` остаётся genesis signature root и не переписывается;
  авторизация и repair workers используют роль из folded `GroupState`. Два
  независимых `setRole` намеренно не применяются, поэтому между репликами не
  возникает промежуточного состояния с нулём/двумя владельцами. Операция
  запускает ротацию restricted channel-control, чтобы новый owner получил
  управляющий key envelope;
* проверка нового слоя: `flutter analyze` чист, полный `flutter test` — 1319
  passed, 40 conditional skipped. Свежий arm64 Android APK установлен и
  разблокирован; свежий macOS bundle leaf-by-leaf development-signed,
  strict-verified, запущен единственным экземпляром и разблокирован через debug
  API. Native `/group_selftest` подтвердил sign/verify/tamper/fold/JSON; causal
  frontier/checkpoint/boundary/fork migration проверены Dart integration suite,
  включая 257 state-changing control authors, Merkle/AEAD tamper и потерянный
  checkpoint gap-fill. Restricted channel-control v5, ciphertext-only message
  v3, recipient-tailored sync, holder redistribution и revoke/rekey также
  покрыты integration suite. iOS Simulator на текущем стенде остаётся
  build-only: production-цепочка `mobile_scanner 5.2.3` → Google ML Kit
  формирует `x86_64` Runner, а единственный iOS 26.5 runtime требует `arm64` и
  отклоняет установку. Временный scanner stub в production graph не вводится.

Это не означает готовность эпика. Публичная подписка без membership пока не
включена: для неё нужен отдельный discovery/holder протокол, который раздаёт
только publicSigned posts/media и никогда control/channel/epoch данные. Текущая
`SpaceSubscription` управляет лентой активного участника. Линейный frontier в
legacy V3/V4 остаётся ограничен 256 авторами, но новые V5/V6 posts используют
переиспользуемый Merkle checkpoint и проверены на 257 state-changing авторах.
Сам checkpoint сейчас содержит полный causal cut с защитным пределом 4096
heads; следующий шаг масштабирования — proof-based частичная доставка leaves,
а не увеличение каждой публикации. Channel-scoped ACL/epochs для restricted
text и базовая signed moderation уже реализованы; следующими слоями остаются
настоящий indistinguishable secret scope, protected-scope
moderation/media/reactions/voice, appeal transport и retention.

Архивирование Space также не должно появляться как локальный UI-флаг. Текущий
`GroupMessage` не подписывает causal cut состояния Space, поэтому без нового
message checkpoint/boundary узел не отличит задержавшееся сообщение,
разрешённое до архивации, от новой записи после неё. Безопасный lifecycle wire
должен атомарно зафиксировать границу: исторический causal prefix остаётся
читаемым, а post-boundary mutations закрываются на ingest и publish.
