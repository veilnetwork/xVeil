part of 'messaging_core.dart';

/// Domain-separated content digest for a replication transfer id.
///
/// The id used to carry `someJson.hashCode & 0x7fffffff` — THIRTY-ONE bits of
/// Dart's non-cryptographic string hash, and the id is what decides whether a
/// snapshot is new. Two distinct snapshots that landed on the same value were
/// not a crash but a SILENT SUPPRESSION: the sender's durable outbox is keyed
/// by frame id and `enqueueOutboxFrame` returns early on an id it already
/// holds, and the receiver's seen-set re-ACKs the "duplicate" without
/// processing it. So the newer state was dropped while both ends looked
/// healthy. 31 bits collide by accident within tens of thousands of snapshots,
/// and Dart's string hash is cheap enough to collide on purpose (audit XV-11).
///
/// [domain] separates the group-snapshot and document namespaces so a digest
/// minted for one can never be replayed as the other; [scopeHex] binds the
/// digest to its group/document. Both are NUL-terminated, which is
/// unambiguous — neither a domain tag nor a hex id can contain a NUL.
String _replicationDigest(String domain, String scopeHex, Uint8List payload) =>
    crypto.sha256
        .convert(<int>[
          ...utf8.encode('$domain\u0000'),
          ...utf8.encode('$scopeHex\u0000'),
          ...payload,
        ])
        .toString();

const _kGroupSnapshotDigestDomain = 'xveil.replication.group-snapshot.v1';
const _kCloudDocumentDigestDomain = 'xveil.replication.cloud-document.v1';

/// Bounded replication for oversized group snapshots and shared-document
/// frames. [MessagingService] keeps the public transport API; this subsystem
/// owns chunking, admission-aware reassembly, and terminal ACK decisions.
class _MessagingReplication {
  _MessagingReplication(this._owner);

  final MessagingService _owner;

  /// Reassembly state is per (SENDER, transfer id) — never per transfer id
  /// alone.
  ///
  /// A transfer id is not unique by itself: it names a group/document and a
  /// content digest, both of which any member can compute or simply copy off a
  /// chunk they received. Keyed by the id alone, two senders shared one slot —
  /// so a member could claim index 0 of a transfer somebody else was still
  /// sending (`parts.containsKey` then drops the honest slice as a duplicate)
  /// and the joined bundle became a splice that no signature check accepts.
  /// The honest snapshot simply never lands (audit XV-11).
  ///
  /// Same shape as `_MessagingOutbox._key` — one composite-key convention for
  /// frame state, not a third invention.
  static String _reasmKey(NodeId src, String transferId) =>
      '${src.hex}|$transferId';

  /// In-RAM reassembly of chunked group snapshots, keyed by [_reasmKey].
  final _groupReasm =
      <String, ({int count, Map<int, Uint8List> parts, int bytes})>{};

  /// Document chunks additionally retain the durable ACK route per slice.
  final _cloudDocumentReasm =
      <
        String,
        ({
          int count,
          Map<int, Uint8List> parts,
          Map<int, ({NodeId src, int replyId, String fid})> acks,
          int bytes,
        })
      >{};

  /// Stop feeding a destination whose durable queue is not draining.
  ///
  /// Replication fans every change out to every member, so a member that never
  /// acknowledges accumulates one batch per change with no end. Measured on the
  /// stand: 3473 frames and 9.56 MB queued to a linked device that had been
  /// wiped four days earlier, and growing at every app start.
  ///
  /// This DROPS NOTHING — it declines to add more — and it does not weaken the
  /// guarantee that two devices reach the same state. That guarantee never came
  /// from this queue: a device that comes back asks what it is missing
  /// (`nudgeGroupSyncAll` runs for every group at every app start) and the
  /// sender recomputes the answer against that device's own frontier. The queue
  /// is an optimisation for a peer that is briefly away, and below the cap
  /// nothing about it changes.
  ///
  /// Says so out loud, once the queue crosses the line and then at most once a
  /// minute per peer: a subsystem that has quietly stopped replicating is
  /// indistinguishable from one with nothing to say.
  bool _backedUp(NodeId dst, String what) {
    if (!_owner._outbox.replicationBackedUpFor(dst.hex)) return false;
    final now = _owner._now();
    final last = _backlogLoggedAt[dst.hex];
    if (last == null || now.difference(last) >= const Duration(minutes: 1)) {
      _backlogLoggedAt[dst.hex] = now;
      devLog(
        () =>
            'xVeil[group]: NOT queueing a $what for ${dst.short} — '
            '${_owner._outbox.pendingFor(dst.hex)} frames already undelivered. '
            'It will get the current state by asking, when it is back.',
      );
    }
    return true;
  }

