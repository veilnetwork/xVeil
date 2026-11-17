# Retired notification tickets must clean up uncertain post outcomes

Base: `9019f046`. This fixes a controlled backend-fault handling gap in the
shared notification helper. It is not a reproduction of the reporting user's
missing Windows 10 banner, nor evidence of a native Windows partial failure.

## Evidence

showIfCurrent withdrew a retired post only when show returned true. An
exception skipped that check, and a false reply skipped cancellation. The real
NotificationService.show catches plugin exceptions and returns false, so the
helper could finish without attempting withdrawal even when an OS effect was
not disproven by the unsuccessful response.

The fault fixture first records a controlled notification effect, delays its
reply, retires the ticket and then returns false or throws. A separate fake
plugin exercises the real NotificationService init/show/cancel implementation,
including its exception-to-false conversion. Two widget cases use the actual
NotificationBinder and change the active identity before its messaging service
has rebound, for a message and a clear-request alert.

**Eight cases fail by assertion on the unchanged base; three current-owner
controls pass.** The eleven new cases check cancellation, visible fixture
state, original result/error behavior and an independently gated cancellation
before a successor can reuse the same OS ID. The fault is intentionally
injected after the controlled effect. No physical OS was observed accepting a
post and later returning an error in this qualification.

## Change

Once a show attempt begins, retirement cleanup runs in finally for successful,
false and exceptional completion. Cancellation remains awaited inside the
existing per-ID queue. The next post therefore cannot be removed by an older
take-down. A current ticket's failure does not cancel its alert, a queued ticket
retired before backend admission still never posts, and the different-ID path
remains independent. Original exception behavior is preserved when cleanup
succeeds; the normal wrapper still reports plugin errors as false.

The show documentation now describes backend acknowledgment rather than
claiming direct proof of visible OS state. The existing native cancellation is
best effort; this change proves the attempted withdrawal and ordering, not that
every OS permits it. No new permission, activation, retry or window policy is
introduced. A failed result never acquires notification/reply ownership.

Two deliberate mutants qualify the boundaries: not joining cancellation gives
four failures (premature completion and successor removal), and moving cleanup
out of the exceptional path gives two. Source is restored byte-for-byte after
each. The first mutation's initially underestimated expected failure count was
corrected from its actual four assertion results; no product finding is derived
from that runner assertion.

## Qualification and limits

**209 related tests passed, zero skipped**, across seventeen notification,
call-alert/window/tray, policy/payload/reply, caller-label and diagnostic suites.
With XVEIL_DIAGNOSTICS=true, **115 tests passed, zero skipped**, across six
overlapping suites. Counts are not added as unique cases. The final eleven-case
focused run also passes. The analyzer reports no issues after two test-style
findings were corrected; whitespace checks pass.

Selected core/storage libraries match producer hashes and 1,144 Rust/Cargo
inputs; all 50 storage ABI checks pass. No native build or dependency change
is made. All checks are headless with TMPDIR=/private/tmp/. Notification effects
are recording stand-ins, including behind the real wrapper; no native toast,
app window, focus change, OS input, user container, installed app or seed is
touched. The existing user's app stays running. No push or release.
