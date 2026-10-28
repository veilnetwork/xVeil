# Video startup before audio RTT — 2026-10-28

Video remained at one frame per second while the audio RTT was still unknown.
Native video receiver reports already provided a positive RTT, decoder reports
confirmed delivered frames, and both audio directions had current playout
measurements. In the baseline stand the first positive audio RTT appeared
27.8–30.1 seconds after camera-enable sampling began. The video budget reached
at least 30 FPS only after 34.0–37.3 seconds.

The adapter can now use measured video RTT while audio RTT is unknown. It
requires matching native route epochs, decoder-supported delivery telemetry,
video receiver reports for all expected recipients, healthy workers, and
measured audio playout in every expected audio direction. Existing audio loss,
buffer, outage, source-pressure and ACK pacing rules still run. A known bad
audio RTT is not replaced by video RTT. Missing or legacy telemetry cannot authorize this fallback.

After a route change, cached peer audio health cannot earn growth: a newer
playout report must arrive. Replacing the native engine clears that baseline.
The handover regression grew from 2 to 4 FPS on cached audio health before the
fix and holds until the new report afterward. This is an adapter regression;
no physical handover is qualified by the stand.

The related 20-file suite passed 428 tests and static analysis found no issues.
Guard cases cover missing feedback, worker stalls, route mismatch, playout
outages, buffer growth, audio/video loss, jitter, severe audio RTT, cached
ACKs, incomplete recipient feedback and inconsistent playout measurements.

## Stand design

A is an Android profile/AOT build on Wi-Fi; B is its macOS sibling; C is a
separate identity on macOS. Mac builds use debug Dart. Each phase reused retained
profiles, sent an unpaced burst of 12 A-to-C and six C-to-X messages, then ran a
90-second video call. Histories advanced between phases. Native test hooks,
private stage timers and forced routes were absent. The timing endpoint returned
404 on all three roles. SDK and hidden-volume sources were unchanged.

A private experiment shortened native audio sender RTCP reports from five to
one second. It improved startup unevenly and was rejected. The Dart candidate,
reverse-call check and final build all reuse exactly the baseline native
libraries. The experimental C++ assignment was never made in the repository.

See [summary.json](summary.json) for allowlisted phase measurements, message
convergence, call state and cleanup. All times are relative to sampling after
both camera-enable calls, using each endpoint's host request midpoint. They are
not times from dialling or exact frame-production timestamps. Snapshot FPS
fields are cumulative since the first frame; actual cadence estimates here
use frame-count differences. The first >=24 FPS window spans at least three
seconds and does not establish lasting frame-by-frame smoothness.

## Results and limits

The Dart candidate reached an applied budget of at least 30 FPS after
10.6–11.8 seconds, compared with 34.0–37.3 seconds before. Its first complete
three-second-or-longer rendered counter windows at >=24 FPS ended after
12.9–14.0 seconds, compared with 36.2–39.5 seconds before. The reverse A-to-C
call also ran for 90 seconds; B did not start a second call. Counter-rate
medians after 30 seconds were approximately 29–30 FPS in both directions.
These candidate/reverse measurements precede the added handover freshness guard.

In the first final-build run, all 18 new messages converged without duplicates;
all 640 visible IDs and their order agreed on A/B/C. Burst submission still
took 25.7 seconds. C-to-X rang A/B after 445/519 ms; answering on A stopped B
ringing. Active state was observed 2,767 ms after answering. Applied video
budgets reached at least 30 FPS after 13.7/16.8 seconds. This call ended early
at sampled second 25.1, after A sent an end signal. The user subsequently
corrected the earlier answer: the phone was untouched and the call was not
ended manually. This is an unresolved unexpected termination, not a successful
90-second qualification. No ring/liveness timeout was logged before that end
signal; an emitted end signal alone does not identify a user action.

The call-only repeat used the same final source and baseline native libraries;
it did not repeat the message burst. Both A/B rang after 534/538 ms; answering
on A stopped B ringing. A/C became active 6,861 ms after the answer. Across
78 samples spanning 89.9 seconds, both endpoints stayed active on P2P with
cameras and microphones enabled. No worker stalled. Audio receive counters
increased, and sampled native audio-delay peaks were 103/82 ms. These are
playout-buffer observations, not end-to-end speech-delay measurements.

| Final repeat observation | A | C |
| --- | ---: | ---: |
| Applied budget first >=30 FPS, seconds | 12.5 | 24.0 |
| First >=24 FPS rendered window end, seconds | 26.2 | 15.9 |
| That window span, seconds | 3.2 | 3.5 |
| Rendered interval-rate median after 30 seconds, FPS | 29.9 | 29.6 |

Each rendered window describes the opposite endpoint's transmission. The
variation between calls remains material: this removes an unnecessary audio
RTT prerequisite, not every source of slow video startup. The current stand
qualifies Wi-Fi P2P only, not relay-only behavior or a physical route handover.

## Cleanup and remaining work

Each phase closed its app instances. An independent final audit checked all
15 recorded owned process groups and both owned Mac executable paths: no
process remained. The Android QA process and owned ADB forward were absent.
Main application data and system power settings were unchanged. The retained
QA installation contains the final Dart source and original native libraries.
Public evidence contains only allowlisted roles, counters and timings; raw
logs, addresses, identities, device IDs and credentials stay private.

Burst submission and subsequent convergence still need work. Live speech,
headphone volume, frame-by-frame smoothness, Windows reports, partial chunk-ACK
receiver-crash recovery, long offline and the full multi-device matrix remain
unqualified. No changes were pushed, released or deployed.
