# Call platform activity and packet-delay localization — 2026-10-20

## Change

Active direct calls already requested the Android low-latency Wi-Fi lock (plus
its screen-off fallback). macOS had no corresponding process activity, and the
group media controller did not request the Android network activity at all.

A shared, serialized identity-owner registry now holds platform activity while
call media owns it. Duplicate acquisition is idempotent; one owner cannot release
another. Failed/unsupported acquisition retains no owner and can retry. Group
startup failure releases its ownership. Direct route repairs retain ownership
until the call actually ends.

On macOS `CallActivity` pairs `ProcessInfo.beginActivity` and `endActivity`, using
`userInitiated` and `latencyCritical` only during the call; destruction also ends
the activity. Display sleep and persistent system settings are not changed.
[Apple documents the activity options](https://developer.apple.com/documentation/foundation/processinfo/activityoptions)
and [latencyCritical](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/latencycritical).
Android uses the existing native Wi-Fi implementation. No relay/wire priorities,
transport format, or server configuration changed.

This fixes an uncovered local power-policy lifecycle. It does **not** establish
that App Nap or Wi-Fi power management caused the earlier network delay.

## Verification

- 229 Flutter tests passed: registry races/failures, call-service regressions and
  group media. Group checks cover successful stop, failed initial audio budget,
  and a thrown native audio start. FakeAsync fixtures inject an explicit no-op
  activity instead of making real platform calls.
- Targeted Flutter analysis: no issues. Xcode project syntax and diff whitespace
  checks passed. macOS and Android profile builds succeeded.
- A compiled standalone Swift probe checked actual owned OS assertions:
  `0 → 1 → 1 → 0 → 1 → 0` across acquire, duplicate, release, reacquire and
  destruction. Its process exited normally. `native-activity-proof.json` retains
  only the probe's own assertion lines.
- A real Mac ↔ Blackview call used the normal call controllers and QA synthetic
  ADM, with cameras enabled after 30 s, two 32 MiB file requests after 45 s,
  cancellation after 90 s, and observation through 150 s. No physical microphone
  or speaker was used. All samples retained P2P.
- During the real call, macOS had exactly one owned `xVeil active call` assertion;
  Android had the existing low-latency and screen-off Wi-Fi locks. Both call
  diagnostics reported active ownership. Idle and post-hangup checks found no
  owned OS assertion or Wi-Fi lock, while applications were still running.
- All 290 expected tone transitions in the 5–150 s analysis interval matched.
  With video and file activity, point p95/max were **101/120 ms** Mac → phone and
  **101/141 ms** phone → Mac. The observed clock envelope for the largest reverse
  delay was **132–149 ms**. PCM blocks are 10 ms and unsampled clock drift is not
  proven bounded. These are decoded synthetic PCM timings, not hardware loudness
  or a live-speech quality verdict.

Actual outgoing FPS uses counter differences over each interval, rather than
whole-call average counters:

| Approximate interval (s) | Mac outgoing FPS | Phone outgoing FPS |
|---|---:|---:|
| 31–45 | 0.69 | 0.90 |
| 45–75 | 3.80 | 4.97 |
| 75–91 | 5.92 | 6.88 |
| 91–120 | 14.71 | 16.71 |
| 120–150 | 28.52 | 29.00 |

The policy progressed from startup level 4 to level 0 without a sampled downward
transition. The initial low FPS and roughly 107–111 s ramp after enabling video
remain visible; this run does not qualify fast video startup or sustained scene
quality. It is also not a controlled power-management A/B comparison: no causal
speedup is attributed to the new activity. Live group calls and background /
screen-off power behavior were not physically qualified in this cycle.

Native traces contained zero session violations or peer bans, and two expected
closed-stream messages on the phone. Neither requested 32 MiB file completed
before cancellation. HTTP download waiters still ended with RemoteDisconnected
on app shutdown; this run verifies coexistence/cancellation, not full file
throughput or completion. The API waiter cancellation behavior remains open.

## Earlier long packet wait

`previous-udp-proof.json` joins 19 ciphertext datagrams by digest and byte length
between the prior phone primary QUIC connection 37 send log and Mac receive log
in source seconds 47–53. Platform monotonic / wall-clock pairs and sampled PCM
clock brackets align the two endpoints. `join-previous-udp.py` reproduces the
calculation from private retained baseline traces; raw logs are not committed.

The worst matched 300-byte datagram has a point send-log → receiver-kernel wait
of about **581 ms** (observed clock envelope **573–591 ms**); kernel → userspace is
**0.84 ms**. This localizes the major wait before Mac kernel delivery. A send log
does not prove NIC departure, and this cannot distinguish sender scheduling,
Wi-Fi, network, or their power behavior. It does not identify a relay/provider
fault or prove that the new macOS activity cures it.

## Provenance and cleanup

The disposable QA app export includes the changed call-controller sources and
macOS activity, with SDK `70a99c1f`. Native media/SDK/storage/PCM-driver inputs and
Android signer were pinned byte-for-byte to QA 12625. Current QA build is 12626;
no foreign root or SDK edits were included. A first staging attempt copied
framework symlinks as ordinary directories and failed signing; it was discarded
before launch, then restaged preserving symlinks and verified successfully.

The ordinary phone APK 12622 was restored; its installed SHA-256 matches the
original. Independent checks found all owned app/helper PIDs and the ADB forward
absent, including secondary Android package processes. Mac exit still required
SIGKILL after its grace period (exit -9); activity had already been released
before process termination. No push or release. The broader audio/video/screen /
data isolation goal remains active.
