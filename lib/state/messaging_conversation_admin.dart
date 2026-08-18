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
        await _recordShown(conversationId, ts);
        _owner.onConversationRead?.call(conversationId, ts);
      }
    } catch (_) {
      // storage locked / unavailable — skip the badge clear.
    }
  }

  // ── What this device has SHOWN, and when.
  //
  // The read-after window needs a per-message answer to "when did I first see
  // this", and the obvious shape — a stamp per message id — is the wrong one.
  // It grows for the life of the conversation, while the thing it describes is
  // interesting for minutes; and once an entry is dropped the message it
  // covered would reappear, because "no stamp" reads as "never shown".
  //
  // What is stored instead is the SHOWING: "at wall-clock `atMs` this device
  // had shown everything posted up to `throughTs`". That is one entry per
  // visit to the chat, and the moment its window has passed it collapses into
  // a single watermark — every message at or below `throughTs` is hidden from
  // then on, forever, with one integer holding the fact.
  //
  // The monotone quantity it rides on already existed: the read marker, which
  // `markRead` advances to the newest message in the conversation. This just
  // records WHEN each advance happened.

  static const _kShownPrefix = 'disap.shown.v1:';

  /// Entries kept before the oldest two are merged. A merge keeps the larger
  /// coverage and the earlier moment, so it can only hide slightly SOONER than
  /// the truth — never later, and never resurrect anything.
  static const _kShownMaxEntries = 64;

  String _shownKey(String conversationId) => '$_kShownPrefix$conversationId';

  Future<void> _recordShown(String conversationId, int throughTs) async {
    final nowMs = _owner._now().millisecondsSinceEpoch;
    // A message's timestamp is its SENDER's clock, and the read marker rises
    // to the newest one. Left uncapped, a peer dating a message to the year
    // 3000 would push one showing event over the whole conversation and hide
    // all of it once the window passed. Coverage therefore stops at our own
    // now: a message claiming the future is not something we have shown, and
    // it stays visible rather than taking the history with it.
    final covered = throughTs < nowMs ? throughTs : nowMs;
    if (covered <= 0) return;
    final state = await _loadShown(conversationId);
    if (covered <= state.watermark) return;
    final entries = [...state.entries];
    // First showing wins: an entry that already covers this much keeps its own
    // earlier moment rather than being refreshed by re-opening the chat.
    if (entries.isNotEmpty && entries.last.$1 >= covered) return;
    entries.add((covered, nowMs));
    while (entries.length > _kShownMaxEntries) {
      final a = entries.removeAt(0);
      final b = entries.removeAt(0);
      entries.insert(0, (b.$1, a.$2 < b.$2 ? a.$2 : b.$2));
    }
    await _saveShown(conversationId, state.watermark, entries);
  }

  /// Messages posted at or before this instant are hidden on this device by
  /// the read-after window. Zero when the window is off or nothing qualifies.
  ///
  /// Folds and PERSISTS the collapse as a side effect, which is what keeps the
  /// entry list short without a separate maintenance pass.
  Future<int> hiddenThroughTs(NodeId peer) async {
    try {
      return await _hiddenThroughTs(peer);
    } catch (_) {
      // Best-effort, like [markRead] and [sweepDisappearing] beside it. This
      // runs on the chat's fifteen-second timer, which keeps firing while a
      // screen tears down and the container closes under it; a locked store
      // must mean "ask again next tick", not an exception out of a timer.
      // Hiding nothing is also the direction that cannot lose a message.
      return 0;
    }
  }

  Future<int> _hiddenThroughTs(NodeId peer) async {
    final setting = await disappearingOf(peer);
    final window = setting.hideWindow;
    if (window == null) return 0;
    final conversationId = peer.hex;
    final state = await _loadShown(conversationId);
    final now = _owner._now();
    var watermark = state.watermark;
    final live = <(int, int)>[];
    for (final entry in state.entries) {
      final shownAt = DateTime.fromMillisecondsSinceEpoch(entry.$2);
      if (setting.isHiddenAfterRead(shownAt, now)) {
        if (entry.$1 > watermark) watermark = entry.$1;
      } else {
        live.add(entry);
      }
    }
    if (watermark != state.watermark || live.length != state.entries.length) {
      await _saveShown(conversationId, watermark, live);
    }
    return watermark;
  }

  Future<({int watermark, List<(int, int)> entries})> _loadShown(
    String conversationId,
  ) async {
    try {
      final raw = await _owner._storage.getSetting(_shownKey(conversationId));
      if (raw == null || raw.isEmpty) return (watermark: 0, entries: const <(int, int)>[]);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return (watermark: 0, entries: const <(int, int)>[]);
      final entries = <(int, int)>[];
      for (final row in (decoded['e'] as List? ?? const [])) {
        if (row is List && row.length == 2 && row[0] is int && row[1] is int) {
          entries.add((row[0] as int, row[1] as int));
        }
      }
      return (watermark: decoded['w'] as int? ?? 0, entries: entries);
    } catch (_) {
      // A corrupt record must not hide a conversation, nor reveal one that is
      // already hidden by the post-time window. Starting over means the read
      // clock restarts, which is the visible-for-longer direction.
      return (watermark: 0, entries: const <(int, int)>[]);
    }
  }

  Future<void> _saveShown(
    String conversationId,
    int watermark,
    List<(int, int)> entries,
  ) async {
    await _owner._storage.putSetting(
      _shownKey(conversationId),
      jsonEncode({
        'w': watermark,
        'e': [for (final e in entries) [e.$1, e.$2]],
      }),
    );
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
