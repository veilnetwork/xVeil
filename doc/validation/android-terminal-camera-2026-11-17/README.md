# Camera2 terminal stop must reach the live call state

Base: `dd78fc67`. This follows the
[Android camera startup outcomes](../direct-android-camera-outcome-2026-11-17/README.md).
It does not attribute the original Windows 10 camera report.

## Confirmed mechanism

The native Android capturer explicitly stops on a current Camera2 device error
or disconnection and exposes camera_running=false. The Dart Camera2 bridge
already consumes that status, clears its own texture/preview and stops its stats
timer. The media controller observed only desktop capture termination, leaving
camera ON and the peer capture announcement unchanged after the Android stop.

The added fixture uses real AndroidNativeCallCamera, VeilCallMediaController and
CallService. Only the MethodChannel camera platform and media/transport engines
are controlled; there is no physical camera or JNI frame transfer. The platform
returns successful startup, then a terminal false status. Explicitly advancing
the existing periodic callbacks proves the outcome without waiting for a frame
timeout or making a latency claim.

On the base, **one assertion failure and four passing controls** distinguish
boolean false from true, missing status, integer zero and the string "false".
The failure is cameraOn=true after the real bridge has removed its preview.
The corrected baseline includes each value's runtime type in its test name;
an earlier invocation's duplicate bool/string display names are not counted as
additional evidence.

## Change

The existing one-second media observation now also checks the current owned
Camera2 source's explicit terminal status. It requires the same owned engine/call,
camera ON and no pending/live screen share, and emits the existing scoped camera
failure feedback once. The live call and video receive are retained. Turning ON
again first joins the old source's stop fence and then starts a fresh source on
the same engine.

Android does not use the C++ engine's camera_capturing field: its camera is owned
by Camera2/plugin. Missing/malformed source stats and lack of frames prove no
termination. A terminal observation cannot report against a removed source or an
intentional OFF. Existing bridge generation/preview checks continue to reject
late stats from a replaced lens.

An intermediate candidate still read C++ stats before checking Camera2 and missed
the terminal state when that unrelated read threw. One additional assertion
failure isolated the gap. Android source observation now precedes that read
inside the existing guarded periodic callback; no new polling timer is added.

The anonymous cameraStopped evidence contains cameraCapturing=0. It copies no
source ID, error text, peer/call identifier or image. Desktop terminal handling
retains its existing integer-state and numeric-evidence contract.

## Qualification and limits

Six new controller cases cover the terminal stop/retry, an unreadable C++ stats
path, and four nonterminal/malformed controls. They check one failure notice,
active call, peer capture OFF, a fresh preview/source after retry and no failure
notice from subsequent intentional OFF. Their engine reports camera_capturing=0
to ensure an absent Android C++ capturer is never mistaken for source death.

**661 tests passed, zero skipped**, across fifteen related suites: direct media
startup/FSM, route operations/qualification, camera intent, group media/FSM/
teardown, native Camera2 bridge start/stats lifecycles, plugin capture/selection/
retirement and diagnostic journal. All **30 direct cases also pass with
diagnostics enabled**, including the actual categorical terminal-event export
and private fixture text/ID exclusion. `dart analyze lib test` reports no issues
after using the requested null-aware map-entry syntax in the fixture.

All tests are headless with TMPDIR=/private/tmp/. No app window, input injection,
physical camera, source recording, native build, installed-app change or seed
operation is used. The existing user's Mac app stays running. Native Camera2
hardware disconnection and plugin-source runtime termination are separate
qualification scopes. This is control-flow evidence; the user's Windows 10
waiting-preview complaint remains open. Nothing is pushed or released.
