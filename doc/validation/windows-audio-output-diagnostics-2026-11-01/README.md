# Windows audio-output diagnostics — 2026-11-01

## Confirmed diagnostic gaps

Native output samples alone cannot distinguish an audible call from a muted
Windows application session, a muted endpoint, or output on another default
device. Previously the anonymous application report lacked these observations;
the earlier stand's external mixer probe was not part of the product.

A failed audio start could also end the call before the first periodic native
sample. The report retained only generic startup failure, losing the separate
capture/playout outcomes. Startup now immediately retains the two allowlisted
integer results when available, including failed receive-only mute setup.

## Implementation and privacy

Opt-in diagnostics sample a bundled, read-only `xveil_audio_probe.exe` on Windows
at most once per ten seconds during a call and once when exporting a report.
Ordinary builds do not launch it. The helper inspects only its parent process;
it accepts no target process argument and needs no elevation. It does not change
volume, mute or routing, open audio capture, write files, or use the network.

The helper reports whether there are zero, one or multiple active render
sessions. Only an unambiguous single session yields app/endpoint volume and mute
observations and comparisons with ordinary/communications default outputs.
Incomplete enumeration is failure, not a guessed zero. Device names, endpoint
IDs, process IDs, paths and exception messages are not exported. Internal
endpoint IDs are used only for equality comparisons.

COM calls execute outside Flutter. A native hard deadline terminates the helper
after 1.5 seconds even if a device provider hangs or its caller disappears.
Dart independently bounds waiting/output and retains one unfinished reader at
most; repeated report requests cannot spawn unbounded helpers. Late call samples
are discarded after their owning engine/call ends.

`callAudioOutput` retains the last in-call observation separately from
`audioOutputSnapshot` at export time. Post-call absence of an active audio
session therefore does not overwrite the mixer evidence from the call. All
fields pass a fixed typed/ranged allowlist. Unsupported/malformed observations
remain distinguishable from measured mute or zero volume.

## Verification

- 300 related tests passed: sampler/privacy, journal, actual direct-call media
  controller, group media, call service and error journal. Scenarios cover
  disabled/non-Windows operation, timeout sharing, no duplicate unfinished
  reader, stale ownership, malformed data, valid zero/false values, and separate
  call/export evidence. Dart analysis is clean.
- Normal/opt-in standalone AOT diagnostic privacy checks passed, including
  canaries for private strings and process IDs. Workflow pin/branch guards pass.
- The helper's actual CMake target built on the Windows host; the generated
  install rules include it. Production serializer/watchdog tests compiled with
  MSVC `/W4 /WX`: valid zero/false preservation, cancelled deadline and forced
  hard-deadline exit 124 passed. These checks are wired into Windows CI/release.
- A rebuilt Windows Dart AOT plus the new helper ran against published 0.13.94
  native libraries. A real Mac → Windows P2P call reached active, exchanged audio,
  and emitted output samples. A selected Windows snapshot had 183 received audio
  packets, 339,840 emitted output samples and output band 3.
- After hangup, the real Settings clipboard export retained **session=one,
  app volume=100%, endpoint volume=56%, both mute=false, both default-output
  comparisons=true** for the call. Its separate export-time observation reported
  **session=none**. The actual helper, parent attribution, pipe completion,
  application sampling and post-call export therefore ran together successfully.

The host is Windows 11, not a Windows 10 qualification. Runner/plugins are
frozen release binaries because ATL headers are unavailable; Dart AOT, Flutter
engine and helper were rebuilt. Mac uses the earlier explicitly versioned
control SDK `08b67a6e`; this is not qualification of a new Mac release or the
complete current multi-device/revoke matrix. A final Dart formatting pass is
whitespace-only relative to the physically tested production source.

No human listening, speech intelligibility or sound-pressure measurement was
performed. The owner's Poco → Windows no-audio report and NETCALL-01 remain
open; this round supplies missing evidence, not their proven cause or fix.
Android QA installation remains refused by the OS. Its main app, identities
and Wi-Fi/mobile-data settings were not changed in this round.

## Teardown

Both owned apps were stopped after call teardown; Windows scheduled tasks and
helper processes were checked absent. The owned SSH tunnel was closed and Mac
app/API/listening ports were checked free. The canonical networked QA profile
is retained without rolling back cryptographic state. Private logs, identities,
device labels and raw clipboard content are not included here. No push/release.
