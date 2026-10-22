# Cellular call and file validation — 2026-10-22

**Status: file backpressure corrected on the tested path; call/video failures remain.**

## Latest follow-up: content credit and audio reserve

[credit-and-audio-reserve.json](credit-and-audio-reserve.json) contains only
allow-listed aggregate results. Raw traces, endpoint identities, addresses,
profile names, file names, device labels and keys remain outside the repository.

### Corrections and verification

- Reliable content streams negotiate a 256 KiB application-read window with
  cumulative credit every 64 KiB. The first 128 KiB implementations prevented
  queue-full markers but were too slow to finish 32 MiB within 180 seconds;
  they were not accepted as the final fix. The final sliding window retains
  bounded reads and compatibility with old clients/servers. Credit is not
  durable delivery; existing piece and final hash verification remain required.
- The native RTP-age catch-up path no longer drains below the adaptive decoder
  reserve merely because audio spent time upstream. The new regression fails
  on the old code. The independent hard local-storage budget is unchanged.
  The long-Opus, recurring-jitter and group real-PCM gates pass. Recurring-jitter
  arrivals now follow source RTP time to avoid unrelated callback-boundary
  variation between controls; no acceptance threshold was relaxed.
- The complete Flutter suite passes **5,777 tests, 154 skipped** for the sliding
  protocol. After changing only its window size, the final content, credit and
  idle-write subset passes **70 tests**; all six changed Dart files analyze
  cleanly. Slow sinks, cancellation, partial/invalid ACKs, final-close races,
  FIFO writes, range resume and both legacy compatibility directions are covered.

### Physical file results

| Direction | Size | Download time | Verification |
|---|---:|---:|---|
| Phone → laptop | 32 MiB | 142.09 s | Exact SHA-256 match |
| Laptop → phone | 32 MiB | 52.30 s | Exact SHA-256 match |

The phone used cellular data with Wi-Fi disabled. During the upload the owned
laptop receiver process was stopped for five seconds after at least 4 MiB and
then resumed. No queue-full marker or payload restart was observed. The first
upload attempt timed out **before its manifest**; a warmed direct-stream retry
then carried the complete payload. The reverse transfer needed one request.
The physical payload used direct streams; anonymous transport and compatibility
were also checked in the simulated transport tests. Older peers retain their
uncredited behaviour. These measurements do not establish a universal speed.

### Calls remain unresolved

Clean production native engines, real microphones/cameras and the normal SDK
were used for both calls; the temporary file-test SDK probe was removed first.

- Laptop → phone: incoming signaling took **1.10 s**, connection after answer
  **2.55 s**. The call remained connected for **139 s**, but only nine laptop
  frames and zero phone frames were sent; decoding froze. Sampled local audio
  delay peaked at **210/749 ms** (laptop/phone). The reserve correction did not
  establish recovery of video or elimination of catch-up events on this path.
- Phone → laptop: **179 s**, with cameras enabled at **60 s**. Audio trouble
  existed before video: native receive age reached **844/693 ms** and sampled
  forced catch-up totals reached **340/4,970 ms** in the first 55 seconds.
  After camera enable, the call switched from P2P to relay at about **65–66 s**.
  Sampled native receive age on the laptop peaked at **14,041 ms** around
  recovery; phone local audio delay peaked at **1,704 ms**. Only five/two sent
  video frames were counted across media epochs. The call survived, video did
  not recover. Nonzero retained FPS was not treated as decoder progress.

Audio packet counters progressed in both directions. This does not certify
speaker audibility or speech quality: the user could not listen or speak during
these tests. Local buffer delay is not acoustic end-to-end latency. A single
field network does not identify the carrier, a relay or the endpoint as the
cause. Call quality and the P2P-to-relay stall remain release risks.

All owned apps and log captures were stopped afterward; original phone APK
restoration and its hash were verified, and owned phone file fixtures removed.
No relay classification, relay priority, mailbox fallback or container change
was introduced. Commits for this cycle are local and unsigned.

## Previous follow-up: paused-source feedback and receive queues

[follow-up.json](follow-up.json) contains only aggregate measurements.

### Corrections verified

- SDK `76820278` drains already queued receive fragments in bounded reads.
  The regression failed on the old code (2,048 bytes returned for 65,536 bytes
  already available) and passes after the correction. Short reads never wait
  for a full buffer. Partial frames, empty DATA, EOF and credit accounting are
  covered. All 51 SDK unit tests pass.
