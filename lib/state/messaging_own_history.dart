part of 'messaging_core.dart';

/// Anti-entropy for history which has outlived the bounded device journal.
/// Nothing here extends that journal, changes consent, or uses mailbox. One
/// outstanding request per sibling bounds reassembly and supplies backpressure.
class _MessagingOwnHistory {
  _MessagingOwnHistory(this._owner);
  final MessagingService _owner;
  final _tasks = AsyncTasks();
  final _pulls = <String, _OwnHistoryPull>{};
  final _starting = <String, Object>{};
  final _serving = <String>{};
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
  static const _page = 8;
  static const _slice = 2048;
  static const _maxParts = 64;
  static const _maxDevices = 32;

  bool get _ready =>
      !_closed &&
      !_owner._disposed &&
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
    unawaited(_tasks.runRequired(action).catchError((Object _) => _report()));
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    _tick();
  }

  void _tick() => _run(() async {
    if (!_ready) return;
    final devices = await _owner.myOtherDevices?.call() ?? <NodeId>[];
    final live = devices.map((d) => d.hex).toSet();
    for (final pull in _pulls.values.toList()) {
      if (!live.contains(pull.device.hex) ||
          !identical(pull.binding, _owner.groupBindingsOwner)) {
        _finish(pull, Duration.zero);
      }
    }
    _nextScan.removeWhere((key, _) => !live.contains(key));
    _lastWake.removeWhere((key, _) => !live.contains(key));
    _answers.removeWhere((key, _) => !live.contains(key));
    for (final device in devices) {
      _begin(device);
    }
  });

  /// A presence frame has already proved this device is back. A fresh process
  /// starts with no cooldown; repeated announcements do not restart a pull.
  void wake(NodeId device) {
    if (!_ready) return;
    final now = _owner._now();
    final last = _lastWake[device.hex];
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastWake[device.hex] = now;
    _nextScan.remove(device.hex);
    _begin(device);
  }

  Future<bool> _allowed(NodeId device, Object? binding) async =>
      _ready &&
      identical(binding, _owner.groupBindingsOwner) &&
      (await _owner.myOtherDevices?.call() ?? <NodeId>[]).contains(device) &&
      _ready &&
      identical(binding, _owner.groupBindingsOwner);

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
    pull.attempts = 0;
    pull.query = {
      'op': pull.progress['peer'] == null ? 'list' : 'page',
      if (pull.progress['peer'] != null) 'peer': pull.progress['peer'],
      if (pull.progress['peer'] != null) 'cursor': pull.progress['cursor'],
      if (pull.progress['peer'] == null) 'after': pull.progress['after'],
    };
    _transmit(pull);
  }

  void _transmit(_OwnHistoryPull pull) {
    if (!_ready || _pulls[pull.device.hex] != pull) return;
    if (++pull.attempts > 6) {
      _finish(pull, const Duration(minutes: 5));
      return;
    }
    final seconds = (1 << pull.attempts).clamp(2, 30);
    pull.timer = Timer(Duration(seconds: seconds), () => _transmit(pull));
    _run(() async {
      if (!await _allowed(pull.device, pull.binding)) {
        _finish(pull, const Duration(minutes: 5));
        return;
      }
      await _send(pull.device, {
        'v': 1,
        'd': await _owner._selfHex(),
        'id': pull.id,
        'q': pull.query,
      });
    });
  }

  Future<void> _send(NodeId device, Map<String, dynamic> body) => _owner
      ._send(
        device,
        WireEnvelope.deviceHistory(jsonEncode(body)).encode(),
        background: true,
      )
      .timeout(_owner.liveLegDeadline);

  void _finish(_OwnHistoryPull pull, Duration cooldown) {
    pull.timer?.cancel();
    pull.parts.clear();
    if (_pulls[pull.device.hex] == pull) {
      _pulls.remove(pull.device.hex);
      _nextScan[pull.device.hex] = _owner._now().add(cooldown);
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
    if (!_ready || !message.provenance.isAuthenticated || body.length > 5000) {
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
      if (_serving.length >= _maxDevices || !_serving.add(device.hex)) return;
      _run(() async {
        try {
          await _serve(device, binding, decoded['id'] as String, query);
        } finally {
          _serving.remove(device.hex);
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
  // is, and so are current text, inline emoji and its edit frontier. Comparing
  // only IDs left held-but-stale rows invisible to recovery after compaction.
  String _digest(({List<Message> rows, Map<String, int> edits}) snapshot) {
    final sorted = snapshot.rows.toList()..sort((a, b) => a.id.compareTo(b.id));
    final state = [
      for (final message in sorted)
        [
          message.id,
          message.body,
          encodeInlineCustomEmoji(message.customEmoji),
          snapshot.edits[message.id],
          message.direction == MessageDirection.outgoing &&
              message.status == MessageStatus.delivered,
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

  Future<void> _serve(
    NodeId device,
    Object? binding,
    String id,
    Map<String, dynamic> query,
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
      } else if (query['op'] == 'page') {
        final peer = query['peer'], cursor = query['cursor'];
        if (!_hex(peer) || !_validCursor(cursor)) return;
        final node = NodeId.fromHex(peer as String);
        if (peer == await _owner.selfIdentityHex?.call() ||
            await _owner._isSiblingDevice(node)) {
          return;
        }
        final snapshot = await _snapshot(peer);
        final window = snapshot.rows
            .where((m) => cursor == null || _compare(m, cursor as List) > 0)
            .take(_page + 1)
            .toList();
        final page = window.take(_page).toList();
        final events = <String>[];
        final ttl = (await _owner._storage.getContact(
          node,
        ))?.disappearingTtlSeconds;
        for (final message in page) {
          if (!await _allowed(device, binding)) return;
          var event = await _owner.ownHistoryEncode!(node, message);
          event = DeviceSyncEvent(
            kind: event.kind,
            key: event.key,
            tsMs: event.tsMs,
            payload: {
              ...event.payload,
              'historyEditSeq': ?snapshot.edits[message.id],
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
          events.add(event.toBody());
        }
        result = {
          'op': 'page',
          'peer': peer,
          'events': events,
          'next': window.length > _page
              ? [page.last.timestamp.millisecondsSinceEpoch, page.last.id]
              : null,
        };
      } else {
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(result)));
      if (bytes.length > _slice * _maxParts) {
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
      final end = ((part + 1) * _slice).clamp(0, bytes.length);
      await _send(device, {
        'v': 1,
        'd': await _owner._selfHex(),
        'id': id,
        'i': part,
        'n': parts,
        'b': base64Encode(Uint8List.sublistView(bytes, part * _slice, end)),
      });
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
        data.length > 2800 ||
        (pull.partCount != null && pull.partCount != n)) {
      return;
    }
    final bytes = base64Decode(data);
    if (bytes.length > _slice) return;
    pull.partCount = n;
    final previous = pull.parts[i];
    if (previous != null && base64Encode(previous) != data) return;
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
    if (reply['op'] == 'list') {
      final rows = reply['rows'];
      if (rows is! List || rows.length > _page) {
        throw StateError('Invalid inventory');
      }
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
        if (held.rows.length != entry['count'] ||
            _digest(held) != entry['hash']) {
          await _checkpoint(pull, {'after': after, 'peer': peer});
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
    final peer = pull.progress['peer'];
    final events = reply['events'], next = reply['next'];
    if (reply['peer'] != peer ||
        events is! List ||
        events.length > _page ||
        !_validCursor(next) ||
        (next != null && events.isEmpty)) {
      throw StateError('Invalid history page');
    }
    final visible = await _visible(peer as String);
    final heldEdits = await _owner._storage.editSeqs(peer);
    List<dynamic>? position = pull.progress['cursor'] as List<dynamic>?;
    final seen = <String>{};
    for (final body in events) {
      final event = body is String ? DeviceSyncEvent.fromBody(body) : null;
      if (event == null ||
          event.kind != DeviceSyncKind.msgMirror ||
          event.payload['peer'] != peer ||
          event.payload['body'] is! String ||
          !deviceSyncEffectiveAt(event, _owner._now().millisecondsSinceEpoch) ||
          !seen.add(event.key) ||
          !await _allowed(pull.device, pull.binding)) {
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
      if ((editSeq != null &&
              (editSeq is! int || !isAcceptableWireSeq(editSeq))) ||
          (delivered != null && delivered is! bool)) {
        throw StateError('Invalid history state');
      }
      if (expiry != null &&
          (expiry is! int ||
              expiry < event.tsMs ||
              expiry.abs() > 8640000000000000)) {
        throw StateError('Invalid history expiry');
      }
      if ((expiry == null || _owner._now().millisecondsSinceEpoch < expiry) &&
          visible(DateTime.fromMillisecondsSinceEpoch(event.tsMs))) {
        await _owner.ownHistoryApply!(event);
        if (!await _allowed(pull.device, pull.binding)) {
          throw StateError('History session ended');
        }
        final target = await _owner._storage.loadMessageById(peer, event.key);
        if (target != null) {
          var changed = false;
          if (editSeq is int && editSeq > (heldEdits[event.key] ?? -1)) {
            final body = event.payload['body'] as String;
            await _owner._storage.editMessage(
              peer,
              event.key,
              body,
              seq: editSeq,
              customEmoji: parseInlineCustomEmoji(body, event.payload['ce']),
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
            final stored = await _owner._storage.loadMessageById(
              peer,
              event.key,
            );
            if (stored != null && stored.status != MessageStatus.delivered) {
              throw StateError('History delivery state was not saved');
            }
            changed = true;
          }
          if (changed) _owner._signal();
        }
      }
      position = [event.tsMs, event.key];
    }
    if (next != null && jsonEncode(next) != jsonEncode(position)) {
      throw StateError('History cursor did not advance');
    }
    await _checkpoint(
      pull,
      next == null
          ? {'after': peer}
          : {'after': pull.progress['after'], 'peer': peer, 'cursor': next},
    );
    _request(pull);
  }

  Future<void> close() {
    _closed = true;
    _timer?.cancel();
    for (final pull in _pulls.values) {
      pull.timer?.cancel();
    }
    _pulls.clear();
    _answers.clear();
    return _tasks.close();
  }
}

class _OwnHistoryPull {
  _OwnHistoryPull(this.device, this.binding, this.progress);
  final NodeId device;
  final Object? binding;
  Map<String, dynamic> progress;
  Map<String, dynamic> query = {};
  String id = '';
  int attempts = 0;
  Timer? timer;
  bool processing = false;
  int? partCount;
  final parts = <int, Uint8List>{};
}
