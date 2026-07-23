# Groups: media over the content path (design)

Status: IMPLEMENTED v1 — authorization, wire, store/stream path, UI and global
physical reachability GC are integrated.

## Problem

Group media today is INLINE: the whole payload (base64) rides inside the
signed message and fans out over the durable snapshot-chunking path
(`WireKind.groupEntryChunk`, 1800 B raw per chunk because the durable outbox
re-base64s the frame into ~4 KB containers). Consequences:

* a 192 px photo (~52 chunks) takes ~22–34 s to first render on the peer;
* voice notes are capped at 96 000 raw bytes (~45 s of Opus speech);
* video notes (VNOTE1, hundreds of KB for a few seconds) are infeasible —
  ~170+ chunks would take minutes;
* every re-broadcast of the log used to re-ship the media (fixed by deltas,
  but joins still ship everything inline).

The 1:1 chat solved this long ago with the CONTENT PATH: the message carries
a small reference (contentId + micro-thumb), and the receiver pulls the bytes
over a fast stream (RACK, range-swarm; 64 MB ≈ 6–8 s). Groups cannot reuse it
as-is because of the AUTHORIZATION GAP below.

## The gap: every serve is gated on ContactStatus.accepted

The entire inbound dispatch in `messaging.dart` — including the content
offer/pull handlers — drops any frame whose sender is not an ACCEPTED 1:1
contact. Group members are NOT necessarily pairwise contacts (scale-free
groups must not require N² contact handshakes), so a member cannot pull the
author's photo unless they happen to also be 1:1 contacts.

(Today's group fan-out sneaks past this only because the existing group wire
frames carry their own authenticated-sender gate; two-device tests used
already-accepted contacts.)

## Design

### 1. Content reference instead of inline payload

The current domain object is `MediaObject`; `GroupAttachment` remains a
source-compatible name for this historical wire section. Its explicit legacy
codec grows a reference form (wire brick): kind stays
'image' / 'voice' / 'vnote', but instead of `dataB64` with the full payload it
carries a `GroupContentRef`:

```
{ cid,          // contentId hex (BLAKE3/manifest id, as in 1:1)
  size,         // total bytes
  sha256,       // whole-content hash, verified after fetch
  thumbB64?,    // micro-thumb (~2.5 KB) for instant render (images/vnotes)
  w, h,         // layout dims / durationMs for voice (same field reuse)
}
```

The ref is INSIDE the signed message (tamper-evident); the fetched bytes are
verified against `sha256` before rendering, so a malicious holder cannot
substitute content.

Space publications use the same `MediaObject` and content path through a
separate strict reference codec. Keeping the codecs explicit preserves old
message signatures without creating a second blob store or domain entity.

### 2. Membership-authorized fetch (the core, brick 1 — DONE)

A member proves the right to fetch by SIGNING the request with the same
ed25519 identity that signs their group messages (node-id-bound,
`node_id == BLAKE3(pk)` — the exact binding control/message/reaction
signatures already use):

```
GroupContentRequest {
  groupId, contentId,
  channelId?, channelEpoch?, // both present only for protected Space media
  requester (NodeId), nonce (random hex), tsMs,
  authorPubKey, signature   // over canonicalBytes (all fields above)
}
```

The HOLDER authorizes locally and deterministically
(`authorizeGroupContentRequest`):

1. signature verifies (native ed25519, node-id binding);
2. `requester` is a CURRENT member of `groupId` per the holder's own folded
   control-log (leave/remove/ban ⇒ requests stop authorizing at this holder
   as soon as the control delta folds);
3. `contentId` is actually REFERENCED by some message of that group the
   holder has (membership must not become a license to fetch arbitrary 1:1
   content the holder possesses);
4. `tsMs` is within a freshness window (10 min) AND `nonce` is unseen
   (bounded replay cache) — a captured request cannot be replayed later,
   e.g. after a ban.

For a protected Space channel the request additionally signs `channelId` and
the current `channelEpoch`. The holder decrypts its own copy of the current ACL
and requires the requester to be one of its recipients; an unscoped request
explicitly excludes references from channel-encrypted rows. The requester also
fans the request out only to current recipients of that channel. Thus guessing
a CID, remaining a Space member outside the channel, or replaying the request
after an ACL rotation never unlocks the blob and never reveals the channel to
unrelated fanout peers.

Canon (no oracle): an unauthorized request is DROPPED SILENTLY — never a
"not a member" reply. A non-member learns nothing, a removed member just
sees the fetch never complete (same as an offline holder).

### 3. Who serves

v1: the AUTHOR serves (they hold the bytes by definition). Any member that
completed the fetch MAY serve later (member-swarm), since authorization is
holder-local — that is a latency/availability optimization, not a
correctness change.

### 4. Wire

* `WireKind.groupContentRequest` (v:2, RULE WC — old builds drop it) carries
  the signed request; the ACCEPT gate for this kind checks group membership
  (via the authorize core) INSTEAD of ContactStatus.accepted.
* The serve side reuses the existing stream-pull machinery (RACK stream,
  resume offsets) — only the session admission differs.
* Fetch UX mirrors 1:1: micro-thumb renders instantly, tap / auto-download
  under the cap pulls the bytes, progress ring, sha256 verify, then the
  attachment renders from the local file-store.

### 5. Physical lifetime of a shared CID

A 64-hex content id is not owned by the row that happened to create it. The
same bytes may be referenced by multiple personal chats, cloud items, Groups
and Spaces, so none of those domains physically deletes a hash-CID directly.
One hourly identity-scoped mark/sweep derives a global snapshot:

1. storage scans current chat messages, every live cloud item/note head and
   the payload/manifest inventory;
2. GroupService strictly parses `groups.index`, cross-checks it against concrete
   `file:group:*`/legacy bundle roots, and adds signed/decrypted effective Group
   and Space references, including local/server/media-only retention and
   pinned-post preservation;
3. any malformed durable index, unknown bundle or unreadable encrypted row
   aborts fail-closed;
4. a CID must remain unreachable in crash-safe A/B quarantine for 24 hours and
   survive a second full scan before a bounded batch deletes both `cid` and
   `mf:cid`, followed by encrypted-store scrub.

A recoverable deleted Space retains its media until its heavy bundle has been
tombstone-first purged. Legacy non-hash exclusive attachments keep the old
atomic message+blob delete path. The 24-hour quarantine is an internal
anti-race safety delay; it does not change any 7/30/90/365-day retention or
notification mute preset. An unchanged quarantine snapshot is not rewritten or
rotated on every hourly pass.

### 6. Explicitly out of scope for v1

* Persistent/offline encrypted blob relay. Live protected-channel content is
  already scoped by the signed channel epoch grant, encrypted in transit by
  Veil and encrypted at rest; the store does not publish a clear network
  object for later relay.
* Relay/mailbox delivery of content to OFFLINE members (they fetch when the
  author is reachable; durable log still syncs the ref immediately).
* DHT provider records for group content (Ф4 scale work).