  /// Last backlog complaint per peer, so the line above is a signal not a spam.
  final Map<String, DateTime> _backlogLoggedAt = {};

  /// Ship a group snapshot to [dst] durably (direct fanout; keyed per group so
  /// a later snapshot of the SAME group supersedes an un-acked earlier one).
  Future<void> sendGroupSnapshot(
    NodeId dst,
    String groupIdHex,
    String bundleJson,
  ) async {
    if (_backedUp(dst, 'group snapshot')) return;
    final bytes = Uint8List.fromList(utf8.encode(bundleJson));
    // Three things belong in this id, and two of them were missing.
    //
    // CONTENT, so a NEW snapshot of the same group (a fresh message/op) is a
    // distinct durable frame — a group-only id would let the receiver dedup the
    // newer snapshot away. A re-drive of the SAME snapshot still dedups (same
    // digest). See [_replicationDigest] for why 31 bits of `hashCode` was not
    // enough to carry that decision.
    //
    // DESTINATION, because ONE snapshot fans out to EVERY member and the
    // durable outbox is keyed by frame id: `enqueueOutboxFrame` returns early
    // on a key it already has, so only the first member's frame was ever
    // persisted and every other member lost its re-drive. This is the same
    // defect the `gcr:` content request had (audit XV-02), fixed the same way.
    final tid =
        'grp:$groupIdHex:'
        '${_replicationDigest(_kGroupSnapshotDigestDomain, groupIdHex, bytes)}'
        ':${dst.hex}';
    // Small snapshot (control/text updates): one frame, as before (brick 4).
    if (bytes.length <= _groupChunkBytes) {
      await _owner.sendDurable(dst, tid, WireEnvelope.groupEntry(bundleJson));
      return;
    }
    // Oversized (an inline image): a single frame would exceed the auth_deliver
    // 6144 cap and be silently dropped. Split the UTF-8 bytes into chunks, each
    // a durable frame keyed per (snapshot, index) so it acks/dedups on its own;
    // the receiver reassembles by (sender, [tid]) and ingests the joined bundle.
    final count = (bytes.length + _groupChunkBytes - 1) ~/ _groupChunkBytes;
    for (var i = 0; i < count; i++) {
      final start = i * _groupChunkBytes;
      final end = start + _groupChunkBytes < bytes.length
          ? start + _groupChunkBytes
          : bytes.length;
      await _owner.sendDurable(
        dst,
        'grpc:$tid:$i',
        groupEntryChunkEnvelope(
          transferId: tid,
          index: i,
          count: count,
          data: Uint8List.sublistView(bytes, start, end),
        ),
      );
    }
  }

  /// Ship a shared-document invite/snapshot/delta durably. A document frame can
  /// contain a long signed log, so it uses the same conservative double-base64
  /// chunk size as group snapshots while retaining a distinct wire kind.
  Future<void> sendCloudDocumentFrame(
    NodeId dst,
    String documentIdHex,
    String frameJson,
  ) async {
    if (_backedUp(dst, 'document frame')) return;
    final bytes = Uint8List.fromList(utf8.encode(frameJson));
    // Content digest + destination, for exactly the reasons spelled out in
    // [sendGroupSnapshot]: a document frame also fans out to every recipient,
    // and the id is what decides whether this is new state or a re-drive.
    final tid =
        'doc:$documentIdHex:'
        '${_replicationDigest(_kCloudDocumentDigestDomain, documentIdHex, bytes)}'
        ':${dst.hex}';
    if (bytes.length <= _groupChunkBytes) {
      await _owner.sendDurable(
        dst,
        tid,
        WireEnvelope.cloudDocument(frameJson),
      );
      return;
    }
    final count = (bytes.length + _groupChunkBytes - 1) ~/ _groupChunkBytes;
    for (var index = 0; index < count; index++) {
      final start = index * _groupChunkBytes;
      final end = start + _groupChunkBytes < bytes.length
          ? start + _groupChunkBytes
          : bytes.length;
      await _owner.sendDurable(
        dst,
        'docc:$tid:$index',
        cloudDocumentChunkEnvelope(
          transferId: tid,
          index: index,
          count: count,
          data: Uint8List.sublistView(bytes, start, end),
        ),
      );
    }
  }

