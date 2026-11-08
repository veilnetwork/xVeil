part of 'messaging_core.dart';

/// Anti-entropy for history which has outlived the bounded device journal.
/// Nothing here extends that journal, changes consent, or uses mailbox. One
/// outstanding request per sibling bounds reassembly and supplies backpressure.
class _MessagingOwnHistory {
  _MessagingOwnHistory(this._owner);
  final MessagingService _owner;
  final _tasks = AsyncTasks();
  // A complete encoded 64-slice page fits one peer's budget. History is
  // live-only and retries, so overflow drops instead of growing another queue.
  final admission = InboundAdmission(
    label: 'device-history',
    maxBytes: 1 << 20,
    maxFrames: 512,
    maxKnownPeerBytes: 256 << 10,
    maxStrangerPeerBytes: 0,
    maxStrangerBytes: 0,
  );
  Future<void> _inbound = Future<void>.value();
  final _pageApplies = <String, Future<void>>{};

  final _pulls = <String, _OwnHistoryPull>{};
  // A deadline stops waiting, not the underlying transport operation. Credit
  // belongs to the actual request send, even after its pull/binding retires.
  final _requestSends = <String, _OwnHistoryRequestSend>{};
  final _starting = <String, Object>{};
  final _serving = <String, _OwnHistoryServe>{};
  final _answers =
      <
        String,
        ({
          String id,
          String query,
          Uint8List bytes,
          Object? binding,
          DateTime at,
        })
      >{};
  final _nextScan = <String, DateTime>{};
  final _lastWake = <String, DateTime>{};
  Timer? _timer;
  bool _closed = false;
  // Conversation inventory and prefix-proof granularity stay unchanged.
  static const _page = 8;
  // Short messages should share a byte-bounded reply rather than pay another
  // round trip, snapshot and durable cursor every eight rows. The 128-KiB,
  // 64-part and admission ceilings remain independent of this row cap.
  static const _messagePage = 32;
  static const _maxPrefixes = 8;
  // Four-KiB binary slices fit the existing six-KiB transport frame even
  // after base64/envelope encoding. Keep the page byte budget independent
  // of accepted part count (which also admits older, smaller slices).
  static const _slice = 4096;
  static const _maxPartBase64 = ((_slice + 2) ~/ 3) * 4;
  static const _maxWireBody = 6000;
  static const _maxPageBytes = 128 * 1024;
  static const _maxParts = 64;
  static const _maxDevices = 32;
  static const _maxAttempts = 6;
  // Stored message events are bounded at 512 KiB. Mirror metadata fits the
  // existing 1-MiB application-frame bound, separately from the unchanged
  // 128-KiB page. All partial records together share 4 MiB.
  static const _maxRecordBytes = kLargeFrameMaxBytes;
  static const _maxHeldRecordBytes = 4 * kLargeFrameMaxBytes;
  static const _recordSlice = 64 * 1024;
  int _heldRecordBytes = 0;

