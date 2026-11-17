# Incoming-call fallback after native Windows hide/minimize

Base: `655a614d`. This extends the
[bounded window-query checks](../windows-call-window-query-2026-11-17/README.md).
It qualifies a controlled presentation failure, not the original Windows 10
user report or visible delivery of a native toast.

## Reproduction

The pinned window_manager 0.5.2 Windows plugin emits `hide` from WM_SHOWWINDOW
and `minimize` from WM_SIZE. Both reach its generic `onWindowEvent` listener.
The bridge previously refreshed on these events without retaining their meaning.
If Flutter still reported resumed and the subsequent visibility query failed or
missed its deadline, the fallback treated the window as foreground and posted
no incoming-call notification.

The exact base runtime has **four assertion failures and seven passing controls**
in eleven new widget cases:

| Native event | Visibility result | Base result |
| --- | --- | --- |
| hide | PlatformException | No alert while ringing |
| hide | Pending through the production watchdog | No alert while ringing |
| minimize | PlatformException | No alert while ringing |
| minimize | Pending through the production watchdog | No alert while ringing |

The cases deliver plugin events through the incoming MethodChannel, keep the
binding resumed, and inject an offer through the real CallService. The service
is confirmed ringing before checking posts. Pending queries use virtual time,
not elapsed host/OS latency. NotificationService is a recording stand-in; no
native window, tray or toast is created by this fixture.

## Change

Native hiding evidence now supplements lifecycle state only as fallback for the
bounded Windows query. Successful native visibility/focus observations remain
decisive. Show, restore or focus events discard the old hiding evidence; they
do not themselves assert that a visible window has focus. A successful foreground
observation also discards it, covering a missed show/restore event.

Existing request/session ownership, late-result cancellation, notification
privacy and post retry limits remain in use. No window show, focus or activation
operation is introduced.

## Qualification and limits

**26 window-visibility cases pass; the full selected series has 176 passed,
zero skipped** across thirteen suites. The series covers notification startup,
serialized post/cancel races, policy/payload/reply handling, call actions and
sessions, tray-close behavior, Windows notification identity and diagnostic
journal contracts. `dart analyze lib test` reports no issues.

Controls include ending the call before the watchdog, retiring pending queries,
clearing the hiding evidence through show/restore/focus, a successful foreground
observation overriding it, and query failure without any hiding evidence.
All unexpected outbound window-manager operations fail the new fixture.

These are headless Flutter component checks with Windows platform selection on
the macOS host. No Mac/Windows app was launched or activated, and no keyboard or
mouse input was sent. The existing user's Mac app was left running untouched.
Actual native query failure on the reporting Windows 10 machine has not been
observed. Its missing call notification, camera and one-way-contact complaints
remain unattributed. No native library, engine pin, release artifact or deployed
seed was changed; nothing was pushed or released.
