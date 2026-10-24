# Safe media destruction after worker timeout — 24 October 2026

SDK fix `de769239`; baseline `858d84d9`.

## Reproduced defect

The direct and group destructors ignored failed stream stops and reset their
WebRTC Calls anyway. A cancelled stop leaves streams in Call. The pinned
WebRTC destructor has unconditional fatal checks requiring those streams to
be gone; its destruction also belongs on its worker queue.

Four independent fake-device subprocesses reproduce the actual fatal check
against baseline production code: direct/group engine, held audio/video worker.
Each has real audio/video streams, a 10-second scheduling timeout, and a queue
scheduled to recover after 12.5 seconds. **All four baseline processes abort**
on a live-stream check before safely returning. The private host runner reaps
each child and verifies the specific fatal reason.

## Fix

Both destructors retain their state after a cancelled stop and retry until
stream cleanup completes. Both capture paths receive their initial stop before
retrying a worker. After fencing receive callbacks, each Call is reset on its
own worker, with the same cancellation/lifetime handshake on delayed scheduling.
No detached cleanup thread or leaked Call is substituted for destruction.

This preserves synchronous destruction: if a worker never recovers, cleanup
waits for it. Task-queue destruction already joins workers; this fix does not
promise a bounded shutdown of a permanently stuck worker. The C API documents
that callers must not hold locks needed by media callbacks during destruction.

## Verification

* The same four cases now exit zero after about 12.5 seconds, with both audio
  and video Calls destroyed safely. See bounded elapsed values in summary.json.
* The direct/group audio-stop retry and real Opus/VP8 muted/sparse-video suites
  pass against the same corrected library.
* The committed native test runner bounds each child to 30 seconds and kills/
  reaps a timed-out child; its single-case execution was also checked.
* macOS arm64 and Android arm64 production builds keep exactly the previous
  105 public media exports, with no test exports or synthetic-video marker.
* Test subprocesses exited. No physical microphone, speaker, camera, phone,
  installed app, user profile, network endpoint or relay was used/changed.

This establishes a local teardown crash and its fix. It does not identify the
cause of every physical-call freeze or Windows silent-audio report. Private
logs/binaries are excluded from the repository.
