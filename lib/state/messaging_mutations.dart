part of 'messaging_core.dart';

/// Edit, delete, unsend, and out-of-order mutation handling for 1:1 messages.
class _MessagingMutations {
  _MessagingMutations(this._owner);

  final MessagingService _owner;

  Future<void> _deletionTail = Future<void>.value();
  Future<int>? _repair;
  String? _repairCursor;

  Future<T> _sequenceDeletion<T>(Future<T> Function() action) {
    final result = _deletionTail.then((_) {
      if (_owner._disposed) throw StateError('messaging is disposing');
      return action();
    });
    _deletionTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace trace) {},
    );
    return result;
  }

  Future<void> quiesce() => _deletionTail;

  /// Coalesce background retries. A failed first page must not starve later
  /// decisions, and repeated retry ticks must not build an unbounded queue.
  Future<int> retryPendingDeletions() {
    final active = _repair;
    if (active != null) return active;
    if (_owner._disposed) return Future<int>.value(0);
    late final Future<int> run;
    run =
        _sequenceDeletion(() async {
          final publisher = _owner.onMessageDeleted;
          final rows = await _owner._storage.pendingMessageDeletions(
            afterKey: _repairCursor,
            includeMirrorOnly: publisher != null,
          );
          if (rows.isEmpty) {
            _repairCursor = null;
            return 0;
          }
          var complete = 0;
          for (final row in rows) {
            if (_owner._disposed) break;
            _repairCursor = pendingMessageDeletionKey(row);
            try {
              if (await _finishDeletion(row, publisher: publisher)) complete++;
            } catch (_) {
              /* the tombstone retains every unfinished effect */
            }
          }
          return complete;
        }).catchError((Object _) => 0).whenComplete(() {
          if (identical(_repair, run)) _repair = null;
        });
    _repair = run;
    return run;
  }

  Future<bool> _finishDeletion(
    PendingMessageDeletion pending, {
    FutureOr<void> Function(NodeId, String)? publisher,
  }) async {
    // The pending-intent read has already completed committed physical scrubs.
    final peer = NodeId.fromHex(pending.conversationId);
    final id = pending.messageId;
    Object? failure;
    StackTrace? failureTrace;
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, trace) {
        failure ??= error;
        failureTrace ??= trace;
      }
    }

    var peerDone = !pending.peerPending;
    var mirrorDone = !pending.mirrorPending;
    var servingDone = pending.contentId == null;
    // Peer handoff is independent of the device journal. The existing durable
    // send persists first and attempts live delivery without waiting for a
    // general outbox flush. DEL never goes through mailbox.
    if (pending.peerPending) {
      await attempt(() async {
        final frameId = 'del:$id';
        await _owner.sendDurable(peer, frameId, WireEnvelope.del(id));
        await _owner._storage.completeMessageDeletion(peer.hex, id, peer: true);
        peerDone = true;
      });
    }
    if (pending.contentId != null) {
      await attempt(() async {
        await _releaseServeStateForContent(pending.contentId!);
        await _owner._storage.completeMessageDeletion(
          peer.hex,
          id,
          serving: true,
        );
        await _owner._storage.scrubDeleted();
        servingDone = true;
      });
    }
    final publish = publisher ?? _owner.onMessageDeleted;
    if (pending.mirrorPending && publish != null) {
      await attempt(() async {
        await publish(peer, id);
        // A binding replacement may represent a new device-group owner. Keep
        // the obligation until the currently bound publisher has committed it.
        if (identical(publish, _owner.onMessageDeleted)) {
          await _owner._storage.completeMessageDeletion(
            peer.hex,
            id,
            mirror: true,
          );
          mirrorDone = true;
        }
      });
    }
    if (failure != null) Error.throwWithStackTrace(failure!, failureTrace!);
    final complete = peerDone && mirrorDone && servingDone;
    if (complete) rememberDeleteCompleted(peer, id);
    return complete;
  }

  Future<void> _retryDeletedId(
    String id, {
    FutureOr<void> Function(NodeId, String)? publisher,
  }) async {
    // Only already-authorized intents can be recovered without a live row.
    for (final row in await _owner._storage.pendingMessageDeletions(
      messageId: id,
      limit: 256,
    )) {
      await _finishDeletion(row, publisher: publisher);
    }
  }

  /// Edit/delete operations that drained before their target message.
  ///
  /// In-memory, insertion-ordered, and bounded. A peer frame waiting here is
  /// NOT ACKed: its durable sender outbox owns recovery after our restart or
  /// eviction. Own-device mutations are replayed from the signed device log.
  final Map<String, ({int order, _PendingOp op})> _pending = {};
  int _pendingOrder = 0;
  final Set<String> _completedDeletes = {};

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

  String _key(NodeId peer, String id, bool incomingOnly) =>
      '${peer.hex}|$id|${incomingOnly ? 'peer' : 'device'}';

  _PendingOp? takePending(
    NodeId peer,
    String id, {
    MessageDirection direction = MessageDirection.incoming,
  }) {
    final candidates = [
      ?_pending.remove(_key(peer, id, false)),
      ?_pending.remove(_key(peer, id, true)),
    ]..sort((a, b) => a.order.compareTo(b.order));
    _PendingOp? winner;
    for (final candidate in candidates) {
      if (candidate.op.incomingOnly && direction != MessageDirection.incoming) {
        continue;
      }
      if (winner == null || _pendingEditWins(candidate.op, winner)) {
        winner = candidate.op;
      }
    }
    return winner;
  }

  bool _pendingEditWins(_PendingOp candidate, _PendingOp held) {
    if (held.isDelete) return false;
    if (candidate.isDelete) return true;
    if (candidate.seq == null) return held.seq == null;
    return messageEditWins(
      revision: candidate.seq!,
      contentHash: messageEditContentHash(
        candidate.body!,
        candidate.customEmoji,
      ),
      heldRevision: held.seq,
      heldContentHash: messageEditContentHash(held.body!, held.customEmoji),
    );
  }

  void bufferPending(NodeId peer, String id, _PendingOp operation) {
    final key = _key(peer, id, operation.incomingOnly);
    final existing = _pending[key];
    if (existing != null && !_pendingEditWins(operation, existing.op)) return;
    if (!_pending.containsKey(key) && _pending.length >= kMaxPendingOps) {
      _pending.remove(_pending.keys.first);
    }
    _pending[key] = (order: ++_pendingOrder, op: operation);
  }

  /// Apply an edit only to a message authored by the peer, or buffer it until
  /// that message arrives. A peer can never rewrite our outgoing row.
  /// False means only volatile buffering happened: do not ACK the frame yet.
  Future<bool> applyIncomingEdit(NodeId peer, WireEnvelope envelope) async {
    final id = envelope.id;
    if (id == null) return true;
    if (await isIncomingFrom(peer, id)) {
      final target = await _findInConversation(peer.hex, id);
      if (target == null ||
          isSpaceRecommendationMessageBody(target.body) ||
          isSpaceRecommendationMessageBody(envelope.body)) {
        return true;
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
      // Only the device the peer reached heard this. The others keep showing
      // the text the sender replaced.
      _owner._deviceMirror.onMessageEdited?.call(
        peer,
        id,
        envelope.body,
        envelope.customEmoji,
      );
    } else if (!await hasMessage(peer, id) &&
        !await _owner._storage.isMessageDeleted(peer.hex, id)) {
      bufferPending(
        peer,
        id,
        _PendingOp.edit(
          envelope.body,
          envelope.customEmoji,
          incomingOnly: true,
          seq: envelope.seq,
        ),
      );
      return false;
    }
    return true;
  }

  /// Apply an authenticated peer unsend, or buffer it until the post arrives.
  /// False leaves recovery with the sender's durable outbox.
  Future<bool> applyIncomingDelete(NodeId peer, String id) async {
    final deleted = await _owner._storage.isMessageDeleted(peer.hex, id);
    if (deleted && isDeleteCompleted(peer, id)) return true;
    if (deleted || await isIncomingFrom(peer, id)) {
      // A preceding attempt can have committed its tombstone but failed the
      // forensic scrub. A retry must finish that work even with no live row.
      await completeDelete(peer, id, notifyDevices: true);
    } else if (!await hasMessage(peer, id)) {
      bufferPending(peer, id, _PendingOp.delete(incomingOnly: true));
      return false;
    }
    return true;
  }

  bool isDeleteCompleted(NodeId peer, String id) =>
      _completedDeletes.contains(_key(peer, id, true));

  void rememberDeleteCompleted(NodeId peer, String id) {
    _completedDeletes.add(_key(peer, id, true));
    if (_completedDeletes.length > kMaxPendingOps) {
      _completedDeletes.remove(_completedDeletes.first);
    }
  }

  /// The caller has authorized the now-known target's direction. A peer
  /// mutation must enter our durable device log; a deletion FROM that log
  /// must not echo back. Cache completion only after scrub AND publication.
  Future<void> completeDelete(
    NodeId peer,
    String id, {
    required bool notifyDevices,
  }) async {
    await _owner._storage.deleteMessage(peer.hex, id);
    await _owner._storage.scrubDeleted();
    // The local erasure already happened even if publishing to our own
    // devices fails. Do not leave the deleted body visible until another event.
    _owner._signal();
    if (notifyDevices) {
      await _owner._deviceMirror.onMessageDeleted?.call(peer, id);
    }
    rememberDeleteCompleted(peer, id);
  }

  /// Delete a message from this device and immediately scrub its plaintext.
  ///
  /// "This device" was the whole of it until 2026-09-21, and that made the
  /// strongest act in the app the least effective one: `deleteForEveryone`
  /// calls straight through here, so a message erased for the PEER stayed
  /// readable on the person's own second device. The design this path comes
  /// from (doc/MESSAGE-EDIT-DELETE-DESIGN.md) is built for a container opened
  /// under coercion — a surviving sibling copy is precisely the outcome it
  /// exists to prevent, so a delete is now told to the device group.
  Future<void> deleteLocally(String messageId) {
    final publisher = _owner.onMessageDeleted;
    return _sequenceDeletion(
      () => _deleteLocalDecision(
        messageId,
        intent: MessageDeletionIntent.devices,
        publisher: publisher,
      ),
    );
  }

  Future<void> _deleteLocalDecision(
    String messageId, {
    required MessageDeletionIntent intent,
    FutureOr<void> Function(NodeId, String)? publisher,
  }) async {
    final message = await _find(messageId);
    if (message == null) {
      await _retryDeletedId(messageId, publisher: publisher);
      return;
    }
    if (intent == MessageDeletionIntent.everyone &&
        message.direction != MessageDirection.outgoing) {
      return;
    }
    try {
      await _owner._storage.deleteMessage(
        message.conversationId,
        messageId,
        intent: intent,
      );
    } finally {
      // Eager blob cleanup can fail AFTER its atomic tombstone commit.
      _owner._signal();
    }
    await _owner._storage.scrubDeleted();
    await _retryDeletedId(messageId, publisher: publisher);
  }

  /// Drop live and durable serve state unless another post references it.
  /// Failure is retried from the body-less tombstone, not silently forgotten.
  Future<void> _releaseServeStateForContent(String contentId) async {
    if (await _contentReferencedByAnyMessage(contentId)) return;
    final live = _owner._serving[contentId];
    if (live?.source != null) await live!.source!.close();
    if (identical(_owner._serving[contentId], live)) {
      _owner._serving.remove(contentId);
    }
    await _owner._storage.putSetting('served:$contentId', '');
    devLog(() => 'xVeil[content]: released deleted message serve state');
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
  Future<void> deleteForEveryone(String messageId) {
    final publisher = _owner.onMessageDeleted;
    return _sequenceDeletion(
      () => _deleteLocalDecision(
        messageId,
        intent: MessageDeletionIntent.everyone,
        publisher: publisher,
      ),
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
    // My other devices hold their own copy and hear no `edit:` — that frame
    // goes to the PEER. Without this they show the superseded text for good.
    _owner._deviceMirror.onMessageEdited?.call(
      NodeId.fromHex(message.conversationId),
      messageId,
      trimmed,
      customEmoji,
    );
    _owner._signal();
    final destination = NodeId.fromHex(message.conversationId);
    // A compact value-specific ID distinguishes concurrent revisions without
    // adding the body or a long target ID to the delivery envelope.
    final operation = crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              messageId,
              editSeq ?? _uuid.v4(),
              messageEditContentHash(trimmed, customEmoji),
            ]),
          ),
        )
        .toString()
        .substring(0, 32);
    await _owner.sendDurable(
      destination,
      'edit:$operation',
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
