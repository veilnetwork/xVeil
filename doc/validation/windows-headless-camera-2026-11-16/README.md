# Windows headless camera control

The repeated Windows 10 report remains open: the camera is listed but its
preview stays at “waiting for video.” This check uses the available Windows 11
host and its physical camera. It does not establish the cause on the reporter's
computer or qualify the normal application's capture path.

## Method

A console-only C ABI probe loads an exact copy of the media DLL from the
[qualified Release package](../windows-release-aot-storage-package-2026-11-16/README.md),
pinned to `engine-2026.11.12.2`. The DLL hash is checked before and after use.
The probe creates sender and receiver engines with synthetic identities.
A separate, explicitly synthetic transport DLL delivers RTP/RTCP to the other
engine's registered callback in the same process. That DLL replaces no file in
the actual application package and communicates with no real peer.

Each profile runs for approximately five seconds, stops/restarts its camera
without replacing either engine, then runs for another five seconds. Both local
preview and remote decoded frame sequences must increase after restart.
Camera start, stop and restart must all return success; both engines must be
destroyed and the process must exit successfully.

No application window, GUI session activation, mouse/keyboard injection,
microphone capture or speaker playback is started. Camera pixels exist only in
the engines' transient frame buffers; frames, video and audio are not recorded.
No user profile, accepted contact, device selection or system camera setting is
changed. This is callback-loopback encode/decode, **not a network call**.

## Results

| Requested profile | Local sequence before/after restart | Decoded sequence before/after restart | Exit |
|---|---:|---:|---:|
| 352×198, 15 fps, 150 kbit/s | 47 → 94 | 46 → 94 | 0 |
| 640×360, 60 fps, 900 kbit/s | 94 → 189 | 93 → 188 | 0 |

**Two passing profile controls.** Requested FPS is not a claim of the camera's
actual capture rate. The asynchronous frame counters are not packet-loss or
latency measurements. These controls demonstrate fresh capture, encode, decode
and restart on this host, not UI rendering or delivery through Veil relays.

Two preparation attempts are excluded: the first did not resolve the compiler
from its prepared child environment; the second supervisor caught normal
`SystemExit(0)` and incorrectly replaced its result with a harness failure.
The final execution uses the corrected executable lookup and exception handler.

The observer's initial unanchored `remote_sequence` regex matched the earlier
`first_remote_sequence` field. The C++ exit oracle already required real progress
in both phases. The observer was corrected to match exactly one line beginning
with `remote_sequence`; the table uses that corrected reading of the retained
final logs. This correction is not an additional test sample.

## Teardown and remaining scope

The owned supervisor and probe processes have exited. The successful probe's
program copies/compiler outputs are deleted. Copies from the first failed setup
are separately removed only after their six file hashes match the reviewed
inputs. All 45 actual package file hashes remain unchanged.

No product camera code is changed on the strength of this passing control.
The original Windows 10 camera/driver, normal application device selection,
preview widget and network video remain unqualified by this check. The complaint
is not closed, and no release or push is performed.
