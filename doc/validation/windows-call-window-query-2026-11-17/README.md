# Incoming Windows call alerts: bounded window observation

Base: `b428a995`. Confirmed application-side wait, fixed locally without push
or release. The original Windows 10 notification report remains unattributed.

## Confirmed mechanism

The call-alert bridge waited without a deadline for `window_manager.isVisible`
and `isFocused`. Even when Flutter lifecycle already reported a background
application, an unanswered optional window query suppressed the OS post for
the entire ringing interval.

Two assertion-red controls on the base demonstrate this, one per pending
method, alongside six passing controls. They drive the actual CallService and
lifecycle bridge, keep the platform future pending and advance the virtual
clock. No elapsed real-network/plugin time is used as an oracle.

## Change and preserved behavior

One window-query owner now supplies a first result within 250 ms, using the
same lifecycle fallback previously used for a query exception. A resumed or
unknown lifecycle still does not itself authorize a background notification.
This bounds only window observation, not notification-backend initialization,
optional caller metadata lookup or actual OS presentation.

The eventual native answer is retained. If the same request is current, it is
consumed directly rather than starting the slow query again. Thus a delayed
native hidden/unfocused observation can still post while lifecycle says
resumed; a later foreground observation can withdraw the alert. Returning the
same desired state does not enqueue another notification.

Retirement, a newer window/lifecycle/call update or widget disposal cancels the
owner, releases its first-result awaiter and prevents a late visibility result
from starting a focus query. The continuation is created outside the call's
closure context with only a weak State reference and an integer request ticket.
No pending native query retains a call, storage or provider owner after that
bounded await. No window show/focus operation or call acceptance is added.

The first timeout-only candidate lost a healthy late result while lifecycle
remained resumed. Two new controls rejected that candidate before commit. This
is a regression in the intermediate implementation, not an additional baseline
finding. The final implementation keeps the slow-success behavior.

## Diagnostics and checks

The opt-in anonymous report retains `callAlertWindowQuery` separately from
post/dismiss outcomes and busy transport traffic. Its fields are source-owned
numeric codes only:

| Field | Meaning |
| --- | --- |
| code | 0: observed, 1: first-result deadline, 2: query failure |
| background | Selected native observation or lifecycle fallback, 0/1 |
| success | Native query succeeded, 0/1; not OS delivery |

No handle, title, coordinates, process ID, caller ID, query text or native error
message is added. Clearing/disabling the journal removes this evidence too.

Final qualification: **156 Flutter tests passed, no skips**, across twelve
related suites; full `dart analyze lib test` is clean. The window cases include
pending visibility/focus, background/resumed lifecycle, hangup before the
answer, slow successful background results, late errors and no show/focus
calls. Existing call sessions, notification post races/readiness, preferences,
reply identity, tray behavior and Windows registration controls also pass.

The separate AOT artifact test passes with instrumentation both enabled and
disabled. It executes the production journal, verifies the new evidence in the
enabled JSON and preserves the raw-log/private-canary refusal checks. This is
journal/export AOT qualification, not a complete Windows application build.

The OS notification and window backends are mocked. These results do not prove
that the reporter's actual Windows plugin stalls or that its toast is visible.
The fallback depends on available lifecycle information; actual delivery still
requires a functioning OS notification backend.

All tests run in the required temporary directory without launching application
windows or injecting keyboard/mouse input. Owned test processes exit; the
user's existing macOS application remains alive. No phone, installed Windows
application, native library, engine pin or production node is changed.
