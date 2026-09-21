part of 'messaging_core.dart';

/// Multi-device projections owned by the messaging layer.
///
/// Mirrored writes deliberately bypass the ordinary local callbacks so an
/// event received from another device cannot loop back into the device group.
/// Relationship state and per-device P2P policy remain local; only the fields
/// explicitly carried by the bridge are merged.
class _MessagingDeviceMirror {
  _MessagingDeviceMirror(this._owner);

  final MessagingService _owner;

  /// Fires after an ordinary 1:1 messaging write, never after [applyMessage].
  void Function(NodeId peer, Message stored)? onMessageStored;

  /// Fires when one of OUR OWN outgoing messages moves on — the peer's
  /// acknowledgement landed, or the send failed. Only this device hears that,
  /// so a sibling has no other way to learn it.
  ///
  /// Never fired for a status applied FROM a sibling, for the same reason
  /// [onMessageStored] is not fired by [applyMessage]: an event received from
  /// the device group must not loop back into it.
  void Function(NodeId peer, String msgId, MessageStatus status)?
  onMessageStatusChanged;

  /// Fires when a message is erased HERE — by this person, or by the peer who
  /// sent it unsending it. Never fired for an erase applied FROM a sibling.
  void Function(NodeId peer, String msgId)? onMessageDeleted;

  /// Lets the device bridge offer an additional authenticated content source.
  Future<void> Function(String contentId)? deviceContentPull;

  /// Fires only after a local edit of sync-worthy contact preferences.
  void Function(Contact updated)? onContactPrefsChanged;

  /// Apply a message projected from another device without re-mirroring it.
  ///
  /// [tsMs] is bounded by [messageTsOnReceipt] like any other stamp that
  /// arrives from someone else, and this path needs it MORE than the wire path
  /// does: a mirrored row is stored without an author or a seq, so it is off
  /// the event streams the author-monotone effective-ts floor is computed over
  /// and falls back to its raw timestamp for display. Nothing else here reads
  /// the clock — a future stamp that lands keeps the conversation pinned to the
  /// top of the chat list, and poisons its read watermark, until it arrives.
  ///
  /// The value the emit tap mirrors on is the STORED row's timestamp, so a
  /// stamp bounded on the device that received it from the wire travels to the
  /// siblings already bounded and is a no-op here.
  /// Write a sibling's report of how far one of our messages has got.
  ///
  /// Silent when the message is not here yet: the mirror that carries it and
  /// the status ride the same log, so the next fold replay applies this once
  /// the message exists. Never fires [onMessageStatusChanged] — an event from
  /// the device group must not loop back into it.
  Future<void> applyMessageStatus({
    required NodeId peer,
    required String msgId,
    required MessageStatus status,
  }) async {
    if (_owner._disposed) return;
    try {
      await _owner._storage.markMessageStatus(peer.hex, msgId, status);
    } catch (e) {
      devLog(() => 'xVeil[devices]: mirrored status for $msgId failed: $e');
    }
  }

  /// Erase a message because one of my other devices erased it.
  ///
  /// Goes straight to storage rather than through [deleteLocally]: that path
  /// fires [onMessageDeleted], and an erase received from the device group
  /// must not loop back into it.
  ///
  /// A tombstone can outrun the mirror that carries its message — both ride
  /// the same log, but an oversized mirror is deferred to a later fetch window
  /// while a tiny tombstone is not — and `Storage.deleteMessage` writes nothing
  /// for a message it cannot find. So an erase with nothing to erase is PARKED
  /// in the same pending buffer a peer's unsend uses, and [applyMessage] spends
  /// it when the message finally lands.
  Future<void> applyDelete({
    required NodeId peer,
    required String msgId,
  }) async {
    if (_owner._disposed) return;
    try {
      // Already erased here, so there is nothing to park. This is the COMMON
      // case, not an edge one: the folded device-sync state is replayed into
      // the appliers on every app start, so every tombstone the group has ever
      // carried arrives again — and parking each one would churn a buffer of
      // 512 that real pending operations share.
      if (await _owner._storage.isMessageDeleted(peer.hex, msgId)) return;
      if (!await _owner._mutations.hasMessage(peer, msgId)) {
        _owner._mutations.bufferPending(peer, msgId, _PendingOp.delete());
        return;
      }
      await _owner._storage.deleteMessage(peer.hex, msgId);
      await _owner._storage.scrubDeleted();
      _owner._signal();
    } catch (e) {
      devLog(() => 'xVeil[devices]: mirrored delete of $msgId failed: $e');
    }
  }

