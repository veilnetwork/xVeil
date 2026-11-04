part of 'messaging_core.dart';

class _SnapshotExpiryAdmission {
  int writing = 0;
  Object revision = Object();
}

/// Local expiry replaces a COMPLETE, digest-bound transport copy. It never
/// claims receipt of missing bytes and never drops the rest of a mixed delta.
class _DeviceSnapshotExpiry {
  _DeviceSnapshotExpiry(this.replication);
  final _MessagingReplication replication;
  MessagingService get owner => replication._owner;
  bool active = false;
  final _blocked = <String>{};
  final _pending = <String, _SnapshotExpiryAdmission>{};
  final _again = <String>{};
  Completer<void>? _idle;
  bool _closed = false;
  late final _validation = PostReceiptQueue(
    maxBytes: 512 * 1024,
    onError: (error, stack) => _report(error, stack),
  );
  bool blocks(String peer, String id) =>
      _blocked.contains(_MessagingOutbox._key(peer, id)) ||
      _pending.containsKey(_transferKey(peer, id));

  String? _transferKey(String peer, String id) {
    final tid = _MessagingReplication._canonicalGroupTransfer(id)
        ? id
        : _MessagingReplication._canonicalChunkTransfer(id);
    return tid == null ? null : _MessagingOutbox._key(peer, tid);
  }

  Future<String?> beginAdmission(String peer, String id) async {
    final key = _transferKey(peer, id);
    final group = owner.deviceSnapshotExpiryGroup;
    final filter = owner.onDeviceSnapshotExpiry;
    if (_closed ||
        owner._disposed ||
        key == null ||
        group == null ||
        filter == null ||
        owner.groupBindingsOwner == null) {
      return null;
    }
    final binding = owner.groupBindingsOwner;
    final gid = await group();
    if (_closed ||
        owner._disposed ||
        !identical(binding, owner.groupBindingsOwner) ||
        !identical(group, owner.deviceSnapshotExpiryGroup) ||
        !identical(filter, owner.onDeviceSnapshotExpiry)) {
      throw StateError('snapshot expiry owner changed before admission');
    }
    final tid = key.substring(key.indexOf('|') + 1);
    if (tid.split(':')[1] != gid) return null;
    if (!_pending.containsKey(key) && _pending.length >= 4096) {
      throw StateError(
        'snapshot validation backlog full; journal retry retained',
      );
    }
    final admission = _pending.putIfAbsent(key, _SnapshotExpiryAdmission.new);
    admission.writing++;
    admission.revision = Object();
    return key;
  }

  void finishAdmission(String key) {
    final admission = _pending[key];
    if (admission == null) return;
    if (admission.writing > 0) admission.writing--;
    if (admission.writing == 0) _validateLater(key);
  }

  void _validateLater(String key) {
    if (_closed || owner._disposed || _pending[key]?.writing != 0) return;
    // Only a bounded identifier is retained; load the durable image on start.
    // The producer returns at admission, releasing its GroupService lock.
    final before = _validation.coalesced;
    final done = _validation.submit(
      key: key,
      bytes: 512 + 4 * key.length,
      send: () async {
        await sweep(only: key);
      },
    );
    if (_validation.coalesced != before) _again.add(key);
    unawaited(
      done.then((_) {
        if (_again.remove(key)) _validateLater(key);
      }),
    );
  }

  Future<void> close() {
    _closed = true;
    return _validation.close();
  }

  void _report(Object cause, StackTrace stack) {
    const message = 'Device snapshot validation deferred';
    final Object safe = switch (cause) {
      FormatException() => const FormatException(message),
      FileSystemException(:final osError) => FileSystemException(
        message,
        null,
        osError == null
            ? null
            : OSError('operation refused', osError.errorCode),
      ),
      _ => StateError(message),
    };
    errorJournal.record(
      kind: 'device-snapshot-expiry',
      error: safe,
      stack: stack,
      atMs: DateTime.now().millisecondsSinceEpoch,
    );
    devLog(
      () =>
          'xVeil[disappearing]: snapshot validation deferred (${cause.runtimeType})',
    );
  }

