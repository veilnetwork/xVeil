# Windows incoming calls while the window is hidden

The new user report names three symptoms: the PC camera remains at “waiting
for video”, no incoming-call notification appears while the window is closed
to tray, and messages do not appear on one side after contact acceptance.
The report does not provide a new diagnostic export or exact release number.
These symptoms are tracked separately; this cycle confirms and fixes only the
missing Windows notification path. No user application was opened, focused,
replaced or driven by keyboard/mouse automation.

## Confirmed notification mechanism

`CallLifecycleBridge` subscribes to backend call events and rings even without
a Flutter frame. Its OS call notification is an Android foreground-service
operation and returns immediately on Windows. The message notification binder
subscribes to message notices, not call offers. Thus an incoming call can exist
inside the application without ever asking Windows to display a toast.

A widget regression drives an actual `CallService` with an authenticated test
wire offer, a hidden/unfocused Windows window and a recording notification
backend. On the unchanged application the hidden-window assertion fails with
zero posts; the focused-window control passes. An earlier test-platform reset
error was corrected before this credited red/control pair.

## Change

A Windows-only bridge listens to direct/group call events, notification settings
and read-only window/lifecycle events. A ringing call posts a distinct OS alert
when the window is not focused. A focused window keeps its ordinary in-app call
controls. Answer, termination, return to the window, disabled notifications and
owner disposal remove the alert. No notification path automatically accepts a
call or changes consent, media capture or transport authorization.

Hidden previews contain only localized generic call text. Full previews may
resolve the caller label from the open store; read failure retains a generic
alert. The fixed tap payload contains no peer, identity, call ID, source path or
bearer capability, and supports no inline text reply. Only an explicit tap may
restore/focus the existing Windows window. Posting itself never does so.

Posts are generation-guarded. Teardown queues cancellation alongside posts for
the same OS ID; a delayed older teardown cannot cancel a successor's notification.
The notification backend is captured while the widget is mounted. An initial
candidate read Riverpod `ref` during disposal; the regression caught that error
and the final implementation no longer does so.

## Verification

- Final **52 passed, no skips** across call notification actions, post races,
  notification policy, service initialization/cleanup and Windows notification
  build identities. Hidden and focused controls use the production lifecycle
  bridge and `CallService`; they assert that no window show/focus operation is
  invoked on arrival. A held OS post/cancel verifies successor ordering without
  a timing threshold. Tap routing and reply refusal have explicit checks.
- Analysis of all six changed/new Dart source/test files is clean.
- Before this fix, a separate native-backed background series passed **99 checks,
  no skips** for contact acceptance admission, handshake ACK/ingress, consent
  races and call notification/camera state. The selected host library matched
  its retained SHA and Rust-source manifest. This is supporting investigation,
  not a reproduction of the new one-way-message report or a final hardware test.

The tests use mocked window/OS-notification backends. No actual Windows toast,
COM activation or user's camera has been qualified by these tests. The original
camera and asymmetric-message complaints remain open. A disappearing request
banner and a positive node count do not prove durable mutual contact acceptance
or subsequent message delivery.

## Windows package preparation

A separate source-verified Windows workspace now has a fresh Release Veil DLL
with embedded-node/testnet features, the previously qualified persisted-padding
hidden-volume DLL, a media DLL matching its published digest/provenance/current
native source, and a fresh pinned Whisper Release DLL. The old retained Veil
DLL was Debug and was not credited as Release evidence.

Two failed native build preparations are excluded: an overlong MSBuild tracker
path, then inherited GNU C++ options with the MSVC driver. The successful build
uses a shorter owned target and the same target-scoped clang-cl/compiler-remap
policy as the repository builder. Source hashes match before/after compilation.
Whisper's pin check remains enabled; its temporary standalone Git metadata
needed a refs directory, and CMake reformatted an unrelated JavaScript package
JSON without changing its parsed contents. That exact metadata was restored
before final verification; native source files remained unchanged.

These component builds do not qualify the complete current Flutter Release
application. Full packaging, artifact privacy/runtime checks and the incoming
Windows toast on real hardware remain pending. Production managed-storage
activation and release are not performed by this cycle. No push or tag is made;
private stand records and logs remain outside the repository.
