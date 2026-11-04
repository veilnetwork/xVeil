part of 'messaging_core.dart';

/// Edits carry another copy of a message body outside its event journal.
/// Expiry follows the ORIGINAL post, never the edit/enqueue time. A durable
/// tombstone remains authoritative after TTL-off, restart or clock rollback.
class _MessageEditExpiry {
  _MessageEditExpiry(this.outbox);
  final _MessagingOutbox outbox;
  MessagingService get owner => outbox._owner;
  final _retiring = <String, ({String id, Future<void> done})>{};
  final _active = <Future<bool>>{};
  bool _sweeping = false, _closed = false;
  bool blocks(String peer, String id) =>
      _retiring.containsKey(_MessagingOutbox._key(peer, id));

  Future<bool> _expired(NodeId peer, String id) async {
    if (await owner._storage.isMessageDeleted(peer.hex, id)) return true;
    final original = await owner._storage.loadMessageById(peer.hex, id);
    // A concurrent erase can remove the row after the first tombstone read.
    // Missing/foreign/incoming content alone is not deletion authority.
    if (original == null || original.direction != MessageDirection.outgoing) {
      return owner._storage.isMessageDeleted(peer.hex, id);
    }
    final contact = await owner._storage.getContact(peer);
    final setting = DisappearingSetting(
      ttlSeconds: contact?.disappearingTtlSeconds,
      setAtMs: contact?.disappearingSetAtMs ?? 0,
      setBy: contact?.disappearingSetBy ?? '',
    );
    // The row can be erased while policy is read. Evaluate the clock AFTER
    // this last read too: TTL may expire while the storage worker is busy.
    if (await owner._storage.isMessageDeleted(peer.hex, id)) return true;
    if (!setting.hasExpired(original.timestamp, owner._now())) return false;
    if (owner._disposed) return true;
    await owner._storage.deleteMessage(peer.hex, id);
    if (!owner._disposed) owner._signal();
    return true;
  }

  Future<bool> allow(
    String peerHex,
    String frameId,
    Uint8List wire, {
    required bool persisted,
    int? enqueuedAtMs,
  }) {
    WireEnvelope envelope;
    try {
      envelope = WireEnvelope.decode(wire);
    } catch (_) {
      return Future.value(true); // This rule does not own malformed wire.
    }
    if (envelope.kind != WireKind.edit || envelope.id == null) {
      return Future.value(true);
    }
    if (envelope.frameId != null && envelope.frameId != frameId) {
      return Future.value(true);
    }
    if (_closed || owner._disposed) return Future.value(false);
    // Track local validation too: it can already be erasing the canonical row
    // before a replacement is registered. No network future is joined here.
    late final Future<bool> task;
    task =
        _allowEdit(
          peerHex,
          frameId,
          wire,
          envelope,
          persisted: persisted,
          enqueuedAtMs: enqueuedAtMs,
        ).whenComplete(() {
          _active.remove(task);
        });
    _active.add(task);
    return task;
  }

  String _replacementId(NodeId peer, Uint8List wire) {
    final digestInput = BytesBuilder(copy: false)
      ..add(utf8.encode('xveil:expired-edit:v1\u0000'))
      ..add(peer.bytes)
      ..add(wire);
    return 'expired-edit:${crypto.sha256.convert(digestInput.takeBytes())}';
  }

