# Cold application recovery after profile erasure

## Startup behavior

Managed startup no longer stops at a passive pending-erasure screen. Before
ordinary providers, profile files or runtime directories are opened, it creates
one `ColdProfileErasureRecovery` owner from the original platform preference
source. The separate pending app starts that owner once, displays progress and
keeps a retry action on refusal. Errors enter the existing bounded journal.

Ordinary bootstrap runs only after native completion, saved-entry/source
verification, fresh preference installation and resource-admission handoff.
The original resolved profile/support directory are retained. The normal startup
guard is reused if subsequent ordinary bootstrap fails. Disposing or replacing
the recovery UI prevents a late completion from starting ordinary providers.
Close joins accepted cleanup instead of converting it into a new wipe request.

## Protocol

The cold owner never prepares a new native plan. A remaining application plan
supplies its original live scope lease. Persisted protected-slot addresses are
restored into verification state before public metadata is read; their scope set
must match that lease. The journal is acknowledged before cleanup. Missing public
metadata cannot erase knowledge of an old protected slot, and a remaining orphan
credential refuses success without being deleted merely because its address was
serialized.

Terminal/journal-only startup cannot obtain mutation scopes. It performs only
read-only saved-entry and original platform-preference checks, then consumes the
exact native release to install fresh preferences. Newly appearing records are
preserved. A generic native inventory cannot become an application wipe.

The original preference backend must remain selected. Neither a current profile
file nor an empty fallback is substituted for that source. Native release and
fresh-lifetime handoff use the existing receipts. Retry after a lost release
acknowledgment retains its earlier read-only witnesses even when the disk journal
has already disappeared; it does not reconstruct a missing roster or repeat
deletion. A completed preference handoff is retained through resource-release
retry, preserving data created after native completion.

## Platform boundary

This entrypoint accepts only application-type intents. Their production creator
already verifies node, VPN, runtime and accepted-writer shutdown before publishing
the intent. Cold startup introduces none of those ordinary providers or runtime
directories. It acquires the existing platform background/microphone/network
retirement owner and seals the startup capture lifetime before continuation.
Resource checks repeat around cleanup and native finalization; failed observation
keeps recovery closed. A new VPN backend's empty cache is not used as a substitute
for that producer contract or for discovery of arbitrary older privileged helpers.

## Evidence

Twenty new checks cover the cold controller and UI. They include absent/present
native markers, pre-journal continuation, restored addresses after public metadata
removal, an orphan credential, changed platform backend, resource refusal, reentry,
receipt loss, retry handoff and UI disposal/replacement. A mixed encrypted/plain
managed profile plus opaque legacy container is removed while another profile's
identity files and saved-entry records remain byte-identical.

Three checks SIGKILL a separate native writer after journal publication, native
terminal publication, or native plan/terminal removal. Fresh platform and vault
objects carry only persisted synthetic OS values into the cold application owner;
the resulting preference backend is fresh and the operation markers disappear.
Kernel role acquisition and native file operations are real. OS secrets and
platform resource facts are controlled adapters, not a real user's credentials.

A release-reply regression failed behaviorally on the first controller candidate:
it attempted to rebuild a read-only context after its journal was gone. Retaining
the existing context passes. Two compiled controls also fail normally: dropping
restored address witnesses, and allowing a disposed UI's completion callback.
Exact source restoration passes both checks. Harness corrections (writer root,
explicit other-profile directory creation and frontend-normalized scope spelling)
are not counted as product defects.

351 checks pass across 27 serial Flutter suites. Qualification includes the
existing journal/crash/native-erasure tests, live application wipe, startup error
handling and anonymous-error export. Sources and four pinned host native-library
hashes remain fixed across the final run. Focused analysis is clean; no Rust or
media engine is rebuilt.

## Remaining scope

This is host/controller/widget qualification, not packaged application or OEM
proof. Platform smoke and the remaining storage activation work still precede
the new default. Ordinary Android metadata reads still have a separate plugin
initialization path; this change does not claim it became entirely read-only.
Old experimental terminal records without an address witness are preserved and
refused rather than treated as empty. The three storage modes remain disabled
in production defaults. No user container/device installation, push or release
is part of this cycle.
