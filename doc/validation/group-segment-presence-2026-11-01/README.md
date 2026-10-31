# Group journal save: batch segment-presence metadata

## Finding and change

The physical catch-up series in
[the preceding validation](../group-segment-batch-read-2026-10-31/README.md)
recorded substantial time in load, save and the group mutation gate. A save
checked each unchanged message segment with a separate `hasFile` call. With
`HiddenVolumeStorage`, each call performed two separate worker metadata
requests, for the on-disk and in-container tiers. This work grows with the
entire history even when an incoming delta changes only its tail.

`StoredFilePresenceReader` now offers ordered presence checks for at most 32
files. The worker already supports bounded metadata reads; a save uses two
requests per wave instead of two per segment. Backends without this optional
capability retain individual checks. The metadata lookups inside the worker
are still necessary: this change reduces round trips, not native KV lookups.

Presence is uncached. It has the same completeness rules as `hasFile`, including
streamed pieces and the on-disk tier. It does not assert payload integrity.
Loads still read the segment bytes and refuse a missing segment. Missing
segments can still be repaired from a complete signed snapshot with a warm
segment index. The existing file-read session rejects results across close,
identity replacement, erase or blob-directory replacement. Cryptographic
validation, admission, retention and durable publication remain on their
existing paths; no duplicate-ingest shortcut was added.

## Verification

- A regression test failed on the released implementation: a small journal
  append performed three individual segment-presence checks. With the change,
  it performs none through the individual API, retaining the existing messages
  and displaying the appended row.
- The group, file-store and storage lifecycle suite passed **490 tests**, with
  **3 skipped** reported separately. After adding explicit fallback and
  presence-batch/erase coverage, the focused presence/read-session suite passed
  **16 tests**. These runs overlap and are not a summed unique total.
- The native worker test passed with actual signatures and an encrypted
  container, including a 35-segment history crossing the batch boundary. Each
  phase checked all expected signed message hashes in order and the visible
  count; a deliberately removed segment made load fail and was then repaired.
- Analyzer: no issues. No phone installation, public relay modification, push
  or release was performed. No stand app was started; the test worker and
  temporary container were closed in teardown.

## Native I/O control

The same production ingest path replayed the same complete snapshot five times
per phase against one worker/container. A1 and A2 made the former individual
presence calls through a test-only adapter; B used the new batch capability.
This isolates the metadata scheduling change rather than comparing different
SDK builds. All other production ingest/load/save code was the same. Both
controls produced identical RPC counts. Unchanged replay made no commits.

| Rows / segments | Phase | Individual KV requests | Batch KV requests | Payload batch requests | Five replays, ms |
|---|---|---:|---:|---:|---:|
| 128 / 9 | A1 | 110 | 20 | 55 | 355.67 |
| 128 / 9 | B | 20 | 30 | 55 | 314.68 |
| 128 / 9 | A2 | 110 | 20 | 55 | 300.99 |
| 512 / 35 | A1 | 370 | 50 | 185 | 1217.78 |
| 512 / 35 | B | 20 | 70 | 185 | 1159.81 |
| 512 / 35 | A2 | 370 | 50 | 185 | 1179.37 |

The isolated presence portion drops from **18 to 2** requests per save for nine
segments and **70 to 4** for 35. Counts in the table include the remaining
ingest/load/save work. The small timing difference does not establish an
overall speedup, especially for the first profile where B falls between its
controls. This is not a physical multi-device catch-up qualification.

Native Veil FFI matched the recorded build SHA-256
`7a11511fb69d8dbe2c1fc45758b226197de1100ffc34effc29c7746c02004912`;
its production source matches the released SDK. The existing qualified
hidden-volume library matched
`3b2eacc819b307125cafe01665ebbaec5ee6ed9d3b3d5d96bc5d5b26a50f79e7`.
Neither library was rebuilt or installed. The private measurement artifact
contains counts and durations, without identities, message content or paths.

## Remaining work

Slow offline catch-up remains open: the last physical result is still
100 messages in 106 seconds. Repeated delta admission, message/control folding,
segment encoding and header comparison still execute. Their contribution under
the real backlog needs measurement before changing these paths. The expanded
multi-device matrix also remains incomplete. Previously deferred complaints
are not reopened or declared fixed by this change.