  Future<bool> applyMessage({
    required NodeId peer,
    required String msgId,
    required MessageDirection direction,
    required String body,
    required int tsMs,
    String? fileContentId,
    String? fileName,
    int? fileSize,
    String? thumb,
    List<InlineCustomEmoji> customEmoji = const [],
  }) async {
    if (await _owner._hasMessage(peer, msgId)) return false;
    if (await _owner._storage.isMessageDeleted(peer.hex, msgId)) return false;
    // A BLOCK IS A DECISION, and a sibling does not get to overrule it.
    //
    // The line above already refuses to resurrect a message deleted HERE, for
    // the same reason: the mirror converges devices on CONTENT, and content is
    // not the only thing a person decides. Blocking is the stronger statement
    // of the two, and it was being bypassed by the device group.
    //
    // Measured on the two-device stand (2026-09-21). The contact was blocked
    // on one device at the same moment they sent; that device refused the
    // message off the wire, the sibling had not learned the block yet and
    // stored it, and three minutes later the mirror carried it BACK and the
    // blocking device stored it after all. The person blocked someone and
    // their message arrived anyway, on the very device where they blocked it.
    //
    // Only the incoming direction is refused: a message WE sent them before
    // the block is our own history, and the sibling mirroring it back is not
    // the blocked party reaching us.
    if (direction == MessageDirection.incoming) {
      final contact = await _owner._storage.getContact(peer);
      if (contact?.status == ContactStatus.blocked) {
        devLog(
          () =>
              'xVeil[devices]: mirrored message $msgId from ${peer.short} '
              'REFUSED — that contact is blocked on this device',
        );
        return false;
      }
    }
    await _owner._storage.appendMessage(
      Message(
        id: msgId,
        conversationId: peer.hex,
        direction: direction,
        body: body,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          messageTsOnReceipt(tsMs, _owner._now().millisecondsSinceEpoch),
        ),
        status: direction == MessageDirection.outgoing
            ? MessageStatus.sent
            : MessageStatus.delivered,
        fileContentId: fileContentId,
        fileName: fileName,
        fileSize: fileSize,
        thumb: thumb,
        customEmoji: customEmoji,
      ),
    );
    // An erase that got here FIRST is spent now, exactly as the wire path
    // spends a peer's unsend that outran its post: store, then tombstone, so
    // the row never shows and the id is refused if it is mirrored again.
    final pending = _owner._mutations.takePending(peer, msgId);
    if (pending != null && pending.isDelete) {
      await _owner._storage.deleteMessage(peer.hex, msgId);
      await _owner._storage.scrubDeleted();
    }
    _owner._signal();
    return true;
  }

  /// Persist a local contact preference update, then mirror the fresh record.
  Future<void> putContactPrefs(Contact contact) async {
    await _owner._storage.upsertContact(contact);
    onContactPrefsChanged?.call(contact);
  }

  /// Merge contact preferences from another device while preserving local
  /// relationship and P2P policy fields. Unknown contacts are not materialized.
  Future<bool> applyContact({
    required NodeId peer,
    String? name,
    int? mutedUntilMs,
    NotificationMuteMode notificationMuteMode = NotificationMuteMode.none,
    required bool pinned,
    required bool archived,
    int? retentionDays,
    required bool allowPeerDelete,
    DisappearingSetting? disappearing,
  }) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return false;
    // The retention policy is decided by the SAME rule a peer's announcement
    // goes through, not by whoever mirrored last. A sibling that has been
    // offline holds an older view, and its alias edit must not roll the window
    // back — `winner` is last-writer-wins with a deterministic tie-break, so
    // both devices land on one answer whichever order the events arrive in.
    final held = DisappearingSetting(
      ttlSeconds: existing.disappearingTtlSeconds,
      setAtMs: existing.disappearingSetAtMs,
      setBy: existing.disappearingSetBy,
      hideAfterReadSeconds: existing.hideAfterReadSeconds,
    );
    final policy = disappearing == null
        ? held
        : DisappearingSetting.winner(held, disappearing);
    // `copyWith`, NOT a fresh `Contact`. A hand-written field list here named
    // the seven fields the bridge carries and silently defaulted the rest, so
    // mirroring an alias, a pin or a mute wiped the disappearing policy: ttl
    // to null, the stamp to 0, the setter to empty. Turning the window off is
    // an explicit act with a timestamp behind it; an unrelated edit on another
    // device is not that act. The sentinels on `copyWith` exist precisely so a
    // merge can say "leave what I was not told about" — which is what a
    // partial mirror is.
    await _owner._storage.upsertContact(
      existing.copyWith(
        name: name,
        mutedUntil: mutedUntilMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(mutedUntilMs),
        notificationMuteMode: notificationMuteMode,
        pinned: pinned,
        archived: archived,
        retentionDays: retentionDays,
        allowPeerDelete: allowPeerDelete,
        disappearingTtlSeconds: policy.ttlSeconds,
        disappearingSetAtMs: policy.setAtMs,
        disappearingSetBy: policy.setBy,
        hideAfterReadSeconds: policy.hideAfterReadSeconds,
      ),
    );
    _owner._signal();
    return true;
  }
}
