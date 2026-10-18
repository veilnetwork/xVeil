# Video pacing debt reproduction

This is a component counterexample and an **unqualified candidate**, not a
production fix. It uses the real pinned WebRTC pacer and field-trial parser.
No phone, network, codec, relay or audio workload participates.

The existing 4x / 25-ms video profile sends fourteen 1012-byte packets in its
normal high-rate burst. Its rate then changes from 4x900 to 4x15 kbit/s, and a
fresh 412-byte packet arrives one millisecond later. Existing byte debt becomes
a long wait at the new rate: **836 ms**. All fifteen packets survive in order.
The assertion requires the fresh packet within 50 ms and deliberately fails.

```sh
TMPDIR=/private/tmp/ python3 doc/validation/video-pacer-debt-2026-10-18/run.py
```

The candidate bounds pre-existing media debt on a rate decrease using the
existing queue-time/debt limits. Compiling that one upstream translation unit
before the unchanged archive makes this same case pass at **0 ms**, still with
all packets/ordering preserved. The original WebRTC checkout/archive is never
modified by the runner. To review the candidate with the local Mac bundle:

```sh
pacer_repro_dir="$(mktemp -d /private/tmp/xveil-pacer.XXXXXX)"
mkdir -p "$pacer_repro_dir/modules/pacing"
cp /Users/vart/Projects/veilnetwork/webrtc-checkout/src/modules/pacing/pacing_controller.cc "$pacer_repro_dir/modules/pacing/"
patch -d "$pacer_repro_dir" -p1 < doc/validation/video-pacer-debt-2026-10-18/candidate.patch
TMPDIR=/private/tmp/ python3 doc/validation/video-pacer-debt-2026-10-18/run.py --pacing-source "$pacer_repro_dir/modules/pacing/pacing_controller.cc"
```

The runner honors `WEBRTC_SRC` / `WEBRTC_OUT`, like the existing native tests.
Its default is the local Mac arm64 checkout. This source is not compiled into
Veil's normal build. Required next work: verify steady rates, increasing rates,
queued work and low-rate primary behavior; make the dependency fix reproducible
for supported native bundles; then measure actual calls and the original shared
FIFO audio/video/file workload. This example alone does not prove the cause of
every physical freeze, a sound improvement, or a safe production pacing policy.
