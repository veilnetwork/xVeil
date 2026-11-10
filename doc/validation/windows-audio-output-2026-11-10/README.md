# Windows audio output: live-speech diagnosis and candidate

## Confirmed configuration difference

An isolated Windows QA profile and an isolated Android QA application used fresh
paired identities. The real application's profile and settings were read but not
changed. Calls used the frozen application frontend at `8799087a` and the installed
release's native libraries; the production call-audio Dart sources matched the
released frontend. No speech recordings were made.

The Windows media DLL was
`c178c0e370f4a004c9c9fa509fd4f2e1418920891decede8365e2d83b9844df4`;
the Android media library was
`2b658b34a809507ca75a6747f1430e7b79d3d0ad67480fa61476d1d594c68181`.
Staged libraries were checked against the installed release. Loaded Windows
modules were also checked during the earlier saved-output call.

| Live-speech case | Windows output | Human result |
| --- | --- | --- |
| A, fresh process | OS output, no saved override | Voice audible both ways after enabling the Windows microphone |
| B, fresh process | Existing application's saved output copied into QA only | Windows could not be heard playing Android speech |
| A, fresh process | Saved QA override removed | Voice audible both ways with both microphones enabled |

The saved output differed from the OS output. During the successful first A case,
the Windows audio session was on the OS console/communications endpoint, unmuted.
The per-process Windows output meter observed a nonzero rendered signal without
recording PCM. A later OS-observer attempt timed out and is not credited as an
additional endpoint observation.

In the forward-only controls the Windows microphone was deliberately muted;
silence on Android in those controls is expected, not a second delivery failure.
The owner confirmed live speech in both directions twice on the OS output.
Earlier synthetic-speech runs do **not** qualify ordinary microphone speech.
A missed output-switch listening window and a debugger-paused attempt are excluded.
These are configuration contrasts, not latency benchmarks or evidence about all
Windows audio hardware.

## Product changes

- Windows enumerates an explicit `system-default` output role. It selects the OS
  output role, rather than treating numeric device zero as the default.
- The call picker localizes that choice. Returning to it clears the saved output
  override; an unavailable saved output falls back to the advertised OS role.
- The picker marks an output only after native selection succeeds. It no longer
  marks the first enumerated hardware device as if its use had been observed.
- Windows switching checks stop, device selection, initialization and restart.
  A failed switch attempts to restore the previous output and returns failure.
  Idle selection leaves initialization to audio startup. Other platforms retain
  their existing native switching implementation.
- The authenticated local QA API can enumerate and select speakers. Previously a
  `speaker` request fell through to microphone selection; that path was not used
  for the preceding diagnosis.

## Checks and remaining qualification

The extracted previous native switching transaction failed 21 of 25 assertions;
the production helper now passes all 25. Coverage includes the OS role, numeric
selection, idle configuration, malformed IDs, stop failure, failed initialization
and restart, recovery of the previous output, and bounded failed recovery.

Before the Dart change, two of the three speaker-restore cases failed: no saved
choice and an unavailable saved choice. The custom-output case passed. With the
candidate, the media startup and device-picker suites pass all 66 tests, including
failed selection, clearing an override, and an engine without role metadata.
Analyzer: no issues in the six changed call/test files checked.

Physical testing of the **new** native output selector and the completed picker is
still required. The preceding audible calls used the old released media library.
One old-library QA process exited with `0xc0000409` after an output switch; its
cause is unknown, and neither the route diagnosis nor this patch is claimed to
explain that exit. It did not repeat during the roughly ten-minute control call
or subsequent calls. Candidate switching and teardown remain qualification work.

Started QA applications, owned helpers and forwarding were closed after the
series, with process checks. The real Windows application remained running.
Raw reports, settings, endpoint names, identity IDs, host details and debugger
material remain outside version control.
