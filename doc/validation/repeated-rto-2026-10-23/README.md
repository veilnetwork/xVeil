# Repeated no-SACK RTO recovery — 23 October 2026

SDK correction: **`ada6eed6`**. Parent: **`89e7678f`**.

## Confirmed defect

The optional no-SACK RTO policy requeues an unacknowledged flight and starts
replaying from its first unacknowledged byte. `rewind_high` remembers the old
flight's valid ACK ceiling so an original can arrive and be acknowledged while
its replay is still waiting locally. Previously every subsequent rewind
replaced that ceiling with the latest replay endpoint. If that replay was
smaller, a valid late ACK of the original larger flight was rejected as an ACK
of unsent bytes. Recovery could therefore ignore real delivery and replay bytes
that had already arrived.

A second state loss discarded the fact that the original flight included FIN
when a partial replay had not yet reached that FIN. Merely preserving the high
ceiling fixed DATA but still failed to complete the acknowledged send direction.

The correction retains the serial-number maximum of the existing ceiling and
current flight, and keeps the rewound-FIN flag until an ACK covers it. Byte
trimming and the handed-off-data check stay in force. The fix adds no timeout,
wire-format change, relay priority or test hook to production.

## Regression evidence

Both new tests fail on the parent. The fixture hands off a 256-byte original
flight, withholds its ACK, triggers an RTO, locally hands off only one 64-byte
replay segment, then triggers another RTO. The late original ACK must advance
the stream, clear the retry counter and leave only new untransmitted application
bytes pending. An ACK one byte beyond the original flight must be rejected.
The FIN variant must also finish its send direction.

An intermediate ceiling-only fix passes DATA but still fails FIN; retaining
FIN evidence fixes both. The final tests exercise **eight cases**: DATA/FIN,
RACK off/on and ordinary/wrapping 32-bit sequence numbers. All **124 stream
protocol tests** and **62 anonymous-stream client tests** pass, as do rustfmt
and all-target Clippy with warnings denied for both crates.

## Relationship to the physical file failure

The preceding cellular run recorded payload stalls, repeated RTOs and attempts
to continue from a saved offset. The late resume streams received roughly
108–122 KiB beyond their first receiver samples while the corresponding source
samples recorded no cumulative ACK advance after their first source snapshots. The logs do not show whether the
missing cumulative ACK was delivered to the source and rejected. This code
regression proves a relevant recovery defect, **not the original path-loss or
handshake-timeout cause**. Cross-device clocks are not subtracted to infer
network latency. Physical qualification is recorded separately below.

## Physical cellular qualification of the current SDK

Both production-native libraries build with the existing **199 C export names**.
The compatible frontends are unchanged. Before transfer and again before
shutdown, current source/frozen-library hashes, the installed phone APK, loaded
Mac library and owned QA identities were checked. No synthetic media was used.
The phone's default route was cellular with Wi-Fi off, and own-contact P2P was
denied. All observed file opens were anonymous; no call/audio device was opened.

| Phone → Mac | Download time | Integrity | Original 180-second completion gate |
| --- | --- | --- | --- |
| 32 MiB | **347.642 s** | Complete SHA-256 matches | **Failed** |
| 4 MiB afterward | **18.797 s** | Complete SHA-256 matches | **Passed** |

Full diagnostic durations including fixture/offer preparation were
**357.777 s / 19.457 s**. The large file completed after **seven pull requests**
and **six failed attempts**. Resume requests reached **2,359,296**, **4,980,736**
and **10,223,616 bytes**. This run therefore demonstrates successful continuation
to a verified complete file after interruptions, not just progress at a retained
offset. It does not establish that this source correction caused the different
physical outcome: route/network conditions were not controlled against the
previous SDK.

Failures remain: the large transfer recorded **three manifest-first-byte
timeouts**, **two payload-read idle failures**, **two source payload-write idle
failures** and one application reset failure. These are overlapping endpoint
classifications, not independent incidents. No connection-setup timeout,
manifest EOF or harness cancellation occurred. The small transfer completed in
one request without a failed attempt.

Process-wide native counters contain **13 / 14** successful pool builds on Mac /
phone: **12 / 11 Refresh**, **1 / 2 Warm**, **0 / 1 Expand**. Completed failed
pool opens across all reasons were **0 / 2**. No `NoRelays` text or candidate
failure was observed. Sampled local handoff waits reached **29,417 / 7,604 ms**.
These counters and maxima are process-wide, not exclusively one file's path.
The original 180-second large-file target is still unmet. Initial path loss,
manifest-first-byte timeouts, slow routes and long-transfer stability remain
investigation targets; this is not call/video or full multi-device qualification.

## Cleanup and evidence

Own-contact policies, the diagnostic property and exact original phone APK were
restored. An independent APK SHA-256 comparison passed. Owned phone fixtures
were removed and independent checks found no owned Mac app, phone app or log
capture. Wi-Fi remained off and mobile data enabled. The installed Mac app was
not replaced. No push or release occurred.

[summary.json](summary.json) records numeric/boolean evidence and commit
references. Raw identities, endpoints, paths, hashes of user/test content,
configuration and logs remain outside the repository in the private stand cache.