- The video delivery model no longer interprets intentionally stopped source
  media time, or a retained old frame's delay, as a growing decoder queue.
  The adapter regression previously kept video paused after audio recovered;
  it now releases only the one-fps floor. Frames acknowledged during a pause
  cannot authorize growth afterward. The adaptation/privacy subset passes
  186 tests; the changed Dart files analyze cleanly.
- Anonymous reports now include explicitly allowed numeric frame counters,
  native video pause/packetization flags, receive age and catch-up/discard
  counts. They still exclude raw/native logs, identifiers and nested peer maps.

### Physical results and unresolved defects

The clean production media engines and SDK were tested with real microphones
and cameras; temporary native probes were absent in the final call. No live
speech or acoustic assessment was supplied.

- Audio transmission from the Mac returned in subsequent runs, including a
  35-second audio call and two approximately 140-second video calls. These
  stayed connected. The earlier zero-transmission startup remains unexplained;
  no capture-driver fix is claimed.
- Before the paused-source correction, false video queue pressure appeared
  in 117/135 laptop samples and 115/135 phone samples. Afterward it appeared
  in **0/135** at either endpoint. Nevertheless, video still froze: only six
  laptop frames and three phone frames were sent, and decoded counters stopped
  progressing after the first approximately eleven seconds. Stale FPS values
  are not evidence of resumed video.
- Fresh audio damage continued to hold video. The final sampled receiver
  catch-up counters recorded 2,670 ms discarded on the laptop and 10,870 ms on
  the phone. The phone remained paused for 130/135 samples. The cause of this
  frequent audio catch-up needs investigation; disabling this safeguard or
  claiming fixed video is not justified by these measurements.
- Two further phone → laptop 32-MiB files completed with exact SHA-256 matches:
  102.61 s before receive coalescing and 126.49 s afterward, including offers.
  **No speed improvement is established.** The coalesced run still reproduced
  SDK receive-queue overflow, followed by thousands of close notifications and
  successful resumption. Coalescing does not provide missing end-to-end
  receive backpressure; file-stream closure remains an unresolved defect class.

The stream-close probes were isolated in a temporary SDK worktree, which was
removed. Apps and owned capture processes were stopped; the original phone APK
was restored with an exact hash match and its process was verified absent.
Test-file caches were removed without removing the user's profiles.

## Follow-up: automatic investigation

Source correction: Veil `c5ca76b9` (unreleased).

The audio Call had a fixed 96,000-bit/s estimator ceiling. With the observed
509-byte route overhead plus a 20-byte RTP header, a 40-ms packet costs
129,800 bit/s including the existing minimum speech payload. With the encoder's
20% reserve and strict integer comparison it needs at least 162,255 bit/s of
gross allocation. Consequently, the old ceiling could never fund the short
packet required to release video's packetization hold after a yield.

The source correction derives the ceiling from framing, retaining 96,000 bit/s
on lower-overhead paths. It changes the base WebRTC constraint: client
preferences alone can only tighten the original ceiling. No minimum allocation,
new bandwidth estimate, relay priority or override of measured audio pauses is
introduced. This removes a necessary recovery obstacle; it does not prove that
the network will supply enough allocation or that all video failures are fixed.

Automated regression evidence:

- Real Opus, including DTX: reproduce the 60-ms hold at the old relay ceiling;
  decode 40-ms packets and admit video after a funded recovery on 209-, 360-
  and 509-byte routes. A requested duration alone cannot release the hold.
- Observe the actual GoogCC constraints during live overhead changes: the
  larger ceiling reaches the controller and returns to 96,000 bit/s when
  framing shrinks. Independent audio/video routes remain separate. The BWE
  handover regression also passes: only genuine committed path changes reset
  their controllers; framing corrections preserve the current path estimate.
- Four SDK stream regressions pass. A closed stream's credit now reports
  `veil stream already closed`, preserving the FFI's existing closed-stream
  classification. A second stream still writes through the same IPC writer;
  a genuinely exited writer retains its distinct failure text. The earlier
  `veil IPC writer task closed` line alone cannot diagnose an IPC-task crash.

Additional physical calls could not validate recovery: the Mac emitted no audio
packets despite authorized microphone access and successful capture-start
status, and calls ended after approximately 21–35 seconds. Repeating with the
exact previous Mac media binary (verified against the saved build hash) also
produced zero outgoing audio. This is an additional unresolved capture/liveness
failure; it is not evidence that the corrected ceiling restored moving video.
The final base-constraint correction is validated by native tests, not a passing
physical call. The failing 32-MiB upload also remains unresolved.