  bool get _ready =>
      !_closed &&
      !_owner._disposed &&
      !_owner._expiryLifecycle.pending &&
      _owner._ownHistoryBindingsReady &&
      _owner.groupBindingsOwner != null &&
      _owner.ownHistoryEncode != null &&
      _owner.ownHistoryApply != null;
  String _key(String device) => 'device.history.cursor.v2:$device';
  bool _hex(dynamic value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  void _report() => errorJournal.record(
    kind: 'device-history',
    error: StateError('Own-device history exchange could not complete'),
    atMs: _owner._now().millisecondsSinceEpoch,
  );

  void _run(Future<void> Function() action) {
    if (_closed) return;
    // Catch inside the owned future too: close() joins those futures, so an
    // already reported history error must not abort the remaining shutdown.
    unawaited(
      _tasks.runRequired(() async {
        try {
          await action();
        } catch (_) {
          _report();
        }
      }),
    );
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    _tick();
  }

  void nudge() {
    if (_timer != null) _tick();
  }

  /// Detach stale pulls before readiness cleanup yields. An old continuation
  /// must not install its failure cooldown while the replacement is paused.
  void retireStaleBindings() {
    for (final pull in _pulls.values.toList()) {
      if (!identical(pull.binding, _owner.groupBindingsOwner)) {
        _finish(pull, Duration.zero, retirePreparation: true);
      }
    }
    _starting.removeWhere(
      (_, binding) => !identical(binding, _owner.groupBindingsOwner),
    );
  }

  void _tick() => _run(() async {
    if (!_ready) return;
    final binding = _owner.groupBindingsOwner;
    final devices = await _owner.myOtherDevices?.call() ?? <NodeId>[];
    // A lookup from the previous provider must not retire a pull belonging to
    // its replacement. _begin rechecks admission too, but cleanup comes first.
    if (!_ready || !identical(binding, _owner.groupBindingsOwner)) return;
    final live = devices.map((d) => d.hex).toSet();
    for (final pull in _pulls.values.toList()) {
      if (!live.contains(pull.device.hex) ||
          !identical(pull.binding, _owner.groupBindingsOwner)) {
        _finish(pull, Duration.zero, retirePreparation: true);
      }
    }
    _nextScan.removeWhere((key, _) => !live.contains(key));
    _lastWake.removeWhere((key, _) => !live.contains(key));
    _answers.removeWhere((key, _) => !live.contains(key));
    for (final device in devices) {
      final pending = _pulls[device.hex];
      if (pending != null && pending.retryPending) {
        _transmit(pending);
      } else {
        _begin(device);
      }
    }
  });

  /// A presence frame has already proved this device is back. A fresh process
  /// starts with no cooldown; repeated announcements do not restart a pull.
  /// An unfinished query keeps its ID/cursor but need not wait out backoff
  /// after this authorized recovery signal.
  void wake(NodeId device) {
    if (!_ready) return;
    final now = _owner._now();
    final last = _lastWake[device.hex];
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastWake[device.hex] = now;
    _nextScan.remove(device.hex);
    final pending = _pulls[device.hex];
    if (pending == null) {
      _begin(device);
    } else {
      _wakePending(pending, now);
    }
  }

  void _wakeForServedRequest(NodeId device, Object? binding) {
    if (!_bound(binding)) return;
    final pending = _pulls[device.hex];
    if (pending == null ||
        !identical(pending.binding, binding) ||
        pending.processing ||
        pending.attempts >= _maxAttempts) {
      return;
    }
    final now = _owner._now();
    final last = pending.lastRequestWakeAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    // Presence can precede a restarting peer's history host. A request we
    // actually serve proves that host is now ready, independently of an early
    // presence wake. Keep a separate throttle within this existing pull.
    pending.lastRequestWakeAt = now;
    _wakePending(pending, now);
  }

  void _wakePending(_OwnHistoryPull pending, DateTime now) {
    if (pending.processing || pending.attempts >= _maxAttempts) return;
    final sentAt = pending.lastAttemptAt;
    if (sentAt != null) {
      // Recovery can shorten backoff, but must not duplicate startup traffic
      // or postpone an earlier timer when the wall clock rolls back.
      if (now.isBefore(sentAt)) return;
      final earliest = sentAt.add(const Duration(seconds: 2));
      if (now.isBefore(earliest)) {
        if (!(pending.timer?.isActive ?? false) ||
            pending.retryAt == null ||
            pending.retryAt!.isAfter(earliest)) {
          _scheduleRetry(pending, earliest.difference(now));
        }
        return;
      }
    }
    pending.timer?.cancel();
    _transmit(pending);
  }

  bool _bound(Object? binding) =>
      _ready && identical(binding, _owner.groupBindingsOwner);

  Future<bool> _allowed(NodeId device, Object? binding) async =>
      _bound(binding) &&
      (await _owner.myOtherDevices?.call() ?? <NodeId>[]).contains(device) &&
      _bound(binding);

  void _begin(NodeId device) {
    final previous = _pulls[device.hex];
    if (previous != null &&
        !identical(previous.binding, _owner.groupBindingsOwner)) {
      _finish(previous, Duration.zero);
    }
    final binding = _owner.groupBindingsOwner;
    if (_starting.containsKey(device.hex) &&
        !identical(_starting[device.hex], binding)) {
      _starting.remove(device.hex);
    }
    if (!_ready ||
        _pulls.containsKey(device.hex) ||
        _starting.containsKey(device.hex) ||
        _pulls.length + _starting.length >= _maxDevices ||
        (_nextScan[device.hex]?.isAfter(_owner._now()) ?? false)) {
      return;
    }
    _starting[device.hex] = binding!;
    _run(() async {
      try {
        if (!await _allowed(device, binding)) return;
        final raw = await _owner._storage.getSetting(_key(device.hex));
        final progress = raw == null
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        if (!_validProgress(progress)) {
          throw StateError('Invalid history cursor');
        }
        if (!await _allowed(device, binding)) return;
        final pull = _OwnHistoryPull(device, binding, progress);
        _pulls[device.hex] = pull;
        _request(pull);
      } finally {
        if (identical(_starting[device.hex], binding)) {
          _starting.remove(device.hex);
        }
      }
    });
  }

  bool _validCursor(dynamic cursor) =>
      cursor == null ||
      (cursor is List &&
          cursor.length == 2 &&
          cursor[0] is int &&
          (cursor[0] as int).abs() <= 8640000000000000 &&
          cursor[1] is String &&
          (cursor[1] as String).length <= 512);
  bool _validProgress(Map<String, dynamic> p) =>
      (p['after'] == null || _hex(p['after'])) &&
      (p['peer'] == null || _hex(p['peer'])) &&
      _validCursor(p['cursor']);

  void _request(_OwnHistoryPull pull) {
    if (!_ready || _pulls[pull.device.hex] != pull) return;
    pull.timer?.cancel();
    pull.id = _uuid.v4().replaceAll('-', '');
    pull.parts.clear();
    pull.partCount = null;
    pull.processing = false;
    pull.retryPending = false;
    pull.attempts = 0;
    pull.lastAttemptAt = null;
    pull.retryAt = null;
    final record = pull.record;
    final inventory =
        record == null &&
        (pull.recheckInventory || pull.progress['peer'] == null);
    pull.query = {
      'op': record != null
          ? 'record'
          : inventory
          ? 'list'
          : 'page',
      if (!inventory) 'peer': pull.progress['peer'],
      if (!inventory) 'cursor': pull.progress['cursor'],
      if (inventory) 'after': pull.progress['after'],
      if (record != null) ...{'hash': record.hash, 'offset': record.offset},
    };
    if (record == null && !inventory) {
      final prefixes = pull.prefixes
          .where(
            (p) => _afterCursor(p['position'] as List, pull.progress['cursor']),
          )
          .toList();
      while (prefixes.isNotEmpty) {
        final offered = {
          ...pull.query,
          'prefix': prefixes.first,
          if (prefixes.length > 1) 'prefixFallbacks': prefixes.sublist(1),
        };
        if (jsonEncode(offered).length <= 1500) {
          pull.query = offered;
          break;
        }
        prefixes.removeLast();
      }
    }
    _retireRequestPreparation(pull);
    _transmit(pull);
  }

  void _scheduleRetry(_OwnHistoryPull pull, Duration delay) {
    pull.timer?.cancel();
    pull.retryAt = _owner._now().add(delay);
    pull.timer = Timer(delay, () => _transmit(pull));
  }

  void _transmit(_OwnHistoryPull pull) {
    if (_closed ||
        _owner._disposed ||
        _pulls[pull.device.hex] != pull ||
        !identical(pull.binding, _owner.groupBindingsOwner) ||
        pull.processing) {
      return;
    }
    if (!_ready ||
        _requestSends.containsKey(pull.device.hex) ||
        _requestSends.length >= _maxDevices) {
      pull.retryPending = true;
      return;
    }
    if (++pull.attempts > _maxAttempts) {
      _finish(pull, const Duration(minutes: 5));
      return;
    }
    pull.retryPending = false;
    final lease = _OwnHistoryRequestSend(pull);
    _requestSends[pull.device.hex] = lease;
    pull.lastAttemptAt = _owner._now();
    final seconds = (1 << pull.attempts).clamp(2, 30);
    _scheduleRetry(pull, Duration(seconds: seconds));
    final requestId = pull.id;
    final query = Map<String, dynamic>.of(pull.query);
    bool current() =>
        _ready &&
        identical(pull.binding, _owner.groupBindingsOwner) &&
        _pulls[pull.device.hex] == pull &&
        pull.id == requestId;
    _run(() async {
      var transportOwnsLease = false;
      try {
        if (!await _allowed(pull.device, pull.binding)) {
          _finish(pull, const Duration(minutes: 5));
          return;
        }
        if (!current()) return;
        final self = await _owner._selfHex();
        // Lookups may finish after detach or page advance. A late release
        // resumes the current pull, never this captured request/query.
        if (!current()) return;
        final send = _sendWire(pull.device, {
          'v': 1,
          'd': self,
          'id': requestId,
          'q': query,
        });
        lease.started = true;
        transportOwnsLease = true;
        unawaited(
          send.then<void>(
            (_) => _releaseRequestSend(pull.device.hex, lease),
            onError: (Object _, StackTrace _) =>
                _releaseRequestSend(pull.device.hex, lease),
          ),
        );
        await send.timeout(_owner.liveLegDeadline);
      } finally {
        if (!transportOwnsLease) _releaseRequestSend(pull.device.hex, lease);
      }
    });
  }

  void _retireRequestPreparation(_OwnHistoryPull pull) {
    final lease = _requestSends[pull.device.hex];
    if (lease != null && identical(lease.pull, pull) && !lease.started) {
      // An obsolete lookup has handed nothing to transport. A replacement
      // binding/page may proceed; the old task still checks its captured ID.
      _requestSends.remove(pull.device.hex);
    }
  }

  void _releaseRequestSend(String peer, _OwnHistoryRequestSend lease) {
    if (!identical(_requestSends[peer], lease)) return;
    _requestSends.remove(peer);
    if (!_ready) return;
    for (final pending in _pulls.values.toList()) {
      if (pending.retryPending) _transmit(pending);
    }
  }

  Future<void> _sendWire(NodeId device, Map<String, dynamic> body) =>
      _owner._send(
        device,
        WireEnvelope.deviceHistory(jsonEncode(body)).encode(),
        background: true,
      );

  void _releaseServing(String peer, _OwnHistoryServe serving) {
    if (!serving.active &&
        serving.send == null &&
        identical(_serving[peer], serving)) {
      _serving.remove(peer);
    }
  }

  Future<void> _sendReply(
    NodeId device,
    Map<String, dynamic> body,
    _OwnHistoryServe serving,
  ) {
    final send = _sendWire(device, body);
    final lease = Object();
    serving.send = lease;
    void release() {
      if (identical(serving.send, lease)) serving.send = null;
      _releaseServing(device.hex, serving);
    }

    // Keep serving credit after timeout until the actual part write ends.
    // Request traffic has separate credit so replies cannot stop full duplex.
    unawaited(
      send.then<void>(
        (_) => release(),
        onError: (Object _, StackTrace _) => release(),
      ),
    );
    return send.timeout(_owner.liveLegDeadline);
  }

  void _finish(
    _OwnHistoryPull pull,
    Duration cooldown, {
    bool retirePreparation = false,
  }) {
    pull.timer?.cancel();
    pull.retryPending = false;
    pull.parts.clear();
    _releaseRecord(pull.record);
    pull.record = null;
    if (_pulls[pull.device.hex] == pull) {
      _pulls.remove(pull.device.hex);
      _nextScan[pull.device.hex] = _owner._now().add(cooldown);
    }
    if (retirePreparation) _retireRequestPreparation(pull);
  }

  void _releaseRecord(_OwnHistoryRecord? record) {
    if (record == null || record.released) return;
    record.released = true;
    _heldRecordBytes -= record.bytes.length;
  }

  /// Common consent/provenance and ratchet handling already ran in the durable
  /// lane. Slow sibling-roster reads belong to this separately bounded lane,
  /// not in front of unrelated chat messages. Every history effect still checks
  /// the current binding and device authorization in the normal handler.
  void enqueue(InboundMessage message, String body) {
    if (!_ready ||
        !message.provenance.isAuthenticated ||
        body.length > _maxWireBody) {
      return;
    }
    if (!_wanted(message, body)) return;
    final coalesced = admission.coalescedFrames;
    final work = admission.admit(
      message,
      known: true,
      coalesceIdentical: true,
      handle: (frame) {
        final next = _inbound.then((_) async {
          if (_ready && _wanted(frame, body)) await handle(frame, body);
        });
        // A failed read is reported by the owned task, but must not poison
        // the next request in this lane.
        _inbound = next.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return next;
      },
    );
    // The original reservation is already owned. Tracking each duplicate of
    // its future would recreate an unbounded task list despite byte coalescing.
    if (work != null && admission.coalescedFrames == coalesced) {
      _run(() => work);
    }
  }

  // Refusing a stale/held slice exercises no authority. In particular a retry
  // must not refill the queue with an already retained prefix while its missing
  // tail keeps being dropped. Authorization is still checked by handle/apply.
  bool _wanted(InboundMessage message, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return false;
      final device = message.srcDevice ?? message.src;
      if (decoded['q'] is Map<String, dynamic>) return true;
      final pull = _pulls[device.hex];
      return pull != null &&
          !pull.processing &&
          identical(pull.binding, _owner.groupBindingsOwner) &&
          pull.id == decoded['id'] &&
          !pull.parts.containsKey(decoded['i']);
    } on FormatException {
      return false;
    }
  }