  Future<int> sweep({String? only}) async {
    while (active) {
      await _idle!.future;
    }
    final filter = owner.onDeviceSnapshotExpiry;
    final group = owner.deviceSnapshotExpiryGroup;
    if (_closed || owner._disposed || filter == null || group == null) return 0;
    final binding = owner.groupBindingsOwner;
    bool current() =>
        !owner._disposed &&
        identical(binding, owner.groupBindingsOwner) &&
        identical(filter, owner.onDeviceSnapshotExpiry) &&
        identical(group, owner.deviceSnapshotExpiryGroup);
    active = true;
    final idle = _idle = Completer<void>();
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
      final present = {
        for (final tid in transfers.keys)
          _MessagingOutbox._key(tid.split(':').last, tid),
      };
      _pending.removeWhere(
        (key, admission) =>
            admission.writing == 0 &&
            key.substring(key.indexOf('|') + 1).split(':')[1] == gid &&
            !present.contains(key) &&
            (only == null || only == key),
      );
      for (final entry in transfers.entries) {
        if (!current()) break;
        final old = entry.value;
        final key = _MessagingOutbox._key(old.first.peerHex, entry.key);
        if ((only != null && key != only) ||
            (_pending[key]?.writing ?? 0) > 0) {
          continue;
        }
        final blocked = <String>{
          for (final f in old) _MessagingOutbox._key(f.peerHex, f.frameId),
        };
        _blocked.addAll(blocked);
        try {
          final bytes = _completeBytes(entry.key, old);
          if (bytes == null) continue;
          final admission = _pending.putIfAbsent(
            key,
            _SnapshotExpiryAdmission.new,
          );
          final revision = admission.revision;
          final original = utf8.decode(bytes);
          final next = await filter(gid, original);
          if (!current()) break;
          if (admission.writing > 0 ||
              !identical(revision, admission.revision)) {
            continue;
          }
          if (next == null || next == original) {
            if (_pending.remove(key) != null) {
              _blocked.removeAll(blocked);
              await _dispatch(old, current);
            }
            continue;
          }
          final nextBytes = Uint8List.fromList(utf8.encode(next));
          if (nextBytes.length > _kMaxGroupReasmBytes) continue;
          final peer = NodeId.fromHex(old.first.peerHex);
          final stamps = old.map((f) => f.enqueuedAtMs).whereType<int>();
          final stamp = stamps.isEmpty
              ? null
              : stamps.reduce((a, b) => a < b ? a : b);
          final fresh = _frames(peer, gid, nextBytes, stamp);
          final freshKey = _transferKey(peer.hex, fresh.first.frameId)!;
          _pending.putIfAbsent(freshKey, _SnapshotExpiryAdmission.new);
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
          if (admission.writing == 0 &&
              identical(revision, admission.revision)) {
            _pending.remove(key);
          }
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
          // Replacement itself awaited disk. Revalidate that new complete
          // image before it can use either initial or retry transport.
          _validateLater(freshKey);
        } catch (error, stack) {
          _report(error, stack);
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
        idle.complete();
      }
    }
  }

  Future<void> _dispatch(
    List<OutboxFrame> frames,
    bool Function() current,
  ) async {
    final peer = NodeId.fromHex(frames.first.peerHex);
    for (final f in frames) {
      owner._outbox._liveBackoff.remove(
        _MessagingOutbox._key(f.peerHex, f.frameId),
      );
    }
    if (await owner._outbox._longSilent(peer.hex) || !current()) return;
    replication._refreshGroupHandlers();
    for (final f in frames) {
      replication._queueStoredGroupWire(
        peer,
        f.frameId,
        f.wire,
        epoch: replication._groupEpoch,
        background: _MessagingOutbox._backgroundWire(f.wire),
      );
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
