part of 'group_service.dart';

/// Compaction of the state logs: which rows survive, and the bounded pass that
/// visits groups hour by hour.
///
/// A collaborator rather than an extension for the same reason as
/// [_ChannelKeyRotation]: extension members cannot be overridden and dispatch
/// statically. The public entry points and the per-group lock stay on the
/// owner; this file holds the rules for what is superseded.
/// Device-log kinds that describe ONE message or ONE call.
///
/// Every other kind is keyed by something that recurs — a setting, a contact,
/// a conversation — so last-writer-wins keeps its row count bounded by the
/// number of such things. These are keyed by an id that is never written
/// twice, so every row wins its own key and nothing ever superseded one: the
/// log grew by a row for every message the person sent or received, about
/// 720 bytes each, and the whole group is ONE stored blob capped at
/// [kMaxStoredFileBytes]. Measured: 639 live keys after ~400 messages on the
/// stand, so the device log would stop saving — every setting, contact and
/// read mark with it — somewhere around three and a half thousand messages.
///
/// Their job is done once the siblings have applied them: an own-device copy
/// is live-only (the owner's decision of 2026-09-26), and a device that was
/// away longer than the window catches up from its other devices and from the
/// counterpart instead.
const kDeviceLogPerItemKinds = {
  DeviceSyncKind.msgMirror,
  DeviceSyncKind.msgStatus,
  DeviceSyncKind.msgEdit,
  DeviceSyncKind.callLog,
  DeviceSyncKind.reaction,
  DeviceSyncKind.peerReaction,
};

/// How many per-item rows a device log keeps at most, newest first…
///
/// Small, because every event the devices exchange REWRITES the whole log:
/// it is one stored blob. Measured on the stand with ~600 live rows: three
/// sent messages wrote 4.2 MB on the sender and 4.1 MB on its sibling, and a
/// ratchet save queued behind those writes for up to 20 s. The window only
/// has to cover a sibling that is briefly away; a longer absence is caught up
/// from the other devices and from the counterpart.
const kDeviceLogPerItemRowsKept = 250;

/// …and how old one may be.
const kDeviceLogPerItemMaxAge = Duration(days: 7);

/// Which window a per-item row counts against.
///
/// One window for all of them let the bulk — a mirror and a status for every
/// message — push the rare rows out in minutes. Measured on the stand under a
/// load run: 14 reaction rows left, the oldest 20 minutes old, and a sibling
/// that lagged longer than that never applied a reaction made on the other
/// device — there is no catch-up from the counterpart for reactions. The bulk
/// kinds share one window as before; each rare kind has its own, so the log
/// grows by at most that many rows per rare kind, and in practice by the
/// handful actually made.
String deviceLogPerItemPool(DeviceSyncKind kind) => switch (kind) {
  DeviceSyncKind.msgMirror || DeviceSyncKind.msgStatus => 'bulk',
  _ => kind.name,
};

/// The initial device-log row count past which a save schedules compaction
/// instead of waiting for the hourly pass. After a successful pass, a small
/// growth margin above the retained count prevents scanning the same required
/// state on every append. The hourly expiry sweep remains independent.
const kDeviceLogCompactAtRows = 400;

class _LogCompaction {
  _LogCompaction(this._owner);

  final GroupService _owner;