  Future<void> handle(InboundMessage message, String body) async {
    try {
      await _handle(message, body);
    } on FormatException {
      // Malformed JSON/base64 is not a storage failure or a reason to expose
      // input text through diagnostics. The bounded request can retry.
    }
  }

  Future<void> _handle(InboundMessage message, String body) async {
    if (!_ready ||
        !message.provenance.isAuthenticated ||
        body.length > _maxWireBody) {
      return;
    }
    // Bind to the authenticated physical sender, never the body claim or the
    // shared identity address. A revoked sibling is not in the current list.
    final device = message.srcDevice ?? message.src;
    final identity = await _owner.selfIdentityHex?.call();
    if (message.src.hex != identity &&
        !(await _owner.isOwnDevice?.call(message.src) ?? false)) {
      return;
    }
    final binding = _owner.groupBindingsOwner;
    if (!await _allowed(device, binding)) return;
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic> ||
        decoded['v'] != 1 ||
        decoded['d'] != device.hex ||
        decoded['id'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(decoded['id'] as String)) {
      return;
    }
    if (decoded['q'] case final Map<String, dynamic> query) {
      if (_serving.length >= _maxDevices || _serving.containsKey(device.hex)) {
        return;
      }
      final serving = _OwnHistoryServe();
      _serving[device.hex] = serving;
      _run(() async {
        try {
          await _serve(
            device,
            binding,
            decoded['id'] as String,
            query,
            serving,
          );
        } finally {
          serving.active = false;
          _releaseServing(device.hex, serving);
        }
      });
    } else {
      _receivePart(device, decoded);
    }
  }

