# Physical video recovery with intentionally muted audio

## Scope and retained change

Follow-up to [brief-burst video recovery](../video-soft-burst-recovery-2026-10-20/README.md).
The strict 200 ms acoustic target remains deferred. This cycle focuses on video;
it does not change the 300 ms measured buffer ceiling or claim complete call
quality qualification.

Mac/Blackview captured a separate reproducible limiter. After the user muted
both microphones, adaptation correctly stopped requiring audio playout reports,
but applied the audio-style 80 ms jitter downgrade and 40 ms recovery rails to
video RTP reports. Actual downgrade observations had 0% reported loss, 9–13 ms
RTT, no video RTP drop/loss event and 82–189 ms video jitter. The phone repeatedly
returned to the bottom rung. This was unrelated to the deferred acoustic target.

When **neither audio direction is expected**, video packet jitter alone now
neither cuts the camera nor blocks its earned recovery. Measured video delivery,
RTT, loss, drops, receiver reports and the acknowledged bounded source ramp still
govern recovery. Any expected audio direction retains the previous jitter guard.
Relays, metadata, transport scheduling, crypto and native binaries are unchanged.

## Regression checks

- Two new regressions fail against the old adapter: sparse-frame jitter prevents
  recovery from one FPS, and jitter alone cuts a working rung to the floor.
- Recorded jitter values with low RTT and no loss now allow recovery. The loss,
  high-RTT and missing-report cases still withhold growth.
- Separate send-only and receive-only audio cases retain the jitter recovery
  guard. All **133 adapter tests pass**; targeted Dart analysis passes.
- The APK and Mac app contain the changed production Dart code. Native SDK,
  media and storage libraries match the preceding verified artifacts. Only
  formatting changed in the production adapter after the build; independent
  whitespace-equivalence and both source digests are recorded.

## Physical setup and initial failures

Android BV6600Pro, Android 11/API 30, Wi-Fi; Mac on its ordinary network.
Private profile AOT builds with explicit debug-hook opt-in; no production release.
The installed Android app was updated in place with the same signer, preserving
storage. The Mac app is an isolated ad-hoc QA copy with no VPN entitlement.
All Mac app launches used `TMPDIR=/private/tmp/`.

The first attempt never rang within 45 seconds. The old phone test identity's
delegated signing credential had expired approximately 19 hours earlier; native
logs rejected certificate signing. Validation was not bypassed. Its renewal
requires its recovery secret, which was unavailable in the fixture.

A separate one-shot QA profile was therefore created using the user's earlier
authorization to create a test identity. Its recovery material remains in the
private fixture cache, outside this report. The previous profile was retained.
The new credential was published with a future expiry. Its first call attempt
also never rang: bootstrap attempts failed because obfs4 descriptors lacked the
required PSK. Previously verified QUIC fleet descriptors were added through the
app's existing `/add_peer` path. Sessions and rendezvous registration then formed.
This is an explicit stand configuration step, not a fix or qualification of
fresh-install bootstrap or expired-device renewal.

## Captures

The baseline uses root `7fae40df`; the candidate adds the video-only jitter rule.
Both use SDK `19004dc5`. Both run for 300 seconds after answering, enable cameras
at 30 seconds, and begin with real audio capture. In the baseline the user muted
the phone at ~35.6 s and Mac at ~37.6 s; the user subsequently confirmed doing so.
The repeat explicitly mutes both through the API at ~35 s. Speech intelligibility
and headphone loudness are not assessed.

Ring delays were 0.123 s and 0.227 s. Both calls remained active through the
measurement. The baseline explicitly requests relay recovery at ~150.6 s.
The candidate switches automatically: phone ~39.7 s, Mac ~41.8 s. The later
explicit recovery request returns false because it is already on relay.
The cause of that early automatic transition is not established here.

Follow-up: [capture health timestamp validation](../capture-health-timestamp-2026-10-20/README.md)
identifies and fixes the demonstrated mute-induced false fallback. The original
capture and its limitations below are retained.

### Received frame progress

Rates below are **counter differences divided by actual elapsed observation
time**, not averages of the API's `remote_frame_fps` field. That field retains
a cumulative rate and is unsuitable for measuring a short interval or proving
continued frame arrival. Raw counter endpoints and elapsed times are retained
in `physical-summary.json`. Columns describe the receiving device.

| Capture/window | Video rendered on Mac | Video rendered on phone |
| --- | ---: | ---: |
| Baseline, 60–120 s | 0.87 FPS | 1.47 FPS |
| Baseline, 120–150 s | 0.90 FPS | 5.88 FPS |
| Baseline, 180–215 s | 0.67 FPS | 5.87 FPS |
| Baseline, 270–300 s | 0.48 FPS | 26.68 FPS |
| Candidate, 60–120 s | 8.67 FPS | 8.52 FPS |
| Candidate, 120–150 s | 18.88 FPS | 25.68 FPS |
| Candidate, 180–215 s | 2.22 FPS | 1.89 FPS |
| Candidate, 270–300 s | 6.91 FPS | 10.22 FPS |

The candidate escapes the low rung, subsequently reduces quality on fresh video
loss evidence, and recovers within the same call. Captured candidate cuts include
fresh persistent-loss events and 16%, 40% or 66% video loss observations; jitter
alone no longer causes a cut. This does **not** establish stable full-rate video
or a matched-route performance improvement: route timing, real network loss and
file load differ between captures. The baseline also eventually recovers in one
direction; that result is retained rather than describing both as pinned forever.

### Files, screen and audio limits

The baseline's file helper raised `TypeError` before either offer was sent:
its query function's positional `path` argument collided with a query parameter
named `path`. No baseline file-load claim is made. The repeat fixes the helper
parameter name, starts two concurrent 512 KiB files at 90 seconds, and both
received SHA-256 hashes match their respective sources.

The screen control was exercised, but neither capture observed `screenOn=true`.
This is not a successful physical screen-capture qualification. The native phone
diagnostic-file copy also failed in these two captures; evidence comes from
call-state samples, app diagnostics and logcat, not an asserted native-file trace.

No acoustic marker capture or live speech assessment was performed. Muted audio
cannot establish sound quality under recovered high-rate video. Remaining work
includes that case, actual screen capture and the early automatic route change.

## Provenance and cleanup

Package/source/log hashes, original failed attempts and raw result paths are
recorded in `proof.json`. `physical-summary.json` retains loss-driven cuts and
both captures' limitations. Recovery credentials and hook keys are excluded.

All owned phone app processes, Mac app/helper PIDs, file threads, graph-query
helpers and ADB forwards were independently checked absent after the captures.
Mac apps required SIGKILL after the fixture's bounded graceful-exit wait; this
is recorded as exit -9, not a successful graceful exit. Foreign root/SDK work
was preserved. No push, release or relay mutation was performed in this cycle.
