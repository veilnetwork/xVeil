part of 'messaging_core.dart';

/// Edit, delete, unsend, and out-of-order mutation handling for 1:1 messages.
class _MessagingMutations {
  _MessagingMutations(this._owner);

  final MessagingService _owner;

  /// Edit/delete operations that drained before their target message.
  ///
  /// In-memory, insertion-ordered, and bounded: no pending mutation metadata is
  /// persisted, and an accepted peer cannot grow this without limit.
  final Map<String, _PendingOp> _pending = {};

  Future<bool> hasMessage(NodeId peer, String id) async {
    final messages = await _owner._storage.loadMessages(peer.hex);
    return messages.any((message) => message.id == id);
  }

  /// True only when [id] is a message the authenticated [peer] sent us.
  Future<bool> isIncomingFrom(NodeId peer, String id) async {
    for (final message in await _owner._storage.loadMessages(peer.hex)) {
      if (message.id == id) {
        return message.direction == MessageDirection.incoming;
      }
    }
    return false;
  }

  String _key(NodeId peer, String id) => '${peer.hex}|$id';

  _PendingOp? takePending(NodeId peer, String id) =>
      _pending.remove(_key(peer, id));

  void bufferPending(NodeId peer, String id, _PendingOp operation) {
    final key = _key(peer, id);
    final existing = _pending[key];
    if (existing != null && existing.isDelete) return;
    if (!_pending.containsKey(key) && _pending.length >= kMaxPendingOps) {
      _pending.remove(_pending.keys.first);
    }
    _pending[key] = operation;
  }

  /// Apply an edit only to a message authored by the peer, or buffer it until
  /// that message arrives. A peer can never rewrite our outgoing row.
  Future<void> applyIncomingEdit(NodeId peer, WireEnvelope envelope) async {
    final id = envelope.id;
    if (id == null) return;
    if (await isIncomingFrom(peer, id)) {
      final target = await _findInConversation(peer.hex, id);
      if (target == null ||
          isSpaceRecommendationMessageBody(target.body) ||
          isSpaceRecommendationMessageBody(envelope.body)) {
        return;
      }
      // Fold under the editor's seq so both devices converge on (author, seq).
      //
      // NOT scrubbed: an edit is a pure APPEND (a new row at a fresh seq), and
      // the superseded bodies are RETAINED on purpose so the edit history reads
      // back — they are reclaimed only by an explicit clear-history or panic
      // erase. So a vacuum here can free nothing, while costing a full sweep of
      // the container and the loss of the warm fold cache. Measured on a real
      // container: ten edits in a row, zero chunks reclaimed each time (a
      // delete, by contrast, frees one per message).
      await _owner._storage.editMessage(
        peer.hex,
        id,
        envelope.body,
        seq: envelope.seq,
        customEmoji: envelope.customEmoji,
      );
    } else if (!await hasMessage(peer, id)) {
      bufferPending(
        peer,
        id,
        _PendingOp.edit(envelope.body, envelope.customEmoji),
      );
    }
  }

  /// Apply an authenticated peer unsend, or buffer it until the post arrives.
  Future<void> applyIncomingDelete(NodeId peer, String id) async {
    if (await isIncomingFrom(peer, id)) {
      await _owner._storage.deleteMessage(peer.hex, id);
      await _owner._storage.scrubDeleted();
    } else if (!await hasMessage(peer, id)) {
      bufferPending(peer, id, _PendingOp.delete());
    }
  }

  /// Delete a message from this device and immediately scrub its plaintext.
  Future<void> deleteLocally(String messageId) async {
    final message = await _find(messageId);
    if (message == null) return;
    await _owner._storage.deleteMessage(message.conversationId, messageId);
    await _owner._storage.scrubDeleted();
    // A deleted file post must stop advertising and serving its bytes too.
    await _releaseServeStateFor(message);
    _owner._signal();
  }