  Future<List<Message>> _messages(String peer) async {
    final visible = await _visible(peer);
    final rows = (await _owner._storage.loadMessages(
      peer,
    )).where((message) => visible(message.timestamp)).toList();
    rows.sort((a, b) {
      final time = a.timestamp.compareTo(b.timestamp);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    return rows;
  }

  Future<bool Function(DateTime)> _visible(String peer) async {
    final node = NodeId.fromHex(peer);
    final contact = await _owner._storage.getContact(node);
    final policy = await _owner._conversationAdmin.disappearingOf(node);
    final hidden = policy.hidesAfterRead
        ? await _owner._conversationAdmin._hiddenThroughTs(node)
        : 0;
    return (sent) =>
        !policy.hasExpired(sent, _owner._now()) &&
        !((contact?.retentionDays ?? 0) > 0 &&
            sent.isBefore(
              _owner._now().subtract(Duration(days: contact!.retentionDays!)),
            )) &&
        !(hidden > 0 && sent.millisecondsSinceEpoch <= hidden);
  }

  // Pair a body with the revision it actually represents. An edit committed
  // between reading the rows and the revision map must not label an older body
  // as the newer edit. Both reads are warm folds; retry a changing snapshot,
  // rather than rescanning raw history separately for every message.
  Future<({List<Message> rows, Map<String, int> edits})> _snapshot(
    String peer,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await _owner._storage.editSeqs(peer);
      final rows = await _messages(peer);
      final after = await _owner._storage.editSeqs(peer);
      if (before.length == after.length &&
          before.entries.every((entry) => after[entry.key] == entry.value)) {
        return (rows: rows, edits: after);
      }
    }
    throw StateError('History changed during snapshot');
  }

  // Device-local send attempts are not shared state. A positive delivery ACK
  // is, and so are current text, inline emoji, its edit frontier and canonical
  // ordering. Provisional echoes can have equal content but a different source
  // position; compare the repaired ordering, not their unpromoted raw authorship.
  String _digest(({List<Message> rows, Map<String, int> edits}) snapshot) {
    final sorted = snapshot.rows.toList()..sort((a, b) => a.id.compareTo(b.id));
    final state = [
      for (final message in sorted)
        [
          message.id,
          message.orderAuthor,
          message.orderSeq,
          message.body,
          encodeInlineCustomEmoji(message.customEmoji),
          snapshot.edits[message.id],
          message.direction == MessageDirection.outgoing &&
              message.status == MessageStatus.delivered,
          if (message.reflectedEdit) true,
        ],
    ];
    return crypto.sha256.convert(utf8.encode(jsonEncode(state))).toString();
  }

  int _compare(Message message, List<dynamic> cursor) {
    final time = message.timestamp.millisecondsSinceEpoch.compareTo(
      cursor[0] as int,
    );
    return time != 0 ? time : message.id.compareTo(cursor[1] as String);
  }

  // A small, request-local proof of rows already held. It is never itself a
  // cursor: the source must match it and the receiver must recheck before a
  // durable checkpoint. Include chronological coordinates as well as shared
  // content so equal bodies cannot conceal a missing/reordered prefix.
  Map<String, dynamic> _prefixProof(
    ({List<Message> rows, Map<String, int> edits}) snapshot,
  ) {
    final rows = snapshot.rows;
    return {
      'position': [rows.last.timestamp.millisecondsSinceEpoch, rows.last.id],
      'count': rows.length,
      'hash': crypto.sha256
          .convert(
            utf8.encode(
              jsonEncode([
                _digest(snapshot),
                for (final message in rows)
                  [
                    message.id,
                    message.timestamp.millisecondsSinceEpoch,
                    message.direction.index,
                  ],
              ]),
            ),
          )
          .toString(),
    };
  }

  bool _validPrefix(dynamic prefix) =>
      prefix is Map &&
      prefix.length == 3 &&
      prefix['position'] is List &&
      _validCursor(prefix['position']) &&
      prefix['count'] is int &&
      (prefix['count'] as int) > 0 &&
      _hex(prefix['hash']);

  List<Map<String, dynamic>> _prefixProofs(
    ({List<Message> rows, Map<String, int> edits}) snapshot,
  ) => [
    // A returning device may also hold a late echo tail beyond a gap. One
    // all-held hint then fails correctly; bounded shorter candidates let the
    // source verify a real earlier prefix without skipping the gap or repairs.
    for (var step = _maxPrefixes; step > 0; step--)
      if (snapshot.rows.length * step ~/ _maxPrefixes > _page)
        _prefixProof((
          rows: snapshot.rows.sublist(
            0,
            snapshot.rows.length * step ~/ _maxPrefixes,
          ),
          edits: snapshot.edits,
        )),
  ];

  List<Map>? _queryPrefixes(Map query) {
    final prefix = query['prefix'], fallbacks = query['prefixFallbacks'];
    if (prefix == null) return fallbacks == null ? <Map>[] : null;
    if (!_validPrefix(prefix) || (fallbacks != null && fallbacks is! List)) {
      return null;
    }
    final extras = fallbacks as List? ?? const [];
    if (extras.length >= _maxPrefixes) return null;
    final prefixes = <Map>[prefix as Map];
    for (final candidate in extras) {
      final previous = prefixes.last;
      if (!_validPrefix(candidate) ||
          (candidate['count'] as int) >= (previous['count'] as int) ||
          !_afterCursor(previous['position'] as List, candidate['position'])) {
        return null;
      }
      prefixes.add(candidate as Map);
    }
    return prefixes;
  }

  bool _samePrefix(Map left, Map right) =>
      left['count'] == right['count'] &&
      left['hash'] == right['hash'] &&
      jsonEncode(left['position']) == jsonEncode(right['position']);

  bool _afterCursor(List position, dynamic cursor) =>
      cursor == null ||
      (position[0] as int) > (cursor[0] as int) ||
      (position[0] == cursor[0] &&
          (position[1] as String).compareTo(cursor[1] as String) > 0);

  bool _matchesPrefix(
    ({List<Message> rows, Map<String, int> edits}) snapshot,
    Map prefix,
  ) {
    final rows = snapshot.rows
        .where((message) => _compare(message, prefix['position'] as List) <= 0)
        .toList();
    return rows.isNotEmpty &&
        rows.length == prefix['count'] &&
        _samePrefix(_prefixProof((rows: rows, edits: snapshot.edits)), prefix);
  }

  Future<void> _serve(
    NodeId device,
    Object? binding,
    String id,
    Map<String, dynamic> query,
    _OwnHistoryServe serving,
  ) async {
    final encoded = jsonEncode(query);
    if (encoded.length > 1500) return;
    var answer = _answers[device.hex];
    if (answer != null && !identical(answer.binding, binding)) answer = null;
    if (answer?.id == id && answer?.query != encoded) return;
    if (answer != null) {
      final elapsed = _owner._now().difference(answer.at);
      const spacing = Duration(milliseconds: 50);
      if (elapsed < spacing) await Future<void>.delayed(spacing - elapsed);
      if (!await _allowed(device, binding)) return;
    }
    if (answer?.id != id) {
      Map<String, dynamic> result;
      if (query['op'] == 'list') {
        final after = query['after'];
        if (after != null && !_hex(after)) return;
        final peers = <String>[];
        for (final conversation in await _owner._storage.loadConversations()) {
          final peer = conversation.peer.nodeId;
          if (peer.hex == await _owner.selfIdentityHex?.call() ||
              await _owner._isSiblingDevice(peer) ||
              (after is String && peer.hex.compareTo(after) <= 0)) {
            continue;
          }
          peers.add(peer.hex);
        }
        peers.sort();
        final rows = <Map<String, dynamic>>[];
        for (final peer in peers.take(_page)) {
          final snapshot = await _snapshot(peer);
          rows.add({
            'peer': peer,
            'count': snapshot.rows.length,
            'hash': _digest(snapshot),
          });
        }
        result = {'op': 'list', 'rows': rows};
      } else if (query['op'] == 'page' || query['op'] == 'record') {
        final peer = query['peer'];
        var cursor = query['cursor'];
        if (!_hex(peer) || !_validCursor(cursor)) return;
        final node = NodeId.fromHex(peer as String);
        if (peer == await _owner.selfIdentityHex?.call() ||
            await _owner._isSiblingDevice(node)) {
          return;
        }
        final snapshot = await _snapshot(peer);
        Map? acceptedPrefix;
        final prefixes = _queryPrefixes(query);
        if (prefixes == null ||
            (prefixes.isNotEmpty && query['op'] != 'page') ||
            prefixes.any((p) => !_afterCursor(p['position'] as List, cursor))) {
          return;
        }
        for (final prefix in prefixes) {
          if (_matchesPrefix(snapshot, prefix)) {
            acceptedPrefix = prefix;
            cursor = prefix['position'];
            break;
          }
        }
        final window = snapshot.rows
            .where((m) => cursor == null || _compare(m, cursor as List) > 0)
            .take(_messagePage + 1)
            .toList();
        final page = window.take(_messagePage).toList();
        final events = <String>[];
        Map<String, dynamic> pageResult(Message? last) => {
          'op': 'page',
          'peer': peer,
          'prefix': ?acceptedPrefix,
          'events': events,
          'next': last != null && window.length > events.length
              ? [last.timestamp.millisecondsSinceEpoch, last.id]
              : null,
        };
        final ttl = (await _owner._storage.getContact(
          node,
        ))?.disappearingTtlSeconds;
        Future<String> encodeRecord(Message message) async {
          var event = await _owner.ownHistoryEncode!(node, message);
          event = DeviceSyncEvent(
            kind: event.kind,
            key: event.key,
            tsMs: event.tsMs,
            payload: {
              ...event.payload,
              'historyEditSeq': ?snapshot.edits[message.id],
              if (message.reflectedEdit) 'er': true,
              if (message.direction == MessageDirection.outgoing &&
                  message.status == MessageStatus.delivered)
                'historyDelivered': true,
            },
          );
          if (ttl != null && ttl > 0) {
            event = DeviceSyncEvent(
              kind: event.kind,
              key: event.key,
              tsMs: event.tsMs,
              payload: {
                ...event.payload,
                'historyExpiryMs': event.tsMs + ttl * 1000,
              },
            );
          }
          return event.toBody();
        }

        Map<String, dynamic>? descriptor;
        if (query['op'] == 'record') {
          final hash = query['hash'], offset = query['offset'];
          if (!_hex(hash) ||
              offset is! int ||
              offset < 0 ||
              offset >= _maxRecordBytes ||
              offset % _recordSlice != 0) {
            return;
          }
          final bytes = page.isEmpty
              ? null
              : utf8.encode(await encodeRecord(page.first));
          if (bytes == null ||
              crypto.sha256.convert(bytes).toString() != hash) {
            result = {'op': 'record', 'peer': peer, 'changed': true};
          } else {
            if (bytes.length > _maxRecordBytes || offset >= bytes.length) {
              return;
            }
            result = {
              'op': 'record',
              'peer': peer,
              'key': page.first.id,
              'hash': hash,
              'offset': offset,
              'data': base64Encode(
                bytes.sublist(
                  offset,
                  (offset + _recordSlice).clamp(0, bytes.length),
                ),
              ),
            };
          }
        } else {
          if (!await _allowed(device, binding)) return;
          for (final message in page) {
            // Text/already-addressed media need only local preparation here.
            // An inline blob may register content, so keep its fresh gate.
            // Every reply part still needs fresh _allowed below too.
            // A closing/replaced identity must stop local callbacks too.
            if (!_bound(binding)) return;
            if (message.fileContentId == null &&
                message.fileId != null &&
                !await _allowed(device, binding)) {
              return;
            }
            final body = await encodeRecord(message);
            if (!_bound(binding)) return;
            events.add(body);
            // Event bodies are JSON strings inside another JSON envelope.
            if (utf8.encode(jsonEncode(pageResult(message))).length >
                _maxPageBytes) {
              events.removeLast();
              if (events.isEmpty) {
                final bytes = utf8.encode(body);
                if (bytes.length > _maxRecordBytes) {
                  throw StateError('History message too large');
                }
                descriptor = {
                  'op': 'page',
                  'peer': peer,
                  'prefix': ?acceptedPrefix,
                  'record': {
                    'position': [
                      message.timestamp.millisecondsSinceEpoch,
                      message.id,
                    ],
                    'bytes': bytes.length,
                    'hash': crypto.sha256.convert(bytes).toString(),
                  },
                };
              }
              break;
            }
          }
          result =
              descriptor ??
              pageResult(events.isEmpty ? null : page[events.length - 1]);
        }
      } else {
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(result)));
      if (bytes.length > _maxPageBytes) {
        throw StateError('History page too large');
      }
      answer = (
        id: id,
        query: encoded,
        bytes: bytes,
        binding: binding,
        at: _owner._now(),
      );
      if (_answers.length >= _maxDevices) _answers.remove(_answers.keys.first);
      _answers[device.hex] = answer;
    }
    final bytes = answer!.bytes;
    _answers[device.hex] = (
      id: answer.id,
      query: answer.query,
      bytes: bytes,
      binding: binding,
      at: _owner._now(),
    );
    final parts = (bytes.length + _slice - 1) ~/ _slice;
    for (var part = 0; part < parts; part++) {
      if (!await _allowed(device, binding)) return;
      if (part == 0) _wakeForServedRequest(device, binding);
      final end = ((part + 1) * _slice).clamp(0, bytes.length);
      await _sendReply(device, {
        'v': 1,
        'd': await _owner._selfHex(),
        'id': id,
        'i': part,
        'n': parts,
        'b': base64Encode(Uint8List.sublistView(bytes, part * _slice, end)),
      }, serving);
    }
  }

