# Outgoing retries must respect the local recovery journal — 2026-10-29

Four deterministic checks fail on the preceding source (`fdd9f753`):

- A background outbox flush sends a chat row while its required own-device
  journal publication is deliberately held.
- The same flush overtakes an append that has exposed its row but has not yet
  returned to the publication step.
- After a journal write failure, retry sends the stored row without repairing
  the missing publication.
- A peer's gap-fill request sends a post while its publication is held.

The initial send already awaited that publication. Background readers bypassed
it by finding the conversation row in storage first. A crash at this boundary
could leave the peer holding the message while the sender's own-device recovery
journal lacked it. This is separate from the accepted limitation where all
sources are offline and no copy was stored for the missing sibling.

## Change

The ordinary storage path now tracks unfinished row writes from before append
through completion of the required publication. Tracking contains peer/message
keys and active counts only, with entries removed in `finally`; it does not
retain bodies or spawn detached work. A background retry defers such a row,
letting other conversations proceed. It does not transmit or charge retry
backoff for that deferred row.

After failure or restart, an undelivered locally authored outgoing row must
complete its journal publication before outbox retry or gap-fill can send it.
The existing successful-publication cache still prevents unnecessary repeats.
Concurrent recovery passes share the active-write exclusion. Journal errors
propagate and do not authorize a send. Rows projected from another device are
not re-published into the journal. Completed historical rows do not churn the
journal merely because the peer asks for old history.

Gap-fill filters deferred posts before charging its network reship rounds.
Repeated asks during a slow local write therefore do not exhaust the two-round
network budget and impose the ten-minute reship pause after that write commits.
The existing network retry limits remain in place for actual eligible work.

This does not change wire formats, mailbox policy, relay behavior or native
libraries. It does not promise reconstruction of every previously delivered
legacy row that may already lack a journal entry. Ordinary retention and the
accepted source-availability model still apply.

## Checks

All eight new regressions pass: held publication, early-visible append,
publication error/repair, cold storage reopening with concurrent recovery,
gap-fill retry budget, progress of another conversation, sibling loop
suppression and completed-history suppression. The seven-file run passed
155 tests, including existing incoming mirror/ACK recovery, device sync,
gap-fill, outbox and post/group receipt queues. Static analysis of the four
production files and the new test file found no issues.

A disjoint six-file run passed another 116 tests covering shutdown ownership,
first-frame retry, history backfill/serving, file-request scope and durable
control redrive: 271 tests across those two file sets. Formatting of the changed
fragments/files and `git diff --check` passed.

The restart regression reopens persisted fake-container storage; it is not an
instruction-level crash-injection test of every native persistence stage.
Physical convergence and app cleanup are recorded in `summary.json`. Public
evidence uses fixed roles, counts and timings. Raw identifiers, addresses,
payloads and device logs remain private. No push or release is included.

## Physical convergence and cold reopening

A is Android on Wi-Fi, B its Mac sibling, C another identity on Mac. Exact
copies of the final application inventory are built with unchanged production
native libraries; Android runs AOT/profile and Mac runs debug Dart. Anonymous
routing is disabled and cross-identity P2P denied for the delivery measurement.
Original modes and contact policies are restored afterwards.

A submits twelve posts, C six, through six concurrent submitters. Each origin
includes a generated 12,300-character body plus its fixture prefix. All 18
messages and both exact large bodies appear once on every role, with equal
full history IDs and ordering. The large A post is edited, then deleted for
everyone; all unrelated IDs remain.

| Observation | Result |
| --- | ---: |
| First all-role visible sample | 52.8 s |
| Group chunk queues empty | 154.8 s |
| Large edit on every role | 9.2 s |
| Deleted target absent on every role | 13.3 s |
| Equal full histories after cold reopening | 1,541 rows each |
| Surviving fixture posts after cold reopening | 17 each |
| Delivered outgoing fixture statuses A / B / C | 11 / 11 / 6 |
| Duplicate logical IDs | 0 |

One other control frame remained on B at the group-drain sample. These runs
are not controlled speed comparisons: they establish convergence and durability,
and do not demonstrate that the long delay is resolved. The compaction probe
also found no meaningful local-post latency improvement.

Every stand closed its applications. Independent cleanup checked 138 recorded
owned process groups and found zero owned Mac processes, Android package/named
subprocesses, or owned ADB forwards. Main app data and system power settings
were unchanged. No Rust build or server update was performed.
