part of 'messaging_core.dart';

/// A delayed authenticated frame can outlive the local TTL sweep. Refusal is
/// durable before receipt; expiry does not grant a peer authority over another
/// author's stream, and a mirrored edit never publishes back to its source.
class _MessagingInboundExpiry {
  _MessagingInboundExpiry(this.owner);
  final MessagingService owner;

  Future<bool> expired(NodeId peer, DateTime timestamp) async =>
      (await owner.disappearingOf(peer)).hasExpired(timestamp, owner._now());

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      errorJournal.record(
        kind: 'inbound-expiry',
        error: error,
        atMs: owner._now().millisecondsSinceEpoch,
      );
      rethrow;
    }
  }

  Future<void> _finish(NodeId peer, String id, {int? peerSeq}) async {
    if (owner._disposed) throw StateError('Messaging is disposing');
    if (!owner._mutations.isDeleteCompleted(peer, id)) {
      await owner._mutations.completeDelete(peer, id, notifyDevices: true);
    }
    // Only the authenticated peer's own wire sequence may be occupied here.
    // Reflected/mirrored revisions do not prove an authored stream position.
    if (peerSeq != null) {
      await owner._storage.applyRemoteVoid(peer.hex, peer.hex, peerSeq);
    }
  }

  Future<bool> post(
    NodeId peer,
    String? id,
    DateTime? timestamp,
    int? seq,
  ) => _guard(() async {
    final held = id == null
        ? null
        : await owner._storage.loadMessageById(peer.hex, id);
    if (!await expired(peer, held?.timestamp ?? timestamp ?? owner._now())) {
      return false;
    }
    if (owner._disposed) throw StateError('Messaging is disposing');
    if (id != null) {
      if (held == null &&
          !await owner._storage.recordExpiredMessage(
            peer.hex,
            id,
            author: peer.hex,
            seq: seq,
          ) &&
          !await owner._storage.isMessageDeleted(peer.hex, id)) {
        // A mirror may have inserted the same ID while the marker waited.
        // Revalidate its original clock rather than erasing a live row.
        final current = await owner._storage.loadMessageById(peer.hex, id);
        if (current == null) throw StateError('Expiry decision unavailable');
        if (!await expired(peer, current.timestamp)) return false;
      }
      await _finish(peer, id, peerSeq: seq);
      // A prior edit may have arrived ahead of its expired original. Its
      // sender still owns retry; do not retain the orphaned body in RAM.
      owner._mutations.takePending(peer, id);
    }
    return true;
  });

  Future<bool> edit(NodeId peer, Message target, {bool mirrored = false}) =>
      _guard(() async {
        if (!await expired(peer, target.timestamp)) return false;
        if (owner._disposed) throw StateError('Messaging is disposing');
        if (mirrored) {
          await owner._storage.deleteMessage(peer.hex, target.id);
          owner._signal();
        } else {
          await _finish(peer, target.id);
        }
        return true;
      });

  Future<void> deletedEdit(NodeId peer, String id, int? seq) =>
      _guard(() => _finish(peer, id, peerSeq: seq));
}
