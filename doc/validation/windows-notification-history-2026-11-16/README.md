# Portable Windows notification cancellation

A background native test confirmed a separate notification-lifetime defect:
`flutter_local_notifications_windows` 3.1.1 posts notifications for an unpackaged
application, but `cancel(id)` removes shown notifications only for MSIX identities.
An ended or answered call can therefore leave its notification in Action Center.
This does **not** establish why the reported Windows 10 installation showed no
incoming banner, nor does it resolve the camera complaint.

## Change

The Windows build assigns a nonempty `xveil` group to shown and scheduled toasts,
uses that group for updates, and removes shown notifications by tag/group. For an
unpackaged application, removal also supplies the application's AUMID. It never
clears another notification as a fallback.

The patch is applied to a generated compilation copy of the locked dependency's
FFI source. The shared pub cache, Dart ABI and dependency lock remain unchanged.
The normalized source digest is checked before patching; a dependency change
requires review instead of silently compiling a potentially obsolete patch.

Windows documents the tag/group/application-ID overload in
[ToastNotificationHistory.Remove](https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationhistory.remove).
A separate native control rejected an empty group; adding only an AUMID to the
old groupless notification is insufficient.

## Validation

Two DLLs were built from the same dependency source and compiler environment:
one unchanged and one with the production CMake patch. Neither replaced the
installed application's libraries. An independent Windows history observer,
rather than the plugin's unsupported portable active-list API, supplied the
oracle.

| Native check | Original | Patched |
| --- | --- | --- |
| Two shown toasts recorded by Windows | 2 | 2 |
| After cancelling the first | 2, first remains | 1, only the second remains |
| Update an existing toast | Success | Success |
| Cancel one of two scheduled toasts | Only the other remains | Only the other remains |
| Clear/cleanup | No shown or scheduled toasts | No shown or scheduled toasts |

The committed probe was itself run against both DLLs: the original failed the
individual-cancellation assertion and the candidate passed. Both runs removed
their own fresh QA registration and left DLL bytes unchanged. Earlier independent
controls also verified `Clear(AUMID)` and grouped `Remove(tag, group, AUMID)`.

Additional checks:

- Windows configure accepts CRLF source without altering the dependency file.
- A modified dependency source fails configure with the explicit digest guard.
  A separate configure/build check verifies that changing it after configuration
  triggers reconfiguration and rejects the drift before compilation.
- 29 Flutter notification service, race, call-session and identity checks pass.
- No application window was started, activated or controlled. Test processes
  exited; QA history and registrations were removed.

The machine runs Windows 11. The native test runs in SSH's noninteractive session;
it proves OS history operations, **not** visible banners in the user's session,
notification actions, cold COM activation or original Windows 10 behavior.
MSIX was not tested. Old groupless notifications cannot be individually removed
by this new grouped operation; normal application-wide cleanup still applies.
No release or deployment was performed.

## Reproduce on Windows

Run an unpackaged Python process against the notification DLL from a Windows
build. Supply a new JSON output path:

```powershell
python test/native/windows_notification_history_probe.py --dll <plugin-DLL> --result <new-result.json>
```

The probe posts only silent synthetic QA notifications with fresh identities.
Its supervisor removes their history, schedules and registration, including when
the native child fails. It does not launch xVeil or exercise user input.
