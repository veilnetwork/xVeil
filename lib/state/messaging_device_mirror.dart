part of 'messaging_core.dart';

/// Compare recent erasures on every pass and one older page on each pass.
/// The older page advances by the persisted round, including across restarts.
List<int> erasureComparisonPages({required int round, required int pages}) => [
  if (pages > 0) 0,
  if (pages > 1) 1 + (round - 1) % (pages - 1),
];

/// Keep recent conversations current while eventually visiting every older one.
List<int> erasureComparisonConversations({
  required int round,
  required int count,
  int recent = 30,
}) => [
  for (var i = 0; i < count && i < recent; i++) i,
  if (count > recent) recent + (round - 1) % (count - recent),
];

/// Multi-device projections owned by the messaging layer.
///
/// Mirrored writes deliberately bypass the ordinary local callbacks so an
/// event received from another device cannot loop back into the device group.
/// Relationship state and per-device P2P policy remain local; only the fields
/// explicitly carried by the bridge are merged.
class _MessagingDeviceMirror {
  _MessagingDeviceMirror(this._owner);

  final MessagingService _owner;

  /// Per sibling device: when this device last asked it about erasures.
  final Map<String, DateTime> _erasureAskedAt = {};

  /// Exact message keys requested in the current pass, by device and peer.
  /// A sibling's answer may only erase messages named in that pass.
  final Map<String, Map<String, Set<String>>> _erasureAskedKeys = {};

  /// How often one sibling is asked, at most.
  static const _erasureAskEvery = Duration(minutes: 10);

  /// Recent conversations compared on every ask; one older one rotates in.
  static const _erasureConversations = 30;

  /// …and how many of the newest messages of each.
  static const _erasureWindow = 200;

  /// Ask [device], one of MY devices, which of the messages this device still
  /// shows it has erased (see [WireKind.deviceGone]).
  ///
  /// An erase reaches my other devices as a device-log event; one lost there
  /// — measured on the stand when the device-post queue drowned under load —
  /// left the message deleted on one device and shown on the other for good,
  /// with nothing to notice. Every erase is mirrored to my devices, whatever
  /// its route (mine, the peer's unsend, a disappearing window), so a sibling's
  /// tombstone is a delete this device owes.
  Future<void> askSiblingForErasures(NodeId device) async {
    final now = _owner._now();
    final last = _erasureAskedAt[device.hex];
    if (last != null && now.difference(last) < _erasureAskEvery) return;
    _erasureAskedAt[device.hex] = now;
    try {
      // A device often runs only briefly. A RAM cursor restarted at page zero
      // on every launch, so deep history was never compared on such devices.
      final cursorKey = 'device.erasure.round.v1:${device.hex}';
      final previous =
          int.tryParse(await _owner._storage.getSetting(cursorKey) ?? '') ?? 0;
      final round = (previous < 0 ? 0 : previous) + 1;
      await _owner._storage.putSetting(cursorKey, '$round');
      final selfHex = await _owner._selfHex();
      final conversations =
          [
            for (final c in await _owner._storage.loadConversations())
              if (c.lastMessage != null) c,
          ]..sort(
            (a, b) =>
                b.lastMessage!.timestamp.compareTo(a.lastMessage!.timestamp),
          );
      final requested = <String, Set<String>>{};
      _erasureAskedKeys[device.hex] = requested;
      for (final index in erasureComparisonConversations(
        round: round,
        count: conversations.length,
        recent: _erasureConversations,
      )) {
        final c = conversations[index];
        final peer = c.peer.nodeId;
        if (await _owner._isSiblingDevice(peer)) continue;
        final messages = await _owner._storage.loadMessages(peer.hex)
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        if (messages.isEmpty) continue;
        final pages = (messages.length + _erasureWindow - 1) ~/ _erasureWindow;
        for (final page in erasureComparisonPages(round: round, pages: pages)) {
          final keys = [
            for (final m
                in messages.skip(page * _erasureWindow).take(_erasureWindow))
              ownEchoKey(m.id),
          ];
          // Register before sending: an immediate reply may arrive before the
          // send Future completes.
          requested.putIfAbsent(peer.hex, () => <String>{}).addAll(keys);
          await _owner._send(
            device,
            WireEnvelope.deviceGone(
              jsonEncode({'d': selfHex, 'q': peer.hex, 'k': keys}),
            ).encode(),
          );
        }
      }
    } catch (e) {
      devLog(() => 'xVeil[devices]: erasure ask to ${device.short} failed: $e');
    }
  }

