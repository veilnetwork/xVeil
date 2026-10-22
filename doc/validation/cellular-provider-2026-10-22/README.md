# Cellular call and file validation — 2026-10-22

**Status: failures reproduced; production fixes pending.**

## Latest follow-up: paused-source feedback and receive queues

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
