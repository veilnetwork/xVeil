# Storage and desktop/contact integration

The storage-mode branch at `605467fb` is integrated with the contact and desktop
changes through `3f06174d`. The default three-mode router remains enabled;
existing hidden containers retain their original opener and protection.
This source integration does not replace an installed application or publish
native dependencies or application packages.

## Integration decisions

Both branches independently introduced a desktop-call notification producer.
Keeping both would let independent owners post and withdraw the same OS slot.
The integrated tree mounts one `DesktopCallNotificationBridge`, retaining:

- Direct and group ringing from backend events, without requiring a Flutter frame.
- Windows read-only window visibility/focus queries and window-event refresh;
  other desktops use application lifecycle state. Posting never activates UI.
- Readiness including pending startup clears, one post plus at most three
  retries after 1/2/4 seconds, and cancellation on call, owner or policy change.
- Local caller names only in full-preview mode, generic hidden previews and a
  fixed payload containing no peer, identity, call ID or answer capability.
- Immediate withdrawal registration in the shared OS-id queue, including widget
  retirement, so old pending work cannot erase a successor's queued notification.
- Separate Windows QA notification namespaces. Explicit notification taps use
  the shared guarded window-restoration helper once.

The Android foreground-service lifetime guards from the storage branch remain.
The incoming/outgoing contact decision guards from the other branch are retained
in the shared storage write path. Independently encrypted and plaintext storage
continue using that same contact implementation.

## Qualification

The combined source passes **419 Flutter checks with no skips**: 136 call,
notification, readiness/race, privacy, window and diagnostic controls; 281
contact, startup, ownership, storage and maintenance controls across 29 suites;
and two added native controls for contact decisions in independently encrypted
and plaintext storage. The latter preserve acceptance/block against incoming
and outgoing request preparation and keep the block after cold-open.

The call suite includes local-name presentation, hidden versus focused Windows
windows, visible-but-unfocused windows, event-driven withdrawal without a
Flutter lifecycle transition, and an ended call whose focus query returns late.
Fake system channels reject any automatic `show`/`focus` call. The existing
transient-failure, bounded-retry, stale-owner and startup-clear controls run
against the unified producer. These are source-policy tests, not a physical
Windows toast assertion.

Full `dart analyze lib test` is clean. A separate Python control compiles the
production diagnostic journal to AOT and passes its artifact privacy gate.
The staged changes also pass the local private-pattern leak gate.
The selected host storage library matches its producer SHA and all 145 recorded
native source inputs. Its complete 50-entry Dart ABI checksum table matches.
The SQLite library selected by the test native-asset manifest matches the prior
qualified digest. No Rust library is rebuilt during this integration.

All tests use `TMPDIR=/private/tmp/`. Windows visibility and activation checks
use mock platform channels; they do not launch or activate user windows. No
phone, Windows desktop session or production relay is changed in this round.

## Remaining scope

The prior Android three-mode and controlled legacy-mode upgrade qualifications
apply to their frozen source snapshots. They are not final APK qualification of
this merged source. Matching dependency releases and ordinary final application
packages are still required before publication.

The original Windows 10 camera, incoming-toast and one-way-chat reports remain
open: source tests and prior Windows 11/background native controls do not
establish what occurred on the affected user's machine. No new physical toast,
camera, network or human-hearing result is claimed by this merge.
