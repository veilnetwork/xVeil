# Shared cloud documents

Status: CLOUD-3B1 implements the owner-device whole-note revision DAG. Contact
collaboration is deliberately not wired through ordinary group chat messages:
the current message format has no membership epoch and `messagesOf` filters by
current membership, which is insufficient for durable document authorization.

## Implemented prerequisite: branch-preserving notes

Every new note revision names its immediate parent content ids. Two linked
owner devices editing the same parent produce two heads; LWW selects the
default view but does not erase the other ciphertext, manifest, replica claim,
or materialized-index row. A merge revision names every reviewed head and only
then makes their blobs eligible for scrub.

The optimistic editor token is `(revision, content_id)`, not revision alone.
This is necessary because concurrent edits normally have the same revision
number. Replica convergence keys include `(item, device, content_id)`, allowing
one device to advertise several verified heads. Legacy two-part claim keys and
parentless note rows remain readable.

Parents are canonical, unique 64-hex ids, strictly sorted, non-self-referential,
and capped at 32 per merge. The head set itself is never truncated; merges are
performed in repeatable batches if more than 32 offline heads exist. Unknown
parents never suppress a known head.

Deletion is still an owner-device LWW tombstone and intentionally retires every
known head. A delete racing an unseen offline edit is not yet modeled as a DAG
head; delete-vs-edit recovery belongs with the epoch-bound document operation
format in CLOUD-3B2 and must not be claimed by CLOUD-3B1.

## Required wire boundary for contact collaboration

A shared document is a separate mini-group, not the sovereign device group and
not a chat disguised as a document. Its immutable root must bind:

- random document/group id and document kind/version;
- owner key and initial encrypted document key epoch;
- content type and CRDT codec version;
- signed control-log root.

Roles are document-specific: owner, editor, viewer. Every control operation and
document operation must be signed and bind the document id, membership epoch,
author sequence, previous author hash, operation id, parent operation ids and
content/CRDT payload hash. Owner grants, role changes, revokes and epoch rotates
are control entries; editors cannot mutate ACLs.

Revocation semantics require an epoch key rotation. A removed participant keeps
history they already decrypted, but cannot authenticate or encrypt a new-epoch
operation. Old accepted edits remain in history. A receiver validates each
operation against membership at the operation's bound epoch; filtering all
history by current membership is forbidden because it would erase a removed
author's earlier contribution.

## Why ordinary `GroupMessage` is not sufficient yet

The current group message signs `groupId/author/seq/body/policyVersion/time`.
Membership changes do not advance that policy version, no membership epoch is
bound to the message, and authorization currently uses the final folded member
set. Reusing it directly would create one of two false guarantees:

1. removing an editor makes their previously accepted revisions disappear; or
2. retaining raw messages permits a removed signer to submit a backdated edit.

CLOUD-3B2 must therefore add the epoch-bound immutable-history primitive first,
then build invite/ACL UI and document-key distribution on it. Until that wire
exists, sharing a note as a regular file remains immutable file sharing, not
collaborative editing.
