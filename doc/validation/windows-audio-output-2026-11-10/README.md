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

The new selector/picker was subsequently tested using a provenance-checked
Windows build. The owner confirmed live voice in both directions. One roughly
ten-minute call survived ten output switches. Five more completed call lifecycles
each passed two switches, with both capture and playout startup observed. These
twenty switches were checked for API success and call continuity; human audibility
after switching was not confirmed because the owner missed that listening window.

Locking the QA application after those calls exposed a separate release blocker:
an unhandled WinRT exception from notification cancellation. A debugger captured
the second-chance exception. The real application was not affected.

`test/native/windows_audio_com_lifetime_probe.cpp` isolates engine construction
and destruction from Flutter, profiles, microphones, playback and the network.
It loads a real media DLL with a separate transport stub and compares the caller's
COM apartment and context before construction, after construction and after
destruction. With candidate DLL
`065ef10f6738ac02f4ccf3ff213dab7979285185795196a8aa702bcae59ec64c`,
all four cases (direct/group engine, STA/MTA caller) preserved COM on creation
but corrupted it on destruction (exit 1 in each case).

The Windows ADM was created on its dedicated thread, but the final reference
was released on the caller. Its COM initializer therefore uninitialized the
caller's apartment. The candidate now retains a lifetime reference until other
media state and queues are destroyed, then releases it synchronously on the ADM
thread. Both engine types and construction-error cleanup use this rule. Eight
portable lifetime checks pass, including under ASan/UBSan. The tracked probe was
compiled with MSVC and rerun against both DLLs: four original cases fail and all
four repaired cases pass. The repaired DLL is
`979912337dc536a06c74727c990e3875f96a80d01734f35183a47975c7aa3edb`,
from [engine CI 42819906067](https://github.com/veilnetwork/xVeil/actions/runs/42819906067).
The binary hash, source digest, SDK revision and exported ABI were verified.

With that exact library actually loaded, three further application cycles each
completed a call, two output switches, hangup, lock and password unlock. Both
capture/playout startup results were checked. A final live call on the system
output was confirmed audible in both directions by the owner, without synthetic
speech or recordings. The final notification-cancelling lock also succeeded.
The stand's other native libraries and frozen Windows frontend did not change
during this native lifetime qualification.

One old-library QA process exited with `0xc0000409` after an output switch; its
cause is unknown, and neither the route diagnosis nor this patch is claimed to
explain that exit. It did not repeat during the roughly ten-minute control call
or subsequent calls.

Started QA applications, owned helpers and forwarding were closed after the
series, with process checks. The real Windows application remained running.
Raw reports, settings, endpoint names, identity IDs, host details and debugger
material remain outside version control.
