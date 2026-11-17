# Group camera intent reaches capture ownership

Base: `85aa9592`. This follows the
[group hand-back fix](../group-share-handback-2026-11-17/README.md).
It is not attribution of the user's Windows 10 camera-start report.

## Confirmed wiring defect

During an active screen share, `GroupCallService.setCameraEnabled` changed its
Call snapshot but deliberately skipped the physical camera switch. It also
failed to tell the production media controller about that choice. The latter
retained `_cameraEnabled=true` from before sharing. After sharing ended with
camera OFF, another failed desktop screen start could restore that obsolete
camera choice through the production rollback path.

The integration fixture joins the real group FSM to the real
VeilGroupCallMediaController. Group membership/signaling, permissions and engine
I/O are controlled; no real camera is opened. On the exact base runtime, two
camera-OFF cases fail on an unexpected extra engine `startCamera` invocation:
screen start returns false or throws. Both camera-ON controls pass.

The group controller boundary now has `updateCameraIntent`, like the direct
call boundary. The service forwards the choice even when the screen owns the
source. The production implementation only remembers it: it does not switch
sources, clear the preview, stop sharing or open a camera. Rollback reads the
current choice. OFF→ON controls ensure the change does not merely disable all
restoration; subsequent successful share/hand-back remains usable.

## Android fallback and source guards

Android's failed-screen fallback called `_startAndroidCamera` without checking
the updated camera choice. To exercise this actual production branch on the
host without a phone, the controller now accepts test-only capture selection
and camera/screen factories. Production defaults remain Platform.isAndroid,
AndroidCameraCapture and createAndroidScreenCapture with the same capture
lifetime. No environment, preference or remote message selects these seams.

The seam-only Android baseline already contains the intent-wiring fix but no
new Android guards. It has two assertion failures and one passing ON control:
screen denial still creates another camera after OFF, and a deliberately retained
retired-camera callback still reaches the engine while screen capture owns it.
The latter is an adversarial callback boundary test, not proof that the actual
Android capturer emits such a callback after stopping.

Android camera start now requires the current engine, running video, camera
intent, an unoccupied camera slot and absence of active screen sharing. Frame
delivery also checks the captured media epoch and exact source object. After
the asynchronous start result, stale/refused sources are detached and stopped
without touching a replacement. Failed retirement remains with the source's
existing capture-lifetime owner; cleanup errors do not authorize frame delivery.

## Verification and limits

- Four desktop FSM/controller cases cover OFF/ON, refused/throwing screen start,
  no physical source switching while remembering intent, and later recovery.
- Seven injected Android cases cover denied screen capture with OFF/ON,
  rejected old callbacks with a positive screen-frame control, late successful
  camera start after OFF/stop/replacement, and refused-start cleanup. The late
  success/callback sources deliberately behave adversarially; their counters
  qualify controller ownership, not actual Camera plugin behavior.
- **453 related tests pass, zero skips**, across nine suites: group FSM,
  teardown, passive rooms, production group media with controlled engines,
  group overlay/audio/source-priority, direct FSM and route operations.
- `dart analyze lib test` is clean. Staged privacy and whitespace checks pass;
  unrelated formatter changes were excluded.

The Android capture selector changes only which capture branch the tests run.
Permission and foreground-service implementations still use the host OS; those
Android facilities and physical camera retirement are not qualified here. Engine
frame counters do not prove valid pixels, encoding, networking or rendering.
Initial camera intent across all permission/rebuild windows, group camera error
reporting and overlapping hardware operations remain separate verification work.

No GUI apps, focus changes, OS input, native builds, camera/microphone recording,
real profiles, phones, remote hosts or relays were used. Test services/sources
are disposed and test processes exit. The user's existing application stays
running; no installed package, push or release changes.