  /// Drop live and durable serve state unless another message references it.
  Future<void> _releaseServeStateFor(Message message) async {
    final contentId = message.fileContentId ?? message.fileId;
    if (contentId == null) return;
    try {
      if (await _contentReferencedByAnyMessage(contentId)) return;
      final live = _owner._serving.remove(contentId);
      if (live?.source != null) unawaited(live!.source!.close());
      // Storage has no removeSetting; an empty value is the durable tombstone.
      await _owner._storage.putSetting('served:$contentId', '');
      devLog(
        () =>
            'xVeil[content]: released serve state for '
            '${contentId.substring(0, 12)} (message deleted)',
      );
    } catch (error) {
      devLog(() => 'xVeil[content]: release serve state failed: $error');
    }
  }

  Future<bool> _contentReferencedByAnyMessage(String contentId) async {
    for (final conversation in await _owner._storage.loadConversations()) {
      for (final message in await _owner._storage.loadMessages(
        conversation.id,
      )) {
        if (message.fileContentId == contentId || message.fileId == contentId) {
          return true;
        }
      }
    }
    return false;
  }

  /// Delete one of our sent messages locally and durably unsend it at the peer.
  Future<void> deleteForEveryone(String messageId) async {
    final message = await _find(messageId);
    if (message == null || message.direction != MessageDirection.outgoing) {
      return;
    }
    final destination = NodeId.fromHex(message.conversationId);
    await deleteLocally(messageId);
    await _owner.sendDurable(
      destination,
      'del:$messageId',
      WireEnvelope.del(messageId),
    );
  }

  /// Revoke only the recommendation card originally sent to [peer].
  ///
  /// Binding both the authenticated conversation and the reserved typed body
  /// prevents an audit row (or an API caller) from turning this into an
  /// arbitrary-message deletion primitive.
  Future<bool> revokeSpaceRecommendation(NodeId peer, String messageId) async {
    final message = await _find(messageId);
    if (message == null ||
        message.direction != MessageDirection.outgoing ||
        message.conversationId != peer.hex ||
        parseSpaceRecommendationMessage(message.body) == null) {
      return false;
    }
    await deleteForEveryone(messageId);
    return true;
  }

  /// Edit one of our sent messages and durably propagate the new version.
  Future<void> editOwnMessage(
    String messageId,
    String newBody, {
    List<InlineCustomEmoji> customEmoji = const [],
  }) async {
    final trimmed = newBody.trim();
    if (trimmed.isEmpty) return;
    if (isSpaceRecommendationMessageBody(trimmed)) return;
    if (!isValidInlineCustomEmoji(trimmed, customEmoji)) return;
    final message = await _find(messageId);
    if (message == null || message.direction != MessageDirection.outgoing) {
      return;
    }
    if (isSpaceRecommendationMessageBody(message.body)) return;
    // Append-only, like the incoming edit above — no chunk is orphaned, so
    // there is nothing for a vacuum to reclaim (see [applyIncomingEdit]).
    final editSeq = await _owner._storage.editMessage(
      message.conversationId,
      messageId,
      trimmed,
      customEmoji: customEmoji,
    );
    _owner._signal();
    final destination = NodeId.fromHex(message.conversationId);
    // Include the edit seq in the durable id: every edit is distinct, while a
    // re-drive of the same edit remains idempotent and cannot regress the fold.
    await _owner.sendDurable(
      destination,
      'edit:$messageId:${editSeq ?? _uuid.v4()}',
      WireEnvelope.edit(
        messageId,
        trimmed,
        seq: editSeq,
        customEmoji: customEmoji,
      ),
    );
  }

  Future<Message?> _find(String messageId) async {
    for (final conversation in await _owner._storage.loadConversations()) {
      for (final message in await _owner._storage.loadMessages(
        conversation.id,
      )) {
        if (message.id == messageId) return message;
      }
    }
    return null;
  }

  Future<Message?> _findInConversation(
    String conversationId,
    String messageId,
  ) async {
    for (final message in await _owner._storage.loadMessages(conversationId)) {
      if (message.id == messageId) return message;
    }
    return null;
  }
}
