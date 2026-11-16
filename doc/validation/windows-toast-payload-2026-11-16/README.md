# Oversized Windows notification terminates the native caller

Confirmed on the available Windows 11 computer with the real Windows Dart
notification plugin. A valid notification containing 65,536 ASCII body
characters terminates the Flutter test before its Dart catch/finally completes.
The previous short-notification control appears in Windows history normally.

An independent WinRT control accepts the XML and constructs the notification,
then `ToastNotifier.Show` rejects it with HRESULT **0x803E0115**. Microsoft names
this [WPN_E_NOTIFICATION_SIZE](https://learn.microsoft.com/en-us/windows/win32/com/com-error-codes-9):
notification content is too large. The plugin catches XML-load errors but lets
construction/delivery HRESULT exceptions escape its C ABI. The Flutter command
ends with 79 and reports an incomplete test; 79 is the tool exit, not a claimed
native exception code. The controlled Dart result stops at the oversized call.

## Applicability

Incoming direct-message notices pass the stored body to the notification binder;
group previews and Space publication bodies can also supply long text. Full
notification preview forwards that text to `NotificationService.show`, which
previously imposed no display limit. Its Dart catch cannot contain this native
exception. Generic hidden previews do not include the incoming message body.

This is a confirmed failure in the application's notification path. It is **not**
proof of the cause of the reported Windows 10 incoming-call banner failure or
camera failure. Neither report is closed by this finding.

## Change

- Windows previews have conservative UTF-8/XML budgets: title 384 bytes and body
  2,048 bytes. Clipping preserves complete grapheme clusters and marks truncation
  with an ellipsis. XML entity expansion and whitespace are budgeted; a single
  enormous grapheme cannot bypass the limit. Stored chat content is unchanged.
- Routing payloads are kept intact. A payload exceeding its 1,024-byte escaped
  budget refuses the alert instead of creating a truncated destination. This
  preserves the existing false-post/notification-owner contract.
- The existing source-digest-guarded CMake patch now contains WinRT HRESULT
  exceptions across the complete native bool `showNotification` and
  `scheduleNotification` calls, including construction and delivery. Rejection
  returns false through the existing ABI. Dart can report failure and keep the
  backend usable. Other native methods are not changed by this exception fix.

The shared pub cache, plugin dependency lock, media-engine pins, protocols,
message storage and non-Windows presentation paths are unchanged.

## Executable evidence

| Control | Outcome |
| --- | --- |
| Original real Dart plugin, short notification | OS history contains it |
| Original real Dart plugin, 64-KiB body | Test terminates during native show |
| Independent OS control of that body | XML/constructor succeed; Show rejects with 0x803E0115 |
| Patched native DLL, old application service | Raw rejection is a caught Dart exception; long service preview still fails to post |
| Patched native DLL and current application service | Raw rejection is contained; all three long preview cases post successfully |

The credited service red uses the previous committed service source with the
patched DLL. It reaches `service-preview` after proving short display and raw
error containment. Thus catching the exception alone does not satisfy the
intended visible-preview behavior. The final run changes that service source
and passes the same committed native fixture.

Final system-history observations:

| Input family | Shown count | XML bytes | Routing payload preserved |
| --- | ---: | ---: | --- |
| ASCII | 1 | 2,713 | Yes |
| XML metacharacters | 1 | 2,711 | Yes |
| Emoji graphemes | 1 | 2,708 | Yes |

The final fixture also refuses a huge routing token, posts subsequent short
notifications, and removes only one of two notifications before clearing all.
An independent Python/C ABI run passes raw oversized show **and schedule**
rejection, normal show/update, individual history/schedule cancellation and
clear. Both supervisors finish with empty QA history/schedules and remove only
their own fresh registrations.

The uploaded application service, preview helper, logger and committed native
fixture inputs are hash-checked before and after execution; copies of those
inputs populate the disposable Flutter workspace. The minimal
Flutter workspace uses the existing qualified SDK and dependency sources,
including the real notification plugin. All **44** selected dependency versions
match the current project; **73** relevant notification/FFI Dart source files
also match by hash. Unrelated SQLite is absent from this fixture's dependency
closure; the application runtime code under test is not replaced by mocks.
The real Windows backend only overrides its sound setting to make QA toasts
silent. Aumid/GUID derive from the production QA namespace function.

Local checks: **40 pass / 1 physical-case skip** across the preview and related
notification suites. The disabled native opt-in is a skip, not a pass. Changed
Dart-source analysis is clean. The native DLL compiles with the production CMake
patch and the same locked plugin source; no media/Rust rebuild is involved.

## Excluded preparation and hypothesis

A direct Dart/WinRT control observes an existing MTA apartment both before and
after initialization and successfully posts a short notification. The hypothesis
that this host lacked COM initialization is rejected; no COM initialization or
thread-apartment change is added to the application.

The first Python supervisor could not import a neighboring helper under its
isolated interpreter and exited before plugin use. Another fixture attempt used
Flutter test's default Android platform dispatch; the independent Windows
history check rejected its empty result. Neither is a product red or credited
successful native test. The committed Windows fixture explicitly selects the
real host's Windows dispatch and restores the prior framework override afterward.

## Reproduce and scope

`test/native/windows_toast_payload_native_test.dart` is opt-in and requires a
supervisor that supplies a fresh `dart-qa-<12 hex digits>` build namespace,
verified plugin DLL, result-file path and independent cleanup. It refuses to
initialize a backend without a QA namespace. See its environment inputs and
`XVEIL_NATIVE_WINDOWS_TOAST_TEST` / `XVEIL_WINDOWS_NOTIFICATION_NAMESPACE` defines.
Use an outer process-tree watchdog: an older native DLL can terminate the test
before Dart cleanup. The Python `windows_notification_history_probe.py` also
covers oversized native show/schedule rejection.

Tests run headlessly without application windows, focus changes or input
injection. No real profile/container, phone, chat or production registration is
opened. Temporary DLL copies and all owned Windows workspaces are removed after
private evidence collection; installed libraries and the retained qualified
package are unchanged. This does not qualify visible banners/actions in the
interactive Windows session, the full call bridge, Windows 10 hardware, or an
installed AOT build. No push, deployment or release occurs.