  void _receivePart(NodeId device, Map<String, dynamic> body) {
    final pull = _pulls[device.hex];
    if (pull == null || pull.processing || pull.id != body['id']) return;
    final i = body['i'], n = body['n'], data = body['b'];
    if (i is! int ||
        n is! int ||
        n < 1 ||
        n > _maxParts ||
        i < 0 ||
        i >= n ||
        data is! String ||
        data.length > _maxPartBase64 ||
        (pull.partCount != null && pull.partCount != n)) {
      return;
    }
    final bytes = base64Decode(data);
    if (bytes.length > _slice) return;
    final previous = pull.parts[i];
    if (previous != null && base64Encode(previous) != data) return;
    final heldBytes = pull.parts.values.fold<int>(
      0,
      (total, part) => total + part.length,
    );
    if (heldBytes - (previous?.length ?? 0) + bytes.length > _maxPageBytes) {
      return;
    }
    pull.partCount = n;
    pull.parts[i] = bytes;
    if (pull.parts.length != n) return;
    pull.processing = true;
    pull.timer?.cancel();
    final joined = BytesBuilder(copy: false);
    for (var index = 0; index < n; index++) {
      joined.add(pull.parts[index]!);
    }
    pull.parts.clear();
    _run(() async {
      try {
        final reply =
            jsonDecode(utf8.decode(joined.takeBytes())) as Map<String, dynamic>;
        await _apply(pull, reply);
      } catch (_) {
        _finish(pull, const Duration(minutes: 5));
        _report();
      }
    });
  }

