part of 'messaging_core.dart';

extension MessagingProfiles on MessagingService {
  /// No mailbox, outbox, presence subscription or third-party image host.
  /// Cached profile is refreshed when a conversation/avatar is opened again.
  Future<void> requestPeerAvatar(NodeId peer) async {
    try {
      if (_disposed ||
          (await _storage.getContact(peer))?.status != ContactStatus.accepted) {
        return;
      }
      if (_disposed) return;
      final now = DateTime.now();
      final last = _avatarRequestedAt[peer.hex];
      if (last != null && now.difference(last) < const Duration(minutes: 1)) {
        return;
      }
      if (_avatarRequestedAt.length >= 512) {
        _avatarRequestedAt.remove(_avatarRequestedAt.keys.first);
      }
      _avatarRequestedAt[peer.hex] = now;
      await _send(
        peer,
        const WireEnvelope(WireKind.profileAvatar, '?').encode(),
      );
    } catch (_) {
      /* offline/closing storage is not an error in the chat UI */
    }
  }

  Future<String?> loadAvatar({NodeId? peer}) => _storage.getSetting(
    peer == null ? kSelfAvatarSetting : peerAvatarSetting(peer.hex),
  );

  Future<String> setSelfAvatar(Uint8List? bytes) async {
    final old = await loadAvatar();
    final previous = old == null ? null : ProfileAvatar.decode(old);
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamp = previous != null && previous.updatedAt >= now
        ? previous.updatedAt + 1
        : now;
    final raw = ProfileAvatar(stamp, bytes).encode();
    if (ProfileAvatar.decode(raw) == null) {
      throw ArgumentError('Invalid avatar');
    }
    await applySelfAvatar(raw);
    return raw;
  }

  Future<void> applySelfAvatar(String raw) async {
    final value = ProfileAvatar.decode(raw);
    if (value == null) return;
    final old = await loadAvatar();
    if (old == raw) return;
    // The device journal's LWW fold decides sibling conflicts, as it does for
    // nicknames; do not replace that ordering with an independent local clock.
    await _storage.putSetting(kSelfAvatarSetting, raw);
    _signal();
  }

  Future<void> announceSelfAvatar() async {
    final raw = await loadAvatar();
    if (raw == null || ProfileAvatar.decode(raw) == null) return;
    // Deliberate contact consent, including after a block or contact removal.
    for (final conversation in await _storage.loadConversations()) {
      final contact = conversation.peer;
      if (_disposed) return;
      if (contact.status != ContactStatus.accepted) continue;
      try {
        await _send(
          contact.nodeId,
          WireEnvelope(WireKind.profileAvatar, raw).encode(),
        );
      } catch (_) {
        /* next profile request refreshes an offline contact */
      }
    }
  }

  Future<void> _receiveAvatar(InboundMessage message, String body) async {
    if (body == '?') {
      final now = DateTime.now();
      final last = _avatarRepliedAt[message.src.hex];
      if (last != null && now.difference(last) < const Duration(seconds: 10)) {
        return;
      }
      if (_avatarRepliedAt.length >= 512) {
        _avatarRepliedAt.remove(_avatarRepliedAt.keys.first);
      }
      _avatarRepliedAt[message.src.hex] = now;
      final raw = await loadAvatar();
      if (raw != null && ProfileAvatar.decode(raw) != null) {
        await _send(
          message.src,
          WireEnvelope(WireKind.profileAvatar, raw).encode(),
        );
      }
      return;
    }
    final value = ProfileAvatar.decode(body);
    if (value == null) return;
    final key = peerAvatarSetting(message.src.hex);
    final old = await _storage.getSetting(key);
    if (old == body) return;
    final previous = old == null ? null : ProfileAvatar.decode(old);
    if (previous != null &&
        (value.updatedAt < previous.updatedAt ||
            (value.updatedAt == previous.updatedAt &&
                body.compareTo(old!) <= 0))) {
      return;
    }
    await _storage.putSetting(key, body);
    _signal();
  }
}
