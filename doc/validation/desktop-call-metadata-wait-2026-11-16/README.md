# Optional caller metadata cannot hold desktop ringing alerts

Base: `187d1cbf`. This corrects the local, unreleased desktop-alert implementation;
it is not attributed to the reporter's published Windows 10 build.

## Confirmed waits

In full-preview mode the desktop bridge awaited `loadCallScreenCaller` before
posting. That shared Android presentation helper read both contact and avatar,
even though a text-only desktop post did not use the avatar. A stalled avatar
read suppressed an otherwise immediately available caller name and alert.

A stalled contact read also suppressed the active alert indefinitely. Since
preparation shared an ordered lane, its wait survived the call's end and held
a later caller's alert behind the old lookup.

Three Windows-platform widget cases fail on the base with explicit assertions:
expected one visible post, observed zero. The storage futures are held by gates;
the indefinite-contact case advances virtual time, not real storage or network
latency. The ended-call case requires the next caller without advancing the
clock or releasing the old gate. An earlier fixture accessed `.single` before
checking length; only the subsequent explicit assertion failures are credited.

## Change

- The text-only desktop path reads only the local contact label. Shared label
  formatting retains trimming and the short-ID fallback; Android's combined
  caller-name/avatar loader retains its existing behavior.
- Optional asynchronous name lookup has a **250 ms budget**. Full preview falls
  back to the peer/initiator's short ID when lookup fails or remains pending.
  Hidden preview continues to contain only the generic incoming-call text.
- Each alert ticket owns one cancellation signal. Call/owner/visibility/policy
  changes and disposal release the old metadata wait immediately. Its timer is
  canceled on early completion or retirement.
- One resolved name/fallback is reused by the existing bounded post retries,
  avoiding additional reads against a busy container. Late results/errors do
  not create another ringing banner. A captured storage remains pinned during
  failure/timeout rather than dropping the storage-owner guard.

The budget applies only to optional label lookup; it is not an end-to-end toast
latency guarantee. Native window queries, backend initialization/clears and OS
post execution retain their own contracts. An already queued storage operation
is not forcibly aborted; its future remains observed after the UI wait ends.
The existing shared OS-id queue, stale-ticket post guards, immediate withdrawal,
opaque tap payload and no-automatic-window-activation behavior are preserved.

## Qualification

The final diagnostics-enabled headless run passes **143 tests, zero skips**, in
13 related suites. It includes the three regressions, post retry reusing one
lookup, a late storage error after fallback, policy cancellation and disposal.
Mocks reject any Windows `show` or `focus` call. Existing tests cover direct and
group calls, owner replacement, startup readiness/clear, delayed native posts,
notification privacy, QA namespaces and explicit-tap window restoration.
A narrower initial 36-test run also passes with diagnostics at its default.

Full `dart analyze lib test` and the staged private-pattern/diff gates pass.
No native dependency or binary is changed or rebuilt. No GUI stand, user input,
Windows desktop/SSH, Android/USB, camera/microphone, real profile or production
relay is used. The user's existing Mac application remains running.

These checks prove source-level notification preparation and lifetime policy,
not the visibility or COM activation of a physical Windows toast. That original
qualification limit remains open. Changes are local, without push or release.