  void _beginRecord(_OwnHistoryPull pull, Map<String, dynamic> reply) {
    final raw = reply['record'];
    if (reply['peer'] != pull.progress['peer'] ||
        raw is! Map ||
        reply.containsKey('events') ||
        pull.record != null) {
      throw StateError('Invalid history record');
    }
    final position = raw['position'], size = raw['bytes'], hash = raw['hash'];
    final cursor = pull.progress['cursor'] as List<dynamic>?;
    if (position is! List ||
        !_validCursor(position) ||
        size is! int ||
        size < 1 ||
        size > _maxRecordBytes ||
        !_hex(hash) ||
        (cursor != null &&
            (position[0] < cursor[0] ||
                (position[0] == cursor[0] &&
                    (position[1] as String).compareTo(cursor[1] as String) <=
                        0)))) {
      throw StateError('Invalid history record bound');
    }
    if (_heldRecordBytes + size > _maxHeldRecordBytes) {
      // Leave the durable cursor unchanged. Another sibling's active record
      // owns the budget; a bounded retry can begin after that record releases it.
      _finish(pull, const Duration(seconds: 30));
      return;
    }
    pull.record = _OwnHistoryRecord(
      List<dynamic>.unmodifiable(position),
      hash as String,
      Uint8List(size),
    );
    _heldRecordBytes += size;
    _request(pull);
  }

  Future<void> _applyRecord(
    _OwnHistoryPull pull,
    Map<String, dynamic> reply,
  ) async {
    final record = pull.record;
    if (record == null || reply['peer'] != pull.progress['peer']) {
      throw StateError('Unexpected history record');
    }
    if (reply['changed'] == true) {
      _releaseRecord(record);
      pull.record = null;
      _request(pull);
      return;
    }
    final data = reply['data'];
    if (reply['key'] != record.position[1] ||
        reply['hash'] != record.hash ||
        reply['offset'] != record.offset ||
        data is! String ||
        data.length > ((_recordSlice + 2) ~/ 3) * 4) {
      throw StateError('Invalid history record slice');
    }
    final bytes = base64Decode(data);
    final expected = _recordSlice.clamp(0, record.bytes.length - record.offset);
    if (bytes.length != expected) {
      throw StateError('Invalid history record length');
    }
    record.bytes.setRange(record.offset, record.offset + bytes.length, bytes);
    record.offset += bytes.length;
    if (record.offset < record.bytes.length) {
      _request(pull);
      return;
    }
    // Detach before the ordinary page applier asks for its next page, but keep
    // memory charged through validation and durable apply, including failure.
    pull.record = null;
    try {
      if (crypto.sha256.convert(record.bytes).toString() != record.hash) {
        throw StateError('History record digest mismatch');
      }
      final body = utf8.decode(record.bytes);
      final event = DeviceSyncEvent.fromBody(body);
      if (event == null ||
          event.key != record.position[1] ||
          event.tsMs != record.position[0]) {
        throw StateError('History record position mismatch');
      }
      await _applyPage(pull, {
        'peer': pull.progress['peer'],
        'events': [body],
        'next': record.position,
      });
    } finally {
      _releaseRecord(record);
    }
  }

  Future<void> _checkpoint(
    _OwnHistoryPull pull,
    Map<String, dynamic> next,
  ) async {
    if (_pulls[pull.device.hex] != pull ||
        !await _allowed(pull.device, pull.binding)) {
      throw StateError('History session ended');
    }
    final encoded = jsonEncode(next);
    if (utf8.encode(encoded).length > 1800 || !_validProgress(next)) {
      throw StateError('History cursor too large');
    }
    await _owner._storage.putSetting(_key(pull.device.hex), encoded);
    if (!await _allowed(pull.device, pull.binding)) {
      throw StateError('History session ended');
    }
    pull.progress = next;
  }

