# Admission after device-journal ingest — 2026-10-27

An adopted device ingest saved a fully checked journal, invalidated owner and
master admission caches, then streamed its mirrored messages. Applying a mirror
asks whether its counterparty is a sibling. That lookup reloaded the same
journal for owner/master admission immediately after the successful ingest.

Ingest now primes those bounded caches from the committed bundle before
streaming mirrors. `_save` returns its admitted control rows and durable control
receipts; cache construction does not reuse the pre-admission input state.
The local batch branch still returns a staged view, which wire ingest cannot
consume because it shares the group's mutation gate with local posting.

Master selection uses the existing validated, clock-filtered device-state fold.
Publication checks the membership generation, device-group pointer, local
device address and service lifetime. An unresolved local address skips this
optional work; it does not reopen encrypted node configuration. A cache-preparation
error leaves normal lookup available and does not fail an already durable ingest.
The existing 30-second expiry and local-append invalidation rules remain.

## Compiled checks

The new test first observed **two journal reads, expected zero**, after durable
ingest. It now observes zero, while rejecting a stranger and an obsolete master.
Coverage includes replacement and future announcements, failed header write
without publication, successful retry, sibling addition/revocation, and expiry
that causes a fresh lookup. These are application tests with fake signatures,
not a qualification of native cryptography or the full device-revocation model.

A separate assertion caught one optional node-config read when the local
address was absent. It now observes zero. The final relevant suites passed
**464 tests**, with three existing skips. Static analysis reported no issues.

## Physical stage measurements

A is Android on Wi-Fi and B is macOS, both identity X; C is another macOS
instance, identity Y. The encrypted profiles were retained. Native artifacts
stayed on Veil `1d36980d` and the existing media build. No Rust build, native test
hook, reduced identity difficulty, forced route or server change was used.

Fixed-label stage timers existed only in private QA source copies. Each phase
used a 30-second post-start warm-up and six spaced C-to-X messages with all
devices online. Both phases converged with identical new IDs and no duplicates.
Stage windows can contain background work and overlapping operations; profiles
advanced between phases, so these are not controlled end-to-end speedup ratios.

| Later window | Owner reads before / after | Mirror apply before, ms | Mirror apply after, ms | Cache preparation after, ms |
|---|---:|---:|---:|---:|
| 4 | 1 / 0 | 1,054.8 | 271.7 | 0.7 |
| 5 | 2 / 0 | 2,258.2 | 240.6 | 0.5 |
| 6 | 1 / 0 | 1,244.9 | 331.3 | 0.6 |

End-to-end delay remains. The candidate's later first observations on A were
11,547, 6,832 and 9,223 ms. In window 5, one group apply took 3,476.7 ms;
its merge took 2,551.6 ms, including a 324.3-ms save. The later mirror apply
took 240.6 ms. The roughly 2.2 seconds inside merge before save still needs
finer measurement. These intervals can overlap and must not be added as
independent costs. They demonstrate local processing time, not relay transit
time or a determination of packet loss.

## Uninstrumented checks

After removal of the timers, a three-message pass checked two C-to-X messages
and one A-to-C message, including the outgoing copy on online B. All three
devices converged without duplicates. The A submission itself took 14,427 ms;
B first showed its copy after 21,362 ms. A 57.8-second P2P video call rang A/B,
was answered on A, stopped B's ringing, and carried media both ways. Its
connection after answer took 7,532 ms.

That pass exercised the resolved-device path. A separate pass built from the
exact final source, including the unresolved-address guard, checked another
C-to-X message and a 28.6-second P2P video call. The message appeared on A after
24,934 ms. A/B rang after 436/454 ms, and connection after answer took 9,054 ms.
Both endpoints stayed active with cameras on and increasing audio counters.
Video FPS was low in this short call: receive medians 1.5 on A and 3.3 on C.
This is a remaining quality symptom, not a successful video-quality qualification.
Live speech intelligibility and headphone volume were not assessed.

The complete final visible conversation had 484 rows per device, with identical
ID sets and visible order. File bytes and other state dimensions were not
compared. All three final normal kernels lacked the private timer path/name,
and its endpoint returned 404 on all three running apps.

## Cleanup and open work

Every stand phase closed its started apps and checked their processes. The
final audit found no process in five recorded groups, no process for either
owned Mac executable and no Android QA process. Permissions were restored and
the owned ADB forward removed. Main app data and system power settings were
unchanged. Only allowlisted roles, counts and timings are exported in
[summary.json](summary.json); raw logs, IDs and credentials stay outside the repo.

Nothing was pushed, released or deployed. Slow startup catch-up, the remaining
local merge/dispatch time, slow Android submission, call setup and low video FPS
are still open. Windows, long offline cases, files and the full multi-device
matrix are not qualified by this run. The previously documented partial
chunk-ACK receiver-crash limit is not addressed here.
