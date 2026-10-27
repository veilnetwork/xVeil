# Device-sync reply addresses and delta ingest — 2026-10-27

The adopted-device delta path loaded the complete journal to restore an
omitted manifest, then loaded it again for the serialized merge. It now
restores the manifest and merges against one fully loaded view inside the
group mutation gate. Hash, membership, signature and missing-segment checks
remain. Ordinary groups and adoption seeds keep their existing routes.

Two reply-address defects were also reproduced:

* A cold sync ask was built before the lazy local device address was resolved.
  Resolving that address later, while choosing recipients, did not repair the
  already-built request. Resolution now precedes building the request.
* A master's announced transport address can sit outside device-group
  membership. Its request fell back to the shared authority address. The
  responder now accepts that device only through its own resolved address
  list, after sender admission. An authority-addressed ask without a valid
  device target receives no fragmented answer.

The outbox also retires legacy group snapshots/chunks queued to the sender's
own shared alias when it is confirmed to be the sovereign authority. Wire
kind is checked; unrelated control frames and non-authority identities remain
queued. The authority lookup is shared across one flush, and a failed lookup
does not justify deletion. Correctly addressed state is recovered from the
source journal through ordinary sync. Mailbox and relay scheduling are unchanged.

## Automated checks

Compiled regression tests observed two complete journal reads instead of one,
a missing device reply field after cold startup, a reply sent to the authority
instead of the announced master device, and obsolete authority snapshots left
in the outbox. Each failed before its corresponding correction.

The final relevant suites passed **439 tests**, with three existing skips;
static analysis passed without issues. Coverage includes hash mismatch,
non-members, a revoked fixture device, bad message signatures, missing segments,
write failure and identical retry, an incoming delta queued behind a local
append, stranger redirect rejection, and preservation of unrelated outbox rows.

## Physical stand

A Android on Wi-Fi and B macOS share identity X; C macOS is identity Y.
All roles retained their encrypted profiles. The normal QA builds used the
same frozen Veil `1d36980d` and media artifacts. No timing overlay, native
test hook, reduced identity difficulty, Rust build or server change was used.
The application `lib` trees were verified equal to both QA source copies.

On base `fbb905e6`, after a fixed 30-second post-start warm-up, one C-to-X
message appeared on B after 427 ms, but not on A within the 90-second
observation window. Later baseline rounds were not sent. B's stored outbox
contained 26 group fragments addressed to its own shared authority alias.

With the candidate, the same warm-up preceded six spaced C-to-X messages.
A/B/C stayed online. Each round ended with identical message-ID sets and no
duplicates:

| Round | First observed on A, ms | First observed on B, ms | Sender retries |
|---|---:|---:|---:|
| 1 | 54,448 | 865 | 0 |
| 2 | 25,223 | 18,535 | 3 |
| 3 | 13,028 | 23,070 | 3 |
| 4 | 1,379 | 10,377 | 0 |
| 5 | 1,276 | 7,832 | 0 |
| 6 | 756 | 10,133 | 0 |

These are polling observations after submission, not isolated network latency.
The prior baseline message also appeared on all three devices with its
original ID. B's authority-addressed queue fell to zero, with 26 retirement
log entries and no logged re-drive to that alias in the candidate run. The
backlog advanced between phases, so no controlled latency improvement ratio is
claimed. In particular, the remaining startup and retry delays are not resolved.

At the end, the entire visible conversation contained **462 messages** on each
device: identical ID sets, identical visible order, and matching text, edit
flags, filenames and file sizes. The API returned the complete conversation.
Some attachment locators differ between local downloaded inline files and
published mirror references, as allowed by the mirror codec. File-byte
equivalence was not tested here; neither were reactions or hidden/deleted state.

## Cleanup and remaining scope

Every started app was closed after its stand run. The final process-group,
Android-process, permission and ADB-forward audit is in the anonymous
[evidence](summary.json). Main app data and system power settings were unchanged.
Nothing was pushed, released or deployed.

Further work remains on slow initial delivery and propagation between siblings:
the sender made three retry attempts in rounds 2 and 3, while later sibling
propagation still took roughly 8–10 seconds. The exact split needs measurement.
Windows, calls, long offline/revocation cases and the full multi-device matrix
are not qualified by this stand. The earlier post-commit/mid-ACK receiver-crash
limit for partial outbox retirement is not addressed by this migration.
