# Immediate capture health must be newer than the last heartbeat

## Reproduced failure and cause

Follow-up to the early automatic P2P-to-relay transition recorded in
[the muted-video capture](../video-muted-jitter-2026-10-20/README.md).

Both physical endpoints logged `established direct audio stalled` about three
seconds after their microphones were intentionally muted. Video/control still
flowed, but the receiving CallService still believed the peer microphone was on.
The following periodic heartbeat finally reported the mute, after fallback had
already started.

`_announceCapture` sends an immediate health message on a capture change. The
ordinary MessagingService path stamps a missing `sentAtMs`; the compact call
control path bypasses MessagingService and sends the supplied encoding directly.
The immediate message therefore had no timestamp. `_foldPeerCapture` treated it
as time zero and rejected it after an already timestamped heartbeat. Periodic
health already supplied a timestamp, which explains the five-second correction
and the race with the three-second established-audio outage guard.

## Correction

CallService stamps its locally originated health messages **before choosing the
carrier**, preserving an existing timestamp. The same capture/urgent feedback
message is ordered consistently on ordinary signaling and separate compact call
control. Relayed own-device messages are excluded from this local stamping path.
Wire format, receiver replay/order checks, audio outage deadlines, privacy policy,
relay behavior, native libraries and audio/video source budgets are unchanged.

## Verification

A paired CallService regression connects two compact-control media fixtures via
the actual CallSignal encoder/decoder. It first establishes P2P, actual audio and
timestamped peer capture/readiness, then mutes both microphones while video and
control remain alive. The old code switches to relay; the correction retains
P2P and records the newer mute. Replayed earlier unmuted heartbeats cannot undo
it. A subsequent real unmute followed by established audio stopping still
triggers relay recovery: the outage protection remains effective.

All **308 tests** in `call_service_test.dart`, `call_bitrate_adapter_test.dart`
and `call_audio_feedback_schedule_test.dart` pass. Targeted Dart analysis and
diff whitespace checks pass. No native source changed or new Rust/native test
claim is made.

## Physical repeat

Same controlled Mac/Blackview profiles and network as the preceding capture.
Android is BV6600Pro, Android 11/API 30, on Wi-Fi. Private profile AOT builds use
the exact changed Dart sources; SDK/media/storage libraries are retained.
Android update 12622 uses the same signer and preserves existing profiles.
The Mac QA app has no VPN entitlement and runs with `TMPDIR=/private/tmp/`.
The fresh phone QA profile retains the earlier explicit QUIC bootstrap setup.

| Event | Actual observation |
| --- | --- |
| Call starts | P2P, ring delay 0.142 s |
| Cameras enabled | ~30 s, both directions |
| Both microphones intentionally muted | 35.749 s |
| Both peers observed muted | 38.002 s, next polling sample |
| Before the explicit relay request | Both endpoints remain P2P throughout |
| Two concurrent 512 KiB files at ~90 s | Both received SHA-256 hashes match |
| Explicit relay request | 150.637 s, accepted |
| Observed route changes | Mac 150.637 s, phone 158.438 s |
| End of measurement | 269.834 s, both calls still active |

Neither endpoint logs an established-audio stall in this repeat. The Mac's
generic relay-recovery log belongs to the explicit diagnostic request; it is
not labeled an automatic fallback. The prior run's early automatic transition
at ~40 s does not recur.

Actual rendered-frame progress, computed from counter differences over elapsed
observation time, is retained in `physical-summary.json`:

| Window | Received/rendered on Mac | Received/rendered on phone |
| --- | ---: | ---: |
| P2P, 40–90 s | 5.44 FPS | 5.11 FPS |
| P2P with file transfers, 90–145 s | 4.59 FPS | 4.37 FPS |
| Relay, 180–225 s | 7.26 FPS | 3.28 FPS |
| Relay, 225–270 s | 4.83 FPS | 3.06 FPS |

These variable rates are not a stable full-quality video result or a claim of
an FPS improvement from timestamping. This repeat qualifies the demonstrated
false-fallback cause. It begins with audio capture, but both microphones are
intentionally off from ~35 s onward. It does not qualify intelligibility,
headphone loudness, or audio priority during the later file/video load. The
strict 200 ms acoustic target remains deferred. Actual screen capture and
broader audio-with-video contention verification remain open.

## Evidence and cleanup

`proof.json` records the parent commits, exact compiled source hashes, regression
failure/success logs, passing checks and private raw capture hashes/paths.
Package proofs identify the two installed/launched AOT artifacts. Hook keys and
recovery material are not included. The phone native diagnostic-file copy failed;
the physical result uses API counters, app diagnostics and logcat, not an asserted
native diagnostic-file trace.

All owned host app/helper PIDs and the Android app process were checked absent,
file threads exited and the owned ADB forward was removed. The Mac app required
SIGKILL after the bounded graceful-exit wait; exit -9 is retained. Foreign
root/SDK work fingerprints are unchanged. No push, release or relay mutation.
