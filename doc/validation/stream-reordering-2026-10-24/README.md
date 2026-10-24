# Recent reordering evidence, 2026-10-24

SDK `fa7123f5`. This is a follow-up to the rebuilt Android host qualification in
[report29](../report29-2026-10-24/README.md).

## Confirmed defect and change

The original-packet RACK reordering maximum had no ageing: one delayed original
could raise the loss-detection allowance for the remainder of a long stream,
even after the slower route/queue disappeared. During the preceding cellular
run the allowance grew to 7.185 seconds; the unchanged 32 MiB/180 s gate failed
with a 16 MiB receiver high-water mark. That network run alone does not isolate
how much of its delay came from this defect.

Recent original-packet reordering now uses the same 30-second evidence horizon
as the existing RACK timing history. One maximum per one-second bucket bounds
metadata to 31 entries. The partial oldest bucket is retained conservatively
for at most one extra second, preserving all still-recent slow-route evidence.
ACK/timer loss detection expires old observations; a current smaller route
delta survives removal of an older larger maximum. The explicit carrier-set
multipath floor and matched D-SACK/RTO contract are unchanged. Added numeric
observed/duplicate components to the existing local debug snapshot.

## Verification

* All **148** stream unit/integration/simulation tests passed, no ignores.
  This includes steady two-route reordering, real loss under reordering,
  repeated repairs, local admission/backlog, duplication and byte integrity.
* A regression proves a six-second historical spike expires, retains a more
  recent 400 ms route delta, repairs a newly lost head at the current deadline,
  and preserves the carrier's explicit floor. Another bounds metadata over
  continuous observations. With expiry disabled the regression fails; the
  exact production source was then restored.
* Clippy with warnings denied and the workspace format check passed.
* Fresh guarded macOS/Android release-native libraries were staged into the
  rebuilt `b88ea12c` stand frontends. Dart/media binaries and C ABI are unchanged;
  no media/PCM test drivers were used. These are opt-in QA profile builds, not
  release-packaging qualification.
* After abrupt Android restart, a new message arrived exactly once. The
  **32 MiB Mac → cellular Android file completed in 112.960 s**, full SHA-256
  match, within the original **180 s** gate. P2P was denied for this check.
* Live counters show the observed reordering maximum decreasing as older
  buckets expire. This confirms the new branch executes on the physical path.
  The two runs are not a controlled causal throughput comparison.
* Signed authorization documents remained in Android's encrypted container;
  copied checkpoints again passed native signature/binding restore.
* Original APK independently pulled/hash-verified after restoration; Mac/phone
  processes and captures absent, forwarding removed, profile pointer and debug
  property restored. No calls, audio devices or servers were changed.

`summary.json` contains only approved numeric/boolean/software-revision/hash
fields. Identifiers, keys, container snapshots and raw logs remain private.
This does not qualify all provider paths, Windows, audio/video or the complete
multi-device matrix.
