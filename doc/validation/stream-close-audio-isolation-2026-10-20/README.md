# Stream-close isolation from live audio

## Failure and changes

The earlier physical PCM repeat lost all Mac → Android audio before video
started. It was not an idle audio-only test: old QA downloads resumed during
warmup. The phone banned the Mac's physical node for 25 seconds following file
stream errors. During the ban its direct QUIC receiver passed 298 authenticated
eligible datagrams to the dispatcher, but the dispatcher silently returned
before endpoint routing. Media ingress first appeared immediately after the
ban expired. The original lines and source hashes are retained in
`../physical-pcm-probe-2026-10-20/delivery-ban-cause.json`.

SDK `6c554706` separates an absent stream from a live stream whose receive
credit is exhausted, atomically under the existing table lock. Late bytes for
an absent stream receive `AppClose`; they are not delivered and allocate no
stream state. A live window overrun remains a violation. Regression tests
exercise a locally backpressured bridge, already closed/unopened streams,
continued independent datagram delivery, and the live window guard. Two
regressions fail on the previous source.

The first device run of that change exposed a further problem: repeated late
segments produced identical close replies until the bounded reply queue filled.
Retiring the carrier then generated scope errors and a temporary peer ban.
SDK `70a99c1f` coalesces identical *pending* close responses on the same child
generation, before the capacity check. Different streams, app scopes, child
generations and all receipt multiplicity retain their previous FIFO/bounds.
A regression with 4096 repeated closes fails without this change, including
when the queue is already at capacity. After both changes, **955 tests pass and
8 existing tests are ignored** across veil-app, veil-dispatcher and veil-session.

These changes affect local stream lifecycle handling, not video thresholds,
wire metadata or relay priority. Genuine live-window violations, distinct-response
flood limits and dispatcher rate/bandwidth/ban checks remain in effect.

## Intermediate physical measurement (6c554706)

A packaging attempt stopped before the Mac test API became available: the build
product lacked the separately staged media, storage and PCM-driver libraries.
No call occurred. The app exited and the ordinary phone APK was restored. Those
missing inputs were then staged from the verified PCM stand and the app signed.

The resulting 300-second Mac ↔ Blackview run completed with one engine generation
on each device. Sources were calibrated to a shared future epoch and both full
PCM recordings were copied before APK restoration. Cameras were enabled at 30 s,
4 MiB files offered in both directions at 45 s and 180 s, and an **explicit test
request** changed P2P to relay at 150 s. Old background fixture downloads were
also present; phase names in the analyzer describe the scheduled actions, not
an idle network. No automatic route fallback preceded the explicit request.

All **590 expected one-second tone transitions in the 5–300 s analysis interval**
were matched by actual decoded PCM (295 each direction). This does not prove
absence of shorter audio defects or speech intelligibility.

| Scheduled phase | Mac → phone p95 / max | Phone → Mac p95 / max |
| --- | ---: | ---: |
| P2P, video and file requests (45–150 s) | 134 / 334 ms | 138 / 147 ms |
| Forced route handover (150–180 s) | 405 / 498 ms | 318 / 418 ms |
| Relay, video and file requests (180–300 s) | 254 / 264 ms | 219 / 248 ms |

These are decoded-pipeline point estimates, not hardware acoustic latency or
an internal jitter-buffer size. PCM blocks are 10 ms; the measured clock-bracket
envelope and unbounded unsampled drift limitation remain in the JSON. The strict
200 ms target is deferred. No overall call-quality pass is assigned.

Only the phone → Mac P2P 4 MiB file completed with a matching SHA-256. Three other
downloads remained unfinished, were explicitly cancelled with the correct
`/download_cancel` endpoint, and their HTTP requests ended. This does not qualify
all file transfers or sustained successful bulk throughput. Old QA source files
reused by earlier runs also generated expected unavailable-source retries; those
are not treated as production data-loss evidence.

## Final cancellation regression

The SDK 70a99c1f run completed 150 seconds of calibrated continuous synthetic
audio, with cameras from 30 s and two fresh 32 MiB file requests from 45 s.
Old pending QA downloads were cancelled before warmup; new source paths did not
overwrite old offered files. Both active streams were explicitly cancelled at
90.645 s. Both device logs confirm the corresponding reads ended with
`stream already closed`; this was not merely a successful cancellation API reply.
Audio then continued for almost another minute, with no engine replacement or
route change. The complete logs contain **zero session violations and zero
automatic bans** on both devices, including warmup and teardown.

All **290 expected transitions in the 5–150 s interval** were matched (145 in
each direction). During the video/file phase, p95 point estimates were 175 ms
Mac → phone and 137 ms phone → Mac, but individual peaks reached **588 / 665 ms**.
Those transients remain; no strict latency or overall quality pass is claimed.
`final-decoded-pcm.json` retains the full clock and driver limits.

This run deliberately cancels the large files, so it does not qualify their
completion. A separate debug-API limitation remains: although actual streams
closed at cancellation, their long HTTP download waiters ended only when the
app was shut down. They all exited and this is retained as `RemoteDisconnected`,
not a successful file result. The prior 4 MiB completion limitations remain.

## Limits and remaining work

The original first file error did not distinguish an absent stream from a real
credit overrun, so the exact initial teardown cannot be reconstructed from it.
The new source regressions establish the lifecycle defect, while subsequent
device cancellation check establishes that this sequence no longer bans its
live audio peer. Full audio/video/screen/
file isolation remains open. Live speech, device speaker/headphone loudness and
successful completion of the three unfinished file paths are not verified here.

All native builds use clean SDK sources excluding the four foreign security
edits. QA PCM overlays are confined to disposable exports. Test profiles are
retained, the ordinary phone APK is restored, and started apps/helpers/ADB
forwards are independently checked absent. No push, release or relay mutation.
