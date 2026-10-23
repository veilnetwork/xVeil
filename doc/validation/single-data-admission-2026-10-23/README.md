# Single-DATA local admission recovery — 23 October 2026

SDK correction: **`66167052`**. Parent: **`ada6eed6`**.

## Observed local blockage

The preceding cellular run completed both files but had three full-pull
manifest-first-byte timeouts. Matched native streams show the receiver-side
requester already Established, retaining two unhanded cells including its
48-byte request, no subsequent receive progress, and zero DATA RTO events.
The final sampled local blocked ages were **8007 / 7475 / 8007 ms**; the
corresponding cumulative local rejection counts were **3346 / 3004 / 3206**.
The serving-side matched streams had no request bytes delivered to the app.
This is local admission wait, not evidence of a slow server preparing a reply.

The process log contains explicit session `Full` rejection diagnostics, reaching
27,000 reported cumulative rejections. `Full` covers both the ordinary channel
and its recoverable byte-credit reservation. The log's configured channel cap
of 4096 is **not** evidence that 4096 frames were queued; the much smaller
recoverable credit budget may be exhausted. Endpoint clocks are not subtracted.
Raw stream/node identities and logs stay in the private stand cache.

## Confirmed code defect and correction

A DATA run of two or more cells already tried other ready, correctly bound
paths after local rejection. A one-cell DATA run and the direct scalar send
used a separate path that returned WouldBlock immediately on its pinned queue.
A small file request could therefore keep waiting while a usable alternate
first hop was ready. Local rejection starts no network retransmission timer.

All DATA sizes now use the existing data-run admission path, including the
single-cell direct entrypoint. Its bounded fallback tries already-open routes
with a distinct first hop and exactly the same receiver cookie/key. An actual
local enqueue is required before a cell is removed or counted as sent. All-full
queues leave the original batched cell pending and do not quarantine routes.
The primary stream pin, wire priority, queue sizes, relay scheduling and pacing
remain in force; no route construction, new wire field or priority was added.
Oversized DATA is classified as InvalidInput by the shared path, consistently
with detailed transport errors, and does not cool a path. The former scalar
envelope-size check returned a generic Other error.

## Regression gates

The real NodeServices/outbox regression fills the pinned and another first-hop
queue, offers an available path with the wrong receiver key, then a third
correctly bound healthy path. A 48-byte request fails on the parent despite that
usable path. The correction passes **four cases**: direct/batched entrypoints
and healthy/all-full alternatives. The wrong key is skipped, positive delivery
is admitted once, the original pin is retained and negative admission is not
misreported as a send. A separate public-send regression checks oversized input.

All **124 stream tests**, **64 anonymous-stream client tests**, all-target
Clippy with warnings denied and rustfmt pass. The change introduces no native
media test hook and changes no frontend code.

## Scope still open

This fixes the missing alternate-path admission, not every cause of a full
queue. The content layer still starts its first-byte timer after handshake
readiness rather than explicit request handoff; if every path is blocked, that
timer can still include local wait. Handoff-aware deadline separation remains
open and was not substituted for restoring actual delivery. The first-byte
deadline and original 180-second file gate were not increased.

## Physical cellular run

Production macOS and Android builds retain the same **199 C export names**.
Compatible frontends are unchanged. Before transfer and again before shutdown,
the current source/frozen-library hashes, installed APK, loaded Mac dylib and
owned QA identities were checked. The phone used cellular data with Wi-Fi off;
own-contact P2P was denied and all observed file opens were anonymous. No call,
audio device or synthetic media was opened.

| Phone → Mac | Result | Original 180-second completion gate |
| --- | --- | --- |
| 32 MiB | Timed out at **600 s**; last sink sample **26,476,544 bytes (25.25 MiB)** | **Failed** |
| 4 MiB afterward | Timed out at **180 s**; last sink sample **2,359,296 bytes (2.25 MiB)** | **Failed** |

Neither completed, so **integrity is unverified**. Full diagnostic durations
including fixture/offer setup were **612.178 s / 180.717 s**. The large file had
four failed pull attempts including final harness cancellation, one setup
timeout, two payload-read idle failures and one source payload-write idle
failure. Resume was requested at **17,825,792 bytes**. The small file had three
failed attempts including cancellation, two payload-read idle failures and one
application reset failure; resume was requested at **262,144 bytes**. Endpoint
failure categories overlap and must not be added as independent incidents.

**No manifest-first-byte timeout or manifest EOF was observed** in either file.
The Mac's 446 sampled driver dumps had a maximum sampled local blocked wait of
**0 ms**; that does not exclude shorter waits between one-second snapshots.
The phone's 608 samples reached **21,089 ms**. The previous long requester-side
local blockage did not recur in the retained samples, but the physical file
completion gates remain failed. Routes/network conditions were not controlled
against the preceding SDK; no speed improvement or complete provider fix is
claimed.

Process-wide native counters recorded **21 / 87** successful pool completions
on Mac / phone: **20 / 83 Refresh**, **1 / 2 Warm**, **0 / 2 Expand**. Completed
failed pool opens were **0 / 4** across all reasons. No `NoRelays` text or
candidate failure was observed. **85** phone pool-completion messages
match the diagnostic prefix of its served file-request peer, across both phases.
Comparing only with the peer's identity receive address would miss its runtime
device address. This prefix match does not attribute every completion to one
specific stream. Reconstruction, stalled payloads and circuit lifetime/recovery
remain investigation targets. Calls/video, Windows and the full multi-device
matrix were not requalified.

## Cleanup and evidence

Own-contact policies, the diagnostic property and exact original phone APK were
restored; an independent APK SHA-256 comparison passed. Owned phone fixtures
were removed. Independent checks found no owned Mac app, phone app or log
capture process. Wi-Fi remained off and mobile data enabled. The installed Mac
app was not replaced. No push or release occurred.

[summary.json](summary.json) contains numeric/boolean results and commit
references. Raw identities, diagnostic peer prefixes, endpoints, content hashes,
paths, files and logs remain in the private stand cache outside the repository.
