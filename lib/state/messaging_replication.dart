part of 'messaging_core.dart';

/// Bounded replication for oversized group snapshots and shared-document
/// frames. [MessagingService] keeps the public transport API; this subsystem
/// owns chunking, admission-aware reassembly, and terminal ACK decisions.
class _MessagingReplication {
  _MessagingReplication(this._owner);

  final MessagingService _owner;

  /// In-RAM reassembly of chunked group snapshots, keyed by transfer id.
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

  /// Ship a group snapshot to [dst] durably (direct fanout; keyed per group so
  /// a later snapshot of the SAME group supersedes an un-acked earlier one).
  Future<void> sendGroupSnapshot(
    NodeId dst,
    String groupIdHex,
    String bundleJson,
  ) async {
    // Key the frame by CONTENT so a NEW snapshot of the same group (a fresh
    // message/op) is a distinct durable frame — a group-only id would let the
    // receiver dedup the newer snapshot away. A re-drive of the SAME snapshot
    // still dedups (same hash). (The renegotiate lesson: type-only ids collide.)
    final h = bundleJson.hashCode & 0x7fffffff;
    final bytes = Uint8List.fromList(utf8.encode(bundleJson));
    // Small snapshot (control/text updates): one frame, as before (brick 4).
    if (bytes.length <= _groupChunkBytes) {
      await _owner.sendDurable(
        dst,
        'grp:$groupIdHex:$h',
        WireEnvelope.groupEntry(bundleJson),
      );
      return;
    }
    // Oversized (an inline image): a single frame would exceed the auth_deliver
    // 6144 cap and be silently dropped. Split the UTF-8 bytes into chunks, each
    // a durable frame keyed per (snapshot, index) so it acks/dedups on its own;
    // the receiver reassembles by [tid] and ingests the joined bundle.
    final tid = 'grp:$groupIdHex:$h';
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
    final hash = frameJson.hashCode & 0x7fffffff;
    final bytes = Uint8List.fromList(utf8.encode(frameJson));
    if (bytes.length <= _groupChunkBytes) {
      await _owner.sendDurable(
        dst,
        'doc:$documentIdHex:$hash',
        WireEnvelope.cloudDocument(frameJson),
      );
      return;
    }
    final tid = 'doc:$documentIdHex:$hash';
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
    var slot = _groupReasm[f.transferId];
    if (slot == null) {
      // Cap concurrent reassemblies — evict the oldest partial (insertion order).
      if (_groupReasm.length >= _kMaxGroupReasmConcurrent) {
        _groupReasm.remove(_groupReasm.keys.first);
      }
      slot = (count: f.count, parts: <int, Uint8List>{}, bytes: 0);
      _groupReasm[f.transferId] = slot;
    }
    if (f.count != slot.count) return; // stray chunk from a different snapshot
    if (slot.parts.containsKey(f.index)) return; // duplicate slice
    final nextBytes = slot.bytes + f.data.length;
    if (nextBytes > _kMaxGroupReasmBytes) {
      _groupReasm.remove(f.transferId); // refuse an oversized snapshot
      return;
    }
    slot.parts[f.index] = f.data;
    _groupReasm[f.transferId] = (
      count: slot.count,
      parts: slot.parts,
      bytes: nextBytes,
    );
    if (slot.parts.length < slot.count) return; // still missing chunks
    // Complete: concatenate in index order, decode, ingest once.
    _groupReasm.remove(f.transferId);
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
    var slot = _cloudDocumentReasm[frame.transferId];
    if (slot == null) {
      if (_cloudDocumentReasm.length >= _kMaxGroupReasmConcurrent) {
        _cloudDocumentReasm.remove(_cloudDocumentReasm.keys.first);
      }
      slot = (
        count: frame.count,
        parts: <int, Uint8List>{},
        acks: <int, ({NodeId src, int replyId, String fid})>{},
        bytes: 0,
      );
      _cloudDocumentReasm[frame.transferId] = slot;
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
      _cloudDocumentReasm.remove(frame.transferId);
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
    _cloudDocumentReasm[frame.transferId] = slot;
    if (slot.parts.length != slot.count) return;
    _cloudDocumentReasm.remove(frame.transferId);
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