  /// Reassemble a chunked group snapshot ([WireKind.groupEntryChunk]); once
  /// every chunk of a transferId is present, hand the joined bundle to
  /// [_owner.onGroupEntry] exactly like a whole [WireKind.groupEntry]. In-RAM +
  /// bounded; a lost partial re-heals on the sender's next full re-broadcast.
  /// A NON-contact's chunk: admit only when the group layer confirms the
  /// sender is a member of the group named in the transferId
  /// (`grp:<gidHex>:<hash>`) — checked before buying reassembly RAM.
  Future<void> ingestStrangerGroupChunk(NodeId src, String body) async {
    final GroupEntryChunkFrame f;
    try {
      f = parseGroupEntryChunk(body);
    } catch (_) {
      return; // malformed / hostile chunk
    }
    final parts = f.transferId.split(':');
    if (parts.length < 3 || parts[0] != 'grp') return;
    final gidHex = parts[1];
    if (!(await _owner.allowStrangerGroupSync?.call(src, gidHex) ?? false)) {
      return; // silent drop — no membership oracle
    }
    ingestGroupChunk(src, body, fromStranger: true);
  }

  void ingestGroupChunk(NodeId src, String body, {bool fromStranger = false}) {
    final GroupEntryChunkFrame f;
    try {
      f = parseGroupEntryChunk(body);
    } catch (_) {
      return; // malformed / hostile chunk
    }
    if (f.count <= 0 || f.index < 0 || f.index >= f.count) return;
    final key = _reasmKey(src, f.transferId);
    var slot = _groupReasm[key];
    if (slot == null) {
      // Cap concurrent reassemblies — evict the least recently ADVANCED
      // partial. The audit asked for a TTL here; a wall-clock TTL is the wrong
      // instrument, because the transfer it would kill first is the honest slow
      // one — a big snapshot over a congested mailbox route is exactly the case
      // that takes minutes and is still making progress. Ordering the map by
      // last progress instead means a partial is only ever dropped when it is
      // BOTH the stalest AND we need its slot, which is the property a TTL was
      // reaching for without the false positives (audit XV-11).
      if (_groupReasm.length >= _kMaxGroupReasmConcurrent) {
        _groupReasm.remove(_groupReasm.keys.first);
      }
      slot = (count: f.count, parts: <int, Uint8List>{}, bytes: 0);
      _groupReasm[key] = slot;
    }
    if (f.count != slot.count) return; // stray chunk from a different snapshot
    if (slot.parts.containsKey(f.index)) return; // duplicate slice
    final nextBytes = slot.bytes + f.data.length;
    if (nextBytes > _kMaxGroupReasmBytes) {
      _groupReasm.remove(key); // refuse an oversized snapshot
      return;
    }
    slot.parts[f.index] = f.data;
    // Remove-then-insert, not a plain overwrite: Dart keeps a map's ORIGINAL
    // insertion order when a present key is reassigned, so without this the
    // eviction above would still be picking the oldest-STARTED partial.
    _groupReasm.remove(key);
    _groupReasm[key] = (
      count: slot.count,
      parts: slot.parts,
      bytes: nextBytes,
    );
    if (slot.parts.length < slot.count) return; // still missing chunks
    // Complete: concatenate in index order, decode, ingest once.
    _groupReasm.remove(key);
    final joined = BytesBuilder(copy: false);
    for (var i = 0; i < slot.count; i++) {
      final part = slot.parts[i];
      if (part == null) return; // gap despite full count — bail defensively
      joined.add(part);
    }
    try {
      final bundle = utf8.decode(joined.toBytes());
      // The stranger path re-validates membership at ingest too (the guarded
      // service half) — this routing just keeps the two admission stories
      // separate end to end.
      if (fromStranger) {
        _owner.onGroupEntryFromStranger?.call(src, bundle);
      } else {
        _owner.onGroupEntry?.call(src, bundle);
      }
    } catch (_) {
      /* undecodable joined bundle */
    }
  }

