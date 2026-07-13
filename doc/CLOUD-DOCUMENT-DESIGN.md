# Shared cloud documents

Status: CLOUD-3B2 implements encrypted contact collaboration for rich text,
tasks and calendars, including a versioned owner-signed root transition for
physical history compaction. Collaboration deliberately does not use ordinary
group chat messages: that format has no document membership epoch.

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

## Implemented: CLOUD-3B2/4 encrypted payload and invitation UI

Every signed document operation now has exactly one separately serialized
ChaCha20-Poly1305 ciphertext. Its random nonce, ciphertext and authentication
tag are domain-separated and hashed into the operation's signed `payloadHash`.
AEAD associated data binds the document id, membership epoch, author, author
sequence and previous hash, operation id, sorted parents, codec operation type
and timestamp. A ciphertext therefore cannot be moved to another operation or
epoch even if its bytes are copied intact.

Cleartext is capped at 1 MiB. Replication also caps the complete encoded frame
and aggregate sealed payload bytes beneath the existing bounded document
reassembly allocation. Frame and deniable-store format v2 require one unique,
hash-matching payload per accepted operation. A v1 empty log remains readable;
an old metadata-only operation is not silently presented as decryptable data.

After the signed log and membership fold pass, ingest opens any missing local
epoch keys and authenticates every operation from every epoch in which the
local identity was a member before committing the merged bundle. Adoption does
the same only after the user's explicit action. An invite remains inert while
pending, and a signed but AEAD-invalid payload cannot poison durable history.
Temporary validation plaintext and loaded epoch-key copies are wiped in RAM.

The Storage screen now exposes pending shared-document invitations with
explicit accept and reject actions. The list follows the active deniable
identity and live service changes. Its narrow mobile layout is covered at
390x844 in Russian; invitation rows stack their actions and the empty cloud
surface scrolls when invitations reduce available height.

This brick does **not** add owner-side document creation, grant/setRole/revoke/
rotate controls, rich-text CRDT materialization, or claim a real cross-node
encrypted-operation run. Those are the next service/UI and CRDT bricks.

## Implemented: CLOUD-3B2/5 owner creation and ACL controls

The owner can create a signed note document, grant an accepted contact as an
editor or viewer, change roles, revoke, rotate an epoch explicitly and resend
an invitation. Every ACL mutation advances the epoch and closes the old one
with the exact cumulative signed author frontier. The next key is enveloped for
exactly the next membership. Local durable state is committed before fanout;
delivery failures are reported without rolling the ACL back. A revoked member
receives the closing snapshot but no envelope for the new key.

The Storage UI exposes the same owner-only controls and a read-only membership
view to other roles. Durable document chunks are acknowledged only after the
async handler reaches terminal persistence or a permanent reject. A storage
failure releases the complete reassembly for redrive instead of ACKing a frame
that was never committed.

## Implemented: CLOUD-3B2/6 rich-text sequence CRDT

Shared notes use `xveil.note.rga.v1` directly on the authenticated document
operation log. A CRDT atom is one Unicode grapheme, identified by the signed
operation id plus its offset. Inserts name a stable left anchor; concurrent
siblings use causal rank and operation id as a deterministic order. Deletes
name exact atoms. Formatting is an exact per-atom register with bold, italic,
underline, strike, inline code and paragraph/heading/quote/list/code-block
roles. Insert/checkpoint style runs use a compact bounded encoding. A long
insertion is materialized with an iterative traversal, so an authorized large
note cannot overflow the Dart stack.

The implementation deliberately reuses the existing signed operation ids,
parents, author sequence, epoch, AEAD payload and deniable store. It does not
introduce an unsigned HLC, a second persistence engine or a parallel sync
protocol. This followed an engine audit: Automerge has maintained JavaScript,
Rust and C surfaces but no first-party Dart binding; Yjs lists many language
ports but no Dart port; the established Dart `crdt` package is a map CRDT, and
`crdt_lf` describes itself as still in progress and brings its own HLC/log.
Those are poor fits for making the already signed epoch log authoritative.

Saving computes a grapheme diff against the exact heads shown by the editor.
Remote heads that arrived after the editor opened are not smuggled into its
parent set, so the two writes remain genuinely concurrent. More than 32 heads
are collapsed through signed no-op merge records instead of truncating a
branch. Viewers cannot append; owner/editors persist locally before a durable
delta is fanned out to every current member.

