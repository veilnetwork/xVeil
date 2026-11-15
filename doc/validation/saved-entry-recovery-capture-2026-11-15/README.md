# Saved-entry recovery capture

## Recovery requirement

The subsequent [application-journal implementation](../application-erasure-journal-2026-11-15/README.md)
connects this capture barrier to durable publication and native finalization.
The implementation limits below describe the original capture-only round.

The native full-profile erasure terminal deliberately retains no OS credential
roster. The live application owner remembers protected quick-unlock slot
addresses, but a restarted application loses them after public metadata is
removed. The next enclosing application-recovery journal needs these addresses
durably bound to the original operation **before** any such removal. A list
captured only after successful deletion is too late for a crash at that boundary.

This change supplies the vault-side capture/persistence ordering. It does not
publish that journal or enable cold-start continuation yet. The native plan and
terminal formats are unchanged.

## Capture and removal protocol

`prepareAbsenceWitness` seals enrollment for every selected scope synchronously
before awaiting any scope. It joins previously accepted enrollment in each
scope's existing serial queue and reads public cleanup metadata. Already retained
biometric-slot addresses are included, so retries do not forget a slot whose
public record was removed by an earlier prefix. Capture deletes no OS records
and does not read protected passwords or prompt for biometric authentication.

The bounded immutable witness contains only known scope hashes and protected OS
record addresses belonging to those scopes. Its strict versioned codec refuses
foreign scopes, duplicate/malformed addresses, unsupported fields and oversized
input. It contains no password, pattern wrapper, identity name, network address
or hidden-space roster. Legacy hidden storage always contributes its one legacy
scope; visible identities may already be enumerated under the requested storage
model. The witness is not a cleanup grant.

`retire(persistWitness: ...)` waits for the supplied persistence callback before
the first removal. A callback failure preserves the records and the sealed
owner for retry. Bound operation ownership is rechecked after capture and after
persistence. A newly appearing protected-slot address that was not captured
refuses deletion, preserving its record instead of silently widening the saved
set. Successful retirement also checks every captured address absent, including
slots retained from earlier attempts, before returning to native payload removal.

A decoded witness can perform only read-only `contains` checks against the
selected secret-store adapter. Reappearing records refuse success and remain
untouched. The existing operation-bound receipt is still required to admit a
fresh lifetime; a serialized witness cannot mint that receipt or retire scopes.

## Additional corrected read boundary

Removal used to decrypt/read public metadata even when it was absent. That could
initialize an unnecessary cipher, fail on an unavailable key, or reach plugin
initialization before the Android backing-file guard. The removal/configuration
metadata path now checks presence first and skips the plugin read on absence.
On Android this uses the validated raw-record channel. A present record that
then reads as absent is an error, not permission to proceed as an empty setup.
Detached lifetime checks remain after asynchronous operations.

This does not change ordinary unlocked/options reads or claim that all plugin
initialization paths have now been made read-only.

## Evidence and limits

Focused checks exercise unchanged record bytes before persistence acknowledgment,
callback refusal/retry, all-scope sealing behind accepted enrollment, exact
address capture without passwords, immutable/strict codec behavior, missing
metadata without cipher initialization, and read-only refusal of reappearing
records. A post-capture replacement slot is preserved rather than deleted.
Two checks failed behaviorally before their corresponding corrections: unnecessary
metadata read for an absent record, and acceptance of the uncaptured replacement
slot. An earlier test fixture omitted a required argument; that compile failure
is not counted as a red regression test.

202 checks pass across 16 serial Flutter suites. The full qualification includes
real native managed-identity payloads,
worker ownership/retry, vault handoff, profile erasure, old read races and pending
startup exclusion. OS-record operations in these Dart tests use synthetic
adapters. The preceding Android raw-store qualification remains separate and is
not claimed as runtime coverage of this new Dart capture protocol.

The application composer still calls retirement without a persistence callback.
The next implementation step is the enclosing durable application-recovery
journal and cold owner, including startup exclusion and platform resource
retirement. No disk witness is published by this increment. Managed storage
remains disabled; the requested three modes and encrypted default remain work
in progress. No user credentials, device installations, push or release are
involved.
