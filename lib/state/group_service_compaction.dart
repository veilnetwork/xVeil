part of 'group_service.dart';

/// Compaction of the state logs: which rows survive, and the bounded pass that
/// visits groups hour by hour.
///
/// A collaborator rather than an extension for the same reason as
/// [_ChannelKeyRotation]: extension members cannot be overridden and dispatch
/// statically. The public entry points and the per-group lock stay on the
/// owner; this file holds the rules for what is superseded.
class _LogCompaction {
  _LogCompaction(this._owner);

  final GroupService _owner;

  /// Where the last compaction pass stopped, so consecutive hours cover
  /// different groups instead of re-folding the same first few.
  int _compactionCursor = 0;

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

  List<GroupMessage> compactDeviceMessages(
    NodeId groupId,
    List<GroupMessage> input,
  ) {
    final latest =
        <
          (DeviceSyncKind, String),
          ({DeviceSyncEvent event, GroupMessage message})
        >{};
    final heads = <String, GroupMessage>{};
    final unknown = <String>{};
    for (final m in input) {
      if (!_owner._validMessageFor(groupId, m)) continue;
      final head = heads[m.author.hex];
      if (head == null || m.seq > head.seq) heads[m.author.hex] = m;
      final event = DeviceSyncEvent.fromBody(m.body);
      if (event == null) {
        // Forward-compatible: an older build must not erase a newer event kind.
        unknown.add(m.ref);
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
    final keep = <String>{
      ...unknown,
      for (final v in latest.values) v.message.ref,
      for (final m in heads.values) m.ref,
    };
    return [
      for (final m in input)
        if (_owner._validMessageFor(groupId, m) && keep.contains(m.ref)) m,
    ];
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
  Future<GroupLogCompaction?> compactLocked(NodeId groupId) async {
    final b = await _owner.load(groupId);
    if (b == null) return null;
    final control = [
      for (final e in b.control)
        if (_owner._validControlFor(b.manifest, e)) e,
    ];
    final messages = b.manifest.name == GroupService.kDeviceGroupName
        ? compactDeviceMessages(groupId, b.messages)
        : _owner._retainedMessageRows(b.manifest, b.messages);
    final reactions = await _compactReactions(b);
    final posts = _owner._retainedPostRows(groupId, b.posts);
    final result = GroupLogCompaction(
      messagesBefore: b.messages.length,
      messagesAfter: messages.length,
      postsBefore: b.posts.length,
      postsAfter: posts.length,
      controlBefore: b.control.length,
      controlAfter: control.length,
      reactionsBefore: b.reactions.length,
      reactionsAfter: reactions.length,
    );
    if (result.changed) {
      await _owner._save(
        b.copyWith(
          control: control,
          messages: messages,
          posts: posts,
          reactions: reactions,
        ),
      );
    }
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
    // NOT gated on the index: the device group is not listed there (nothing
    // enumerating `_index()` has ever reached it, which is why its log had
    // grown to 2748 rows), so a membership check here would skip the one
    // group this pass exists for.
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
