# Android/macOS delivery and refused audio capture

Local investigation of the reported Windows 10/Android one-way delivery and
missing calls. Client source base is `231f7947`, with the required-audio guard
in this cycle; native Veil is `1d36980d`. Nothing was released, pushed or
installed into the main application. No relay was changed.

## Scope

A is an Android QA instance on Wi-Fi, B is a separate macOS QA process of the
same identity X, and C is another macOS QA process of identity Y. Existing
containers were reopened and advanced, without restoring older ratchet state.
The shared identity, distinct physical device keys and device group were
verified against the retained private records. This cycle checks retained
links, not a new QR ceremony.

Both platform FFI libraries were rebuilt with production seeds and without
low-difficulty test identities. Android and macOS media libraries have no
native test hooks. The APK's two selected native libraries were verified by
hash after packaging, and the installed QA update retained its signing
certificate and app data. The Dart driver is an explicitly enabled, keyed,
loopback-only QA API. Per-contact P2P was disabled for the call checks; their
actual active transport was relay at both endpoints. Network anonymity settings
were not changed. These measurements do not qualify Windows 10 or cellular
service.

## Delivery, call and file observations

- At the first cold start, C's text appeared on B but was still absent from A
  after the 60-second observation limit. It eventually appeared on A. There was
  concurrent device-history/group synchronization, but its causal contribution
  has not been established. This remains a latency finding, not a proved fix.
- After the initial synchronization, C to X appeared once on A/B in 896 ms;
  A to C appeared once on B/C in 9,755 ms; B to C appeared once on A/C in
  4,771 ms. These are single observations, not latency percentiles.
- C's audio call rang A/B in 301 ms. B answered, A stopped ringing, and both
  active endpoints received additional audio packets over 20 seconds.
- A's outgoing audio call reached C in 563 ms while B was online. Both active
  endpoints received additional audio packets over 20 seconds; B did not create
  a competing media endpoint. Hangup converged.
- After 45 seconds with Android's screen off, its native stack remained ready;
  it received a text once in 854 ms and an incoming call in 77 ms. This is a
  short background check on USB power, not an overnight Doze/OEM power-policy
  qualification. The incoming call in this check was not answered.
- Independent uncached files of 3,145,979 bytes transferred C to A in 12,530 ms
  and A to C in 7,652 ms. Full size and SHA-256 matched in both directions.
- During another uncached C to A transfer, the C process group was killed after
  3,145,728 of 8,388,859 bytes (37.5%) had reached the temporary sink. C stayed
  down for five seconds, then reopened its current profile with the same
  identity and physical key. A completed automatically, with matching SHA-256:
  38,896 ms overall, 28,312 ms after interruption. No manual download retry or
  crypto/profile rollback was used.

The successful audio packet-flow checks above preceded the Dart guard below.
They establish transport/packet movement, not speech intelligibility,
loudness, long-call stability or post-guard physical speech quality.

## Confirmed and corrected defect

A later C to X incoming video call was accepted through the QA API on A while
Android was still behind its keyguard after the background test. The platform
refused microphone startup and camera access. Native `startAudio` returned
false, yet `startVideo` returned true for its mounted receive/send pipeline.
The Dart controller accepted `audioOk || videoOk`, so the call stayed active
for 30 seconds with zero transmitted audio/video from A. C received neither.

The controller now returns failure immediately when the call requires audio
and native audio startup fails. Video startup cannot conceal that failure.
The existing call service sends the error termination and tears down its media
resources. Muted calls still use their existing native muted-start path; no
permission, routing, mailbox or relay priority policy was changed.

The updated QA APK was exercised under the same refused-capture condition.
Native audio again refused; A never became active, video was not started after
that refusal, and both call states terminated/cleared within 5,790 ms. Terminal
states can clear before an observer reads them; the proof records clearance,
not a fabricated retained end-reason value.

This correction surfaces an audio-device failure instead of presenting a
healthy silent video call. It does not bypass Android's camera/microphone
restrictions or establish the cause of the external Windows report. A physical
call with the updated guard on an unlocked phone still needs qualification.
The user was asked to unlock the phone; other checks continued independently.

## Checks and evidence boundaries

The call-service, media seal, microphone state and route-operation suites passed:
196 tests. Analysis of the changed controller and `git diff --check` passed.
Raw logs, QA credentials, identifiers, fixture contents and private build proofs
remain outside the repository. The adjacent JSON contains explicit aggregate
allowlists only.

## Remaining backlog-latency finding

With B stopped, A sent one text to C, then C sent 100 marked texts to X.
C retained all 101 records. A did not have all 101 within a further 120-second
wait after sending the burst; an intermediate poll saw 46 unique records.
The observer restored B after that timeout: B recovered all 101, while A was
still catching up. No duplicates were observed in these samples. The planned
five-minute transition with C then offline was not executed, and the offline
file fixture for that later stage was not created. This is not a passing
100-message backlog test.

In 28 captured ratchet-flush step measurements during this run, encrypted
state saves had a median of 440.5 ms and a maximum of 2,083 ms. The captured tail
contained no inbound admission drop, dispatch failure or index-full marker.
These observations locate work worth investigating; they do not establish
whether storage, routing, device mirroring, or their combination caused the
backlog delay. The first cold-message delay above also remains unresolved.

With all three devices online, the later convergence observer found all 101
records on A/B/C, with the same logical ID sets and no duplicates. That observer
ran for 52,648 ms after the preceding investigation; it is not an end-to-end
backlog recovery time. There is no evidence of permanent loss in this run, but
the 120-second delivery boundary failed and remains open.

All recorded macOS QA process groups and QA runtime commands were absent after
cleanup, including the deliberately crashed/restarted source. The Android QA
process was force-stopped and verified absent; the owned ADB forward was removed.
Temporary QA contact overrides were cleared to follow the global policy, and
package permissions were restored to their recorded state. Current encrypted
profiles were retained. Installed main applications, their data and system
power settings were unchanged. Android remains behind its keyguard and needs
manual unlocking for the deferred normal incoming-call qualification. No claim is made for the
entire 63-case multi-device matrix, long offline TTL, device revocation, or all
potential causes of one-way delivery.

Follow-up on 2026-10-27: after the user unlocked Android, the deferred normal
incoming video call passed on the audio-startup guard build. Worker timing
also separated native commit work from RPC scheduling, and subsequent queue
and journal-read corrections were tested. Burst delivery remains open. See
[the follow-up evidence](../inbound-replay-queue-2026-10-27/README.md) for the
exact build scope, failed delivery limits and cleanup audit.
