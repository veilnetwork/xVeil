# Drained queues and outstanding local source flight

## Scope and retained fix

The user deferred the strict 200 ms acoustic target and asked to focus on video
quality while audio is healthy. This cycle does not change that target, audio
buffer thresholds, frame lifetimes, relay behavior or pixel-sizing policy.

`SourceFlightPool::app_limited` cleared a secondary's blocked-send witness as
soon as its producer queue emptied. Real transmitted bytes could still be
unacknowledged. Their subsequent delivery therefore could not fund the local
flight window. The regression fails against the old implementation: expected
3601 bytes, received 2401.

The fix retains that witness while the drained queue still has outstanding
flight. QUIC reports actual DATA delivery before releasing that flight. When
both queue and flight finish, the witness is cleared; a second regression
checks that partial credit cannot buy a later send's window. Freshness,
current-window/reserve matching, the one-growth-per-RTT rule, route resets and
the independent normal QUIC congestion controller remain enforced.

This is local endpoint bookkeeping. No roles are disclosed on the wire and no
relay priority is added.

## Controlled result: video quality remains unresolved

Built from an SDK archive plus only the owned source file, excluding foreign
multi-device changes. The native media library retains the original pixel
guard and the previously committed frame diagnostics. The source-pressure
policy is root `ecab34f5`.

Conditions match the previous retained run: 360 measured seconds, three
isolated SDK/media workers, six media directions, a neutral 1024 kbit/s FIFO
relay, and three concurrent encrypted 512 KiB transfers.

| Measurement | Baseline | Candidate |
| --- | --- | --- |
| Synthetic audio markers delivered / missing | 2112 / 0 | 2112 / 0 |
| Peak marker delay | 200.22 ms | 200.17 ms |
| Complete files with matching hashes | 3 | 3 |
| Final-minute decoded FPS across six directions | 2.07–2.83 | 1.78–2.79 |
| Final resolution in all directions | 80×60 | 80×60 |
| Local flight window median / maximum | 5808 / 7260 bytes | 5808 / 7260 bytes |
| Outgoing datagrams expired | 2565 | 2715 |

All six final motion gates passed in both runs. The candidate's final selected
video budgets rose to 26–38 kbit/s and 3.75 FPS, but actual encoder targets were
25.2–29.4 kbit/s and its pixel cap remained in effect. This is not evidence of
an improvement in decoded quality or of increased local flight capacity.
Expiry counts have different offered traffic and are not normalized loss
rates. The bookkeeping defect is fixed; the practical video problem is not.

The complete native image/fanout/decode recorders were validated separately
with `--native-only`. That analysis explicitly marks SDK admission unaudited;
it does not identify which expired datagrams carried video or attribute loss
to a particular relay. The existing attribution evidence and limits remain in
`../video-frame-attribution-2026-10-20/README.md`.

The next investigation is recovery of the video allocation and pixel cap after
a reduction, using measured delivery rather than the acoustic target alone.
Do not infer physical presentation quality or speech intelligibility from
these synthetic markers and decoder counters.

## Verification

- Old implementation fails the new outstanding-flight regression.
- All 11 local flight tests pass with the fix.
- Full release library suite: 639 passed, 8 ignored, 0 failed.
- Production-feature FFI build, `dlopen`, 202 unchanged exports and ABI hash
  verification passed. Source/binary hashes are in `build-proof.json`.
- The strict 200 ms gate still fails; it was neither relaxed nor reported green.
- Workers, policy processes, fixture and helper were reaped; node stop results
  are all zero and no fixture sockets remain. Both early process snapshots
  and final summary PIDs were independently checked.
- Foreign root and SDK work was preserved; no push, release, relay update or
  physical phone call was performed in this cycle.

See `comparison.json`, `test-proof.json` and the cleanup proofs for details.
