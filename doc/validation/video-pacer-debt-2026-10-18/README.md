# Video pacing debt reproduction

This retains a component counterexample and a **rejected first candidate**.
The corrected v2 is integrated in the native builders; see the qualification
below. These tests use the real pinned WebRTC pacer and field-trial parser.
No phone, network, codec, relay or audio workload participates.

The existing 4x / 25-ms video profile sends fourteen 1012-byte packets in its
normal high-rate burst. Its rate then changes from 4x900 to 4x15 kbit/s, and a
fresh 412-byte packet arrives one millisecond later. Existing byte debt becomes
a long wait at the new rate: **836 ms**. All fifteen packets survive in order.
The assertion requires the fresh packet within 50 ms and deliberately fails.

```sh
TMPDIR=/private/tmp/ python3 doc/validation/video-pacer-debt-2026-10-18/run.py
```

The rejected `candidate.patch` bounds pre-existing media debt on a rate decrease using the
existing queue-time/debt limits. Compiling that one upstream translation unit
before the unchanged archive makes this same case pass at **0 ms**, still with
all packets/ordering preserved. The original WebRTC checkout/archive is never
modified by the runner. This first candidate regresses the queued-frame case
from **24 to 574 ms**, so it must not be shipped. To reproduce its limited
original result with the local Mac bundle:

```sh
pacer_repro_dir="$(mktemp -d /private/tmp/xveil-pacer.XXXXXX)"
mkdir -p "$pacer_repro_dir/modules/pacing"
cp /Users/<user>/Projects/veilnetwork/webrtc-checkout/src/modules/pacing/pacing_controller.cc "$pacer_repro_dir/modules/pacing/"
patch -d "$pacer_repro_dir" -p1 < doc/validation/video-pacer-debt-2026-10-18/candidate.patch
TMPDIR=/private/tmp/ python3 doc/validation/video-pacer-debt-2026-10-18/run.py --pacing-source "$pacer_repro_dir/modules/pacing/pacing_controller.cc"
```

The runner honors `WEBRTC_SRC` / `WEBRTC_OUT`, like the existing native tests.
Its default is the local Mac arm64 checkout.

## Corrected v2

`candidate-v2.patch` caps debt when the **adjusted** media rate decreases,
including when a temporary queue-rate boost ends. Capping only in
`SetPacerConfig` missed that second transition. The unchanged SDK archive is
linked after the replacement object. Private header hashes are checked before
compiling; ordinary Mac and Android builds and their unchanged public exports
were verified. Linux, Windows and iOS builders are updated but not built here.

The retained `matrix-results.json` includes both failures and the v2 result.
The full matrix also asserts packet counts, payload bytes and FIFO, with runtime
assertions enabled. It covers steady/increasing/decreasing rates, queued data,
unpaced audio and accounted audio. Run the production override regression:

```sh
TMPDIR=/private/tmp/ python3 third_party/veil/flutter/veil_media/test/run_video_pacing_debt_smoke.py
TMPDIR=/private/tmp/ python3 third_party/veil/flutter/veil_media/test/run_video_pacing_debt_smoke.py --common-compile-flags
```

The original 360-s shared-FIFO audio/video/file qualification also passed with
this exact v2 source. Actual calls still show separate relay-video stalls and
larger sampled pacer queues. This fix does not establish the cause of every
physical freeze or prove acoustic/headset quality. Full evidence and limits:
[`call-pacer-debt-fix-2026-10-18.json`](../call-pacer-debt-fix-2026-10-18.json).
