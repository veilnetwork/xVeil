part of 'messaging_core.dart';

class _ReactionState {
  _ReactionState(this.values, this.stamps);
  final Map<String, Map<String, String>> values;
  final Map<String, Map<String, int>> stamps;
}

/// Local conversation features that deliberately do not own transport or the
/// canonical event-log write path. The parent remains the boundary for wire
/// sends and [_MessagingLocalChat] calls [MessagingService._store] for every
/// note, preserving multi-device taps and author/sequence semantics.
class _MessagingLocalChat {
  _MessagingLocalChat(this._owner);

  final MessagingService _owner;
  final Map<String, Future<void>> _reactionWrites = {};
  final Set<Future<void>> _reactionSends = {};
  bool _reactionsClosed = false;

  Future<T> _serializeReactions<T>(String convId, Future<T> Function() action) {
    if (_reactionsClosed) return Future.error(StateError('reactions closed'));
    final result = (_reactionWrites[convId] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _reactionWrites[convId] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_reactionWrites[convId], tail)) {
          _reactionWrites.remove(convId);
        }
      }),
    );
    return result;
  }

  Future<void> closeReactions() async {
    // The owner first drains admitted inbound lanes. Those handlers must
    // still be able to publish their reactions after disposal has begun.
    // A local action admitted before close also owns its callback/outbox
    // publication, not merely the first write of its visible reaction.
    await Future.wait(_reactionSends.toList());
    _reactionsClosed = true;
    await Future.wait(_reactionWrites.values.toList());
  }

  /// Reactions and their stamps live in the FILE store, not a setting.
  ///
  /// One settings record per conversation grew by an entry for every reaction
  /// and was never pruned; past a few dozen reactions it no longer fitted a
  /// record, every write threw `PayloadTooLarge`, and reacting in that chat
  /// stopped working for good (measured on the stand under a mixed load). The
  /// file store chunks a large value. Legacy settings/files remain readable
  /// until the first successful publication of the combined state.
  Future<String?> _readReactionBlob(String key) async {
    final blob = await _owner._storage.loadFile(key);
    if (blob != null) return utf8.decode(blob);
    return _owner._storage.getSetting(key);
  }

  /// Load all reactions for a conversation: msgId → (reactorHex → emoji).
  Future<Map<String, Map<String, String>>> loadReactions(String convId) async {
    try {
      return (await _readReactionState(convId)).values;
    } catch (_) {
      return {};
    }
  }

  // Publish values and their ordering floors together. FileStore's final
  // metadata commit retains the old complete blob until the replacement is
  // durable. A failed mutation must not advance a stamp without its value.
  Future<_ReactionState> _readReactionState(String convId) async {
    final raw = await _owner._storage.loadFile('rx2:$convId');
    if (raw == null) {
      return _ReactionState(
        await _loadLegacyReactions(convId),
        await _loadReactionStamps(convId),
      );
    }
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map || decoded['v'] != 1) {
      throw const FormatException('unsupported reaction state');
    }
    // Mutations deliberately propagate corruption instead of replacing an
    // unreadable authoritative snapshot with an empty reaction map.
    return _ReactionState(
      {
        for (final e in (decoded['r'] as Map).entries)
          e.key as String: Map<String, String>.from(e.value as Map),
      },
      {
        for (final e in (decoded['t'] as Map).entries)
          e.key as String: Map<String, int>.from(e.value as Map),
      },
    );
  }

  Future<void> _writeReactionState(String convId, _ReactionState state) async {
    await _owner._storage.storeFile(
      'rx2:$convId',
      Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 1, 'r': state.values, 't': state.stamps})),
      ),
      name: 'reactions',
    );
    // Retire migrated copies only AFTER publishing the complete replacement.
    // A cleanup failure cannot undo that commit or skip its peer outbox write;
    // retry on the next mutation while rx2 remains authoritative.
    for (final key in ['rx:$convId', 'rxat:$convId']) {
      try {
        await _owner._storage.deleteStoredFile(key);
        final legacy = await _owner._storage.getSetting(key);
        if (legacy != null && legacy.isNotEmpty) {
          await _owner._storage.putSetting(key, '');
        }
      } catch (error) {
        devLog(
          () =>
              'xVeil[reactions]: legacy cleanup incomplete (${error.runtimeType})',
        );
      }
    }
  }

  Future<Map<String, Map<String, String>>> _loadLegacyReactions(
    String convId,
  ) async {
    try {
      final raw = await _readReactionBlob('rx:$convId');
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

  /// Legacy separate ordering floors. Read once when migrating to rx2;
  /// records written before floors existed carry no floor.
  Future<Map<String, Map<String, int>>> _loadReactionStamps(
    String convId,
  ) async {
    try {
      final raw = await _readReactionBlob('rxat:$convId');
      if (raw == null || raw.isEmpty) return {};
      final j = jsonDecode(raw);
      if (j is! Map) return {};
      return {
        for (final e in j.entries)
          if (e.value is Map)
            e.key as String: {
              for (final r in (e.value as Map).entries)
                r.key as String: (r.value as num).toInt(),
            },
      };
    } catch (_) {
      return {};
    }
  }

  /// Apply one reaction to the store (empty [emoji] removes this reactor's).
  ///
  /// [atMs] is the sender's stamp for THIS reaction. A frame older than the one
  /// already applied for the same reactor is ignored: mailbox blobs arrive
  /// unordered, so a delayed 👍 must not undo the ❤️ that replaced it.
  Future<void> applyReaction(
    String convId,
    String msgId,
    String reactorHex,
    String emoji, {
    int? atMs,
  }) => _serializeReactions(convId, () async {
    final state = await _readReactionState(convId);
    if (!_applyReactionState(state, msgId, reactorHex, emoji, atMs: atMs)) {
      return;
    }
    await _writeReactionState(convId, state);
  });

  bool _applyReactionState(
    _ReactionState state,
    String msgId,
    String reactorHex,
    String emoji, {
    int? atMs,
  }) {
    if (atMs != null) {
      final seen = state.stamps[msgId]?[reactorHex];
      final current = state.values[msgId]?[reactorHex] ?? '';
      // Exactly the payload ordering of foldDeviceSync for reaction and
      // peerReaction, including an empty-emoji removal at an equal stamp.
      if (seen != null &&
          (atMs < seen ||
              (atMs == seen &&
                  jsonEncode({
                        'e': emoji,
                      }).compareTo(jsonEncode({'e': current})) <=
                      0))) {
        return false;
      }
      (state.stamps[msgId] ??= <String, int>{})[reactorHex] = atMs;
    }
    final all = state.values;
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
    return true;
  }

  /// Apply a reaction locally and persist its durable wire frame for a peer.
  Future<void> sendReaction(NodeId peer, String msgId, String emoji) {
    if (_owner._disposed) return Future.error(StateError('messaging disposed'));
    final result = _sendReaction(peer, msgId, emoji);
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _reactionSends.add(settled);
    unawaited(settled.then((_) => _reactionSends.remove(settled)));
    return result;
  }

  Future<void> _sendReaction(NodeId peer, String msgId, String emoji) async {
    final selfHex = await _owner._selfHex();
    final atMs = await _serializeReactions(peer.hex, () async {
      final state = await _readReactionState(peer.hex);
      final seen = state.stamps[msgId]?[selfHex];
      if (seen == 0x7fffffffffffffff) {
        throw StateError('reaction version exhausted');
      }
      final now = _owner._now().millisecondsSinceEpoch;
      final at = seen != null && seen >= now ? seen + 1 : now;
      _applyReactionState(state, msgId, selfHex, emoji, atMs: at);
      await _writeReactionState(peer.hex, state);
      return at;
    });
    _owner._signal();
    // Saved Messages is local-only: never address a reaction to ourselves.
    if (peer.hex == selfHex) return;
    _owner.onReactionSent?.call(peer, msgId, emoji, atMs);
    // Millisecond stamps can collide across devices. Give every user mutation
    // its own durable ID; retransmission retains that same stored ID. Otherwise
    // dedup can discard a different emoji before the ordering rule sees it.
    await _owner.sendDurable(
      peer,
      'rx:$msgId:${_uuid.v4()}',
      WireEnvelope.reaction(msgId, emoji, sentAtMs: atMs),
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
