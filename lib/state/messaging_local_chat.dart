part of 'messaging_core.dart';

/// Local conversation features that deliberately do not own transport or the
/// canonical event-log write path. The parent remains the boundary for wire
/// sends and [_MessagingLocalChat] calls [MessagingService._store] for every
/// note, preserving multi-device taps and author/sequence semantics.
class _MessagingLocalChat {
  _MessagingLocalChat(this._owner);

  final MessagingService _owner;

  /// Load all reactions for a conversation: msgId → (reactorHex → emoji).
  Future<Map<String, Map<String, String>>> loadReactions(String convId) async {
    try {
      final raw = await _owner._storage.getSetting('rx:$convId');
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw);
      if (j is! Map) return {};
      return {
        for (final e in j.entries)
          if (e.value is Map)
            e.key as String: {
              for (final r in (e.value as Map).entries)
                r.key as String: r.value as String,
            },
      };
    } catch (_) {
      return {};
    }
  }

  /// Apply one reaction to the store (empty [emoji] removes this reactor's).
  Future<void> applyReaction(
    String convId,
    String msgId,
    String reactorHex,
    String emoji,
  ) async {
    final all = await loadReactions(convId);
    final forMsg = all[msgId] ?? <String, String>{};
    if (emoji.isEmpty) {
      forMsg.remove(reactorHex);
    } else {
      forMsg[reactorHex] = emoji;
    }
    if (forMsg.isEmpty) {
      all.remove(msgId);
    } else {
      all[msgId] = forMsg;
    }
    await _owner._storage.putSetting('rx:$convId', jsonEncode(all));
  }

  /// Apply a reaction locally and persist its durable wire frame for a peer.
  Future<void> sendReaction(NodeId peer, String msgId, String emoji) async {
    final selfHex = await _owner._selfHex();
    await applyReaction(peer.hex, msgId, selfHex, emoji);
    _owner._signal();
    // Saved Messages is local-only: never address a reaction to ourselves.
    if (peer.hex == selfHex) return;
    await _owner.sendDurable(
      peer,
      'rx:$msgId',
      WireEnvelope.reaction(msgId, emoji),
    );
  }

  /// Append a text note locally with no consent, mailbox, or transport work.
  Future<void> saveNote(
    String text, {
    String? replyToId,
    String? forwardedFrom,
    List<InlineCustomEmoji> customEmoji = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!isValidInlineCustomEmoji(trimmed, customEmoji)) return;
    final selfId = NodeId.fromHex(await _owner._selfHex());
    await _owner._store(
      selfId,
      MessageDirection.outgoing,
      trimmed,
      // A self-note has no peer ACK. `sent` would incorrectly trigger a
      // reconnect to ourselves and create a pendingIncoming self-contact.
      MessageStatus.delivered,
      replyToId: replyToId,
      forwardedFrom: forwardedFrom,
      customEmoji: customEmoji,
      timestamp: _owner._now(),
    );
    _owner._signal();
  }

  /// Append a file note using the same whole-blob/content tiers as a real send.
  Future<void> saveFileNote(
    Uint8List bytes,
    String name, {
    String? sourcePath,
    String? forwardedFrom,
  }) async {
    final selfId = NodeId.fromHex(await _owner._selfHex());
    String? thumb;
    if (isImageFileName(name)) {
      thumb = await _owner._imageThumbMaker(bytes);
    } else if (isVideoFileName(name) && sourcePath != null) {
      try {
        thumb = await _owner._videoThumbMaker(sourcePath);
      } catch (e) {
        devLog(() => 'xVeil[saved]: video thumb skipped for $name: $e');
      }
    }

    if (bytes.length > MessagingService._contentThreshold) {
      final base = ContentManifest.fromBytes(
        name,
        bytes,
        pieceSize: MessagingService.adaptivePieceSize(bytes.length),
        chunkBytes: MessagingService._contentChunkBytes,
      );
      await _owner._storeServedBlob(base, bytes);
      await _owner._store(
        selfId,
        MessageDirection.outgoing,
        '📎 $name',
        MessageStatus.delivered,
        fileId: base.contentId,
        fileName: name,
        fileSize: bytes.length,
        thumb: thumb,
        forwardedFrom: forwardedFrom,
        timestamp: _owner._now(),
      );
    } else {
      if (bytes.length > kMaxStoredFileBytes) {
        devLog(() => 'xVeil[saved]: ${bytes.length}B over cap — dropped');
        return;
      }
      final fileId = _uuid.v4();
      await _owner._storage.storeFile(fileId, bytes, name: name);
      await _owner._store(
        selfId,
        MessageDirection.outgoing,
        '📎 $name',
        MessageStatus.delivered,
        fileId: fileId,
        fileName: name,
        fileSize: bytes.length,
        thumb: thumb,
        id: fileId,
        forwardedFrom: forwardedFrom,
        timestamp: _owner._now(),
      );
    }
    _owner._signal();
  }

  /// Copy an already-held file reference into Saved Messages without bytes.
  Future<bool> saveFileNoteRef(Message message, {String? forwardedFrom}) async {
    final key = message.fileId ?? message.fileContentId;
    if (key == null || !await _owner._storage.hasFile(key)) return false;
    final selfId = NodeId.fromHex(await _owner._selfHex());
    await _owner._store(
      selfId,
      MessageDirection.outgoing,
      message.body,
      MessageStatus.delivered,
      fileId: message.fileId,
      fileName: message.fileName,
      fileSize: message.fileSize,
      fileContentId: message.fileContentId,
      thumb: message.thumb,
      forwardedFrom: forwardedFrom,
      timestamp: _owner._now(),
    );
    _owner._signal();
    return true;
  }
}
