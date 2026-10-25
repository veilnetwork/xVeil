# Startup probe pacing and RTCP transit attribution

## Change and status

Removed a redundant three-second wait between cautious **startup** probes.
A new causal decoder acknowledgement from every receiver now permits the next
bounded step after the existing 950-ms minimum interval. The cautious gain
remains 25% for cadence and bytes. Cached frames, unknown audio measurements,
loss, growing buffers, missing receivers and failed native updates still cannot
fund growth. The 400-ms RTT failure rail, loss drain and cruise intervals remain.

The previous physical trace contained short healthy growth opportunities with
decoder credit already available while this timer still withheld the next step.
Three new assertions fail semantically against the preceding implementation;
all five new tests pass against the change. This establishes the controller
defect independently of variable network performance.

**Physical qualification:** one candidate relay call passed with moving video
and continued audio packet reception on both endpoints. Its cautious RTT branch
was never eligible: this call qualifies ordinary startup and continuity, **not**
the changed branch or a measured speedup caused by it. Live speech and loudness
were not assessed.

## Physical runs

All three used the same preserved QA identities, phone on Wi-Fi, Mac, production
seeds, real codecs and a contact policy denying P2P. Both cameras were enabled
after ten seconds of audio. No native fault-injection hooks were enabled.

| Build/run | First five decoded frames on both | First 5-second window >=20 FPS: Mac / phone | Final decoded FPS: Mac / phone |
|---|---:|---:|---:|
| Previous controller, run 1 | 7.164 s | 15.324 / 14.307 s | 30.05 / 29.27 |
| Previous controller, run 2 | 8.048 s | 68.396 / 27.500 s | 29.61 / 30.00 |
| Candidate | 7.222 s | 14.414 / 13.385 s | 29.89 / 29.11 |

Times start at camera enable; FPS uses decoded-frame deltas and elapsed time,
not the requested encoder limit. These consecutive, uncontrolled calls show
substantial network variation and cannot establish an old/new speed ratio.
The candidate kept receiving video in all eighteen subsequent five-second
windows; its final two windows also had positive audio packet deltas on both
devices. Registered audio interruptions were zero, and observed video-phase
audio jitter-buffer peaks were 81 ms on Mac and 122 ms on the phone. Counters
do not substitute for listening to continuous speech.

## Where the high RTCP RTT comes from

Extended the existing opt-in native trace with bounded RTCP Sender Report
metadata. It records no packet payload, performs no callback file I/O and changes
no transport behavior or ABI. Sender Reports are capped at 8,192 per recorder,
including under concurrent callbacks; malformed compound packets publish no
valid prefix. Disabled tracing remains inactive.

Match the exact SR compact-NTP token to RR.LSR and the corresponding report
block at both endpoints:

- `t1`: sender's SR callback; `t2`: receiver's SR callback.
- `t3`: receiver's RR callback; `t4`: sender's RR callback.
- Callback transit round trip: `(t4 - t1) - (t3 - t2)`.
- Receiver residence omitted by DLSR: `(t3 - t2) - DLSR`.

Endpoint clock offsets cancel because each subtraction uses one endpoint's
clock. Compact-NTP progression also estimates *relative* source SR scheduling
excess above that recorder's minimum, not an absolute clock calibration.
Missing, ambiguous and incorrectly ordered matches are rejected.

In the slower baseline run, all 127/126 received RR blocks with LSR matched
their four events. For audio:

| Measurement | Mac source | Phone source |
|---|---:|---:|
| Callback transit RTT, median | 199.625 ms | 217.949 ms |
| Callback transit RTT, maximum | 508.356 ms | 512.610 ms |
| Receiver residence omitted by DLSR, maximum | 0.743 ms | 0.053 ms |
| Relative source SR scheduling excess, maximum | 0.020 ms | 0.052 ms |

Thus the reproduced ~500-ms RTT is predominantly in the callback-to-callback
transit path, not unaccounted receiver residence or relative source RTCP
scheduling. That path still includes sender SDK queues, connections, relays,
network transit and receiving dispatch. This evidence does **not** isolate a
specific relay, prove network packet loss is the sole cause, or measure one-way
voice latency. The earlier ~805-ms spike was not reproduced in these runs.
No relay traffic classification or media priority was introduced.

## Checks and provenance

- 304 focused adapter, delivery, source-pressure and group-media tests passed.
- Analyzer: no issues in the changed Dart files.
- Native trace smoke test passed: disabled behavior, exact SR token, caps,
  malformed compound rejection, concurrent accounting and flush idempotence.
- Android and Mac frontends built; Mac signature verification passed. The
  complete installed QA APK hash matched the built artifact.
- External build mount remained present. Flutter and stand apps used
  `TMPDIR=/private/tmp/`.
- After every physical run, owned Mac process groups and the QA phone process
  were independently verified exited; exact previous microphone/camera grants
  were restored, the owned ADB forward removed and the QA Mac profile archived.
  The main app and its data were not changed.

[summary.json](summary.json) records baseline commit IDs plus patch artifact
hashes and numeric results. Builds preceded commits; the source patch is part
of this work cycle. A later smoke-test assertion correction did not alter native
production code. The three decision CSVs retain only an explicit scalar
allowlist with times relative to camera enable. Native traces, source IDs,
addresses, credentials, capture labels and absolute timestamps remain private.

## Remaining work

Qualify the changed cautious branch on a physical run that naturally exercises
it, and split high transit RTT into actual endpoint queue, connection and relay
contributions. Cold anonymous multi-device startup, the wider multi-device
matrix, Windows reports, Android background behavior and live speech/loudness
remain separate unfinished work.
