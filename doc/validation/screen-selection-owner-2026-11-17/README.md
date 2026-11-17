# Screen selection must retain its call, engine and source outcome

Base: `2b768f05`. This fixes the supported macOS screen/window selector and
delivery of local screen-stop feedback. It does not attribute the original
Windows 10 camera report. No Windows native source or DLL is changed.

## Evidence

selectScreen retained an engine, awaited source discovery and then used that
engine and shared fields without checking ownership. Hangup could leave a late
successful choice on an ended call; a replacement call/engine could cause
stopScreen on the disposed old engine; a newer choice could be overwritten.
Profile retirement was not checked either.

The method also ignored stop refusal. If the requested source failed, it tried
the former source, but did not report failure when both were unavailable. A
throw from the requested source skipped that restoration entirely. The real
CallService could therefore keep advertising screenOn=true without a source.

Fifteen new controlled cases use the real CallService and media controller.
Only the public listScreens dependency and native engine port are controlled;
no production test hook or platform override is added. Gates delay discovery,
then exercise hangup, a different call, same-call engine replacement, a newer
selection and profile replacement. Controls retain ordinary selection and a
valid choice made while sharing is off. Refusal cases distinguish failed stop,
failed requested source, failed restoration and exceptional completion.

On the unchanged base, **eleven assertion-red cases and four controls** cover
these outcomes. Tests check actual source commands, no calls to disposed engines,
source identity, real FSM screen/camera flags, continued audio-call state and
peer renegotiation. An early snapshot oracle using List identity inside records
was corrected before these counts; that failed control is not product evidence.

## Change

Selection claims its operation before discovery and checks the current call,
engine, media epoch, latest choice and preferences lifetime afterwards. No
native source is touched for a retired request. A refusal to stop preserves
the existing source/choice and does not attempt another start.

The selected ID is committed after a successful new start, or remembered
directly for a future share while capture is off. A failed/throwing new start
attempts the exact former source once. If restoration also fails, the controller
reports stopped through the existing stream, preserving the call and the
camera-off intent. CallService updates its state and tells the peer.

Stop records retain private call/media ownership internally; the public API
remains Stream<void>. Delivery filters retired sessions and already recovered
sources, including a paused subscriber. Android's retained MediaProjection
source is still allowed to rebind to a replacement engine in the same call:
its callback checks source/call ownership and records the current media epoch,
not its original engine. Host tests do not qualify a physical Android projection.

Three deliberate mutants produce one, one and two assertion failures: removing
latest-selection ownership, ignoring stop refusal, and removing stop-delivery
filtering. The latter detects both same-engine recovery and engine replacement
with an older event still queued. Source is restored byte-for-byte each time.

## Qualification and limits

**895 related tests passed, zero skipped**, across thirty call/media, camera,
screen/projection, permission, capture-lifetime, routing and widget suites.
With XVEIL_DIAGNOSTICS=true, **293 tests passed, zero skipped**, across nine
overlapping suites; counts are not added as unique cases. The final focused
selection run passes all 15 cases. The analyzer reports no issues after three
test-style findings were corrected; whitespace checks pass.

Selected core/storage libraries match producer hashes and 1,144 Rust/Cargo
inputs; all 50 storage ABI checks pass. No native build is made. Tests use
TMPDIR=/private/tmp/ and controlled device ports, without physical capture,
screen enumeration, an app window, focus change, OS input, user profile/container,
phone installation or seed operation. The existing user's app is left running.

The initial Windows buffer-stride hypothesis was not confirmed: the existing
contiguous-lock path and default-stride interpretation agree with the
[documented representation](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-mt-default-stride-attribute).
No speculative conversion change is included. The original Windows 10 case
and physical capture remain separate qualification. No push or release.
