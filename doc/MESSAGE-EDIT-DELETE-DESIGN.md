# Message edit & delete — design

Goal (user): "предусмотреть удаление сообщений (в том числе и полученных),
изменение сообщений (отправленных)." Delete **any** message including received
ones; edit **own sent** messages. Because xVeil is built for users in hostile
states, a "delete" that only hides the text while the plaintext survives in the
container is unacceptable — under coercion the space is unlocked and the
"deleted" message would be recoverable. Delete MUST be a real, forensic erase.

## What hidden-volume actually gives us (verified in the core)

`Tx::append_log(namespace, log_id, payload)` is **last-write-wins by `log_id`**:
re-appending the same `log_id` replaces the prior value on read. The core's own
doc comment calls this out as "load-bearing for the messenger use-case
(re-deliver / **edit a message**)". There is *no* per-record log delete in the
Tx API (only KV `delete` and whole-namespace `erase_namespace`), so:

- **Edit** = re-write the same `log_id` with the new body.
- **Delete** = re-write the same `log_id` with a tombstone payload.

Crucially, the replaced/tombstoned value's chunk is **not auto-scrubbed**:

> The previous DataBatch chunk that held the old value is not physically
> scrubbed by `append_log` — it becomes orphaned ... reclaimed by the next
> `vacuum_data_batches` / `compact_known`. Until then a key-holder forensic with
> the password can recover the prior value from the orphan chunk.

So real erasure = tombstone/replace **then** run `vacuum_data_batches`. The Dart
plugin already exposes `HvSpace.vacuumDataBatches()` — no native change needed.

## Implementation (this slice — done)

Messages live in the `MESSAGE_LOG` append-log, each under a monotonic `log_id`,
with the domain UUID inside the payload. To rewrite "the same record" we need a
stable UUID → `log_id` map:

- `appendMessage` now also writes `SETTINGS["msgidx:<uuid>"] = <log_id>`.
- `editMessage(id, body)` — look up the `log_id`, re-append it with the full
  message payload, new body, `e:1` (edited). `_scanLog` surfaces `Message.edited`.
- `deleteMessage(id)` — re-append the `log_id` with `{op:'del', id}` and drop the
  index entry. `_scanLog` removes a tombstoned id entirely (no "deleted" stub —
  the existence of the message is itself not advertised).
- `scrubDeleted()` → `KvLogStore.scrub()` → `HvSpace.vacuumDataBatches()`
  (no-op on the in-memory fake, which never persists). Called immediately after
  every edit/delete so the plaintext is gone *now*, not at some later GC.

The in-memory fake was made faithful to the core: `AppendLogOp` is now
last-write-wins by `log_id` (it previously always appended, silently diverging).

MessagingService exposes `deleteMessageLocally(id)` (any message, incl. received)
and `editOwnMessage(id, body)` (our sent text), each scrubbing + signalling the
UI. Both are **local-only** for now.

Tests: `hidden_volume_storage_test.dart` (edit-in-place, delete incl. received,
unknown-id no-op, gone-after-scrub) and `messaging_outbox_test.dart` (service
edit + received-message purge).

## Follow-ups (not yet done)

1. **Peer propagation.** Editing/deleting a *sent* message should reach the
   recipient. Add `WireKind.edit` (id + new body) and `WireKind.del` (id); the
   receiver applies `editMessage` / `deleteMessage` + scrub on their side. Note
   this is best-effort and the recipient can always have copied the text — UI
   should not promise the peer's copy is gone.
2. **UI.** Long-press / context menu on a bubble: Edit (own text bubbles only),
   Delete (any). Edit opens the composer pre-filled; an "edited" marker renders
   from `Message.edited`. New l10n keys (RU/EN).
3. **Scrub cost.** `vacuumDataBatches` rewrites data batches; scrubbing after
   every single delete may be heavy on large containers. If it bites, batch the
   scrub (debounce) while keeping the logical tombstone immediate — but never
   leave the orphan un-scrubbed across an app lifetime.
4. **File messages.** Deleting a file message should also delete the stored
   blob (FileStore) + scrub, not just the log row.
