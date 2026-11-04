part of 'messaging_core.dart';

enum _PeerBodyState { live, gone, deferred }

/// A history read cannot assume the background prune already ran. A bodyless
/// authored slot is justified only by a durable local deletion decision;
/// storage failures never become synthetic receipt/deletion evidence.
class _PeerHistoryExpiry {
  _PeerHistoryExpiry(this.owner);
  final MessagingService owner;

  void _report(String kind, Object error) => errorJournal.record(
    kind: kind,
    error: error,
    atMs: owner._now().millisecondsSinceEpoch,
  );

  Future<_PeerBodyState> state(NodeId peer, String id) async {
    try {
      if (owner._disposed) return _PeerBodyState.deferred;
      if (await owner._storage.isMessageDeleted(peer.hex, id)) {
        return _PeerBodyState.gone;
      }
      final original = await owner._storage.loadMessageById(peer.hex, id);
      final setting = await owner.disappearingOf(peer);
      if (owner._disposed) return _PeerBodyState.deferred;
      if (await owner._storage.isMessageDeleted(peer.hex, id)) {
        return _PeerBodyState.gone;
      }
      if (original == null) {
        // A legacy missing target has no original clock. Retain it, and do
        // not invent a void under an active TTL from the edit's own time.
        if (setting.isOn) {
          _report(
            'peer-sync-expiry-origin',
            StateError('Original post unavailable'),
          );
          return _PeerBodyState.deferred;
        }
        return _PeerBodyState.live;
      }
      if (!setting.hasExpired(original.timestamp, owner._now())) {
        return _PeerBodyState.live;
      }
      try {
        await owner._storage.deleteMessage(peer.hex, id);
      } catch (error) {
        // A failed scrub/reply may follow the committed tombstone. Re-read
        // the authoritative decision rather than assuming either outcome.
        devLog(
          () => 'xVeil[sync]: expiry erase deferred (${error.runtimeType})',
        );
        _report('peer-sync-expiry-erase', error);
      }
      if (owner._disposed) return _PeerBodyState.deferred;
      return await owner._storage.isMessageDeleted(peer.hex, id)
          ? _PeerBodyState.gone
          : _PeerBodyState.deferred;
    } catch (error) {
      devLog(
        () => 'xVeil[sync]: expiry validation deferred (${error.runtimeType})',
      );
      _report('peer-sync-expiry-read', error);
      return _PeerBodyState.deferred;
    }
  }

  Future<LogEvent?> event(NodeId peer, LogEvent event) async {
    if (event.kind != EventKind.post &&
        event.kind != EventKind.filePost &&
        event.kind != EventKind.edit) {
      return event;
    }
    final id = event.kind == EventKind.edit ? event.target : event.id;
    if (id == null) return null;
    switch (await state(peer, id)) {
      case _PeerBodyState.live:
        return event;
      case _PeerBodyState.deferred:
        return null;
      case _PeerBodyState.gone:
        return (
          kind: EventKind.void_,
          author: event.author,
          seq: event.seq,
          id: '',
          target: null,
          body: null,
          ts: 0,
          replyTo: null,
          forwardedFrom: null,
          customEmoji: const <InlineCustomEmoji>[],
        );
    }
  }

  /// Purely exclude expired rows BEFORE paginating/hash work. This is not a
  /// declaration about the peer's authored sequence and does not mint voids.
  Future<List<Message>> visible(NodeId peer, List<Message> messages) async {
    try {
      final setting = await owner.disappearingOf(peer);
      if (owner._disposed) return [];
      final now = owner._now();
      return [
        for (final m in messages)
          if (!setting.hasExpired(m.timestamp, now)) m,
      ];
    } catch (error) {
      _report('peer-sync-expiry-read', error);
      return [];
    }
  }
}
