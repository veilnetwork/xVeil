# Retrying audio stop after a stalled worker — 24 October 2026

SDK fix `858d84d9`; baseline `19171c10`.

## Confirmed defect

Both direct and group audio stop cleared `audio_running` before scheduling
stream destruction. A worker scheduling timeout cancelled that destruction.
The next stop returned success immediately because the flag was already false,
even though the Call still owned its sender and receiver. A retry after worker
recovery also returned success without cleaning up those two streams.

The fake-ADM regression reproduces this against unchanged baseline production
code: first stop returns STATE, repeated stop returns OK, and **two real audio
streams remain after the recovery retry**. The baseline test exits nonzero;
it still explicitly cleans up its streams before destroying the fixture.

## Change and verification

Stop always attempts worker cleanup, including after an earlier scheduling
failure. Capture/playout are still stopped before worker cleanup; only a completed
cleanup can return success. Repeated successful stops remain safe.
No new public API or device behavior was introduced.

For both direct and group engines, the same regression now confirms:

* Two actual 10-second scheduling timeouts both return STATE while the worker
  is held. The cancelled tasks do not run later.
* Both real streams remain until the explicit retry on the released worker;
  that retry returns OK and removes both streams.
* Restart creates the sender/receiver again, a healthy stop removes them, and
  another healthy stop succeeds with no streams left.
* The muted/receive-only/stopped-video real Opus/VP8 regression still passes.
* Production libraries build for macOS arm64 and Android arm64, with the same
  105 public media exports, no test exports and no synthetic-video marker.

The targeted test uses the existing counting ADM, actual Call/Opus streams and
held queues. It opens no physical capture/playout device or network endpoint.
Test processes exited; no phone, user profile, installed app or server changed.
This lifecycle fix does not establish a cause for every reported silent call.
Private logs and binaries are excluded; bounded results/hashes are in summary.json.
