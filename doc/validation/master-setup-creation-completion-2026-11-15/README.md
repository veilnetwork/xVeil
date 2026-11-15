# Journaled ordinary master creation and completion

Status: ordinary routed single-identity conversion now uses the protected
creation intent. Authenticated application recovery is still incomplete;
managed production defaults remain OFF. No release was made.

The subsequent [application-recovery follow-up](../master-setup-app-recovery-2026-11-16/README.md)
connects the controller and recovery screen. Statements below about incomplete
application wiring describe this earlier checkpoint; packaged and physical
activation gates remain open.

## Ordinary creation

The application previously kept its source row and new child's reference only
in memory while creating a master. The preparation backend now participates in
that ordinary path:

1. Allocate the intended child locator without creating or registering a child.
2. Atomically publish the original source row, planned child and pending-master
   marker inside the authenticated, inspected new master.
3. Create the planned child, check collisions and existing contents, then close
   it and durably attach its actual keys to the parent intent.
4. Reopen that exact child by keys and initialize its profile under a pending
   identity marker. No personalized child payload precedes key attachment.
5. Reopen the exact master, publish and strictly reread its complete roster,
   then atomically replace the live secret intent with a completion receipt and
   clear pending-master. Adopt the new access root only after this boundary.

Hidden stores still close before opening another space of the same container.
The existing edit owner seals services across route changes and retains native
work through cancellation. The original source is neither rewritten nor erased.
Temporary intents and copied keys are owned and wiped on both success and
failure. The child gets no reverse pointer to the master.

This change covers routed conversion to a new master. Existing-master appends
and the legacy non-router creation path have not been converted to this new
protocol. Full default activation still requires the complete application and
platform qualification described in `STORAGE-MODES.md`.

## Completion and retry behavior

Child preparation checks the exact recorded locator and opened keys, refuses a
master/erasure conflict, and uses strict roster reads. An unfinished child's
accepted profile must match the plan; unknown payload, credentials or node
configuration prevent initialization. Each accepted step can be retried after a
lost reply or process death without resetting stored data.

A child whose own completion marker is already zero is verified without
replaying its initial profile. Later renames, node state and user data remain
unchanged. A completed marker with a missing profile refuses instead of minting
an identity. Completion authority is an in-memory witness tied to the full plan;
the application must retain exclusive lifetime ownership between validation and
parent publication.

The parent's roster must be absent or exactly match the full intended rows.
Publication preserves a conflicting roster and does not report completion.
The receipt contains only its format, completion flag and a digest of the full
plan; it has no source/child keys, locators or labels. It replaces the live file
reference atomically with clearing the marker. This is not a claim that retired
encrypted storage records have been securely erased.

A lost final reply is read-only on retry. A receipt cannot be replayed as a
creation intent or restore a row removed by a later legitimate unbind.
Unsupported atomic writers refuse before roster publication; no sequential
receipt/marker fallback was added. Transport, peer authorization, ratchet and
mailbox policies are unchanged.

## Evidence

The updated normal-creation test failed on the previous product code in all
four mode combinations because the completed conversion had no protected
intent/receipt. The candidate passes those actual AppController/native-store
creation, append and cold-reopen cases.

Three additional AppController/native controls refuse the planned child's
creation at the router factory boundary. In every master mode, the parent has
already saved the original source keys/locator and the exact planned slot;
there is no registered child, the master remains pending, and the original
source reopens with its profile, keys and sentinel unchanged.

Nine actual SIGKILL cases cover three master modes and three later boundaries:
after the child's profile but before clearing its pending marker, after the
full roster but before atomic parent completion, and after completed
publication. Cold opens verify the original source, child keys/profile, marker
and intent/receipt, followed by backend completion. Another cold read checks
the accepted roster/receipt, and a later unbind remains intact after an old
completion retry. These extend the earlier nine preparation crash cases.

Deterministic controls cover conflicting keys/locators/profile/roster, unknown
stages and metadata, a proof for another plan, cancellation after an accepted
child profile or final publication, a refused final publication, lost final
replies, preservation of a completed child's newer data, and missing-profile
refusal. Development fixture compilation errors are not counted as red
product evidence.

The final frozen-source run passed **166 tests across 17 suites**, with no
skipped cases. This includes the 18 actual SIGKILL cases across preparation and
completion, the four ordinary conversion/cold-open cases and three ordinary
creation-refusal controls. Analysis of the complete library and changed test
fixtures reports no issues. The qualified source manifest was checked again
after the run; no tested source changed during that qualification.

The existing native library's hash and unchanged Rust provenance were checked.
No native build, packaging or GUI application launch was performed. The tests
are host process-death qualification, not power-loss, physical OEM or
release-AOT qualification.

## Remaining work

Connect ordinary unlock/recovery UI to authenticated parent-intent replay;
resume an interrupted planned child without replacing a failed authentication,
including an unlisted partial managed creation; preserve accepted newer data;
and retain lifecycle ownership through root adoption and ordinary re-entry.
Qualify the complete application path, existing-master appends, destructive
maintenance and remaining platform gates before activating the requested
enumerable encrypted default. A readable journal alone is not user-facing
recovery, and these backend crash tests do not prove that UI path complete.
