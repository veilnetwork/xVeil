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
