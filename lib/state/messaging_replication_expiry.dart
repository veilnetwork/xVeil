part of 'messaging_core.dart';

/// Local expiry replaces a COMPLETE, digest-bound transport copy. It never
/// claims receipt of missing bytes and never drops the rest of a mixed delta.
class _DeviceSnapshotExpiry {
  _DeviceSnapshotExpiry(this.replication);
  final _MessagingReplication replication;
  MessagingService get owner => replication._owner;
  bool active = false;
  final _blocked = <String>{};
  bool blocks(String peer, String id) =>
      _blocked.contains(_MessagingOutbox._key(peer, id));

  Future<int> sweep() async {
    final filter = owner.onDeviceSnapshotExpiry;
    final group = owner.deviceSnapshotExpiryGroup;
    if (active || owner._disposed || filter == null || group == null) return 0;
    final binding = owner.groupBindingsOwner;
    bool current() =>
        !owner._disposed &&
        identical(binding, owner.groupBindingsOwner) &&
        identical(filter, owner.onDeviceSnapshotExpiry) &&
        identical(group, owner.deviceSnapshotExpiryGroup);
    active = true;
    var replaced = 0;
    try {
      await owner._storage.finishOutboxCleanup();
      if (!current()) return 0;
      final gid = await group();
      if (!current() ||
          gid == null ||
          !_MessagingReplication._digestHex.hasMatch(gid)) {
        return 0;
      }
      final pending = await owner._storage.pendingOutboxFrames();
      final transfers = <String, List<OutboxFrame>>{};
      // Check the active group before decoding any unrelated group payload.
      for (final frame in pending) {
        final tid = _MessagingReplication._canonicalGroupTransfer(frame.frameId)
            ? frame.frameId
            : _MessagingReplication._canonicalChunkTransfer(frame.frameId);
        if (tid == null) continue;
        final fields = tid.split(':');
        if (fields[1] != gid || fields.last != frame.peerHex) continue;
        (transfers[tid] ??= []).add(frame);
      }
      for (final entry in transfers.entries) {
        if (!current()) break;
        final old = entry.value;
        final blocked = <String>{
          for (final f in old) _MessagingOutbox._key(f.peerHex, f.frameId),
        };
        _blocked.addAll(blocked);
        try {
          final bytes = _completeBytes(entry.key, old);
          if (bytes == null) continue;
          final original = utf8.decode(bytes);
          final next = await filter(gid, original);
          if (!current()) break;
          if (next == null || next == original) continue;
          final nextBytes = Uint8List.fromList(utf8.encode(next));
          if (nextBytes.length > _kMaxGroupReasmBytes) continue;
          final peer = NodeId.fromHex(old.first.peerHex);
          final stamps = old.map((f) => f.enqueuedAtMs).whereType<int>();
          final stamp = stamps.isEmpty
              ? null
              : stamps.reduce((a, b) => a < b ? a : b);
          final fresh = _frames(peer, gid, nextBytes, stamp);
          blocked.addAll(
            fresh.map((f) => _MessagingOutbox._key(f.peerHex, f.frameId)),
          );
          _blocked.addAll(blocked);
          for (final frame in old) {
            replication._cancelQueuedGroupFrame(frame.peerHex, frame.frameId);
            owner._outbox._flushSnapshot?.invalidate(
              _MessagingOutbox._key(frame.peerHex, frame.frameId),
            );
          }
          final didReplace = await owner._storage.replaceOutboxFrames(
            old,
            fresh,
          );
          if (!current()) break;
          if (!didReplace) continue;
          replaced++;
          for (final frame in old) {
            owner._outbox._liveBackoff.remove(
              _MessagingOutbox._key(frame.peerHex, frame.frameId),
            );
            owner._outbox._flushSnapshot?.invalidate(
              _MessagingOutbox._key(frame.peerHex, frame.frameId),
            );
          }
          owner._outbox._groupSliceAcks.remove(
            _MessagingOutbox._key(peer.hex, entry.key),
          );
          for (final frame in fresh) {
            owner._outbox.recordQueued(frame.frameId, frame.peerHex);
          }
          _blocked.removeAll(
            fresh.map((f) => _MessagingOutbox._key(f.peerHex, f.frameId)),
          );
          // Publication is durable before exposing replacement bytes to the
          // existing initial-send lane. Preserve silent-peer probe policy.
          final skipLive = await owner._outbox._longSilent(peer.hex);
          if (!current()) break;
          if (!skipLive) {
            replication._refreshGroupHandlers();
            for (final frame in fresh) {
              replication._queueStoredGroupWire(
                peer,
                frame.frameId,
                frame.wire,
                epoch: replication._groupEpoch,
                background: _MessagingOutbox._backgroundWire(frame.wire),
              );
            }
          }
        } catch (error) {
          devLog(
            () =>
                'xVeil[disappearing]: queued snapshot expiry deferred (${error.runtimeType})',
          );
        } finally {
          _blocked.removeAll(blocked);
        }
      }
      if (current()) await owner._storage.finishOutboxCleanup();
      return replaced;
    } finally {
      // Uncertain replies can leave either durable image. Counters come from
      // storage, never from an assumed successful replacement.
      owner._outbox._pendingSeeded = false;
      try {
        if (current()) await owner._outbox.ensurePendingCounted();
      } finally {
        _blocked.clear();
        active = false;
      }
    }
  }

