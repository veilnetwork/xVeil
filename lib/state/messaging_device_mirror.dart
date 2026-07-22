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
        timestamp: DateTime.fromMillisecondsSinceEpoch(tsMs),
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
  }) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return false;
    await _owner._storage.upsertContact(
      Contact(
        nodeId: existing.nodeId,
        name: name,
        status: existing.status,
        mutedUntil: mutedUntilMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(mutedUntilMs),
        notificationMuteMode: notificationMuteMode,
        pinned: pinned,
        archived: archived,
        retentionDays: retentionDays,
        allowPeerDelete: allowPeerDelete,
        p2pOverride: existing.p2pOverride,
      ),
    );
    _owner._signal();
    return true;
  }
}
