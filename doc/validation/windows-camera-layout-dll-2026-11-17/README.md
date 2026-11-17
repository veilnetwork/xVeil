# Windows camera layout fix: full DLL and physical component qualification

This qualifies a freshly built Windows x64 component from Veil `33314eac`,
including the [layout validation fix](../windows-camera-layout-2026-11-17/README.md).
It does not replace an installed application or attribute the original Windows
10 camera report. No GUI window, focus change or input control was used.

## Build and provenance

The unchanged Windows wrapper builder compiles all ten native translation units
in an owned output directory. All 79 transferred producer inputs match their
recorded SHA-256 values before/after compilation and again before cleanup.
The source digest matches the checked-out tree:

```text
4bed5b6ba7edb408a6c85223906497c1c072874c018d318363696eeba5770ac4
```

The WebRTC SDK matches its selected pin and the manifest's library hash before
and after building. The prior isolated PowerShell 5.1 SDK setup adapter is reused:
only its single-entry JSON array handling differs. Extraction/header rebasing
is allowed; the generated compiler commands retain all other archived flags.
No installed SDK, global policy or product source is modified for preparation.

The resulting DLL is 5,963,264 bytes; its SHA-256 is:

```text
a81448b53467e81ede8f85d785039dc1d8e5b4958b0a4536ed3a9f04246048bd
```

The downloaded binary and provenance pass the source/binary verifier. The
previous DLL from `86a73c43` is independently rejected against current sources;
it is not reused as the candidate. The PE gate checks 107 exports and 107 Dart
lookups under its existing required/optional/sibling rules. The artifact
private-pattern check passes. These are separate from runtime capture tests.

## Physical control

The committed opt-in windows_camera_dll_probe.py loads the exact new DLL and an
isolated callback transport compiled from windows_camera_loopback_transport.cpp.
Two real engines encode/decode camera video in one process. There is no real
Veil node, authenticated peer, application profile or network call. Frames exist
only in transient memory and are not recorded. Audio capture/playout is not
started and the microphone is muted.

| Requested profile | Local updates before/after restart | Decoded updates before/after restart | Datagram attempts |
| --- | --- | --- | ---: |
| 352×198, 15 fps, 150 kbit/s | 10 / 10 | 10 / 10 | 30 |
| 640×360, 60 fps, 900 kbit/s | 11 / 11 | 10 / 10 | 42 |

**Both cases pass, exit 0.** The same engines remain alive across camera stop/
restart. The enabled diagnostics control also checks live MF stage/counters,
explicit stop, failure of a nonexistent selected source with no fresh counters,
and successful default-source restart. Requested FPS is not measured capture
rate; polling updates are not all encoded frames. No speed, color-quality,
audibility or packet-loss comparison is claimed.

The probe result matches the candidate binary hash, which is unchanged after
execution and cleanup verification. Runtime dependency source files remain
unchanged. The supervisor and its owned child use independent watchdogs;
loader error dialogs are disabled in the probe. Both producer/probe supervisors
finish, their children exit, and cleanup verifies zero owned processes.

The owned source, SDK extraction, compiler output and synthetic transport are
removed after marker/source/binary/SDK checks. The downloaded DLL/provenance and
qualification records remain private for packaging. The small owned source ZIP
is removed locally; the pre-existing SDK archive is retained. The user's existing
Mac app remains running and installed Windows/Android apps are untouched.

## Remaining scope

This physically qualifies ordinary camera capture/conversion/encoding/decoding,
restart and numeric diagnostics on the available Windows 11 camera with the
new layout guard. It does not force the malformed layouts covered by the prior
native fixture, prove support for every driver, or qualify the original Windows
10 hardware. Widgets, normal call signaling, real relay/P2P transport and an
installed AOT package remain separate checks.

The artifact is private. New immutable engine pins for supported targets and
final application packaging remain necessary before release; source-digest
checks stay enabled. Nothing was pushed, published or deployed to seeds.
