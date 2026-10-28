# Android notification actions belong to one call — 2026-10-28

Two widget regressions reproduced a missing correlation check in the actual
`xveil/call_actions` handler. An action authenticated for an old call, delivered
to Dart after another call began, was applied to the new call: `accept` opened
the new call and `hangup` ended it. Native one-use authentication did not supply
Dart with the call context it needed after that asynchronous boundary.

The application now generates a local random notification session for each
call instance. It binds the controller owner, call ID and local start time;
capture/status updates retain the session, while identity/controller changes,
another call, clearing or bridge recreation cannot reuse it. The random value
is not a network ID or an authentication credential and is never sent to peers
or added to the anonymous diagnostic report.

The Flutter plugin carries the session to the Android notification. Native
capabilities bind action, token and session atomically; the activity forwards
only the authenticated action/session pair. Dart checks that pair against the
actual currently live controller/call before acting, including when UI state
has not yet rebuilt. Unscoped and malformed payloads fail closed in xVeil.

Notification PendingIntents also have a per-session category. Android's
`Intent.filterEquals` compares categories and ignores extras: reusing the same
identity with `FLAG_UPDATE_CURRENT` could otherwise rewrite an old button with
the next call's extras before native authentication. The category separates
calls without adding a navigable URI. The one-use token and immutable intent
protections remain in place.

The plugin's session argument is optional for other hosts; legacy Java/Kotlin
mint/consume overloads are retained. xVeil updates its activity, Dart receiver
and pinned Flutter plugin together. Rust SDK/media/hidden-volume binaries and
relay behavior are unchanged. No test-only production endpoint was added.

## Checks

Four related Dart files passed 201 tests with the default diagnostics gate;
four passed 207 tests with diagnostics enabled (counts overlap). These include
three regressions observed failing before correction, six session-boundary
checks, foreground-service checks and the existing call state-machine suite.
Static analysis found no issues in the four changed application Dart files.

Eight pure JVM scenarios cover correct consumption, wrong-session refusal
without burning the valid token, session substitution, token rotation, wrong
action/token, revocation, 32 concurrent consumers with exactly one winner, and
the legacy unscoped host API. The original Java overloads were checked in the
compiled class. Android/profile-AOT and both Mac QA bundles compiled; APK DEX
markers and hashes of the platform source overlay were checked separately.

The additional regression came from the physical two-call check: the second
call reached the backgrounded application's state machine, but no fresh call
notification/session was posted. Platform effects had been driven from widget
`build`, which Flutter can defer in the background. The bridge now subscribes
directly to the current direct/group services and updates notification/ringing/
PiP state on backend events, replacing subscriptions on controller changes.
A widget test pauses the lifecycle, delivers an offer, flushes events without
pumping a frame and requires the platform ring effect. It failed before the
correction (`0`, expected `1`) and now passes.

## Physical checks and limits

The physical check uses retained QA profiles: A is Android on Wi-Fi, B is its
Mac sibling and C is another identity on Mac. The dedicated QA application is
labelled `xveil QA` only in its private build manifest so automation can select
its notifications without touching the main application's controls. Notification
buttons are exercised through SystemUI and the real immutable PendingIntents,
not the diagnostic accept/hangup APIs. Raw UI XML and pending-intent dumps remain
private; only allowlisted counts, roles and outcomes are published.

Automation matches labels without case, scrolls and expands only the QA
notification, and requires the call to end after tapping its button. Preliminary
selector failures were not counted as completed button qualifications.

| Final source, C calls A/B and A answers | First call | Second call |
| --- | ---: | ---: |
| Phone explicitly sent Home before offer | No | Yes |
| A / B first observed ringing, ms | 754 / 866 | 573 / 578 |
| Last active sample, seconds | 44.232 | 44.392 |
| Answer through QA notification | Passed | Passed |
| Hangup through QA notification | Passed | Passed |
| A terminal origin | androidNotification | androidNotification |
| C terminal origin | remoteSignal | remoteSignal |
| Unexpected termination | None | None |

The OS activity dump confirms the phone application was not the resumed
activity before the second offer. PendingIntent snapshots contain one scoped
session in the first call and two distinct sessions by the second, including a
new session for that call. Only counts/difference checks are published.

UI action-to-active observations were 9,604 and 13,407 ms, including SystemUI
scrolling, hierarchy capture and the button tap; they are not network setup
latency measurements. All 18 new messages converged without duplicates on
A/B/C. Complete histories contained the same 1,336 IDs in the same order.
These are control/packet/frame checks, not live speech qualification.

Owned apps were closed. The final independent audit checked 83 recorded process
groups, both Mac QA executables, Android package/subprocess names and the owned
ADB forward; none remained. Main apps/profiles were untouched.

Final runtime results and the independent process audit are in `summary.json`.
These checks do not prove the cause of the earlier unexplained 25.094-second
phone termination, nor qualify human speech, Windows or cellular call quality.