  /// Physically retire locally expired 1:1 bodies from a sovereign device log.
  /// Each decision uses a verified current member's row plus this container's
  /// contact policy/tombstones. Unknown kinds and unverifiable rows stay intact.
  /// Author floors are local sequence-allocation metadata, not prefix cuts:
  /// older unrelated state must remain readable and synchronizable.
  Future<GroupBundle> _withoutExpiredDeviceBodies(
    GroupBundle b, {
    Set<String>? storedHashes,
  }) async {
    if (!b.manifest.isSovereignDevice ||
        await _owner.deviceGroupIdHex() != b.manifest.groupId.hex) {
      return b;
    }
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _owner._validControlFor(b.manifest, e),
    ).state;
    final rows =
        <({GroupMessage message, DeviceSyncEvent event, String peer})>[];
    final deleted = <String, Set<String>>{};
    final ttl = <String, int?>{};
    final now = _owner._clockNowMs();
    for (final m in b.messages) {
      if (!_owner._validMessageFor(b.manifest.groupId, m) ||
          !state.isMember(m.author)) {
        continue;
      }
      final event = DeviceSyncEvent.fromBody(m.body);
      if (event == null ||
          (event.kind != DeviceSyncKind.msgMirror &&
              event.kind != DeviceSyncKind.msgEdit)) {
        continue;
      }
      final peer = event.payload['peer'];
      if (peer is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(peer)) {
        continue;
      }
      if (!deleted.containsKey(peer)) {
        deleted[peer] = await _owner._storage.deletedMessageIds(peer);
        ttl[peer] = (await _owner._storage.getContact(
          NodeId.fromHex(peer),
        ))?.disappearingTtlSeconds;
        final seconds = ttl[peer];
        if (seconds != null && seconds > 0) {
          await _owner._storage.pruneConversationBefore(
            NodeId.fromHex(peer),
            DateTime.fromMillisecondsSinceEpoch(now - seconds * 1000)
                .add(const Duration(microseconds: 1)),
          );
          deleted[peer] = await _owner._storage.deletedMessageIds(peer);
        }
      }
      rows.add((message: m, event: event, peer: peer));
    }
    // Discover original post expiry before judging edits: edit timestamps do
    // not renew a message's lifetime, including when the edit is another
    // physical author's last row.
    final expiredMirrors = Set<GroupMessage>.identity();
    for (final row in rows) {
      final e = row.event;
      final seconds = ttl[row.peer];
      if (e.kind != DeviceSyncKind.msgMirror ||
          seconds == null ||
          seconds <= 0) {
        continue;
      }
      final sent = messageTsOnReceipt(e.tsMs, now);
      if (now < sent + seconds * 1000 || deleted[row.peer]!.contains(e.key)) {
        continue;
      }
      final author = e.payload['au'], seq = e.payload['sq'];
      final position =
          author is String &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(author) &&
          seq is int &&
          isAcceptableWireSeq(seq);
      // Persist the rejection before retiring the only journal copy: replay
      // after TTL-off/clock rollback must not recreate the conversation row.
      final recorded = await _owner._storage.recordExpiredMessage(
        row.peer,
        e.key,
        author: position ? author : null,
        seq: position ? seq : null,
      );
      if (recorded ||
          await _owner._storage.isMessageDeleted(row.peer, e.key)) {
        deleted[row.peer]!.add(e.key);
      } else {
        // The unseen-message marker refuses to overwrite a live canonical
        // row. A conflicting old mirror clock is not deletion authority over
        // that row's fresh mirror or edits. Retire this expired copy only;
        // a durable tombstone above still retires every body for the ID.
        expiredMirrors.add(row.message);
      }
    }
    final gone = <String>{};
    final floors = {...b.deviceMessageSeqFloors};
    for (final row in rows) {
      if (!deleted[row.peer]!.contains(row.event.key) &&
          !expiredMirrors.contains(row.message)) {
        continue;
      }
      gone.add(_owner._messageHash(row.message));
      final author = row.message.author.hex;
      floors[author] = max(floors[author] ?? -1, row.message.seq);
    }
    if (gone.isEmpty) return b;
    return b.copyWith(
      messages: [
        for (final m in b.messages)
          if (!gone.contains(_owner._messageHash(m))) m,
      ],
      deviceMessageSeqFloors: floors,
      deviceMessageScrubPending:
          b.deviceMessageScrubPending ||
          storedHashes == null ||
          gone.any(storedHashes.contains),
    );
  }

  /// Where the last compaction pass stopped, so consecutive hours cover
  /// different groups instead of re-folding the same first few.
  int _compactionCursor = 0;

  // A pass can retain more than the trigger: distinct settings, tombstones,
  // unresolved branches and not-yet-verifiable rows must remain. Give the
  // retained state a small growth margin before repeating that entire scan.
  // This is scheduling metadata only, never a fold or authorization cache.
  final _deviceSizeScans = <String, ({int budget, int retained, int next})>{};
  static const _maxDeviceSizeScans = 64;

  bool shouldCompactOnSave(GroupBundle bundle) {
    if (bundle.manifest.name != GroupService.kDeviceGroupName) return false;
    final budget = _owner.deviceLogCompactAtRows;
    final key = bundle.manifest.groupId.hex;
    final previous = _deviceSizeScans[key];
    final applicable =
        previous != null &&
        previous.budget == budget &&
        bundle.messages.length >= previous.retained;
    if (!applicable) _deviceSizeScans.remove(key);
    final threshold = applicable ? max(budget, previous.next) : budget;
    return bundle.messages.length > threshold;
  }

  void _noteDeviceSizeScan(GroupBundle bundle, int retained) {
    if (bundle.manifest.name != GroupService.kDeviceGroupName) return;
    final budget = _owner.deviceLogCompactAtRows;
    final growth = (budget ~/ 4).clamp(1, 16);
    final key = bundle.manifest.groupId.hex;
    _deviceSizeScans.remove(key);
    if (_deviceSizeScans.length >= _maxDeviceSizeScans) {
      _deviceSizeScans.remove(_deviceSizeScans.keys.first);
    }
    _deviceSizeScans[key] = (
      budget: budget,
      retained: retained,
      next: max(budget, retained + growth),
    );
  }

  Future<List<GroupReaction>> _compactReactions(GroupBundle bundle) async {
    final latest = <String, GroupReaction>{};
    final heads = <String, GroupReaction>{};
    for (final stored in bundle.reactions) {
      if (!_owner._validReactionFor(bundle.manifest.groupId, stored)) continue;
      final r = await _owner._materializeEncryptedReaction(bundle, stored);
      if (r == null) continue;
      final key = '${r.author.hex}|${r.targetKind.name}|${r.target}';
      final current = latest[key];
      if (current == null || isNewerGroupReaction(r, current)) {
        latest[key] = r;
      }
      final headKey = '${_owner._reactionGeneration(stored)}|${r.author.hex}';
      final head = heads[headKey];
      if (head == null || r.seq > head.seq) heads[headKey] = r;
    }
    final keep = <String>{
      for (final r in latest.values) '${r.author.hex}:${r.seq}',
      for (final r in heads.values) '${r.author.hex}:${r.seq}',
    };
    return [
      for (final r in bundle.reactions)
        if (_owner._validReactionFor(bundle.manifest.groupId, r) &&
            keep.contains('${r.author.hex}:${r.seq}'))
          r,
    ];
  }

  /// Which rows survive a device-log compaction.
  ///
  /// [isMember] is required, and that is the fix for report9 X-18. Reads answer
  /// from `_messagesOfBundle`, which keeps only authors who are members of the
  /// CURRENT state; this pass judged a row by its signature alone. So a device
  /// that had been revoked still competed for keys here, and when one of its
  /// rows won, the honest row it beat was deleted from disk — while the winner
  /// stayed invisible to every read. The key simply disappeared.
  ///
  /// The migration caller in `group_service.dart` already filtered its input
  /// this way. Making the parameter required is what stops the two paths from
  /// disagreeing again: the rule now lives with the pass rather than beside one
  /// of its callers.
  List<GroupMessage> compactDeviceMessages(
    NodeId groupId,
    List<GroupMessage> input, {
    required bool Function(NodeId author) isMember,
  }) {
    final latest =
        <
          (DeviceSyncKind, String),
          ({DeviceSyncEvent event, GroupMessage message})
        >{};
    final heads = <String, GroupMessage>{};
    final unknown = <String>{};
    // A note's branches are all rows under one key (the item id), so the
    // LWW-per-key rule below would keep one and drop the concurrent edit —
    // resolving by wall clock the very conflict the note DAG preserves. Ask
    // the domain which revisions are still unresolved heads and keep those too.
    final branches = <String>{};
    // Rows stamped further ahead than [kDeviceSyncClockSkew]. They are the one
    // thing this pass must not resolve: a device that claims to live in the
    // future would otherwise win every key it touches and the honest rows it
    // beat would be deleted from disk here, permanently. Deferred rows are
    // kept and are barred from winning until their own time arrives.
    final deferred = <String>{};
    final nowMs = _owner._now();
    final valid = [
      for (final m in input)
        if (_owner._validMessageFor(groupId, m) && isMember(m.author)) m,
    ];
    final entries = [
      for (final m in valid)
        if (DeviceSyncEvent.fromBody(m.body) case final e?)
          if (e.kind == DeviceSyncKind.cloudEntry) e,
    ];
    final effective = [
      for (final e in entries)
        if (deviceSyncEffectiveAt(e, nowMs)) e,
    ];
    // Both reachability questions below decide what to DELETE, and a deferred
    // revision changes the answer in both directions: present, it can orphan an
    // honest claim; absent, it can orphan its own. So each is asked under both
    // views and a row survives if either view keeps it. With no deferred row
    // the two views are the same list and the outcome is unchanged.
    final noteBranches = {
      ...unresolvedCloudNoteRevisions(entries),
      ...unresolvedCloudNoteRevisions(effective),
    };
    // Claims key on the cid, so a new revision of an object mints a NEW key
    // and the old claim wins its own key forever — this is what actually grew
    // the device log to thousands of rows. A claim whose cid no longer belongs
    // to any answerable revision is unreachable: nothing can ask for it.
    final answerable = answerableCloudContentIds(entries);
    final answerableNow = answerableCloudContentIds(effective);
    for (final m in valid) {
      final head = heads[m.author.hex];
      if (head == null || m.seq > head.seq) heads[m.author.hex] = m;
      final event = DeviceSyncEvent.fromBody(m.body);
      if (event == null) {
        // Forward-compatible: an older build must not erase a newer event kind.
        unknown.add(m.ref);
        continue;
      }
      if (event.kind == DeviceSyncKind.cloudEntry &&
          noteBranches.contains(
            '${event.key}|${CloudItem.fromEvent(event)?.contentId}',
          )) {
        branches.add(m.ref);
      }
      if (!deviceSyncEffectiveAt(event, nowMs)) {
        deferred.add(m.ref);
        continue;
      }
      if (event.kind == DeviceSyncKind.cloudReplica &&
          _unreachableClaim(event, answerable) &&
          _unreachableClaim(event, answerableNow)) {
        // Deliberately not entered into `latest`: it must not survive as the
        // winner of its own key. The author high-water above still holds it if
        // it happens to be that author's newest row, so seq allocation and
        // gap-fill are unaffected.
        continue;
      }
      final key = (event.kind, event.key);
      final current = latest[key];
      if (current == null ||
          isNewerDeviceSync(event, current.event) ||
          (!isNewerDeviceSync(current.event, event) &&
              messageIdentityCompare(m, current.message) > 0)) {
        latest[key] = (event: event, message: m);
      }
    }
    // Per-item rows past the window go, even as winners of their own key.
    final perItem = [
      for (final v in latest.values)
        if (kDeviceLogPerItemKinds.contains(v.event.kind)) v,
    ]..sort((a, b) => b.event.tsMs.compareTo(a.event.tsMs));
    final oldestKept = nowMs - kDeviceLogPerItemMaxAge.inMilliseconds;
    final seenInPool = <String, int>{};
    final expired = <String>{
      for (final v in perItem)
        if ((seenInPool.update(
                  deviceLogPerItemPool(v.event.kind),
                  (n) => n + 1,
                  ifAbsent: () => 1,
                ) >
                kDeviceLogPerItemRowsKept) ||
            v.event.tsMs < oldestKept)
          v.message.ref,
    };
    final keep = <String>{
      ...unknown,
      ...branches,
      ...deferred,
      for (final v in latest.values)
        if (!expired.contains(v.message.ref)) v.message.ref,
      // The author's newest row stays whatever it says: seq allocation and
      // gap-fill read the high-water from it.
      for (final m in heads.values) m.ref,
    };
    return [
      for (final m in valid)
        if (keep.contains(m.ref)) m,
    ];
  }

  /// Whether a replica-claim row names content no revision can ask for.
  ///
  /// Fail-closed at every step: a legacy two-part key carries no cid to judge,
  /// and an item with no revision row in this log is unjudgeable — a claim can
  /// arrive before the row that explains it. Both are kept.
  bool _unreachableClaim(
    DeviceSyncEvent event,
    Map<String, Set<String>> answerable,
  ) {
    final parts = event.key.split('|');
    if (parts.length != 3) return false;
    final live = answerable[parts[0]];
    return live != null && !live.contains(parts[2]);
  }

  int messageIdentityCompare(GroupMessage a, GroupMessage b) {
    final author = a.author.hex.compareTo(b.author.hex);
    return author != 0 ? author : a.seq.compareTo(b.seq);
  }

  /// Compact only logs whose old entries are superseded state. Ordinary group
  /// messages are chat history and are never removed. Reaction winners and
  /// device-sync LWW winners are retained together with each author's max-seq
  /// row, preserving the current fold, next-seq allocation, and gap-fill
  /// high-water. Invalid/cross-group rows are scrubbed as part of the rewrite.
  Future<GroupLogCompaction?> compactLocked(
    NodeId groupId, {
    bool notify = true,
    bool shareEpochKeys = true,
  }) async {
    final original = await _owner.load(groupId);
    if (original == null) return null;
    final b = await _withoutExpiredDeviceBodies(original);
    // A ROW THIS DEVICE CANNOT VERIFY RIGHT NOW IS NOT A ROW IT MAY DELETE.
    //
    // This pass used to rewrite every group keeping only what verified at
    // that moment, and it runs the moment the app starts — before the cache
    // of other members' identity documents has been read. A member whose
    // device key is not their identity key signs rows that verify only
    // against that document, so on a cold start every one of them failed,
    // and the rewrite erased them from disk for good. Measured on the stand
    // 2026-09-23, second by second after a restart: two members became one,
    // the stored message went at +5 s, the epoch keys with it, and no later
    // sync could bring them back.
    //
    // "Cannot verify yet" is not "invalid", and only one kind of row is
    // provably not this group's business: one that names ANOTHER group.
    // Everything else stays on disk; the fold ignores what it cannot verify
    // and picks it up again once it can.
    bool ownControl(ControlEntry e) =>
        e.groupId == null || e.groupId == b.manifest.groupId;
    final control = [
      for (final e in b.control)
        if (ownControl(e)) e,
    ];
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _owner._validControlFor(b.manifest, e),
    ).state;
    final ownRows = [
      for (final m in b.messages)
        if (m.groupId == groupId) m,
    ];
    final List<GroupMessage> messages;
    if (b.manifest.name == GroupService.kDeviceGroupName) {
      // Superseded device-sync state is resolved among the rows that DO
      // verify; the ones that do not yet are carried through untouched, so
      // they neither win nor get deleted.
      final unverified = [
        for (final m in ownRows)
          if (!_owner._validMessageFor(groupId, m)) m,
      ];
      messages = [
        ...compactDeviceMessages(groupId, ownRows, isMember: state.isMember),
        ...unverified,
      ];
    } else {
      // Ordinary group messages are history and never compacted; the only
      // rewrite here is dropping exact duplicates and foreign rows.
      messages = {
        for (final m in ownRows) groupMessageHash(m): m,
      }.values.toList();
    }
    final reactions = await _compactReactions(b);
    final posts = _owner._retainedPostRows(groupId, b.posts);
    final result = GroupLogCompaction(
      messagesBefore: original.messages.length,
      messagesAfter: messages.length,
      postsBefore: b.posts.length,
      postsAfter: posts.length,
      controlBefore: b.control.length,
      controlAfter: control.length,
      reactionsBefore: b.reactions.length,
      reactionsAfter: reactions.length,
    );
    final compacted = b.copyWith(
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
    );
    if (result.changed || compacted.deviceMessageScrubPending) {
      await _owner._save(
        compacted,
        notify: notify,
        shareEpochKeys: shareEpochKeys,
      );
    }
    if (compacted.deviceMessageScrubPending) {
      // The replacement header durably carries both sequence floors and this
      // obligation before old bytes are vacuumed. A failed vacuum or final
      // header write remains retryable after restart, even with no rows left.
      if ((_owner._segmentIndex[_owner._key(groupId)]?.pending.isNotEmpty) ??
          false) {
        throw StateError('device journal segment cleanup incomplete');
      }
      await _owner._storage.scrubDeleted();
      await _owner._save(
        compacted.copyWith(deviceMessageScrubPending: false),
        notify: notify,
        shareEpochKeys: shareEpochKeys,
      );
    }
    // No marker is installed if validation/storage threw. A failed pass must
    // remain eligible on the next save. Hourly and explicit passes still run
    // independently of this watermark, including expiry without new rows.
    _noteDeviceSizeScan(b, result.messagesAfter);
    return result;
  }

  /// Compact superseded state rows across the groups this device holds.
  ///
  /// Compaction has always existed but ran only at boot (via
  /// [nudgeGroupSyncAll]). Replication ships a group's bundle WHOLE, so what
  /// the log accumulates between restarts is paid again on every sync:
  /// measured on the stand, a device-sync log at **2748 rows and 173 inline
  /// images** for a cloud of nine items, which one compaction pass collapsed
  /// to 233 and 11. A long-running app therefore got slower to sync the
  /// longer it ran, and a restart "fixed" it — which is how this was found.
  ///
  /// [limit] bounds one pass for the same reason the other sweeps are
  /// bounded: this runs hourly on a phone. The cursor makes the budget
  /// rotate, so a device in many groups still compacts all of them, just
  /// across several hours.
  Future<int> sweep({int limit = 8}) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    final ids = await _owner._index();
    if (ids.isEmpty) return 0;
    var collapsed = 0;
    final take = limit < ids.length ? limit : ids.length;
    // The device-sync group grows fastest — every cloud edit appends to it —
    // so it is compacted on EVERY pass rather than waiting for the cursor to
    // come round. Measured live: with a plain rotating budget it sat outside
    // the first window and one pass collapsed nothing while a manual run of
    // the same code collapsed 21 rows.
    // The device group has a dedicated pointer. Process it even when an older
    // or partially restored index lacks its entry.
    final deviceHex = await _owner.deviceGroupIdHex();
    final order = <String>[
      ?deviceHex,
      for (var i = 0; i < take; i++)
        if (ids[(_compactionCursor + i) % ids.length] != deviceHex)
          ids[(_compactionCursor + i) % ids.length],
    ];
    for (final hex in order) {
      try {
        final result = await _owner.compactStateLogs(NodeId.fromHex(hex));
        if (result == null || !result.changed) continue;
        collapsed +=
            (result.messagesBefore - result.messagesAfter) +
            (result.postsBefore - result.postsAfter) +
            (result.controlBefore - result.controlAfter) +
            (result.reactionsBefore - result.reactionsAfter);
      } catch (_) {
        // One unreadable group must not stop the rest of the pass.
      }
    }
    _compactionCursor = (_compactionCursor + take) % ids.length;
    return collapsed;
  }
}