  Uint8List? _completeBytes(String tid, List<OutboxFrame> frames) {
    try {
      Uint8List bytes;
      if (frames.length == 1 && frames.single.frameId == tid) {
        final envelope = WireEnvelope.decode(frames.single.wire);
        if (envelope.kind != WireKind.groupEntry || envelope.frameId != tid) {
          return null;
        }
        bytes = Uint8List.fromList(utf8.encode(envelope.body));
      } else {
        int? count;
        var total = 0;
        final parts = <int, Uint8List>{};
        for (final frame in frames) {
          final envelope = WireEnvelope.decode(frame.wire);
          if (envelope.kind != WireKind.groupEntryChunk ||
              envelope.frameId != frame.frameId) {
            return null;
          }
          final part = parseGroupEntryChunk(envelope.body);
          if (part.transferId != tid ||
              part.count < 1 ||
              part.count > _kMaxGroupReasmChunks ||
              part.index < 0 ||
              part.index >= part.count ||
              frame.frameId != 'grpc:$tid:${part.index}' ||
              (count != null && count != part.count) ||
              parts.containsKey(part.index)) {
            return null;
          }
          count = part.count;
          total += part.data.length;
          if (total > _kMaxGroupReasmBytes) return null;
          parts[part.index] = part.data;
        }
        if (count == null || parts.length != count) return null;
        final joined = BytesBuilder(copy: false);
        for (var i = 0; i < count; i++) {
          joined.add(parts[i]!);
        }
        bytes = joined.takeBytes();
      }
      if (bytes.length > _kMaxGroupReasmBytes ||
          !_MessagingReplication._matchesGroupDigest(tid, bytes)) {
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  List<OutboxFrame> _frames(
    NodeId peer,
    String gid,
    Uint8List bytes,
    int? stamp,
  ) {
    final tid =
        'grp:$gid:${_replicationDigest(_kGroupSnapshotDigestDomain, gid, bytes)}:${peer.hex}';
    OutboxFrame frame(String id, WireEnvelope envelope) => OutboxFrame(
      frameId: id,
      peerHex: peer.hex,
      wire: envelope.withFrameId(id).encode(),
      enqueuedAtMs: stamp,
    );
    if (bytes.length <= _groupChunkBytes) {
      return [frame(tid, WireEnvelope.groupEntry(utf8.decode(bytes)))];
    }
    final count = (bytes.length + _groupChunkBytes - 1) ~/ _groupChunkBytes;
    return [
      for (var i = 0; i < count; i++)
        frame(
          'grpc:$tid:$i',
          groupEntryChunkEnvelope(
            transferId: tid,
            index: i,
            count: count,
            transferAck: true,
            data: Uint8List.sublistView(
              bytes,
              i * _groupChunkBytes,
              (i + 1) * _groupChunkBytes < bytes.length
                  ? (i + 1) * _groupChunkBytes
                  : bytes.length,
            ),
          ),
        ),
    ];
  }
}
