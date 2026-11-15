# All-owner compaction collection and controller entry

This connects the [full-profile worker](../managed-legacy-compaction-worker-2026-11-15/README.md)
to the collection dialog and controller. Managed defaults remain disabled;
this is qualification of the coordinated host path, not release activation.

## Collection and ownership

The dialog keeps two distinct authorities. Hidden password/key pairs define
the native keep-set. Enumerable owners are selected by exact local ID and mode
and individually authenticated to authorize reference updates. Plaintext owners
require an explicit “Allow link updates” action; an empty password or opening
the dialog does not approve them. Their data stays in independently owned files.
The Run action requires both complete visible-owner authorization and every
known hidden child learned from any authenticated roster. Visible passwords
never enter the hidden keep-set. No unknown hidden spaces are enumerated.

The in-memory authority model validates inventory, mode, key shape and consent,
copies accepted keys, hands off independent snapshots and clears its own buffers
on disposal. The controller checks complete current inventory and retains its
own snapshots synchronously before awaiting teardown. A route can disappear or
discard its model without changing an accepted operation's credentials.

Visible probes use a separate existing-owner facade and never change the active
view or create a missing owner. The router adopts each facade before its first
open, so router close owns failed/late opens and native-close retries too. Its
normal selected-root reference-recovery callback is preserved: a private intent
from interrupted compaction is recovered after authentication before serving
that root. Probe results include only legacy children relevant to the keep-set;
managed child keys are not treated as hidden spaces. A late lease revocation,
failed constructor, wrong password or refused close cannot return new authority.
Each probe owns its accepted operation through close and settles its barrier.

The old single-password path remains guarded for a nonempty visible catalog.
The new explicit all-owner controller entry tears down sessions, calls the
profile owner's coordinated worker and restores the session only while its
original lease and confirmed profile availability remain current. The ordinary
mixed-profile fallback is still refused; a complete explicit collection is the
only newly admitted route. Independent-root reclamation is unchanged.

## Preserve the operation outcome through reopen

Two native regressions fail in the intermediate controller integration: a
reopen exception hides a real post-publication alias warning, and a reopen
exception after successful publication appears as an ordinary failure. The
controller now retains the publication/recovery result separately. An original
native warning stays primary; a later reopen-only error is reported as possibly
applied with its actual recovery witness. A bounded local diagnostic records a
secondary reopen error without exporting native text or credentials.

The dialog explains uncertain outcomes, disables retry in that collection and
lets the user close it. The encrypted-owner password prompt uses a text field
owned by its own route; an intermediate prompt controller was disposed before
its pop animation ended, and the widget test caught that assertion. It was
fixed before qualification. Neither intermediate error is claimed as an old
release defect.

## Evidence

Nine native collection/controller cases exercise actual hidden master/child
files plus independent encrypted and plaintext masters. They verify exact
payloads and repaired key generations, old-entry refusal, incomplete consent
with unchanged source, caller disposal after command acceptance, post-publication
warnings with reopen failures, successful publication with reopen failure, and
ordinary recovery of real pending private intents. The pending case asserts
journal presence before probing; an earlier unseeded attempt is not counted as
recovery qualification. Wrong-password, absent plaintext consent, constructor
failure/retry and late-lease controls verify probe-barrier cleanup and an
unchanged hidden source. The normal unlock override reopens the real store but
stops before node boot; this does not qualify full application/network restart.

Widget controls on a narrow viewport verify explicit selected-owner/password
requests, no automatic plaintext approval, hidden-child coverage, separated
hidden/visible credentials, correct entry selection, outcome messaging and no
retry after uncertain publication. The model has four additional focused cases.

Final sequential terminal results:

| Run | Passed | Skipped | Scope |
|---|---:|---:|---|
| Native collection and worker | 25 | 0 | Nine composition/probe cases and 16 native operation/lifetime/crash cases |
| Controller/UI/profile regressions | 174 | 6 | Existing maintenance, lock/wipe/probe, roster, preferences, owner and headless checks |
| Explicit native-entry opt-in | 6 | 0 | All six initially skipped native-entry cases, rerun with their required opt-in enabled |
| Focused UI outcome controls | 2 | 0 | Success and uncertain-publication UI; success also appears in the regression run |

The skips are not counted as passes. Full library/new-test/helper analysis is
clean. The chosen native binary digest and all 145 recorded Rust input digests
match; no Rust change or native rebuild belongs to this round. Test processes
and fixture directories are checked after completion.

The dialog/controller are now connected, but physical Android/OEM, ordinary
packaged app lifecycle, release AOT, Windows source-name durability, custom
source-name journal binding, complete credential/model inventory, and all-target
persisted-padding native packaging remain open. Pending-source recovery still refuses unsupported Windows durability, and the
profile owner explicitly rejects custom source names.
Managed defaults remain OFF. No push or release is part of this round.