Both endpoints were closed after these checks. The original phone APK was
restored again with an exact hash match; its process and the owned Mac process
were verified absent. No live speech was requested or assessed.

Two physical endpoints: a Mac laptop and an Android phone on cellular data,
with Wi-Fi disabled on the phone. The phone was awake and unlocked. Test profiles
were isolated from existing conversations. The stand frontend used xVeil
`a6b7524b`, Veil `0.11.44` / `c67cfe30` and hidden-volume `2.6.3`. It used ordinary
production media engines and real microphones/cameras, with synthetic media and
PCM injection disabled. Builds finished before network measurements began.

Only aggregate observations are retained here: no peer/device identifiers,
addresses, paths, keys, message contents, camera images or audio recordings.
[summary.json](summary.json) contains the numeric measurements. Private working
captures are excluded from the repository.

## Results

| Case | Observed result |
|---|---|
| Contact request, laptop → phone | Received in 4.15 s; accepted at both endpoints by 5.29 s. |
| Text, each direction | Observed within 0.57 s, one copy each. After the failed large upload both directions still delivered within 0.57 s. |
| 32 MiB, laptop → phone, no call | Completed in 104.50 s; SHA-256 matched. |
| 32 MiB, phone → laptop, no call | Timed out at 180 s. Observed partial file reached 3,932,160 bytes (3.75 MiB); repeated stream reopening did not complete it. The source file was not moved or modified. |
| Audio call, laptop → phone, then enable cameras | Ring in 1.10 s, active 1.02 s after answering. Remained connected for 149 s. Automatically moved P2P → relay at about 35.4 s; the harness requested no route change. Sustained video failed: 2 decoded phone → laptop frames, none in the other direction across sampled media epochs. |
| Initial video call, phone → laptop, after phone restart | Ring in 1.71 s, active 4.72 s after answering. Remained connected for 179 s. Brief relay/P2P transitions settled on relay. The phone decoded 11 early laptop frames, then stopped progressing after about 14.3 s. No phone frames reached the laptop. |
| Audio-only call with two simultaneous 1 MiB files | Call remained P2P for 90 s, without ending unexpectedly. Both files eventually passed SHA-256, taking about 106 s from transfer start; completion was after hangup. |

The first 4 MiB simultaneous-transfer attempt was canceled by the harness before
completion. It is unscored as a product failure. The smaller-file recheck waited
for completion and for its request threads to exit.

## Evidence and remaining questions

### File upload

The receive side logged resume offsets, EOF mid-piece and subsequent attempts
that failed to obtain a manifest. The sending phone reported the fixed SDK
failure `veil IPC writer task closed`, a payload-write idle timeout and later an
onion-stream driver closure. These establish failure in the stream path; they
do not establish which network or application condition caused its first stall.

The ongoing ability to send short messages and establish calls after the failed
upload separates this observation from a complete node/process outage. The
32 MiB reverse transfer remains a failing case.

### Call media

The first automatic relay recovery followed a native audio-receive age above
3 seconds after cameras were enabled. Media counters were grouped by media epoch
so handover resets are not mistaken for an entire call's totals. Reported FPS
was not used as proof of moving video: frame counters stopped advancing while a
stale nonzero FPS value remained visible in one run.

Cameras continued capturing on Android while video transmission was held. Native
`audio_packetization_video_hold` / `video_send_paused` stayed set for most video
samples, with 60-ms audio packetization. This identifies a local admission gate
that requires investigation, including whether audio adaptation can release it
under these conditions. It does not prove that the gate caused the original
network/audio interruption.

Measured jitter-buffer-plus-device audio delay:

| Call | Laptop median / maximum | Phone median / maximum |
|---|---|---|
| First call with camera enable and handover | 10 / 198 ms | 151 / 1657 ms |
| Reverse video call | 32 / 242 ms | 151 / 303 ms |
| Audio-only recheck | 10 / 140 ms | 142 / 201 ms |

These are local buffer measurements, not end-to-end acoustic delay. Live speech,
headphone loudness and intelligibility were not assessed. The observed network
and one endpoint pair do not isolate the carrier as the cause of either defect.

## Cleanup

- All calls ended and owned log-capture processes exited.
- Owned Mac stand process exited; the installed Mac app was not replaced.
- Phone test caches were removed.
- The original phone APK was restored in place, with an exact SHA-256 match,
  preserving existing application data. Restored version: `0.13.88`, code `2107`.
- The phone app process was absent after restoration; the owned ADB forward was
  removed.