  Future<void> ingestCloudDocumentChunk(
    InboundMessage message,
    String body,
    String? frameId,
  ) async {
    final GroupEntryChunkFrame frame;
    try {
      frame = parseGroupEntryChunk(body);
    } catch (_) {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    final idParts = frame.transferId.split(':');
    if (idParts.length < 3 || idParts.first != 'doc') {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    if (frame.count <= 0 || frame.index < 0 || frame.index >= frame.count) {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    final key = _reasmKey(message.src, frame.transferId);
    var slot = _cloudDocumentReasm[key];
    if (slot == null) {
      // Least-recently-advanced eviction — see [ingestGroupChunk].
      if (_cloudDocumentReasm.length >= _kMaxGroupReasmConcurrent) {
        _cloudDocumentReasm.remove(_cloudDocumentReasm.keys.first);
      }
      slot = (
        count: frame.count,
        parts: <int, Uint8List>{},
        acks: <int, ({NodeId src, int replyId, String fid})>{},
        bytes: 0,
      );
      _cloudDocumentReasm[key] = slot;
    }
    if (slot.count != frame.count) {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    if (slot.parts.containsKey(frame.index)) {
      return;
    }
    final bytes = slot.bytes + frame.data.length;
    if (bytes > _kMaxGroupReasmBytes) {
      _cloudDocumentReasm.remove(key);
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    slot.parts[frame.index] = frame.data;
    if (frameId != null) {
      slot.acks[frame.index] = (
        src: message.src,
        replyId: message.replyId,
        fid: frameId,
      );
    }
    slot = (
      count: slot.count,
      parts: slot.parts,
      acks: slot.acks,
      bytes: bytes,
    );
    _cloudDocumentReasm.remove(key); // re-insert: order by last progress
    _cloudDocumentReasm[key] = slot;
    if (slot.parts.length != slot.count) return;
    _cloudDocumentReasm.remove(key);
    final joined = BytesBuilder(copy: false);
    for (var index = 0; index < slot.count; index++) {
      final part = slot.parts[index];
      if (part == null) return;
      joined.add(part);
    }
    try {
      final terminal = await deliverCloudDocumentFrame(
        message.src,
        utf8.decode(joined.toBytes()),
      );
      if (!terminal) return;
      for (final ack in slot.acks.values) {
        await ackTerminalDocumentFrame(
          InboundMessage(
            src: ack.src,
            payload: Uint8List(0),
            replyId: ack.replyId,
          ),
          ack.fid,
        );
      }
    } catch (_) {
      // Malformed UTF-8 is an unauthorized/malformed frame: silent drop.
      for (final ack in slot.acks.values) {
        await ackTerminalDocumentFrame(
          InboundMessage(
            src: ack.src,
            payload: Uint8List(0),
            replyId: ack.replyId,
          ),
          ack.fid,
        );
      }
    }
  }

  Future<bool> deliverCloudDocumentFrame(NodeId peer, String frameJson) async {
    final handler = _owner.onCloudDocumentFrame;
    if (handler == null) return false;
    try {
      return await handler(peer, frameJson);
    } catch (_) {
      return false;
    }
  }

  Future<void> ackTerminalDocumentFrame(
    InboundMessage message,
    String? frameId,
  ) async {
    if (frameId == null) return;
    _owner._outbox.remember(message.src.hex, frameId);
    await _owner._ackFrame(message, frameId);
  }
}
