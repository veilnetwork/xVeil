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

## Implemented: CLOUD-3B2/1 epoch-bound log core

The first CLOUD-3B2 brick is the pure, transport-independent wire and fold in
`lib/domain/cloud_document.dart`, with native node-id-bound Ed25519 adapters in
`lib/state/cloud_document_crypto.dart`.

The immutable v1 root signs the random document id, owner, document kind,
codec version, epoch-0 key commitment, hash of the encrypted epoch envelopes,
and the initial control-chain root. Control entries are owner-only and bind the
document id, exact current and next epoch, sequence, previous signed control
hash, unique control id, ACL mutation, next key commitment/envelope hash, and a
canonical operation frontier for the epoch being closed. Grant, role change,
revoke, and explicit rotation all advance the epoch. This deliberately avoids
an ambiguous within-epoch role transition that could otherwise be backdated.

Document operations bind document id, membership epoch, author sequence,
previous signed author hash, operation id, sorted parent ids, codec operation
type, payload/ciphertext hash, and timestamp. Owner and editor operations are
accepted; viewers cannot mutate. Duplicate signed author sequences or owner
control sequences are equivocation and fail closed. Invalid-signature poison
is discarded before duplicate detection, so an unauthenticated frame cannot
block a valid sequence.

An epoch-closing control contains the exact `(author -> seq, signed record
hash)` frontier accepted by the owner. A late old-epoch suffix from a revoked
editor is withheld unless it is part of that signed hash chain, while the
prefix named by the frontier remains visible forever. Missing parents and
incomplete closed frontiers are withheld, not interpreted as empty state.
This closes the backdating problem that an epoch number alone cannot solve.

This brick does **not** yet persist or replicate document logs, encrypt payload
bytes, construct per-recipient key envelopes, expose invite/ACL UI, or provide
a rich-text CRDT. Those are the next CLOUD-3B2 bricks; ordinary `GroupMessage`
remains forbidden for collaborative edits.

## Implemented: CLOUD-3B2/2 epoch envelopes and deniable log store

Epoch keys now have a bounded recipient-envelope codec and a production crypto
adapter over veil's existing ML-KEM mailbox seal/open path. Seal resolves a
verified recipient certificate; open decrypts under the local identity and
returns a cryptographically verified sender. A fixed document-key app id and
endpoint prevent a valid mailbox blob for another purpose from being replayed
as a document key.

The sealed plaintext is a fixed 101-byte binary record: version, document id,
epoch, 32-byte key, and a domain-separated commitment. The outer canonical
bundle binds document id, epoch, commitment, and up to 256 sorted unique
recipient envelopes (64 KiB cap each). Root/control entries sign SHA-256 of the
whole bundle. Open requires the expected bundle hash, exact owner, recipient,
app id, endpoint, document, epoch, and commitment; every mismatch has one local
reject result. Temporary mutable payload/key copies are wiped where ownership
allows. The mailbox envelope is delivery crypto, not permanent key storage:
after successful open the key is persisted inside the deniable hidden volume.

`CloudDocumentStore` persists strict root/control/operation/envelope/key bundles
in chunked A/B generations, separately from the single-setting size limit. A/B
read validates the current generation and falls back to the prior valid one.
The document directory is also A/B. A single serialized pending marker closes
the document-written/index-not-yet-published crash window: a fully written
orphan is discoverable after restart and folded into the index by the next
write. Local keys are commitment-checked before persistence and have an
explicit RAM wipe method.

## Implemented: CLOUD-3B2/3 replication and explicit adoption

Shared documents now have distinct `cloudDocument` / `cloudDocumentChunk` wire
kinds. They are durable-outbox frames with bounded in-RAM reassembly and never
reuse `groupEntry` or its stranger-membership admission. The transport accepts
them only from an accepted contact. The document layer then independently
verifies the signed root, owner-only control chain, author chains, epoch
frontiers, recipient-envelope hashes, and current membership. A chat contact is
therefore a delivery prerequisite, not document authority.

An invite from the signed root owner is persisted as an A/B pending record in
the deniable hidden volume. It is inert: receiving or restarting with it does
not materialize a document and does not decrypt an epoch key. Explicit local
`adopt` revalidates the complete log, opens only envelopes addressed to the
local node id through production mailbox crypto, persists the resulting keys in
the document bundle, wipes temporary key copies, and removes the pending invite.
The provider is wired eagerly for every unlocked identity, including every
hosted pipeline in all-online mode rather than only the identity visible in the
UI. This matters because a durable frame must never be acknowledged and then
dropped merely because its identity is inactive. The wiring exists before
document UI, so an inbound invite survives until its later adopt UI.

Snapshot and delta frames merge by immutable signed-record hash and envelope
epoch. Exact replay is idempotent; a conflicting root/envelope, signature
failure, sequence fork, incomplete closure, unknown dependency, non-member
sender, or post-revocation operation rejects the candidate without modifying
the stored document. The current sender may relay another member's signed
record while they are a current document member; authority always comes from
the record signature and folded epoch, not from transport authorship.

This brick still does **not** encrypt/store the CRDT payload bytes named by
`payloadHash`, expose invitation/ACL UI, or implement rich-text CRDT operations.
Those remain CLOUD-3B2/4+; a real three-device cross-node invite/adopt run also
remains device verification rather than a claimed unit-test property.

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
