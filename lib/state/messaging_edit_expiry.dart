part of 'messaging_core.dart';

/// Edits carry another copy of a message body outside its event journal.
/// Expiry follows the ORIGINAL post, never the edit/enqueue time. A durable
/// tombstone remains authoritative after TTL-off, restart or clock rollback.
class _MessageEditExpiry {
  _MessageEditExpiry(this.outbox);
  final _MessagingOutbox outbox;
  MessagingService get owner => outbox._owner;
  final _retiring = <String>{};
  bool _sweeping = false;
  bool blocks(String peer, String id) =>
      _retiring.contains(_MessagingOutbox._key(peer, id));

  Future<bool> _expired(NodeId peer, String id) async {
    if (await owner._storage.isMessageDeleted(peer.hex, id)) return true;
    final original = await owner._storage.loadMessageById(peer.hex, id);
    // Missing, foreign and incoming rows cannot justify discarding an edit.
    if (original == null || original.direction != MessageDirection.outgoing) {
      return false;
    }
    final contact = await owner._storage.getContact(peer);
    final setting = DisappearingSetting(
      ttlSeconds: contact?.disappearingTtlSeconds,
      setAtMs: contact?.disappearingSetAtMs ?? 0,
      setBy: contact?.disappearingSetBy ?? '',
    );
    if (!setting.hasExpired(original.timestamp, owner._now())) return false;
    if (owner._disposed) return true;
    // Use the existing local erasure path: it keeps sequence slots and voids
    // historical edit bodies as well as the post, with no peer-delete intent.
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
  }) async {
    WireEnvelope envelope;
    try {
      envelope = WireEnvelope.decode(wire);
    } catch (_) {
      return true; // This rule does not own malformed/legacy non-edit data.
    }
    if (envelope.kind != WireKind.edit || envelope.id == null) return true;
    if (envelope.frameId != null && envelope.frameId != frameId) return true;
    final peer = NodeId.fromHex(peerHex);
    if (owner._disposed || blocks(peer.hex, frameId)) return false;
    if (!await _expired(peer, envelope.id!)) return !owner._disposed;
    if (owner._disposed) return false;
    final key = _MessagingOutbox._key(peer.hex, frameId);
    if (!_retiring.add(key)) return false;
    outbox._flushSnapshot?.invalidate(key);
    try {
      var queuedAt = enqueuedAtMs;
      if (persisted && queuedAt == null) {
        // Initial sends know the wire but not the storage admission stamp.
        // Read it only on expiry; healthy sends need no queue scan. The
        // replacement below still CAS-checks the exact peer/id/wire bytes.
        final held = (await owner._storage.pendingOutboxFrames())
            .where((frame) => frame.peerHex == peerHex && frame.frameId == frameId)
            .firstOrNull;
        if (held == null) return false; // Already ACKed or replaced.
        queuedAt = held.enqueuedAtMs;
      }
      // The placeholder has no target/body. Bind its stable ID to the exact
      // old wire AND recipient, so retries are idempotent across restarts.
      final digestInput = BytesBuilder(copy: false)
        ..add(utf8.encode('xveil:expired-edit:v1\u0000'))
        ..add(peer.bytes)
        ..add(wire);
      final id =
          'expired-edit:${crypto.sha256.convert(digestInput.takeBytes())}';
      final seq = envelope.seq;
      final placeholder = seq != null && seq > 0
          ? WireEnvelope.voidSeq(seq).withFrameId(id)
          : null;
      if (persisted) {
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
          outbox._liveBackoff.remove(key);
          owner._mailboxDelivery.removeStashed(frameId);
          outbox._pendingSeeded = false;
          await owner._storage.finishOutboxCleanup();
        }
      } else if (placeholder != null) {
        // An edit can expire while its local mutation/publication is waiting.
        // Never write the body into Outbox just to remove it again.
        await outbox.send(peer, id, placeholder, awaitLive: false);
      }
    } finally {
      _retiring.remove(key);
    }
    return false;
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
