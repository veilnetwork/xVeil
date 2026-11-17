# Route reconstruction must not retire a newer session of the same call

Base: `9027baac`. This qualifies local 1:1 controller/FSM ordering. It does not
attribute the reported Windows 10 camera, silence, notification or handshake
symptoms, and does not reopen the deferred historical call-duration complaint.

## Evidence

The local route-rebuild path awaited retirement of its native sources and then
checked only the call ID before starting another engine. A newer start could
already own that same call while the old source's stop reply was pending. The
retired repair would then close the replacement and create an unnecessary third
engine. The same missing ownership check after restart interpreted an obsolete
false result or lookup exception as current failure. The real CallService then
ended the working replacement with mediaRepairFailure.

Fourteen gate-controlled cases drive the real CallService health-request path
and VeilCallMediaController. Both peers negotiate a legitimate relay route:
both postures permit it, P2P consent remains disabled, and every actual fake-port
channel open is checked for relay=true/direct=false. The wire fixture starts at
the service's already-authenticated signal boundary; it is not a transport or
cryptographic integration test.

On the unchanged base, **eight cases fail by assertion and six controls pass**.
The failures cover native and plugin successors after delayed retirement,
supersession during identity lookup (normal completion and exception), a newer
pending start, and synchronous restart from the old source's stop callback.
Controls cover ordinary rebuilds, genuine current engine/lookup failure,
replacement by a different call, and hangup. They check the real FSM's active
state, engine disposal, channel closure and actual route, not only the helper's
boolean result. The hangup oracle uses absence of a live call; hangup clears the
current call rather than retaining an ended snapshot.

## Change

The repair claims a start-operation epoch before invoking stop, including before
any synchronous callback. It checks that owner after retirement and after its
replacement start, including exceptional completion. A newer session of the
same call owns readiness; the retired repair does not restart it or report its
own obsolete failure. A pending replacement uses CallService's existing
converging result rather than being mistaken for a broken route.

Normal current failure still returns failure and the FSM still ends the call.
Different-call replacement and hangup do not inherit success. Cooldown and
rebuild logging belong to the current repair only. The existing legacy route
switch rebuild shares the helper but still requires its exact target transport;
the native preserving-handover path and consent/privacy gates are unchanged.
The new cases qualify repair, not every legacy switch or physical P2P handover.

Three deliberate mutants verify the boundaries: claiming after stop invocation
produces one reentrancy failure; removing the post-start ownership check produces
two failures (the two exception controls still pass); removing only the scoped
exception check produces two failures. Each mutation is restored byte-for-byte.
An intermediate candidate's missing exception handling was caught before final
qualification; its earlier broad-test counts are not the final result.

## Qualification and limits

**839 related tests passed, zero skipped**, across twenty-four call/media,
camera/video lifecycle, routing, network/grant and widget suites. With
XVEIL_DIAGNOSTICS=true, **249 tests passed, zero skipped**, across seven
overlapping suites. These counts are not added as unique cases. The final
analyzer reports no issues; whitespace checks pass.

Selected core/storage libraries match their producer hashes and 1,144 recorded
Rust/Cargo inputs. The storage ABI check passes all 50 symbols. No native build,
wire format, permission change or diagnostic payload is introduced.

All checks run headlessly with TMPDIR=/private/tmp/. No GUI app is launched or
activated; no OS input, focus change, microphone/camera capture, phone install,
container change or seed operation is performed. Existing user app processes
are left alone. This is controlled lifetime qualification, not evidence of a
physical Windows 10 call. No push or release.