  Future<bool> _allowEdit(
    String peerHex,
    String frameId,
    Uint8List wire,
    WireEnvelope envelope, {
    required bool persisted,
    int? enqueuedAtMs,
  }) async {
    final peer = NodeId.fromHex(peerHex);
    final key = _MessagingOutbox._key(peer.hex, frameId);
    while (!_closed && !owner._disposed) {
      final current = _retiring[key];
      if (current != null) {
        final sameWire = current.id == _replacementId(peer, wire);
        await current.done; // Cleanup failure belongs to every joining caller.
        if (sameWire) return false;
        continue; // A different payload needs its own current-state verdict.
      }
      final expired = await _expired(peer, envelope.id!);
      if (_closed || owner._disposed) return false;
      // Another validator may have registered a replacement during our read.
      if (_retiring.containsKey(key)) continue;
      if (!expired) return true;
      final ownedWire = Uint8List.fromList(wire);
      final id = _replacementId(peer, ownedWire);
      outbox._flushSnapshot?.invalidate(key);
      late final Future<void> done;
      done =
          Future<void>.microtask(
            () => _retire(
              peer,
              frameId,
              ownedWire,
              envelope,
              id,
              persisted: persisted,
              enqueuedAtMs: enqueuedAtMs,
            ),
          ).whenComplete(() {
            if (identical(_retiring[key]?.done, done)) _retiring.remove(key);
          });
      _retiring[key] = (id: id, done: done);
      await done;
      return false;
    }
    return false;
  }

  Future<void> _retire(
    NodeId peer,
    String frameId,
    Uint8List wire,
    WireEnvelope envelope,
    String id, {
    required bool persisted,
    int? enqueuedAtMs,
  }) async {
    var queued = persisted;
    var queuedAt = enqueuedAtMs;
    if (!persisted || queuedAt == null) {
      // A manual retry enters before enqueue even if its old wire is ALREADY
      // durable. Retire that copy as well, preserving its actual queue stamp.
      // Healthy edits do not scan the queue. CAS still checks exact wire bytes.
      final held = (await owner._storage.pendingOutboxFrames())
          .where(
            (frame) => frame.peerHex == peer.hex && frame.frameId == frameId,
          )
          .firstOrNull;
      if (held == null && persisted) {
        await owner._storage.finishOutboxCleanup();
        return;
      }
      queued = held != null;
      queuedAt ??= held?.enqueuedAtMs;
    }
    final seq = envelope.seq;
    final placeholder = seq != null && seq > 0
        ? WireEnvelope.voidSeq(seq).withFrameId(id)
        : null;
    if (queued) {
      final changed = await owner._storage.replaceOutboxFrames(
        [
          OutboxFrame(
            frameId: frameId,
            peerHex: peer.hex,
            wire: wire,
            enqueuedAtMs: queuedAt,
          ),
        ],
        [
          if (placeholder != null)
            OutboxFrame(
              frameId: id,
              peerHex: peer.hex,
              wire: placeholder.encode(),
              enqueuedAtMs: queuedAt,
            ),
        ],
      );
      if (changed) {
        outbox._liveBackoff.remove(_MessagingOutbox._key(peer.hex, frameId));
        owner._mailboxDelivery.removeStashed(frameId);
        outbox._pendingSeeded = false;
      }
      // A prior replacement may have committed but failed its scrub. Even
      // when CAS now returns false, the caller must finish that durable work.
      await owner._storage.finishOutboxCleanup();
    } else {
      await owner._storage.finishOutboxCleanup();
      if (placeholder != null) {
        await outbox.send(peer, id, placeholder, awaitLive: false);
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    // Only local reads/writes and bodyless queue admission live in this set.
    // Preserve errors for the original callers while finishing owner teardown.
    await Future.wait<void>([
      for (final task in _active.toList())
        task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
  }

  Future<void> sweep() async {
    if (_sweeping || owner._disposed) return;
    _sweeping = true;
    try {
      await owner._storage.finishOutboxCleanup();
      final pending = await owner._storage.pendingOutboxFrames();
      for (final frame in pending) {
        if (owner._disposed) break;
        try {
          await allow(
            frame.peerHex,
            frame.frameId,
            frame.wire,
            persisted: true,
            enqueuedAtMs: frame.enqueuedAtMs,
          );
        } catch (error) {
          devLog(
            () =>
                'xVeil[disappearing]: queued edit cleanup deferred '
                '(${error.runtimeType})',
          );
        }
      }
      if (!owner._disposed) await outbox.ensurePendingCounted();
    } finally {
      _sweeping = false;
    }
  }
}
