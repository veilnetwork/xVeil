part of 'messaging_core.dart';

/// Local conversation administration that does not own inbound dispatch or
/// the message/content pipelines. Keeping it behind [MessagingService]
/// preserves the service's public API while isolating encrypted contact
/// preferences, chat folders, read markers, and destructive chat actions.
class _MessagingConversationAdmin {
  _MessagingConversationAdmin(this._owner);

  final MessagingService _owner;

  static const _kFoldersKey = 'chat_folders';

  Future<void> setContactName(NodeId peer, String? name) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    final trimmed = name?.trim();
    // copyWith, not a fresh Contact. The hand-written field list this replaces
    // predated the disappearing window and never learned about it, so renaming
    // a contact silently turned their disappearing messages OFF — and then
    // announced that to them as a decision.
    await _owner._putContactPrefs(
      existing.copyWith(
        name: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      ),
    );
    _owner._signal();
  }

  Future<void> setContactMutedUntil(
    NodeId peer,
    DateTime? until, {
    NotificationMuteMode mode = NotificationMuteMode.none,
  }) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    await _owner._putContactPrefs(
      existing.copyWith(mutedUntil: until, notificationMuteMode: mode),
    );
    _owner._signal();
  }

  Future<void> setContactArchived(NodeId peer, bool archived) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    await _owner._putContactPrefs(existing.copyWith(archived: archived));
    _owner._signal();
  }

  Future<void> setContactAllowPeerDelete(NodeId peer, bool allow) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    await _owner._putContactPrefs(existing.copyWith(allowPeerDelete: allow));
    _owner._signal();
  }

  Future<void> setContactP2POverride(
    NodeId peer,
    ContactP2POverride value,
  ) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    await _owner._storage.upsertContact(existing.copyWith(p2pOverride: value));
    _owner._signal();
  }

  Future<void> setContactPinned(NodeId peer, bool pinned) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    await _owner._putContactPrefs(existing.copyWith(pinned: pinned));
    _owner._signal();
  }

  Future<void> setContactRetention(NodeId peer, int? days) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    final window = (days == null || days <= 0) ? null : days;
    // Same fix as [setContactName], same reason: this list did not carry the
    // disappearing window either, so changing local retention wiped the shared
    // one.
    await _owner._putContactPrefs(existing.copyWith(retentionDays: window));
    _owner._signal();
    if (window != null) {
      await _owner._storage.pruneConversation(peer, window);
      _owner._signal();
    }
  }

  /// Read the conversation's shared disappearing-message setting.
  Future<DisappearingSetting> disappearingOf(NodeId peer) async {
    final c = await _owner._storage.getContact(peer);
    if (c == null) return DisappearingSetting.off;
    return DisappearingSetting(
      ttlSeconds: c.disappearingTtlSeconds,
      setAtMs: c.disappearingSetAtMs,
      setBy: c.disappearingSetBy,
      hideAfterReadSeconds: c.hideAfterReadSeconds,
    );
  }

  /// Choose a disappearing window for this conversation and tell the peer.
  ///
  /// `seconds == null` (or <= 0) turns it off. The order matters: the setting
  /// is persisted and applied HERE first, and only then announced. A send that
  /// fails must still leave this device honouring what its owner asked for —
  /// the peer's copy catches up on the next announcement, but a person who
  /// asked for 30 seconds and got "the network was down" would have neither.
  Future<void> setContactDisappearing(NodeId peer, int? seconds) =>
      _setHalf(peer, ttl: (seconds,), hideAfterRead: null);

  /// Choose the READ-clock window: how long a message stays on screen after
  /// this device first showed it. Announced the same way and by the same
  /// frame, because the two windows are one setting with one stamp.
  Future<void> setContactHideAfterRead(NodeId peer, int? seconds) =>
      _setHalf(peer, ttl: null, hideAfterRead: (seconds,));

  /// One writer for both halves.
  ///
  /// A record passed as `(value,)` is being CHANGED (to `value`, which may be
  /// null for off); a plain `null` means "leave this half alone". Written as
  /// one method because two independent setters each building a whole
  /// [DisappearingSetting] would each have to remember to carry the other half
  /// — and the one that forgot would silently clear a window its owner set,
  /// then announce the erasure to the peer as a fresh decision.
  Future<void> _setHalf(
    NodeId peer, {
    required (int?,)? ttl,
    required (int?,)? hideAfterRead,
  }) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return;
    int? clamp(int? seconds) => (seconds == null || seconds <= 0)
        ? null
        : seconds.clamp(1, kDisappearingMaxSeconds);
    final selfHex = await _owner._selfHex();
    final setting = DisappearingSetting(
      ttlSeconds: ttl == null
          ? existing.disappearingTtlSeconds
          : clamp(ttl.$1),
      hideAfterReadSeconds: hideAfterRead == null
          ? existing.hideAfterReadSeconds
          : clamp(hideAfterRead.$1),
      setAtMs: _owner._now().millisecondsSinceEpoch,
      setBy: selfHex,
    );
    await _applyDisappearing(peer, existing, setting, incoming: false);
    await _announceDisappearing(peer, setting);
  }

  /// Adopt an announcement that arrived from [peer]. Returns whether it won.
  Future<bool> adoptDisappearing(NodeId peer, DisappearingSetting incoming) async {
    final existing = await _owner._storage.getContact(peer);
    if (existing == null) return false;
    final held = DisappearingSetting(
      ttlSeconds: existing.disappearingTtlSeconds,
      setAtMs: existing.disappearingSetAtMs,
      setBy: existing.disappearingSetBy,
      hideAfterReadSeconds: existing.hideAfterReadSeconds,
    );
    if (!identical(DisappearingSetting.winner(held, incoming), incoming)) {
      return false;
    }
    await _applyDisappearing(peer, existing, incoming, incoming: true);
    return true;
  }

  Future<void> _applyDisappearing(
    NodeId peer,
    Contact existing,
    DisappearingSetting setting, {
    required bool incoming,
  }) async {
    await _owner._putContactPrefs(
      existing.copyWith(
        disappearingTtlSeconds: setting.ttlSeconds,
        disappearingSetAtMs: setting.setAtMs,
        disappearingSetBy: setting.setBy,
        hideAfterReadSeconds: setting.hideAfterReadSeconds,
      ),
    );
    _owner._signal();
    // A row in the timeline, not a silent toggle: the window governs what the
    // OTHER person's device deletes too, so both people have to be able to see
    // that it changed and when.
    await _writeDisappearingMarker(peer, setting, incoming: incoming);
    await sweepDisappearing(peer);
  }

  Future<void> _writeDisappearingMarker(
    NodeId peer,
    DisappearingSetting setting, {
    required bool incoming,
  }) async {
    // Deterministic id — the stamp and the setter, nothing per-delivery in it.
    // That is the WHOLE dedup: the event log folds by message id, so a
    // re-delivered announcement lands on the same row, and a row the owner
    // deleted stays deleted because its tombstone is keyed the same way.
    //
    // Deliberately no belt-and-braces "have I seen this id" read in front of
    // it. Two guards used to sit here and neither could be told apart from the
    // fold by any test — code a break-check cannot make fail is code that
    // silently stops being true. The tests pin the two observable properties
    // instead (a replay adds no second notice; a replay resurrects no deleted
    // one), and those go red if the fold ever changes.
    //
    // The chat-deleted marker cannot do this: its id embeds the frame id, so a
    // redelivery genuinely does mint a second row and genuinely does need a
    // guard.
    final id = 'sys:disap:${setting.setAtMs}:${setting.setBy}';
    await _owner._store(
      peer,
      incoming ? MessageDirection.incoming : MessageDirection.outgoing,
      '$kDisappearingMarkerPrefix${setting.ttlSeconds ?? 0}',
      MessageStatus.delivered,
      id: id,
      timestamp: DateTime.fromMillisecondsSinceEpoch(setting.setAtMs),
      selfAuthored: true,
    );
  }

  Future<void> _announceDisappearing(
    NodeId peer,
    DisappearingSetting setting,
  ) async {
    final selfHex = await _owner._selfHex();
    if (peer.hex == selfHex) return;
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    final fid = 'disap:${_uuid.v4()}';
    final wire = WireEnvelope(
      WireKind.disappearingSet,
      jsonEncode(setting.toWireJson()),
      sentAtMs: setting.setAtMs,
    ).withFrameId(fid).encode();
    try {
      await _owner._send(peer, wire);
    } catch (_) {
      // Live path down — the durable copy below still carries it.
    }
    try {
      await _owner._maybeStash(peer, fid, wire);
    } catch (_) {
      // Best-effort: an unreachable mailbox must not undo a setting the owner
      // already has locally.
    }
  }

  /// Delete everything in this conversation that has outlived the window.
  ///
  /// Cheap and idempotent by design, so it can be called on chat open, after
  /// an inbound message, and on a timer without anyone having to reason about
  /// which of those already ran.
  Future<int> sweepDisappearing(NodeId peer) async {
    try {
      final setting = await disappearingOf(peer);
      final cutoff = setting.cutoffAt(_owner._now());
      if (cutoff == null) return 0;
      final pruned = await _owner._storage.pruneConversationBefore(peer, cutoff);
      if (pruned > 0) _owner._signal();
      return pruned;
    } catch (_) {
      // Best-effort, like [pruneConversation]: a locked store means the sweep
      // happens on the next call, not that the caller fails.
      return 0;
    }
  }

  Future<void> pruneConversation(NodeId peer) async {
    try {
      final c = await _owner._storage.getContact(peer);
      final days = c?.retentionDays;
      if (days == null || days <= 0) return;
      final pruned = await _owner._storage.pruneConversation(peer, days);
      if (pruned > 0) _owner._signal();
    } catch (_) {
      // Best-effort on open (like markRead): storage locked/unavailable → skip.
    }
  }

  Future<void> deleteConversation(
    NodeId peer, {
    bool notifyPeer = false,
  }) async {
    if (notifyPeer) await _sendChatDeletedFarewell(peer);
    await _owner._storage.removeConversation(peer);
    // The chat is gone; its ratchet must go with it. AFTER the farewell, which
    // is itself a send and would re-open a session we were about to drop.
    //
    // Both devices of a two-device contact go, and that is exactly why the key
    // is flat: everything with this node id in its middle 32 bytes belongs to
    // this chat, and no side table is needed to say so. Irreversible by
    // construction — nothing public rebuilds a chain — which is right for a
    // deletion and wrong for anything else.
    await _owner._forgetRatchetWith(peer, 'chat deleted');
    _owner._mailboxDelivery.clearPeerBackoff(peer.hex);
    await _removeFromAllFolders(peer.hex);
    _owner._signal();
  }

  Future<void> _sendChatDeletedFarewell(NodeId peer) async {
    final selfHex = await _owner._selfHex();
    if (peer.hex == selfHex) return;
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    final fid = 'chatdel:${_uuid.v4()}';
    final wire = WireEnvelope(
      WireKind.chatDeleted,
      '',
      sentAtMs: _owner._now().millisecondsSinceEpoch,
    ).withFrameId(fid).encode();
    try {
      await _owner._send(peer, wire);
    } catch (_) {
      // Live path down — the mailbox deposit below still delivers.
    }
    try {
      await _owner._maybeStash(peer, fid, wire);
    } catch (_) {
      // Best-effort: the delete must not be blocked by an unreachable mailbox.
    }
  }

  Future<List<ChatFolder>> loadFolders() async {
    try {
      return ChatFolder.decodeList(
        await _owner._storage.getSetting(_kFoldersKey),
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveFolders(List<ChatFolder> folders) async {
    await _owner._storage.putSetting(
      _kFoldersKey,
      ChatFolder.encodeList(folders),
    );
    _owner._signal();
  }

  Future<ChatFolder> createFolder(
    String name, {
    List<String> members = const [],
  }) async {
    final folders = List<ChatFolder>.from(await loadFolders());
    final folder = ChatFolder(
      id: _uuid.v4(),
      name: name.trim(),
      memberHexes: members,
    );
    folders.add(folder);
    await _saveFolders(folders);
    return folder;
  }

  Future<void> renameFolder(String folderId, String name) async {
    final folders = await loadFolders();
    await _saveFolders([
      for (final f in folders)
        if (f.id == folderId) f.copyWith(name: name.trim()) else f,
    ]);
  }

  Future<void> deleteFolder(String folderId) async {
    final folders = await loadFolders();
    await _saveFolders(folders.where((f) => f.id != folderId).toList());
  }

  Future<void> setFolderMembership(
    String folderId,
    String peerHex,
    bool member,
  ) async {
    final folders = await loadFolders();
    await _saveFolders([
      for (final f in folders)
        if (f.id != folderId)
          f
        else
          f.copyWith(
            memberHexes: member
                ? (f.contains(peerHex)
                      ? f.memberHexes
                      : [...f.memberHexes, peerHex])
                : f.memberHexes.where((h) => h != peerHex).toList(),
          ),
    ]);
  }

  Future<void> _removeFromAllFolders(String peerHex) async {
    final folders = await loadFolders();
    if (!folders.any((f) => f.contains(peerHex))) return;
    await _saveFolders([
      for (final f in folders)
        f.copyWith(
          memberHexes: f.memberHexes.where((h) => h != peerHex).toList(),
        ),
    ]);
  }

  Future<void> clearConversation(NodeId peer) async {
    final selfHex = await _owner._selfHex();
    final ev = await _owner._storage.emitClearConversation(peer, selfHex);
    await _owner.sendDurable(
      peer,
      'clear:${peer.hex}:${ev.seq}',
      WireEnvelope.clear(jsonEncode(ev.watermark), seq: ev.seq),
    );
    _owner._signal();
  }

  Future<void> markRead(String conversationId) async {
    try {
      await _owner._storage.markRead(conversationId);
      _owner._signal();
      final ts = await _owner._storage.readMarker(conversationId);
      if (ts > 0) {
        _owner.onConversationRead?.call(conversationId, ts);
      }
    } catch (_) {
      // storage locked / unavailable — skip the badge clear.
    }
  }

  Future<bool> applyMirroredReadMark(String conversationId, int tsMs) async {
    try {
      if (await _owner._storage.readMarker(conversationId) >= tsMs) {
        return false;
      }
      await _owner._storage.setReadMarker(conversationId, tsMs);
      _owner._signal();
      return true;
    } catch (_) {
      return false;
    }
  }
}