  /// An ask or an answer from one of MY devices (the caller checked that).
  Future<void> handleErasureFrame(InboundMessage m, String body) async {
    try {
      final d = jsonDecode(body);
      if (d is! Map) return;
      NodeId? device = m.srcDevice != null && m.srcDevice != m.src
          ? m.srcDevice
          : null;
      final named = d['d'];
      if (device == null && named is String) device = NodeId.fromHex(named);
      if (device == null) return;
      final mine = await _owner.myOtherDevices?.call() ?? const <NodeId>[];
      if (!mine.contains(device)) return;
      final ask = d['q'], keys = d['k'];
      if (ask is String && keys is List) {
        final wanted = {
          for (final k in keys)
            if (k is String) k,
        };
        final erased = [
          for (final id in await _owner._storage.deletedMessageIds(ask))
            if (wanted.contains(ownEchoKey(id))) id,
        ];
        if (erased.isEmpty) return;
        await _owner._send(
          device,
          WireEnvelope.deviceGone(
            jsonEncode({'d': await _owner._selfHex(), 'a': ask, 'ids': erased}),
          ).encode(),
        );
        return;
      }
      final answer = d['a'], ids = d['ids'];
      if (answer is! String || ids is! List) return;
      // Only an answer to an ask of ours: a sibling cannot volunteer deletes.
      final asked = _erasureAskedAt[device.hex];
      if (asked == null ||
          _owner._now().difference(asked) > const Duration(minutes: 15)) {
        return;
      }
      final peer = NodeId.fromHex(answer);
      final requested = _erasureAskedKeys[device.hex]?[peer.hex];
      if (requested == null) return;
      var applied = 0;
      for (final id in ids) {
        if (id is! String) continue;
        if (!requested.contains(ownEchoKey(id))) continue;
        if (await _owner._storage.loadMessageById(peer.hex, id) == null) {
          continue;
        }
        await applyDelete(peer: peer, msgId: id);
        applied++;
      }
      if (applied > 0) {
        devLog(
          () =>
              'xVeil[devices]: ${device!.short} had erased $applied message(s) '
              'still shown here in ${peer.short} — erased here too',
        );
      }
    } catch (e) {
      devLog(() => 'xVeil[devices]: erasure frame dropped: $e');
    }
  }

  /// Fires after an ordinary 1:1 messaging write, never after [applyMessage].
  FutureOr<void> Function(NodeId peer, Message stored)? _storedPublisher;
  final Set<(String, String)> _storedPublished = {};

  // Storage can expose an appended row before its append Future, and then its
  // required own-device publication, have completed. Background readers must
  // not mistake that visibility for permission to transmit the row.
  final Map<(String, String), int> _storedWrites = {};

  Future<T> withStoredWrite<T>(
    NodeId peer,
    String id,
    Future<T> Function() write,
  ) async {
    final key = (peer.hex, id);
    _storedWrites[key] = (_storedWrites[key] ?? 0) + 1;
    try {
      return await write();
    } finally {
      final left = _storedWrites[key]! - 1;
      if (left == 0) {
        _storedWrites.remove(key);
      } else {
        _storedWrites[key] = left;
      }
    }
  }

  /// Defer unfinished local writes without parking other conversations behind
  /// them. After failure or restart, repair a locally authored row's missing
  /// publication before retrying it. A sibling's projection already came from
  /// the journal and must not be published back into it.
  Future<bool> prepareStoredRetry(NodeId peer, Message stored) async {
    final key = (peer.hex, stored.id);
    if (_owner._disposed || _storedWrites.containsKey(key)) return false;
    // Completed history is not a recovery job. Re-publishing every old,
    // delivered row requested by gap-fill would churn the bounded device log.
    if (stored.direction != MessageDirection.outgoing ||
        stored.status != MessageStatus.sent) {
      return true;
    }
    final self = await _owner._selfHex();
    if (_owner._disposed || _storedWrites.containsKey(key)) return false;
    if (stored.author != self) return true;
    return withStoredWrite(peer, stored.id, () async {
      await publishStored(peer, stored, publisher: onMessageStored);
      return true;
    });
  }

