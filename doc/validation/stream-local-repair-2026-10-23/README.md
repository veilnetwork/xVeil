# Stream repair behind a locally blocked DATA tail — 23 October 2026

SDK correction: **`89e7678f`**. Parent: **`2a3b4999`**.

## Confirmed defect

The driver retained DATA cells that the local carrier had not yet accepted.
While that queue was nonempty it never polled newly due engine output. A
repair of an already accepted, subsequently lost segment therefore waited for
the entire unsent tail, even though the engine had already marked it for
retransmission. Reverse-direction ACKs could wait behind the same tail.

In the preceding physical cellular run, the matched source stream had a marked
repair in every sampled dump from stream-local 3003 through 6005 ms, while the
retained queue drained from 31 to 7 cells and the cumulative ACK did not advance.
That is at least **3002 ms** of observed local repair delay. The last blocked
sample before handoff was 4950 ms old. These are source-local times, not
subtractions of uncalibrated endpoint clocks. The matching receiver has only
three earlier handshake snapshots; these logs do **not** prove it received an
out-of-order tail or explain the original path loss.

The four earlier manifest-only header probes were separately rejected by the
existing acceptance/group-grant policy. They are not counted as the full-pull
first-byte timeout. Authorization was not weakened. Application-level
“manifest sent” records local write acceptance, not network handoff.

## Correction

A repair-only engine poll exposes due ACKs, handshake control and paced
retransmissions without reserving more fresh DATA/FIN. The driver places those
cells before its retained fresh-DATA tail. Eight slots are reserved inside the
existing 512-cell local bound. Existing retained cells keep their relative order
and exact encoding; partial striped acceptance is still correlated with local
handoff tokens. Retransmission pacing, transport congestion/window limits,
local acceptance timing, stream wire format and first-byte deadlines remain in
force. This is local endpoint scheduling of generic stream control/repair, with
no relay priority or media classification.

## Controlled regression and gates

The integration fixture uses the real OnionStream driver and a real peer
StreamEngine under a paused Tokio clock. Its local carrier admits one DATA cell
per 50 ms for originals and repairs alike; it deliberately drops only the first
accepted DATA. Payload length is 32 KiB and every byte is compared after
completion.

| Case | Parent | Corrected |
| --- | --- | --- |
| No loss, RACK disabled/enabled | First byte 0 ms | First byte 0 ms |
| Lost head, RACK disabled | First byte/repair 3200 ms; 500 ms assertion fails | First byte/repair 150 ms |
| Lost head, RACK enabled | Not reached after parent failure | First byte/repair 100 ms |
| ACKs withheld until first-byte repair, RACK disabled/enabled | Not run | RTO required; first byte/repair 150 ms |
| Reverse-direction DATA ACK, RACK disabled/enabled | Not run | ACK delay below 50 ms while the DATA tail is blocked |

These are virtual-clock regression measurements, not physical cellular latency.
All four new tests pass, as do the complete **122 stream-protocol tests** and
**62 anonymous-stream client tests**. Both crates pass all-target Clippy with
warnings denied, and rustfmt passes.

## Physical cellular run with the combined current SDK

Production macOS and Android libraries build and retain the same **199 C export
names**. The compatible frontends are unchanged; source/frozen-library hashes,
the installed APK, loaded Mac dylib and owned QA identities were checked before
the transfer and again before shutdown. No synthetic media or native media test
hook was introduced. The phone used mobile data with Wi-Fi off; own-contact P2P
was denied, so the observed file opens used anonymous streams. No call or audio
device was opened.

| Phone → Mac | Result | Original 180-second completion gate |
| --- | --- | --- |
| 32 MiB | **600-second diagnostic timeout**; last sampled sink **5,767,168 bytes (5.5 MiB)**; integrity unverified | **Failed**; about 3 MiB at the checkpoint |
| 4 MiB, afterward | **44.804 s** download; complete SHA-256 matches | **Passed** |

The incomplete transfer had **nine failed pull attempts**, including the final
harness cancellation, **four connection-setup timeouts**, **three payload-read
idle failures**, **two source payload-write idle failures** and one application
reset failure. These are overlapping endpoint classifications, not independent
incidents. No manifest-first-byte timeout or manifest EOF was observed. Resume
requests reached **786,432** and **5,767,168 bytes**; the last offset did not lead
to completion. That proves attempts to resume, not successful long-file recovery.
The 4 MiB transfer needed one pull request and no failed attempt. Full diagnostic
durations including fixture/offer setup were **633.158 s / 45.521 s**.

Process-wide native counters contain **35 / 13** successful pool builds on Mac /
phone, comprising **34 / 11 Refresh**, **1 / 1 Warm** and **0 / 1 Expand** builds.
There were **3 / 4** completed failed pool opens across all reasons; none were
completed `NoRelays` pool failures. Phone logs contain one `NoRelays` candidate
failure and two textual occurrences. These counts must not be conflated.
Sampled local carrier handoff waits reached **21,419 / 25,062 ms**; a missing
usable route can still block acceptance after the driver repair-order fix.
These are process-wide observations, not exclusively one file's route counts.

The earlier SDK's 136.093-second large-file completion is not a controlled A/B
comparison: routes, network conditions and several intervening SDK corrections
changed. **No physical speed improvement or cure of the provider problem is
claimed.** Long-file recovery and multi-second stream acknowledgement delays
remain open; initial path loss and subsequent repair-handshake failures need
further attribution. This run does not requalify calls, video, live-speech
loudness, Windows, Android background availability or the multi-device matrix.

## Cleanup and evidence

Own-contact policies and the diagnostic property were restored. Owned phone
file fixtures were removed; the exact original phone APK was restored and its
SHA-256 independently checked. Independent checks found no owned Mac app,
phone app or log-capture process. Mobile data remained enabled and Wi-Fi off.
The installed Mac application was not replaced. No push or release occurred.

[summary.json](summary.json) contains numeric/boolean observations and commit
references. Raw identities, endpoints, paths, configuration, content hashes,
file contents and logs remain in the private stand cache outside the repository.