  Future<void> _apply(_OwnHistoryPull pull, Map<String, dynamic> reply) async {
    if (!await _allowed(pull.device, pull.binding) ||
        reply['op'] != pull.query['op']) {
      throw StateError('Wrong history response');
    }
    if (reply['op'] == 'record') {
      await _applyRecord(pull, reply);
      return;
    }
    if (reply['op'] == 'list') {
      final rows = reply['rows'];
      if (rows is! List || rows.length > _page) {
        throw StateError('Invalid inventory');
      }
      // A restored cursor says what was applied, not what is still missing:
      // other live sync paths may have filled its suffix before the crash.
      // Recheck inventory once, preserving the cursor if this peer needs pages.
      final resume = pull.recheckInventory
          ? Map<String, dynamic>.of(pull.progress)
          : null;
      pull.recheckInventory = false;
      var after = pull.progress['after'] as String?;
      for (final entry in rows) {
        if (entry is! Map ||
            !_hex(entry['peer']) ||
            !_hex(entry['hash']) ||
            entry['count'] is! int ||
            (entry['count'] as int) < 0 ||
            (after != null &&
                (entry['peer'] as String).compareTo(after) <= 0)) {
          throw StateError('Invalid inventory row');
        }
        final peer = entry['peer'] as String;
        final held = await _snapshot(peer);
        final count = entry['count'] as int;
        // A fully held smaller inventory is not missing state. This also
        // avoids asking a recovering sibling to replay its known prefix back
        // to the device which already holds the complete source history.
        final prefix = held.rows.take(count).toList();
        if (prefix.length != count ||
            _digest((rows: prefix, edits: held.edits)) != entry['hash']) {
          await _checkpoint(pull, {
            'after': after,
            'peer': peer,
            if (resume?['peer'] == peer) 'cursor': resume?['cursor'],
          });
          pull.prefixes = _prefixProofs(held);
          _request(pull);
          return;
        }
        after = peer;
      }
      if (rows.isEmpty) {
        await _checkpoint(pull, {});
        _finish(pull, const Duration(minutes: 15));
      } else {
        await _checkpoint(pull, {'after': after});
        _request(pull);
      }
      return;
    }
    final prefix = reply['prefix'];
    if (prefix != null) {
      final proposed = _queryPrefixes(pull.query);
      if (reply['op'] != 'page' ||
          reply['peer'] != pull.progress['peer'] ||
          !_validPrefix(prefix) ||
          proposed == null ||
          !proposed.any((p) => _samePrefix(prefix as Map, p)) ||
          !_afterCursor(prefix['position'] as List, pull.progress['cursor'])) {
        throw StateError('Unrequested history prefix');
      }
      final held = await _snapshot(pull.progress['peer'] as String);
      if (!_matchesPrefix(held, prefix)) {
        // The local rows changed while the proof was in flight. Discard the
        // answer and retry a normal page from the unchanged durable cursor.
        pull.prefixes = const [];
        _request(pull);
        return;
      }
      await _checkpoint(pull, {
        'after': pull.progress['after'],
        'peer': pull.progress['peer'],
        'cursor': prefix['position'],
      });
    }
    pull.prefixes = const [];
    if (reply['record'] != null) {
      _beginRecord(pull, reply);
      return;
    }
    await _applyPage(pull, reply);
  }

  Future<void> _applyPage(
    _OwnHistoryPull pull,
    Map<String, dynamic> reply,
  ) async {
    final peer = pull.progress['peer'];
    if (peer is! String || !_bound(pull.binding)) {
      throw StateError('History session ended');
    }
    // A prepared row owns its mirror slot until publication. Two sibling
    // pages for the same conversation must not acquire opposite slots while
    // both wait for a complete cohort. Other conversations remain independent.
    final previous = _pageApplies[peer] ?? Future<void>.value();
    final turn = previous.then((_) async {
      if (_pulls[pull.device.hex] != pull ||
          !await _allowed(pull.device, pull.binding)) {
        throw StateError('History session ended');
      }
      await _applyPageNow(pull, reply);
    });
    final settled = turn.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pageApplies[peer] = settled;
    try {
      await turn;
    } finally {
      if (identical(_pageApplies[peer], settled)) _pageApplies.remove(peer);
    }
  }

  Future<void> _applyPageNow(
    _OwnHistoryPull pull,
    Map<String, dynamic> reply,
  ) async {
    final peer = pull.progress['peer'];
    final events = reply['events'], next = reply['next'];
    if (reply['peer'] != peer ||
        events is! List ||
        events.length > _messagePage ||
        !_validCursor(next) ||
        (next != null && events.isEmpty)) {
      throw StateError('Invalid history page');
    }
    final visible = await _visible(peer as String);
    final heldEdits = await _owner._storage.editSeqs(peer);
    List<dynamic>? position = pull.progress['cursor'] as List<dynamic>?;
    final seen = <String>{};
    final validated = <DeviceSyncEvent>[];
    for (final body in events) {
      final event = body is String ? DeviceSyncEvent.fromBody(body) : null;
      if (event == null ||
          event.kind != DeviceSyncKind.msgMirror ||
          event.payload['peer'] != peer ||
          event.payload['body'] is! String ||
          !deviceSyncEffectiveAt(event, _owner._now().millisecondsSinceEpoch) ||
          !seen.add(event.key)) {
        throw StateError('Invalid history mirror');
      }
      if (position != null &&
          (event.tsMs < position[0] ||
              (event.tsMs == position[0] &&
                  event.key.compareTo(position[1] as String) <= 0))) {
        throw StateError('History page did not advance');
      }
      final expiry = event.payload['historyExpiryMs'];
      final editSeq = event.payload['historyEditSeq'];
      final delivered = event.payload['historyDelivered'];
      final reflected = event.payload['er'];
      if ((editSeq != null &&
              (editSeq is! int || !isAcceptableWireSeq(editSeq))) ||
          (delivered != null && delivered is! bool) ||
          (reflected != null && reflected is! bool)) {
        throw StateError('Invalid history state');
      }
      if (expiry != null &&
          (expiry is! int ||
              expiry < event.tsMs ||
              expiry.abs() > 8640000000000000)) {
        throw StateError('Invalid history expiry');
      }
      validated.add(event);
      position = [event.tsMs, event.key];
    }
    if (next != null && jsonEncode(next) != jsonEncode(position)) {
      throw StateError('History cursor did not advance');
    }
    final prepared = _owner.ownHistoryApplyPrepared;
    final ordinary = _owner.ownHistoryApply;
    final store = _owner._storage;
    if (prepared != null && store is PreparedMessageBatchStore) {
      Future<void> check(List<DeviceSyncEvent> pending) async {
        if (!identical(_owner.ownHistoryApplyPrepared, prepared) ||
            !identical(_owner.ownHistoryApply, ordinary) ||
            _pulls[pull.device.hex] != pull ||
            !await _allowed(pull.device, pull.binding)) {
          throw StateError('History session ended');
        }
        final visibleNow = await _visible(peer);
        final contact = await _owner._storage.getContact(NodeId.fromHex(peer));
        final now = _owner._now().millisecondsSinceEpoch;
        for (final event in pending) {
          final expiry = event.payload['historyExpiryMs'];
          if ((expiry is int && now >= expiry) ||
              !visibleNow(DateTime.fromMillisecondsSinceEpoch(event.tsMs)) ||
              (event.payload['dir'] != 'outgoing' &&
                  contact?.status == ContactStatus.blocked)) {
            throw StateError('History visibility changed before publication');
          }
        }
        if (!await _allowed(pull.device, pull.binding)) {
          throw StateError('History session ended');
        }
      }

      final cohort = _HistoryWriteCohort(store, check);
      try {
        await cohort.applyAll(
          validated,
          (event, writes) => _applyHistoryEvent(
            pull,
            peer,
            event,
            heldEdits,
            visible,
            writes: writes,
            prepared: prepared,
          ),
        );
        await cohort.flush();
      } catch (error, stack) {
        await cohort.abort(error, stack);
        rethrow;
      }
    } else {
      for (final event in validated) {
        await _applyHistoryEvent(pull, peer, event, heldEdits, visible);
      }
    }
    await _checkpoint(
      pull,
      next == null
          ? {'after': peer}
          : {'after': pull.progress['after'], 'peer': peer, 'cursor': next},
    );
    _request(pull);
  }

