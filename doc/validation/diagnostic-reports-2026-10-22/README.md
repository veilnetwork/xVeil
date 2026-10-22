# Anonymous diagnostic reports — 2026-10-22

## Purpose and boundary

Extend the existing Windows/Linux `-debug` distribution archives and add Android
`-debug.apk` counterparts. These remain release AOT builds, using the production
network and ordinary native engines. They enable `XVEIL_DIAGNOSTICS`, not raw
Dart logging, the stand control API, synthetic media or special relay handling.

The explicit clipboard/file actions export source-owned event/metric enums,
finite numeric values, dependency versions, exception classes and package/Dart
source locations. They do not serialize exception text, native JSON wholesale,
peer-keyed nested stats, identifiers, payloads, addresses, filenames or paths.
User exports also omit the profile flag and absolute error timestamps.
Free-form OS descriptions are reduced to a numeric release or `unknown`.

Reports contain operational metadata (relative timings, counts and call/device
state), not a proof of mathematical unlinkability. The journal is process-local,
bounded to 360 sampled events plus fixed-cardinality aggregate counters. It
survives navigation and lock, not process exit/crash. Nothing is uploaded or
written to a log file automatically. File export writes only the chosen JSON.
Existing error summaries remain bounded to 50 distinct errors.

## What can be distinguished

| Reported failure | Evidence |
|---|---|
| Identity setup returns to welcome | Startup/onboarding stages, error class and source frames; numeric OS error where available. Existing-container refusal remains a typed exception. |
| One-way messaging | Live transport acceptance/failure, native numeric error codes, inbound admission, message retries and actual delivery ACKs. Transport acceptance alone is not delivery. |
| Silent call | Call setup/route/end state, audio start result, source payload packet/byte counts, receive counts, mute state, delay/loss/concealment and worker stalls. |
| File download stalls | Failure, resume/parking attempts, eligible-source counts and completion; error type/OS code for failed resume. |
| Android loses availability | Lifecycle transitions and foreground-service start/stop results, independent of assumed OS exemptions. |

Counters aggregate traffic within this process; no peer or message identifiers
are added to correlate it. They cannot identify the selected hardware device or
certify acoustic audibility. A failed native audio start is not, by itself,
proof of a particular Windows driver or permission fault. These changes provide
evidence for the five 0.13.88 reports; they do not claim to fix all five.

## Verification

- Unit adversarial inputs: private paths, IDs, strings, nested peer maps,
  unknown numeric fields, non-finite/oversized values and objects that must
  never be stringified are excluded from the media report.
- Clipboard and user-selected JSON export use the same report builder. Export
  checks include a real `FileSystemException` carrying a private path/message:
  only its class and numeric OS code leave the device.
- Disabled collectors retain no events or counters. Bounded sampling preserves
  event totals and reports ring evictions.
- Builder dry runs enforce release AOT and reject combinations with raw
  logging, stand hooks and native media test hooks.
- A compiled Dart AOT probe contains `xveil-diagnostics/1`, emits the typed
  event and does not contain the `xveil-debug.log` sink. The release workflow
  applies the same binary check to each diagnostic snapshot/APK ABI.
- Full ordinary Flutter suite, a diagnostic-enabled call/messaging/export suite,
  analyzer, workflow guards and Python build-support checks are run for this
  change. No physical Windows reproduction is claimed.

## Reporter instructions

Use the new `-debug` artifact, reproduce the problem, then copy the diagnostic
report in Settings or save `xveil-diagnostics.json` with the adjacent save icon.
The welcome screen and startup failure screen also expose the report. Export
before restarting. For one-way delivery or calls, send a report from both ends.
Do not send the raw log files from older diagnostic archives as anonymous data.

Local results: full Flutter suite 5762 passed, 154 skipped; diagnostic-enabled
call/messaging/export suite 264 passed; analyzer and build-support checks clean.
The export/privacy checks are rerun after final metadata minimization.