Granting a new member creates an authenticated checkpoint in the new epoch.
It carries the current materialized rich text but none of the old epoch keys,
so the invitee sees current content without being retroactively made a member
of prior epochs. The checkpoint replaces the complete owner-signed older epoch,
including when the wire parent cap cannot name every old head.

A document-delete tombstones only insertions in its causal past. An offline
insertion that the deleting replica had not seen remains visible and is marked
as recovered concurrent content. An edit made after seeing the delete is an
ordinary intentional restoration. The UI states this policy in the delete
confirmation, warns when concurrent content was recovered, keeps a dirty local
draft when a remote update arrives, and provides formatted editing plus a
separate ACL surface. The loopback debug hook returns only byte count, digest,
heads and conflict flags; it never echoes decrypted text.

## Implemented: task and calendar map CRDTs

Shared task lists use `xveil.tasks.map.v1`; shared calendars use
`xveil.calendar.map.v1`. Both run on the same signed, epoch-bound operation
log as rich text. A random 256-bit row id owns an LWW register per typed field,
so concurrent edits to different fields merge instead of replacing an entire
task or event. Causal descendants win; concurrent writes to one field use the
signed operation id as the deterministic tie-break. A concurrent deletion wins
over a create/edit, while a create causally after that deletion is an explicit
restore.

The cleartext codecs are strict and bounded before JSON allocation or semantic
materialization: exact keys and wire types, 1 MiB operation ceiling, 4096-row
checkpoint ceiling, bounded UTF-8 fields and non-negative bounded times. Task
rows contain title, notes, completion, optional due time and position. Calendar
rows contain title, notes, start/end, all-day and location; an end before start
is inert until a later causal patch repairs it.

Only the document owner may author a checkpoint. On grant, the owner
materializes the current typed rows and encrypts a canonical checkpoint into
the new membership epoch, so the invitee receives present state without old
epoch keys. Editors can create, patch and delete rows but cannot replace
history with a checkpoint. More than 32 collection heads use the same signed
merge-noop reduction as rich text. The common fold now also rejects an
authenticated parent cycle and every operation dependent on it: signed parent
existence is not sufficient proof of a causal DAG when editors can
pre-coordinate operation ids.

The Storage UI creates notes, task lists or calendars explicitly, exposes
typed task/event editors to owner/editor roles, and remains read-only for a
viewer. UI updates emit only fields that actually changed, preserving
concurrent changes to other registers. The loopback collection hook never
echoes titles, notes or locations; it returns row count, canonical SHA-256,
heads, epoch, role and invalid/unavailable counts.

## Implemented: signed root transition and physical compaction

Root v1 remains byte-for-byte compatible as generation zero. A compacted root
uses wire version two and signs its generation, the exact predecessor signed
root hash, current membership epoch and ACL, current key commitment/envelope
hash, cumulative per-author `(seq, signed-record-hash)` heads, and the current
owner control `(seq, signed-record-hash)` head. Document id, owner key, kind,
codec, genesis control root and creation time are immutable across a
transition.

The owner materializes the authenticated current state in RAM and writes one
encrypted owner checkpoint in the current epoch (plus a document-delete record
when required to preserve delete/recovery semantics). The new deniable bundle
then contains only that checkpoint payload, the current recipient envelope and
current epoch key. Older controls, operations, ciphertext payloads, envelopes
and local epoch keys are physically absent. The A/B document-store write makes
the replacement crash-safe; cleartext and temporary key copies are wiped.

Fold starts at the root's base epoch/ACL and seeds author and control sequence
validation from the signed frontiers. New edits and ACL rotations therefore
continue their original hash chains rather than restarting at sequence zero.
Epoch closures include both compacted base heads and post-transition records.

An existing replica accepts only generation `N+1` whose predecessor is its
exact trusted generation `N`. A downgrade, skipped generation, parallel fork,
rewritten immutable field or invalid owner signature is rejected. The new base
must cover every author/control head already known locally and preserve the
exact current epoch, key commitments and membership. Thus a device with a
newer unsynchronized local edit retains its old generation and rejects the
transition instead of silently losing that edit. Operationally, the owner
should compact after replicas have converged; a future acknowledgement protocol
can automate that quiescence decision.

Fresh invite/adopt works directly from a compacted root without old epoch keys
or records. The owner-only Storage control and loopback metadata hook expose
compaction; the hook never returns checkpoint cleartext or ciphertext.

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
