# A durable retry must not borrow an obsolete contact decision

Base: `54187b1b`. This continues the
[initial acceptance-queue fix](../contact-acceptance-egress-2026-11-17/README.md)
in the independent general Outbox pass. It does not attribute the original
Windows 10 user's one-way messages or missing calls.

## Evidence

The pass read a contact while selecting durable frames, then admitted mailbox
work and collected live candidates. Recipient workers could start much later,
after another candidate's transport wait. ACKs invalidated the captured frame
snapshot, but contact-decision changes did not invalidate either the selection
or the later live candidate. A completed block could therefore be followed by
an acceptance send admitted from an earlier accepted snapshot.

Twenty gate-controlled cases use the actual Outbox pass, MessagingService
block/unblock and authenticated ACK handling. Each runs on ordinary asynchronous
storage and the actual hidden-volume worker. One gate holds the contact read;
the other holds an already-started first send while the target waits in that
recipient's lane. A recording MailboxSink observes deposits separately from
live sends. The fixture restores a durable acceptance row, without invoking the
separate initial-response worker.

The unchanged base gives **eight assertion-red cases and twelve passing
controls**. The failures cover block and block→unblock at both gates on both
backends. Controls cover ACK, unrelated-peer block and no change. Assertions
check both actual live sends and deposit calls. A deposit admitted before a
worker-stage change remains a valid earlier submission and is not recalled.
Durable contact/row state is also checked after cold reopen.

## Change

Candidate selection captures the contact's local consent epoch before reading
its record. The epoch is rechecked after asynchronous classification and before
deposit/retirement decisions that depend on that record. Each selected live
candidate retains that same epoch and checks it on worker entry and after
expiry work, before spending a
silent probe or retry backoff. The existing frame-snapshot ACK guard remains
independent and unchanged.

An obsolete decision defers work; it does not delete the durable row or adopt
a newer relationship's authority implicitly. A block→unblock test immediately
runs another pass and verifies that the current row sends once, without a
delay charged to its cancelled predecessor. Changes to another peer do not
invalidate it. Existing device, group-carrier and external-proposal policy
branches remain intact; this adds freshness to their contact snapshot rather
than replacing those authorizers.

Two deliberate mutants prove the independent boundaries. Removing selection
epoch checks causes four deposit failures despite intact worker checks;
removing worker epoch checks causes four late-live-send failures despite intact
selection checks. Source is restored byte-for-byte after each mutation.

## Qualification and operational limits

The focused queue/consent run passes **42 tests**. Final qualification passes
**744 related tests with no skips** across thirty-eight Outbox, contact,
handshake, mailbox, decision/preference, expiry/provenance and UI suites. With
XVEIL_DIAGNOSTICS=true, **80 tests pass with no skips** across six overlapping
suites; counts are not added as unique tests. The analyzer reports no issues
after a test-style finding was corrected. Whitespace checks pass.

Selected core/storage libraries match producer hashes and 1,144 recorded
Rust/Cargo inputs; all 50 storage ABI checks pass. No native build is made.

No wire field or persistent epoch is added. The local marker already belongs
to contact decision tracking; the candidate merely retains it for this pass.
Already admitted transport operations are not cancelled. The fixture starts
at the service's authenticated signal boundary and records sink admissions;
it is not a physical relay/Windows/Android delivery test.

All tests use TMPDIR=/private/tmp/ and synthetic containers. No app window,
focus change, OS input, physical capture, phone install, user-container change
or seed operation is performed. No push or release.

## Проверка перед передачей в mailbox

Контакт мог измениться после выбора кадра и до вызова `MailboxSink.stash`.
Если проверка принадлежности устройства завершалась после блокировки,
клиент всё равно начинал отправку старого запроса или подтверждения в реле.
Проверка одного статуса после ожидания пропустила бы последовательность
«блокировка → разблокировка».

Первый запрос, ручной повтор, первое подтверждение и повтор из Outbox
передают в mailbox проверку исходной ревизии контакта. После поиска устройства,
перед стартом отправки, mailbox снова проверяет ревизию. Уже начатая
передача не отзывается. Допустимая отправка может начаться после завершения
прямой попытки или прохода Outbox.

Тесты удерживали поиск устройства до записи решения. На прежнем коде
16 сценариев отправляли кадр после блокировки или блокировки с последующей
разблокировкой. Восемь контролей без смены решения успешно отправляли кадр.
Все 24 сценария проходят на исправлении с обычным хранилищем и нативным
worker hidden-volume. Проверка наблюдает вызов приёмника mailbox. Причина
односторонней доставки на Windows 10 остаётся открытой.

Прошли 155 целевых тестов, затем 1 360 связанных тестов в 86 наборах с
включённой диагностикой. Анализатор не нашёл ошибок.
