# Video adaptation audit: hypotheses and rejected experiments

## Scope and retained work

The user deferred the strict 200 ms acoustic target and requested investigation
of video deterioration while audio sounds good. That fixture gate is preserved
in the evidence; it is not the adaptation trigger. Current production buffer
policy uses a separate 300 ms ceiling and confirms growth for three seconds.
Acoustic marker delay and native buffer occupancy are different measurements.

**No experimental scheduling/adaptation change from this cycle is retained.**
The only retained SDK code adds counters to the existing optional once-per-second
endpoint flight diagnostic: fresh/stale delivery, demand, paid credit, RTT wait,
growth and drained-demand reasons. Counters use the existing mutex and introduce
no per-ACK I/O. Admission conditions, flight limits and feedback semantics are
unchanged. No relay classification/priority, wire or ABI change is introduced.
The earlier native measured-audio feature remains at the existing commits.
The retained diagnostic source passes 639 session/bootstrap tests (8 ignored)
from a clean export excluding foreign WIP; no new retained FFI binary is built.

## Concrete problems established

1. **Several controls act on video independently.** The application ladder,
   native pixel/byte budget and SDK shared flight window each constrain quality.
   A healthy-looking current audio buffer does not mean the other controls have
   recovered. FPS, dimensions, target bitrate, actual encoder bitrate and
   transport demand must be observed together.
2. **The primary-path delay guard used to restrain DATA also contracts video flight.** Its
   comment describes DATA-only restraint. More than 1000 events occur in the
   retained group baseline. Removing that side effect reproduces the intended
   local invariant (3601 no longer falls to 2401 bytes), but does not establish
   a safe system correction: group video remains sparse and audio recovery
   increases. The original behavior is restored pending coordinated protection.
3. **One healthy observation can fund multiple growths via first-hop ACKs.** A
   regression reproduces 4801 bytes instead of 3601 before a new assessment.
   Requiring a new healthy observation per step passes that regression, but
   alone does not resolve group quality. This policy experiment is restored too.
4. **Known small audio damage is not a distinct transport growth hold.** It
   currently returns healthy to avoid contracting transport credit. Replacing
   that report with unknown passes a semantic hold test and 227 related Flutter
   tests, but expires the healthy admission lease and changes DATA allowances.
   The real ordinary capture then has worse FPS and unfinished files. Unknown
   cannot safely stand for “maintain the current load.” That experiment is
   reverted, including its proposed tests.

These are observations and interface constraints, not three shipped fixes.
Semantic red tests document a proposed contract; a green unit test alone did
not validate the complete policy. Rejected source patches are retained here
against root aa63ee8b / SDK b88f3fa7 for reproducibility, not automatic use.

## Controlled measurements

Real Opus/VP8, synthetic 320x240 input, neutral aggregate 1024 kbit/s FIFO,
competing encrypted 512 KiB files; independent same-host runs, not a cellular
or speech-listening proof. Ordinary captures measure 180 seconds; group captures
360 seconds with six media directions and three isolated media workers.

| Ordinary capture | Final-minute decoded FPS, two directions | Final dimensions | File hashes complete |
| --- | --- | --- | --- |
| Retained baseline | 6.98 / 12.02 | 320x240 / 320x240 | 2/2 |
| DATA-window separation alone | 1.41 / 1.42 | 320x240 / 160x120 | 2/2 |
| Plus one growth per new assessment | 14.92 / 14.86 | 320x240 / 320x240 | 2/2 |
| Plus unknown-as-short-hold | 2.34 / 3.02 | 240x180 / 240x180 | 0/2 by cutoff |

| Group capture | Final-minute decoded FPS range | Final motion gates | Summed audio recovery discards after 60 s | Marker peak |
| --- | --- | --- | --- | --- |
| Retained baseline | 1.19-1.90 | 4/6 | 200 ms | 230.11 ms |
| DATA-window separation alone | 0.97-1.24 | 6/6 | 1850 ms | 350.09 ms |
| Plus one growth per new assessment | 1.00-2.05 | 6/6 | 1770 ms | 370.19 ms |

The baseline retains 320x240 on all six paths. The assessment-gated group
experiment ends at 160x120 to 240x180, still around 1-2 FPS.
All three completed group captures deliver all 2112 audio markers and all
three files. Audio discard sums span three workers, not one listener's outage.
Raw datagram expiry totals are counts, not normalized loss rates. The strict
acoustic gate remains failed in the group evidence. It was not used as the
reason to reject the video experiments: group quality did not improve as a
whole, and unknown-as-hold regressed ordinary FPS and file completion.
Occasional audio/image damage is allowed; there is no zero-damage criterion.

The final attempted group run was interrupted once the ordinary unknown-hold
regression was established. Its partial data is not a completed group result;
the subsequent screen-slot run was not started. The prior completed screen-slot
capture uses synthetic input through the screen transport, not real display
capture, and has unfinished files. These limitations are explicit in the JSON.

## Next implementation boundary

A local source assessment needs separate meanings for (a) measured audio
pressure, (b) maintaining the current admitted load while withholding growth,
and (c) unknown/expired feedback. A hold must preserve existing DATA credit and
normal primary protection, forbid new flight/pixel growth, and expire cleanly.
It must not renew a congestion reduction or masquerade as missing telemetry.
The current boolean local feedback interface cannot express that distinction.

Only after this separation should the DATA/video coupling be changed. Verify
short damage, recovery and sustained overload with the same ordinary/group
captures; compare final FPS and dimensions, file progress and audio recovery.
The 200 ms acoustic target stays deferred. Physical video, actual screen
presentation, live speech and headphone loudness remain outside these captures.

All owned fixture/helper/policy processes were reaped, node stops returned zero,
and sockets closed, including the interrupted capture. Foreign root/SDK WIP is
preserved. No physical apps, installations, push, release or relay update were
performed in this cycle. The broader audio/video goal remains unfinished.