  FutureOr<void> Function(NodeId peer, Message stored)? get onMessageStored =>
      _storedPublisher;

  set onMessageStored(
    FutureOr<void> Function(NodeId peer, Message stored)? value,
  ) {
    if (!identical(value, _storedPublisher)) _storedPublished.clear();
    _storedPublisher = value;
  }

  /// Complete the local journal side of a chat write. Failed publications are
  /// never cached; a duplicate after a restart also retries once from storage.
  Future<bool> publishStored(
    NodeId peer,
    Message stored, {
    required FutureOr<void> Function(NodeId peer, Message stored)? publisher,
  }) async {
    if (publisher == null) return false;
    final key = (peer.hex, stored.id);
    if (identical(publisher, _storedPublisher) &&
        _storedPublished.contains(key)) {
      return false;
    }
    await publisher(peer, stored);
    if (identical(publisher, _storedPublisher)) {
      _storedPublished.add(key);
      if (_storedPublished.length > kMaxPendingOps) {
        _storedPublished.remove(_storedPublished.first);
      }
    }
    return true;
  }

  Future<bool> mirrorStoredIfPresent(NodeId peer, String id) async {
    final publisher = onMessageStored;
    final stored = await _owner._storage.loadMessageById(peer.hex, id);
    if (stored == null) return false;
    final repaired = await publishStored(
      peer,
      stored,
      publisher: publisher ?? onMessageStored,
    );
    // The first dispatch can fail before its normal UI signal, even though
    // the row is durable. Refresh it after recovery without a duplicate notice.
    if (repaired) _owner._signal();
    return true;
  }

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
  FutureOr<void> Function(NodeId peer, String msgId)? onMessageDeleted;

  /// Fires when a message's TEXT is replaced HERE — by this person editing
  /// their own, or by the peer editing theirs. Never fired for an edit applied
  /// FROM a sibling.
  FutureOr<void> Function(
    NodeId peer,
    String msgId,
    String body,
    List<InlineCustomEmoji> customEmoji,
  )?
  onMessageEdited;

  /// Fires when a whole conversation is cleared HERE. Carries the clear EVENT,
  /// because a clear is not a list of erasures — it is a watermark, and the
  /// watermark is what stops a message from before it reappearing afterwards.
  void Function(
    NodeId peer,
    String author,
    int seq,
    Map<String, int> watermark,
    int atMs,
  )?
  onConversationCleared;

  /// Lets the device bridge offer an additional authenticated content source.
  Future<void> Function(String contentId)? deviceContentPull;

  /// Fires only after a local edit of sync-worthy contact preferences.
  void Function(Contact updated)? onContactPrefsChanged;