  Future<void> _applyHistoryEvent(
    _OwnHistoryPull pull,
    String peer,
    DeviceSyncEvent event,
    Map<String, int> heldEdits,
    bool Function(DateTime) visible, {
    PreparedMessageWrites? writes,
    Future<void> Function(DeviceSyncEvent, PreparedMessageWrites)? prepared,
  }) async {
    if (_pulls[pull.device.hex] != pull ||
        !await _allowed(pull.device, pull.binding)) {
      throw StateError('History session ended');
    }
    final expiry = event.payload['historyExpiryMs'];
    final editSeq = event.payload['historyEditSeq'];
    final delivered = event.payload['historyDelivered'];
    final reflected = event.payload['er'];
    if ((expiry == null || _owner._now().millisecondsSinceEpoch < expiry) &&
        visible(DateTime.fromMillisecondsSinceEpoch(event.tsMs))) {
      if (writes == null) {
        await _owner.ownHistoryApply!(event);
      } else {
        await prepared!(event, writes);
      }
      if (!await _allowed(pull.device, pull.binding)) {
        throw StateError('History session ended');
      }
      // The ordinary applier has already persisted the mirror. Only history
      // state corrections need the stored row; a no-op lookup adds serialized
      // storage work, without validating publication (a missing row was also
      // accepted below). Keep the authorization check above and checkpoint's
      // durable/access barriers even when there is no state to reconcile.
      if (editSeq is! int && delivered != true) return;
      final target = await _owner._storage.loadMessageById(peer, event.key);
      if (target != null) {
        var changed = false;
        if (editSeq is int &&
            messageEditWins(
              revision: editSeq,
              contentHash: messageEditContentHash(
                event.payload['body'] as String,
                parseInlineCustomEmoji(
                  event.payload['body'] as String,
                  event.payload['ce'],
                ),
              ),
              heldRevision: heldEdits[event.key],
              heldContentHash: messageEditContentHash(
                target.body,
                target.customEmoji,
              ),
              reflected: reflected == true,
              heldReflected: target.reflectedEdit,
            )) {
          final body = event.payload['body'] as String;
          await _owner._storage.editMessage(
            peer,
            event.key,
            body,
            seq: editSeq,
            customEmoji: parseInlineCustomEmoji(body, event.payload['ce']),
            reflected: reflected == true,
          );
          heldEdits[event.key] = editSeq;
          changed = true;
        }
        if (delivered == true &&
            target.direction == MessageDirection.outgoing &&
            target.status != MessageStatus.delivered) {
          await _owner._storage.markMessageStatus(
            peer,
            event.key,
            MessageStatus.delivered,
          );
          final stored = await _owner._storage.loadMessageById(peer, event.key);
          if (stored != null && stored.status != MessageStatus.delivered) {
            throw StateError('History delivery state was not saved');
          }
          changed = true;
        }
        if (changed) _owner._signal();
      }
    }
  }

  Future<void> close() {
    admission.close();
    _closed = true;
    _timer?.cancel();
    for (final pull in _pulls.values) {
      pull.timer?.cancel();
      _releaseRecord(pull.record);
      pull.record = null;
    }
    _pulls.clear();
    _requestSends.clear();
    _serving.clear();
    _answers.clear();
    return _tasks.close();
  }
}

class _OwnHistoryRequestSend {
  _OwnHistoryRequestSend(this.pull);
  final _OwnHistoryPull pull;
  bool started = false;
}

class _OwnHistoryServe {
  bool active = true;
  Object? send;
}

class _OwnHistoryPull {
  _OwnHistoryPull(this.device, this.binding, this.progress)
    : recheckInventory = progress['peer'] != null;
  final NodeId device;
  final Object? binding;
  Map<String, dynamic> progress;
  Map<String, dynamic> query = {};
  List<Map<String, dynamic>> prefixes = const [];
  bool recheckInventory;
  String id = '';
  int attempts = 0;
  DateTime? lastAttemptAt;
  DateTime? lastRequestWakeAt;
  DateTime? retryAt;
  _OwnHistoryRecord? record;
  Timer? timer;
  bool processing = false;
  bool retryPending = false;
  int? partCount;
  final parts = <int, Uint8List>{};
}

class _OwnHistoryRecord {
  _OwnHistoryRecord(this.position, this.hash, this.bytes);
  final List<dynamic> position;
  final String hash;
  final Uint8List bytes;
  int offset = 0;
  bool released = false;
}