  /// Apply a message projected from another device without re-mirroring it.
  ///
  /// [tsMs] is bounded by [messageTsOnReceipt] like any other stamp that
  /// arrives from someone else, and this path needs it MORE than the wire path
  /// does: a mirrored row is off the event streams the author-monotone
  /// effective-ts floor is computed over, so it falls back to its raw timestamp
  /// for display. Nothing else here reads the clock — a future stamp that lands
  /// keeps the conversation pinned to the top of the chat list, and poisons its
  /// read watermark, until it arrives.
  ///
  /// It does NOT arrive without an author and a seq, whatever this comment said
  /// until 2026-09-21. Storage allocates both locally on append, and a probe
  /// measured it: a mirrored INCOMING row comes back with the peer's hex as its
  /// author and a locally allocated seq. The distinction cost half an hour of
  /// diagnosing a clear that would not travel.
  ///
  /// The value the emit tap mirrors on is the STORED row's timestamp, so a
  /// stamp bounded on the device that received it from the wire travels to the
  /// siblings already bounded and is a no-op here.
  /// Write a sibling's report of how far one of our messages has got.
  ///
  /// A delivery can arrive before its mirror, or during append. Remember it
  /// before awaiting storage so append can commit the terminal state instead
  /// of exposing another retry job. The signed device journal/history remain
  /// the durable sources after eviction/restart. Never publishes back.
  Future<void> applyMessageStatus({
    required NodeId peer,
    required String msgId,
    required MessageStatus status,
  }) async {
    if (_owner._disposed) return;
    if (status == MessageStatus.delivered) {
      _owner._messageDelivery.noteMirroredDelivery(peer.hex, msgId);
    }
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
      _owner._mutations.rememberDeleteCompleted(peer, msgId);
      _owner._signal();
    } catch (e) {
      devLog(() => 'xVeil[devices]: mirrored delete of $msgId failed: $e');
    }
  }

  /// Replace a message's text because one of my other devices replaced it.
  ///
  /// A current sender carries the edit revision separately from the post's
  /// position. Keep that revision even if the body is unchanged, and resolve
  /// equal revisions by the common content hash. Only a legacy edit without a
  /// revision needs a locally allocated number.
  Future<void> applyEdit({
    required NodeId peer,
    required String msgId,
    required String body,
    int? seq,
    List<InlineCustomEmoji> customEmoji = const [],
    bool reflected = false,
  }) async {
    if (_owner._disposed) return;
    try {
      if (await _owner._storage.isMessageDeleted(peer.hex, msgId)) return;
      final target = await _owner._storage.loadMessageById(peer.hex, msgId);
      if (target == null) {
        if (reflected) return;
        // The edit outran the mirror that carries its message: both ride the
        // same log, but an oversized mirror waits for a later fetch window.
        // Parked in the buffer the wire path uses for the same race, and spent
        // by [applyMessage] when the message lands.
        _owner._mutations.bufferPending(
          peer,
          msgId,
          _PendingOp.edit(body, customEmoji, seq: seq),
        );
        return;
      }
      if (await _owner._inboundExpiry.edit(peer, target, mirrored: true)) {
        return;
      }
      final hash = messageEditContentHash(body, customEmoji);
      final heldHash = messageEditContentHash(target.body, target.customEmoji);
      if (seq == null) {
        if (hash == heldHash) return;
      } else if (!messageEditWins(
        revision: seq,
        contentHash: hash,
        heldRevision: (await _owner._storage.editSeqs(peer.hex))[msgId],
        heldContentHash: heldHash,
        reflected: reflected,
        heldReflected: target.reflectedEdit,
      )) {
        return;
      }
      await _owner._storage.editMessage(
        peer.hex,
        msgId,
        body,
        seq: seq,
        customEmoji: customEmoji,
        reflected: reflected,
      );
      // Keep the original post clock across this await, including reflected
      // peer-history edits. A sibling replay never publishes a deletion back.
      if (await _owner._inboundExpiry.edit(peer, target, mirrored: true)) {
        return;
      }
      _owner._signal();
    } catch (e) {
      devLog(() => 'xVeil[devices]: mirrored edit of $msgId failed: $e');
    }
  }

  /// Empty a conversation because one of my other devices emptied it.
  ///
  /// The same applier a peer's clear-for-everyone goes through — this is a
  /// clear of OUR OWN identity's making, so the author is our identity and the
  /// watermark is ours to honour in full. Idempotent on (author, seq): the fold
  /// is replayed into the appliers on every app start, and a clear already
  /// applied finds its own slot taken and returns.
  Future<void> applyClear({
    required NodeId peer,
    required String author,
    required int seq,
    required Map<String, int> watermark,
    required int atMs,
  }) async {
    if (_owner._disposed) return;
    try {
      await _owner._storage.applyRemoteClear(
        peer,
        author,
        seq,
        watermark,
        selfHex: await _owner._selfHex(),
        // WHEN the clear happened, not when we got round to it. A device group
        // runs minutes behind; bounding by our own clock would sweep away every
        // message that arrived in between, which is every message sent AFTER
        // the clear.
        ownClearAtMs: atMs,
        // A sibling's clear is OURS, whoever authored it: the whole
        // conversation up to the moment it was made, the counterpart's
        // messages included.
        fromOwnDevice: true,
      );
      await _owner._contacts.discardHeldThrough(peer, atMs);
      _owner._signal();
    } catch (e) {
      devLog(
        () => 'xVeil[devices]: mirrored clear of ${peer.short} failed: $e',
      );
    }
  }

  /// Whether the person asked, when this device joined, for the heavy media of
  /// the history too — and that answer still holds.
  Future<bool> _heavyHistoryWanted() async {
    final until = int.tryParse(
      await _owner._storage.getSetting(kHeavyHistoryMediaUntilKey) ?? '',
    );
    return until != null && until > _owner._now().millisecondsSinceEpoch;
  }

  // Active work only, not a cache of completed applies. A live mirror and a
  // folded/history copy can both see a missing row before append is visible.
  // Serialize their complete read/modify/write turn without blocking another
  // (conversation, message) key. Failure releases the next retry too.
  final _mirrorApplyTails = <(String, String), Future<void>>{};

  Future<bool> applyMessage({
    PreparedMessageAppender? appendPrepared,
    PreparedOrderingAdopter? adoptPrepared,
    String? author,
    int? seq,
    bool? positionVerified,
    bool reflectedEdit = false,
    String? replyToId,
    String? forwardedFrom,
    required NodeId peer,
    required String msgId,
    required MessageDirection direction,
    required String body,
    required int tsMs,
    // Outgoing rows default to `sent`; a caller that KNOWS the peer holds the
    // message says so, or the outbox re-sends it.
    MessageStatus? status,
    String? fileContentId,
    String? fileName,
    int? fileSize,
    String? thumb,
    List<InlineCustomEmoji> customEmoji = const [],
  }) {
    if (_owner._disposed) return Future<bool>.value(false);
    // Keep the admission's owner, not the one present after a queued write.
    final binding = _owner.groupBindingsOwner;
    final key = (peer.hex, msgId);
    final previous = _mirrorApplyTails[key] ?? Future<void>.value();
    final result = previous.then<bool>((_) {
      if (_owner._disposed || !identical(binding, _owner.groupBindingsOwner)) {
        return false;
      }
      return _applyMessage(
        appendPrepared: appendPrepared,
        adoptPrepared: adoptPrepared,
        binding: binding,
        author: author,
        seq: seq,
        positionVerified: positionVerified,
        reflectedEdit: reflectedEdit,
        replyToId: replyToId,
        forwardedFrom: forwardedFrom,
        peer: peer,
        msgId: msgId,
        direction: direction,
        body: body,
        tsMs: tsMs,
        status: status,
        fileContentId: fileContentId,
        fileName: fileName,
        fileSize: fileSize,
        thumb: thumb,
        customEmoji: customEmoji,
      );
    });
    late final Future<void> settled;
    settled = result.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_mirrorApplyTails[key], settled)) {
        _mirrorApplyTails.remove(key);
      }
    });
    _mirrorApplyTails[key] = settled;
    return result;
  }

  Future<bool> _applyMessage({
    PreparedMessageAppender? appendPrepared,
    PreparedOrderingAdopter? adoptPrepared,
    required Object? binding,
    String? author,
    int? seq,
    bool? positionVerified,
    bool reflectedEdit = false,
    String? replyToId,
    String? forwardedFrom,
    required NodeId peer,
    required String msgId,
    required MessageDirection direction,
    required String body,
    required int tsMs,
    // Outgoing rows default to `sent`; a caller that KNOWS the peer holds the
    // message says so, or the outbox re-sends it.
    MessageStatus? status,
    String? fileContentId,
    String? fileName,
    int? fileSize,
    String? thumb,
    List<InlineCustomEmoji> customEmoji = const [],
  }) async {
    // NEVER A CONVERSATION WITH MY OWN DEVICE. Every emitter already refuses
    // to mirror one, but a sibling on an older build — or a history replay —
    // can still carry it, and storing it here CREATES a chat, and a contact
    // row, with a device of my own. Measured on the stand: a file pulled from
    // the sibling surfaced as an offer in a chat with that sibling, the replay
    // carried the chat back, and the device ended up with an unanswerable
    // "pending" contact that was ITSELF.
    if (_owner._disposed) return false;
    if (await _owner._isSiblingDevice(peer) ||
        _owner._disposed ||
        !identical(binding, _owner.groupBindingsOwner)) {
      return false;
    }
    // A new-format verified marker promises an original position. Reject an
    // inconsistent record before storage can fill missing fields with local
    // counters and make a later backfill misidentify them as original.
    if (positionVerified == true &&
        (author == null ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(author) ||
            seq == null ||
            !isAcceptableWireSeq(seq))) {
      return false;
    }
    if (await _owner._hasMessage(peer, msgId)) {
      // A legacy copy may already exist as `sent`. Completion evidence from
      // an authenticated sibling repairs its status without changing content,
      // time or provenance. A failed snapshot cannot undo a newer retry.
      var deliveryChanged = false;
      if ((status == MessageStatus.delivered ||
              _owner._messageDelivery.hasMirroredDelivery(peer.hex, msgId)) &&
          direction == MessageDirection.outgoing) {
        final held = await _owner._storage.loadMessageById(peer.hex, msgId);
        if (held?.direction == MessageDirection.outgoing) {
          deliveryChanged = await _owner._storage.markMessageStatus(
            peer.hex,
            msgId,
            MessageStatus.delivered,
          );
          if (deliveryChanged) _owner._signal();
        }
      }
      // An own echo from the contact may win the race with this authenticated
      // device mirror. Its locally allocated position is provisional. Accept
      // the original physical-device position, WITHOUT replacing content or
      // making the echoed body an authentic outgoing event. Neither the peer's
      // echo (no seq) nor a backfill of its identity-alias position can do this.
      if (direction != MessageDirection.outgoing ||
          positionVerified == false ||
          author == null ||
          seq == null ||
          !isAcceptableWireSeq(seq) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(author)) {
        return deliveryChanged;
      }
      final self = await _owner._selfHex();
      if (author != self &&
          !await _owner._isSiblingDevice(NodeId.fromHex(author))) {
        return deliveryChanged;
      }
      final held = await _owner._storage.loadMessageById(peer.hex, msgId);
      final identity = await _owner.selfIdentityHex?.call();
      if (held == null ||
          held.direction != MessageDirection.outgoing ||
          held.author == null ||
          held.seq == null ||
          !(held.author == peer.hex ||
              (identity != null &&
                  identity != self &&
                  held.author == identity))) {
        return deliveryChanged;
      }
      final changed = adoptPrepared == null
          ? await _owner._storage.adoptMessageOrdering(
              peer.hex,
              msgId,
              provisionalAuthor: held.author!,
              provisionalSeq: held.seq!,
              author: author,
              seq: seq,
            )
          : await adoptPrepared(
              MessageOrderingAdoption(
                conversationId: peer.hex,
                messageId: msgId,
                provisionalAuthor: held.author!,
                provisionalSeq: held.seq!,
                author: author,
                seq: seq,
              ),
            );
      if (_owner._disposed || !identical(binding, _owner.groupBindingsOwner)) {
        return false;
      }
      if (changed) _owner._signal();
      return changed || deliveryChanged;
    }
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
    final contact = await _owner._storage.getContact(peer);
    if (direction == MessageDirection.incoming) {
      if (contact?.status == ContactStatus.blocked) {
        devLog(
          () =>
              'xVeil[devices]: mirrored message $msgId from ${peer.short} '
              'REFUSED — that contact is blocked on this device',
        );
        return false;
      }
    }
    final receivedAt = _owner._now();
    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      messageTsOnReceipt(tsMs, receivedAt.millisecondsSinceEpoch),
    );
    final ttl = contact?.disappearingTtlSeconds;
    if (ttl != null &&
        ttl > 0 &&
        !receivedAt.isBefore(timestamp.add(Duration(seconds: ttl)))) {
      if (_owner._disposed || !identical(binding, _owner.groupBindingsOwner)) {
        return false;
      }
      // The bounded device journal can outlive a conversation's TTL. Refuse
      // its late projection before any body/media write, not at the next
      // background sweep. Keep only a local bodyless gap-fill/tombstone slot.
      await _owner._storage.recordExpiredMessage(
        peer.hex,
        msgId,
        author: author,
        seq: seq,
      );
      devLog(
        () => 'xVeil[devices]: expired mirror refused before message storage',
      );
      return false;
    }
    final initialStatus =
        direction == MessageDirection.outgoing &&
            _owner._messageDelivery.hasMirroredDelivery(peer.hex, msgId)
        ? MessageStatus.delivered
        : status ??
              (direction == MessageDirection.outgoing && !reflectedEdit
                  ? MessageStatus.sent
                  : MessageStatus.delivered);
    if (_owner._disposed || !identical(binding, _owner.groupBindingsOwner)) {
      return false;
    }
    final message = Message(
      id: msgId,
      conversationId: peer.hex,
      direction: direction,
      body: body,
      timestamp: timestamp,
      status: initialStatus,
      fileContentId: fileContentId,
      fileName: fileName,
      fileSize: fileSize,
      thumb: thumb,
      customEmoji: customEmoji,
      replyToId: replyToId,
      forwardedFrom: forwardedFrom,
      author: author,
      seq: seq,
      positionVerified: positionVerified,
      edited: reflectedEdit,
      reflectedEdit: reflectedEdit,
    );
    if (appendPrepared == null) {
      await _owner._storage.appendMessage(message);
    } else {
      final result = await appendPrepared(message);
      if (result == PreparedMessageWrite.suppressed) return false;
      if (result == PreparedMessageWrite.existing) {
        // A normal wire arrival or an earlier cohort won the insert race.
        // Re-enter the same merge, without restaging or releasing this key.
        return _applyMessage(
          binding: binding,
          author: author,
          seq: seq,
          positionVerified: positionVerified,
          reflectedEdit: reflectedEdit,
          replyToId: replyToId,
          forwardedFrom: forwardedFrom,
          peer: peer,
          msgId: msgId,
          direction: direction,
          body: body,
          tsMs: tsMs,
          status: status,
          fileContentId: fileContentId,
          fileName: fileName,
          fileSize: fileSize,
          thumb: thumb,
          customEmoji: customEmoji,
        );
      }
    }
    if (_owner._disposed || !identical(binding, _owner.groupBindingsOwner)) {
      return false;
    }
    // The constructor may have run before the receipt arrived while append
    // was pending. Finish its durable status before reporting the apply done.
    if (direction == MessageDirection.outgoing &&
        initialStatus != MessageStatus.delivered &&
        _owner._messageDelivery.hasMirroredDelivery(peer.hex, msgId)) {
      await _owner._storage.markMessageStatus(
        peer.hex,
        msgId,
        MessageStatus.delivered,
      );
    }
    // An erase or an edit that got here FIRST is spent now, exactly as the wire
    // path spends a peer's unsend that outran its post: store, then apply, so
    // the row never shows the superseded text and an erased id is refused if it
    // is mirrored again.
    final pending = _owner._mutations.takePending(
      peer,
      msgId,
      direction: direction,
    );
    if (pending != null && pending.isDelete) {
      await _owner._mutations.completeDelete(
        peer,
        msgId,
        notifyDevices: pending.incomingOnly,
      );
    } else if (pending != null && pending.body != null) {
      await _owner._storage.editMessage(
        peer.hex,
        msgId,
        pending.body!,
        seq: pending.seq,
        customEmoji: pending.customEmoji,
      );
    }
    _owner._signal();
    // A file under this device's auto-download policy comes WITH its message,
    // as it would have off the wire. A newly linked device receives its whole
    // history as mirrors (the owner's decision, 2026-09-26: everything, heavy
    // media only when asked), and a conversation whose every photo waits for a
    // tap is not the conversation the person left on their other device. The
    // policy is what decides "heavy": above it the row stays a reference and
    // the bytes follow the tap, exactly as for a live offer.
    final cid = fileContentId;
    if (cid != null &&
        pending?.isDelete != true &&
        (_owner._filePolicy.allowsAuto(fileSize, fileName) ||
            await _heavyHistoryWanted()) &&
        !await _owner._storage.hasFile(cid)) {
      unawaited(deviceContentPull?.call(cid));
    }
    return true;
  }

  // Only local preference edits allocate witnesses. An own-event echo may
  // wait behind native IO while the UI commits another edit to this contact.
  // Keep the captured snapshot weakly: callers and the outgoing gate own its
  // lifetime, not this map.
  final _localPrefsWitness = <NodeId, Object>{};
  final _prefsSnapshotWitness = Expando<Object>();

  bool isCurrentContactPrefsSnapshot(Contact snapshot) =>
      !_owner._disposed &&
      _prefsSnapshotWitness[snapshot] != null &&
      identical(
        _prefsSnapshotWitness[snapshot],
        _localPrefsWitness[snapshot.nodeId],
      );

  /// Serialize the transform with consent writes and publish only its result.
  Future<Contact?> updateContactPrefs(
    NodeId peer,
    Contact? Function(Contact current) update, {
    bool mirror = true,
    bool local = true,
    String? onlyIfLocalPrefsToken,
  }) async {
    if (_owner._disposed) throw StateError('messaging service is closed');
    Object? previousWitness, attemptedWitness;
    final Contact? committed;
    try {
      committed = await _owner._storage.updateContactPrefs(
        peer,
        (current) {
          final next = update(current);
          if (next != null && local) {
            // Invalidate before the commit await, in the same serialized turn.
            // Even an already queued own echo must check again when it writes.
            previousWitness = _localPrefsWitness[peer];
            final witness = Object();
            attemptedWitness = witness;
            _localPrefsWitness[peer] = witness;
            _prefsSnapshotWitness[next] = witness;
          }
          return next;
        },
        queueForSync: local && mirror,
        onlyIfLocalPrefsToken: onlyIfLocalPrefsToken,
      );
    } catch (_) {
      // A refused write has no snapshot to publish. Do not disqualify the
      // previous committed snapshot, or roll back a newer writer's witness.
      if (attemptedWitness != null &&
          identical(_localPrefsWitness[peer], attemptedWitness)) {
        if (previousWitness == null) {
          _localPrefsWitness.remove(peer);
        } else {
          _localPrefsWitness[peer] = previousWitness!;
        }
      }
      rethrow;
    }
    if (committed == null || _owner._disposed) return null;
    try {
      if (mirror) onContactPrefsChanged?.call(committed);
    } finally {
      _owner._signal();
    }
    return committed;
  }

  Future<bool> applyPolicy(NodeId peer, DisappearingSetting policy) async {
    if (_owner._disposed || await _owner._isSiblingDevice(peer)) return false;
    var known = false;
    await updateContactPrefs(
      peer,
      (current) {
        known = true;
        final held = DisappearingSetting(
          ttlSeconds: current.disappearingTtlSeconds,
          setAtMs: current.disappearingSetAtMs,
          setBy: current.disappearingSetBy,
          hideAfterReadSeconds: current.hideAfterReadSeconds,
        );
        if (DisappearingSetting.compare(policy, held) <= 0) return null;
        return current.copyWith(
          disappearingTtlSeconds: policy.ttlSeconds,
          disappearingSetAtMs: policy.setAtMs,
          disappearingSetBy: policy.setBy,
          hideAfterReadSeconds: policy.hideAfterReadSeconds,
        );
      },
      mirror: false,
      local: false,
    );
    return known && !_owner._disposed;
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
    required ClearRequestPolicy clearPolicy,
    DisappearingSetting? disappearing,
    bool Function()? shouldApply,
    String? onlyIfLocalPrefsToken,
  }) async {
    // See [applyMessage]: a contact record of my own device is not portable.
    if (_owner._disposed || await _owner._isSiblingDevice(peer)) return false;
    // The retention policy is decided by the SAME rule a peer's announcement
    // goes through, not by whoever mirrored last. A sibling that has been
    // offline holds an older view, and its alias edit must not roll the window
    // back — `winner` is last-writer-wins with a deterministic tie-break, so
    // both devices land on one answer whichever order the events arrive in.
    final committed = await updateContactPrefs(
      peer,
      (existing) {
        if (shouldApply != null && !shouldApply()) return null;
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
        return existing.copyWith(
          name: name,
          mutedUntil: mutedUntilMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(mutedUntilMs),
          notificationMuteMode: notificationMuteMode,
          pinned: pinned,
          archived: archived,
          retentionDays: retentionDays,
          allowPeerDelete: allowPeerDelete,
          clearPolicy: clearPolicy,
          disappearingTtlSeconds: policy.ttlSeconds,
          disappearingSetAtMs: policy.setAtMs,
          disappearingSetBy: policy.setBy,
          hideAfterReadSeconds: policy.hideAfterReadSeconds,
        );
      },
      mirror: false,
      local: false,
      onlyIfLocalPrefsToken: onlyIfLocalPrefsToken,
    );
    return committed != null;
  }
}
