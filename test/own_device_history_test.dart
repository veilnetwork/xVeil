import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/device_history_backfill.dart' show deviceMirrorOf;
import 'package:xveil/state/messaging.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
final identity = id(90), a = id(91), b = id(92), peer = id(93);

class _Network {
  final endpoints = <NodeId, _Endpoint>{};
  final history = <({NodeId from, NodeId to, Map<String, dynamic> body})>[];
  bool Function(NodeId, NodeId, Map<String, dynamic>)? drop;
  bool reverseParts = false;
  bool dropPresence = false;
  final parts = <String, List<InboundMessage>>{};

  Future<void> send(_Endpoint from, NodeId to, Uint8List bytes) async {
    final env = WireEnvelope.decode(bytes);
    final target = endpoints[to];
    if (target == null || target.closed) return;
    if (dropPresence && env.kind == WireKind.presence) return;
    final message = InboundMessage(
      src: identity,
      srcDevice: from.me,
      payload: bytes,
      provenance: SenderProvenance.signed,
    );
    if (env.kind == WireKind.deviceHistory) {
      expect(bytes.length, lessThanOrEqualTo(6144));
      final body = jsonDecode(env.body) as Map<String, dynamic>;
      history.add((from: from.me, to: to, body: body));
      if (drop?.call(from.me, to, body) ?? false) return;
      if (reverseParts && body['i'] != null) {
        final key = '${to.hex}|${body['id']}';
        final list = parts.putIfAbsent(key, () => []);
        list.add(message);
        if (list.length == body['n']) {
          parts.remove(key);
          for (final part in list.reversed) {
            target.incoming.add(part);
          }
          target.incoming.add(list.first); // duplicate after the complete page
        }
        return;
      }
    }
    target.incoming.add(message);
  }
}

class _Endpoint implements VeilTransport {
  _Endpoint(this.net, this.me) {
    net.endpoints[me] = this;
  }
  final _Network net;
  final NodeId me;
  final incoming = StreamController<InboundMessage>.broadcast();
  bool closed = false;
  Future<NodeId> Function()? readNodeId;
  @override
  Future<NodeId> nodeId() async => await readNodeId?.call() ?? me;
  @override
  Stream<InboundMessage> messages() => incoming.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload, {bool anonymous = false}) =>
      net.send(this, dst, payload);
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => [];
  @override
  Future<void> dispose() async {
    closed = true;
    await incoming.close();
  }
}

class _RefusingCursorStore extends FakeKvLogStore {
  bool refusePageCursor = false;
  String pageCursorId = 'm0007';
  bool refused = false;
  bool refuseDelivery = false;
  bool deliveryRefused = false;
  final postBatches = <int>[];
  final orderingBatches = <int>[];
  final publicationFamilies = <String>[];

  @override
  int commit(List<KvLogOp> ops) {
    if (refuseDelivery &&
        ops.whereType<AppendLogOp>().any((op) {
          final value = jsonDecode(utf8.decode(op.payload));
          return value is Map &&
              value['op'] == 'status' &&
              value['s'] == MessageStatus.delivered.index;
        })) {
      refuseDelivery = false;
      deliveryRefused = true;
      throw StateError('fixture delivery write failure');
    }
    if (refusePageCursor &&
        ops.whereType<PutOp>().any(
          (op) =>
              utf8.decode(op.key).contains('device.history.cursor.v2:') &&
              utf8.decode(op.value).contains(pageCursorId),
        )) {
      refusePageCursor = false;
      refused = true;
      throw StateError('fixture cursor write failure');
    }
    final result = super.commit(ops);
    final posts = ops.whereType<AppendLogOp>().where((op) {
      if (op.namespace < Ns.messageLogShardFirst ||
          op.namespace > Ns.messageLogShardLast) {
        return false;
      }
      final value = jsonDecode(utf8.decode(op.payload));
      return value is Map && value['k'] == 0 && value['op'] == null;
    }).length;
    if (posts > 0) {
      postBatches.add(posts);
      publicationFamilies.add('post');
    }
    final ordering = ops.whereType<AppendLogOp>().where((op) {
      if (op.namespace < Ns.messageLogShardFirst ||
          op.namespace > Ns.messageLogShardLast) {
        return false;
      }
      final value = jsonDecode(utf8.decode(op.payload));
      return value is Map && value['op'] == 'ordering';
    }).length;
    if (ordering > 0) {
      orderingBatches.add(ordering);
      publicationFamilies.add('ordering');
    }
    return result;
  }
}

class _SnapshotStorage extends HiddenVolumeStorage {
  _SnapshotStorage(super.opener);
  Future<void> Function()? afterMessagesRead;
  Future<void> Function()? beforePreparedCommit;
  void Function(String conversationId, String messageId)? onMessageRead;
  bool ordinaryOrderingOnly = false;

  @override
  Future<Message?> loadMessageById(String conversationId, String messageId) {
    onMessageRead?.call(conversationId, messageId);
    return super.loadMessageById(conversationId, messageId);
  }

  @override
  Future<List<bool>?> adoptMessageOrderingBatch(
    List<MessageOrderingAdoption> requests, {
    required Future<void> Function() beforeCommit,
  }) => ordinaryOrderingOnly
      ? Future.value(null)
      : super.adoptMessageOrderingBatch(
          requests,
          beforeCommit: () async {
            final hook = beforePreparedCommit;
            beforePreparedCommit = null;
            await hook?.call();
            await beforeCommit();
          },
        );

  @override
  Future<List<PreparedMessageWrite>?> appendMissingMessageBatch(
    List<Message> messages, {
    required Future<void> Function() beforeCommit,
  }) => super.appendMissingMessageBatch(
    messages,
    beforeCommit: () async {
      final hook = beforePreparedCommit;
      beforePreparedCommit = null;
      await hook?.call();
      await beforeCommit();
    },
  );

  @override
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    final rows = await super.loadMessages(conversationId, limit: limit);
    final hook = afterMessagesRead;
    afterMessagesRead = null;
    await hook?.call();
    return rows;
  }
}

Future<_SnapshotStorage> _storage({FakeKvLogStore? backing}) async {
  final kv = backing ?? FakeKvLogStore();
  final s = _SnapshotStorage(({required password, required bool create}) => kv);
  await s.open(password: 'fixture', createIfMissing: true);
  await s.upsertContact(Contact(nodeId: peer, status: ContactStatus.accepted));
  return s;
}

Future<void> until(Future<bool> Function() check) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('history condition did not converge');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _historyReply(
  _Endpoint from,
  NodeId to,
  String requestId,
  Map<String, dynamic> reply,
) async {
  final bytes = utf8.encode(jsonEncode(reply));
  await _historyReplyBytes(from, to, requestId, bytes);
}

Future<void> _historyReplyBytes(
  _Endpoint from,
  NodeId to,
  String requestId,
  List<int> bytes, {
  int sliceBytes = 2048,
}) async {
  final parts = (bytes.length + sliceBytes - 1) ~/ sliceBytes;
  expect(parts, lessThanOrEqualTo(64));
  for (var i = 0; i < parts; i++) {
    await from.net.send(
      from,
      to,
      WireEnvelope.deviceHistory(
        jsonEncode({
          'v': 1,
          'd': from.me.hex,
          'id': requestId,
          'i': i,
          'n': parts,
          'b': base64Encode(
            bytes.sublist(
              i * sliceBytes,
              ((i + 1) * sliceBytes).clamp(0, bytes.length),
            ),
          ),
        }),
      ).encode(),
    );
  }
}

void main() {
  late _Network net;
  late _SnapshotStorage sa, sb;
  late _Endpoint ta, tb;
  late MessagingService ma, mb;
  late List<NodeId> bSiblings;
  late _RefusingCursorStore bStore;
  var applied = 0;
  Future<void> Function(DeviceSyncEvent)? beforeApply;
  var now = DateTime.now();

  MessagingService service(_Endpoint t, HiddenVolumeStorage s, NodeId other) {
    final m = MessagingService(t, s, now: () => now);
    m.groupBindingsOwner = Object();
    m.selfIdentityHex = () async => identity.hex;
    m.myOtherDevices = () async => t.me == b ? bSiblings : [other];
    m.isOwnDevice = (p) async =>
        p == identity || (await m.myOtherDevices!()).contains(p);
    m.ownHistoryEncode = (p, message) async =>
        deviceMirrorOf(p.hex, message).event;
    Future<void> apply(
      DeviceSyncEvent event, {
      PreparedMessageAppender? append,
      PreparedOrderingAdopter? adopt,
    }) async {
      await beforeApply?.call(event);
      final p = event.payload;
      await m.applyMirroredMessage(
        appendPrepared: append,
        adoptPrepared: adopt,
        peer: NodeId.fromHex(p['peer'] as String),
        msgId: event.key,
        direction: p['dir'] == 'outgoing'
            ? MessageDirection.outgoing
            : MessageDirection.incoming,
        body: p['body'] as String,
        tsMs: event.tsMs,
        author: p['au'] as String?,
        seq: p['sq'] as int?,
        positionVerified: p['pv'] as bool?,
        reflectedEdit: p['er'] == true,
      );
      if (t.me == b) applied++;
    }

    m.ownHistoryApply = (event) => apply(event);
    m.ownHistoryApplyPrepared = (event, writes) =>
        apply(event, append: writes.append, adopt: writes.adoptOrdering);
    m.onOwnDeviceHistoryReady(m.groupBindingsOwner!);
    return m;
  }

  setUp(() async {
    net = _Network();
    sa = await _storage();
    bStore = _RefusingCursorStore();
    sb = await _storage(backing: bStore);
    ta = _Endpoint(net, a);
    tb = _Endpoint(net, b);
    bSiblings = [a];
    applied = 0;
    beforeApply = null;
    now = DateTime.now();
    ma = service(ta, sa, b);
    mb = service(tb, sb, a);
    errorJournal.clear();
  });
  tearDown(() async {
    await ma.dispose();
    await mb.dispose();
    await ta.dispose();
    await tb.dispose();
    await sa.close();
    await sb.close();
    errorJournal.clear();
  });

  Future<void> seed(
    int count, {
    int bodyBytes = 30,
    String? messageBody,
    DateTime? at,
    MessageStatus status = MessageStatus.delivered,
    MessageDirection direction = MessageDirection.outgoing,
  }) async {
    for (var i = 0; i < count; i++) {
      await sa.appendMessage(
        Message(
          id: 'm${i.toString().padLeft(4, '0')}',
          conversationId: peer.hex,
          direction: direction,
          body: messageBody ?? List.filled(bodyBytes, '${i % 10}').join(),
          timestamp: (at ?? DateTime.utc(2020)).add(Duration(seconds: i)),
          status: status,
          author: a.hex,
          seq: i + 1,
          positionVerified: true,
        ),
      );
    }
  }

  Future<int> count() async => (await sb.loadMessages(peer.hex)).length;
  Future<void> restartB() async {
    await mb.dispose();
    await tb.dispose();
    tb = _Endpoint(net, b);
    mb = service(tb, sb, a)..start();
  }

  Future<String> manualPageRequest() async {
    mb.start(); // No source listener: every reply in this probe is explicit.
    await until(
      () async => net.history.any(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
      ),
    );
    final inventory = net.history.lastWhere(
      (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
    );
    await _historyReply(ta, b, inventory.body['id'] as String, {
      'op': 'list',
      'rows': [
        {'peer': peer.hex, 'count': 1, 'hash': '0' * 64},
      ],
    });
    await until(
      () async => net.history.any(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
      ),
    );
    return net.history
            .lastWhere(
              (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
            )
            .body['id']
        as String;
  }

  Future<List<int>> paddedSingleRowReply(int byteLength) async {
    final message = (await sa.loadMessages(peer.hex)).single;
    final reply = <String, dynamic>{
      'op': 'page',
      'peer': peer.hex,
      'events': [deviceMirrorOf(peer.hex, message).event.toBody()],
      'next': null,
      'padding': '',
    };
    final overhead = utf8.encode(jsonEncode(reply)).length;
    expect(overhead, lessThan(byteLength));
    reply['padding'] = 'x' * (byteLength - overhead);
    final bytes = utf8.encode(jsonEncode(reply));
    expect(bytes, hasLength(byteLength));
    return bytes;
  }

  Future<void> drainHistoryFrames() async {
    await Future<void>(() {});
    await until(() async => mb.historyInboundAdmission.queuedFrames == 0);
    await Future<void>(() {});
  }

  test(
    'history pages use four-KiB slices within the six-KiB wire bound',
    () async {
      await seed(32, bodyBytes: 2000);
      ma.start();
      mb.start();
      await until(
        () async =>
            await count() == 32 &&
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final replies = <String, Map<int, Map<String, dynamic>>>{};
      for (final frame in net.history.where((frame) => frame.from == a)) {
        final body = frame.body;
        if (body['i'] case final int index) {
          replies.putIfAbsent(body['id'] as String, () => {})[index] = body;
        }
      }
      var pages = 0;
      for (final parts in replies.values) {
        final bytes = BytesBuilder();
        for (var i = 0; i < parts.length; i++) {
          bytes.add(base64Decode(parts[i]!['b'] as String));
        }
        final payload = bytes.takeBytes();
        final reply = jsonDecode(utf8.decode(payload)) as Map;
        if (reply['op'] != 'page') continue;
        pages++;
        expect(reply['events'], hasLength(32));
        expect(payload.length, lessThanOrEqualTo(128 * 1024));
        expect(parts.length, (payload.length + 4095) ~/ 4096);
        expect(base64Decode(parts[0]!['b'] as String), hasLength(4096));
      }
      expect(pages, 1);
      expect(applied, 32);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'four-KiB slices accept exactly the existing 128-KiB page budget',
    () async {
      await seed(1);
      final request = await manualPageRequest();
      final bytes = await paddedSingleRowReply(128 * 1024);
      await _historyReplyBytes(ta, b, request, bytes, sliceBytes: 4096);
      await until(() async => await count() == 1);
      expect(
        (await sb.loadMessageById(peer.hex, 'm0000'))!.body,
        (await sa.loadMessageById(peer.hex, 'm0000'))!.body,
      );
      expect(applied, 1);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'page byte budget rejects excess bytes before retaining the final part',
    () async {
      await seed(1);
      final request = await manualPageRequest();
      final cursor = await sb.getSetting('device.history.cursor.v2:${a.hex}');
      final bytes = await paddedSingleRowReply(128 * 1024);
      // The JSON is valid with trailing whitespace too; only the byte budget
      // can refuse this response. 33 parts fit the unchanged count bound.
      await _historyReplyBytes(ta, b, request, [
        ...bytes,
        32,
      ], sliceBytes: 4096);
      await drainHistoryFrames();
      expect(await count(), 0);
      expect(applied, 0);
      expect(await sb.getSetting('device.history.cursor.v2:${a.hex}'), cursor);
      // The rejected part must not occupy its slot. An empty corrected tail
      // now completes exactly 128 KiB using the same request and held prefix.
      await net.send(
        ta,
        b,
        WireEnvelope.deviceHistory(
          jsonEncode({
            'v': 1,
            'd': a.hex,
            'id': request,
            'i': 32,
            'n': 33,
            'b': '',
          }),
        ).encode(),
      );
      await until(() async => await count() == 1);
      expect(applied, 1);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'a decoded part over four KiB cannot occupy its repairable slot',
    () async {
      await seed(1);
      final request = await manualPageRequest();
      final bytes = await paddedSingleRowReply(4096);
      // 4096 and 4097 decoded bytes have the same base64 character count.
      await _historyReplyBytes(ta, b, request, [
        ...bytes,
        32,
      ], sliceBytes: 4097);
      await drainHistoryFrames();
      expect(await count(), 0);
      expect(applied, 0);
      await _historyReplyBytes(ta, b, request, bytes, sliceBytes: 4096);
      await until(() async => await count() == 1);
      expect(applied, 1);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test('short history publishes posts in bounded durable cohorts', () async {
    await seed(64);
    ma.start();
    mb.start();
    await until(() async => await count() == 64);
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    expect(bStore.postBatches.fold<int>(0, (n, size) => n + size), 64);
    expect(
      bStore.postBatches.length,
      lessThanOrEqualTo(4),
      reason: 'sixteen prepared posts share one durable publication',
    );
    expect(bStore.postBatches.every((size) => size <= 16), isTrue);
  });

  for (final (direction, status) in [
    (MessageDirection.incoming, MessageStatus.delivered),
    (MessageDirection.outgoing, MessageStatus.sent),
  ]) {
    test(
      'history ${direction.name} without state corrections avoids post-apply reads',
      () async {
        await seed(64, direction: direction, status: status);
        // Isolate this pull from reverse history reconciliation.
        net.drop = (from, _, body) => from == a && body['q'] != null;
        final completed = <String>{};
        var postApplyReads = 0;
        sb.onMessageRead = (conversation, message) {
          if (conversation == peer.hex && completed.contains(message)) {
            postApplyReads++;
          }
        };
        final apply = mb.ownHistoryApplyPrepared!;
        mb.ownHistoryApplyPrepared = (event, writes) async {
          await apply(event, writes);
          completed.add(event.key);
        };
        ma.start();
        mb.start();
        await until(
          () async =>
              await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
        );
        expect(completed, hasLength(64));
        expect(
          postApplyReads,
          0,
          reason: 'no edit or delivery correction needs the stored row',
        );
        final original = await sa.loadMessages(peer.hex);
        final received = await sb.loadMessages(peer.hex);
        expect(
          received.map(
            (m) => (
              m.id,
              m.body,
              m.direction,
              m.status,
              m.orderAuthor,
              m.orderSeq,
            ),
          ),
          original.map(
            (m) => (
              m.id,
              m.body,
              m.direction,
              m.status,
              m.orderAuthor,
              m.orderSeq,
            ),
          ),
        );
        expect(bStore.postBatches, [16, 16, 16, 16]);
        expect(errorJournal.entries, isEmpty);
      },
    );
  }

  test(
    'history preparation fills one bounded cohort without publishing past a held row',
    () async {
      await seed(32);
      var started = 0;
      final first = Completer<void>(), release = Completer<void>();
      beforeApply = (event) async {
        started++;
        if (event.key == 'm0000') {
          first.complete();
          await release.future;
        }
      };
      ma.start();
      mb.start();
      await first.future;
      try {
        // Gate the first preparation, then drain the fixture's immediate IO.
        // Neither elapsed-time speed nor network timing is the assertion.
        await Future<void>(() {});
        await Future<void>(() {});
        expect(
          started,
          16,
          reason: 'one held row must not serialize fresh reads',
        );
        expect(await count(), 0);
        expect(bStore.postBatches, isEmpty);
      } finally {
        release.complete();
      }
      await until(() async => await count() == 32);
      final original = await sa.loadMessages(peer.hex);
      final received = await sb.loadMessages(peer.hex);
      expect(
        received.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
        original.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
      );
      expect(bStore.postBatches, [16, 16]);
      expect(applied, 32);
    },
  );

  test(
    'mixed history preparation stays within the unpublished cohort budget',
    () async {
      await seed(32);
      // Only B pulls: reverse reconciliation must not enter the shared hook.
      net.drop = (from, _, body) => from == a && body['q'] != null;
      final originals = await sa.loadMessages(peer.hex);
      for (final row in originals.skip(8).take(8)) {
        await sb.appendMessage(
          Message(
            id: row.id,
            conversationId: row.conversationId,
            direction: row.direction,
            body: row.body,
            timestamp: row.timestamp,
            status: row.status,
            author: identity.hex,
            seq: 2001,
            positionVerified: false,
          ),
        );
      }
      bStore.postBatches.clear();
      bStore.orderingBatches.clear();
      bStore.publicationFamilies.clear();
      var started = 0;
      final held = Completer<void>(), release = Completer<void>();
      beforeApply = (event) async {
        started++;
        if (event.key == 'm0016') {
          held.complete();
          await release.future;
        }
      };
      ma.start();
      mb.start();
      await held.future;
      try {
        await Future<void>(() {});
        await Future<void>(() {});
        // Eight posts were published, eight ordering updates remain staged.
        // Only eight more preparations fit before the held row can settle.
        expect(started, 24);
        expect(await count(), 16);
        expect(bStore.postBatches, [8]);
        expect(bStore.orderingBatches, isEmpty);
        expect(bStore.publicationFamilies, ['post']);
      } finally {
        release.complete();
      }
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final received = await sb.loadMessages(peer.hex);
      expect(
        received.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
        originals.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
      );
      expect(bStore.publicationFamilies, ['post', 'ordering', 'post']);
      expect(bStore.postBatches, [8, 16]);
      expect(bStore.orderingBatches, [8]);
      expect(applied, 32);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'revocation while a preparation wave is held refuses its publication',
    () async {
      await seed(32);
      final first = Completer<void>(), release = Completer<void>();
      beforeApply = (event) async {
        if (event.key == 'm0000') {
          first.complete();
          await release.future;
        }
      };
      ma.start();
      mb.start();
      await first.future;
      await Future<void>(() {});
      bSiblings = [];
      release.complete();
      await until(() async => errorJournal.entries.isNotEmpty);
      expect(await count(), 0);
      expect(applied, 0);
      expect(bStore.postBatches, isEmpty);
      final saved =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(saved['cursor'], isNull);
    },
  );

  test(
    'a failed preparation joins a sibling that reaches its write boundary late',
    () async {
      await seed(4);
      final first = Completer<void>(), failFirst = Completer<void>();
      final second = Completer<void>(), releaseSecond = Completer<void>();
      final cleanup = Completer<PreparedMessageWrite>();
      var lateStageRejected = false;
      final held = {
        for (final row in await sa.loadMessages(peer.hex)) row.id: row,
      };
      mb.ownHistoryApplyPrepared = (event, writes) async {
        if (event.key == 'm0000') {
          first.complete();
          await failFirst.future;
          throw StateError('fixture preparation failure');
        }
        if (event.key == 'm0001') {
          second.complete();
          await releaseSecond.future;
        }
        try {
          // Cover every wave member: the deliberately broken implementation
          // may let more than the held row reach a late write boundary.
          await Future.any([writes.append(held[event.key]!), cleanup.future]);
        } catch (_) {
          if (event.key == 'm0001') lateStageRejected = true;
          rethrow;
        }
      };
      ma.start();
      mb.start();
      try {
        await first.future;
        await second.future;
        failFirst.complete();
        await Future<void>(() {});
        expect(
          errorJournal.entries,
          isEmpty,
          reason: 'abort must join the still-preparing sibling before settling',
        );
        expect(bStore.postBatches, isEmpty);
        releaseSecond.complete();
        await Future<void>(() {});
        expect(
          lateStageRejected,
          isTrue,
          reason: 'an aborted wave must reject its late write boundary',
        );
      } finally {
        if (!failFirst.isCompleted) failFirst.complete();
        if (!releaseSecond.isCompleted) releaseSecond.complete();
        cleanup.complete(PreparedMessageWrite.suppressed);
      }
      await until(() async => errorJournal.entries.isNotEmpty);
      expect(await count(), 0);
      expect(applied, 0);
      expect(bStore.postBatches, isEmpty);
      final saved =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(saved['cursor'], isNull);
    },
  );

  test(
    'a later ordering preparation cannot publish before an earlier insert',
    () async {
      await seed(2);
      // Only B pulls in this publication-order probe. Otherwise A's reverse
      // reconciliation of B's provisional row also enters the shared hook.
      net.drop = (from, _, body) => from == a && body['q'] != null;
      final originals = await sa.loadMessages(peer.hex);
      final later = originals[1];
      await sb.appendMessage(
        Message(
          id: later.id,
          conversationId: later.conversationId,
          direction: later.direction,
          body: later.body,
          timestamp: later.timestamp,
          status: later.status,
          author: identity.hex,
          seq: 2001,
          positionVerified: false,
        ),
      );
      bStore.publicationFamilies.clear();
      final first = Completer<void>(), release = Completer<void>();
      var started = 0;
      beforeApply = (event) async {
        started++;
        if (event.key == 'm0000') {
          first.complete();
          await release.future;
        }
      };
      ma.start();
      mb.start();
      await first.future;
      try {
        await Future<void>(() {});
        expect(started, 2);
        expect(bStore.publicationFamilies, isEmpty);
      } finally {
        release.complete();
      }
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(bStore.publicationFamilies, ['post', 'ordering']);
      final received = await sb.loadMessages(peer.hex);
      expect(
        received.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
        originals.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
      );
      expect(applied, 2);
      expect(errorJournal.entries, isEmpty);
    },
  );

  for (final revokeFirst in [false, true]) {
    test(
      revokeFirst
          ? 'a revoked queued source does not poison the next source page'
          : 'overlapping source pages cannot hold opposite message slots',
      () async {
        await seed(2);
        final extra = id(94), tx = _Endpoint(net, id(94));
        addTearDown(tx.dispose);
        bSiblings = [a, extra];
        final firstStaged = Completer<void>(), firstLater = Completer<void>();
        final secondStaged = Completer<void>();
        final releaseFirstLater = Completer<void>(),
            releaseSecondFirst = Completer<void>();
        final cleanup = Completer<PreparedMessageWrite>();
        final original = mb.ownHistoryApplyPrepared!;
        var secondEntered = false;
        mb.ownHistoryApplyPrepared = (event, writes) async {
          final source = event.payload['fixtureSource'];
          if (source == 'second') secondEntered = true;
          if (source == 'first' && event.key == 'm0001') {
            firstLater.complete();
            await releaseFirstLater.future;
          }
          if (source == 'second' && event.key == 'm0000') {
            await releaseSecondFirst.future;
          }
          await original(
            event,
            PreparedMessageWrites(
              append: (message) {
                final result = writes.append(message);
                if (source == 'first' &&
                    event.key == 'm0000' &&
                    !firstStaged.isCompleted) {
                  firstStaged.complete();
                }
                if (source == 'second' &&
                    event.key == 'm0001' &&
                    !secondStaged.isCompleted) {
                  secondStaged.complete();
                }
                return Future.any([result, cleanup.future]);
              },
              adoptOrdering: writes.adoptOrdering,
            ),
          );
        };
        mb.start();
        Future<String> requestFor(NodeId device, String op) async {
          await until(
            () async => net.history.any(
              (f) => f.from == b && f.to == device && f.body['q']?['op'] == op,
            ),
          );
          return net.history
                  .lastWhere(
                    (f) =>
                        f.from == b &&
                        f.to == device &&
                        f.body['q']?['op'] == op,
                  )
                  .body['id']
              as String;
        }

        final sources = [(ta, a, 'first'), (tx, extra, 'second')];
        for (final (transport, device, _) in sources) {
          await _historyReply(transport, b, await requestFor(device, 'list'), {
            'op': 'list',
            'rows': [
              {'peer': peer.hex, 'count': 2, 'hash': '0' * 64},
            ],
          });
        }
        final rows = await sa.loadMessages(peer.hex);
        Map<String, dynamic> response(String source) => {
          'op': 'page',
          'peer': peer.hex,
          'next': null,
          'events': [
            for (final row in rows)
              DeviceSyncEvent(
                kind: DeviceSyncKind.msgMirror,
                key: row.id,
                tsMs: row.timestamp.millisecondsSinceEpoch,
                payload: {
                  ...deviceMirrorOf(peer.hex, row).event.payload,
                  'fixtureSource': source,
                  'historyDelivered': true,
                },
              ).toBody(),
          ],
        };
        try {
          await _historyReply(
            ta,
            b,
            await requestFor(a, 'page'),
            response('first'),
          );
          await firstStaged.future;
          await firstLater.future;
          await _historyReply(
            tx,
            b,
            await requestFor(extra, 'page'),
            response('second'),
          );
          await drainHistoryFrames();
          final oppositeHeld = secondStaged.isCompleted;
          if (revokeFirst) bSiblings = [extra];
          releaseFirstLater.complete();
          releaseSecondFirst.complete();
          await Future<void>(() {});
          if (oppositeHeld) {
            expect(
              await count(),
              0,
              reason:
                  'both cohorts hold a slot needed by the other publication',
            );
          }
          expect(
            oppositeHeld,
            isFalse,
            reason:
                'overlapping pages must not acquire opposite prepared slots',
          );
          if (revokeFirst) {
            expect(
              secondEntered,
              isTrue,
              reason: 'a failed predecessor must not poison the next page',
            );
          }
          await until(
            () async => applied == (revokeFirst ? 2 : 4) && await count() == 2,
          );
          for (final device in [if (!revokeFirst) a, extra]) {
            await until(() async {
              final raw = await sb.getSetting(
                'device.history.cursor.v2:${device.hex}',
              );
              return raw != null &&
                  (jsonDecode(raw) as Map)['after'] == peer.hex;
            });
          }
          final received = await sb.loadMessages(peer.hex);
          expect(
            received.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
            rows.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
          );
          expect(
            received.every((m) => m.status == MessageStatus.delivered),
            isTrue,
          );
          expect(bStore.postBatches, [2]);
          expect(errorJournal.entries, revokeFirst ? isNotEmpty : isEmpty);
          if (revokeFirst) {
            final raw = await sb.getSetting(
              'device.history.cursor.v2:${a.hex}',
            );
            expect((jsonDecode(raw!) as Map)['cursor'], isNull);
          }
        } finally {
          bSiblings = [];
          if (!releaseFirstLater.isCompleted) releaseFirstLater.complete();
          if (!releaseSecondFirst.isCompleted) releaseSecondFirst.complete();
          cleanup.complete(PreparedMessageWrite.suppressed);
        }
      },
    );
  }

  test('a held history page does not block a different conversation', () async {
    await seed(1);
    final extra = id(94), otherPeer = id(95), tx = _Endpoint(net, id(94));
    addTearDown(tx.dispose);
    bSiblings = [a, extra];
    await sb.upsertContact(
      Contact(nodeId: otherPeer, status: ContactStatus.accepted),
    );
    final entered = Completer<void>(), release = Completer<void>();
    beforeApply = (event) async {
      if (event.payload['peer'] == peer.hex) {
        entered.complete();
        await release.future;
      }
    };
    mb.start();
    Future<String> requestFor(NodeId device, String op) async {
      await until(
        () async => net.history.any(
          (f) => f.from == b && f.to == device && f.body['q']?['op'] == op,
        ),
      );
      return net.history
              .lastWhere(
                (f) =>
                    f.from == b && f.to == device && f.body['q']?['op'] == op,
              )
              .body['id']
          as String;
    }

    for (final (transport, device, target) in [
      (ta, a, peer),
      (tx, extra, otherPeer),
    ]) {
      await _historyReply(transport, b, await requestFor(device, 'list'), {
        'op': 'list',
        'rows': [
          {'peer': target.hex, 'count': 1, 'hash': '0' * 64},
        ],
      });
    }
    final firstRow = (await sa.loadMessages(peer.hex)).single;
    final secondRow = Message(
      id: 'other-history',
      conversationId: otherPeer.hex,
      direction: MessageDirection.outgoing,
      body: 'other conversation',
      timestamp: DateTime.utc(2020),
      status: MessageStatus.delivered,
      author: a.hex,
      seq: 1,
      positionVerified: true,
    );
    Map<String, dynamic> response(NodeId target, Message row) => {
      'op': 'page',
      'peer': target.hex,
      'next': null,
      'events': [deviceMirrorOf(target.hex, row).event.toBody()],
    };
    try {
      await _historyReply(
        ta,
        b,
        await requestFor(a, 'page'),
        response(peer, firstRow),
      );
      await entered.future;
      await _historyReply(
        tx,
        b,
        await requestFor(extra, 'page'),
        response(otherPeer, secondRow),
      );
      await drainHistoryFrames();
      expect(
        (await sb.loadMessages(otherPeer.hex)).length,
        1,
        reason: 'only pages sharing message-slot scope may wait for this gate',
      );
      expect(await count(), 0);
    } finally {
      release.complete();
    }
    await until(() async => applied == 2 && await count() == 1);
    expect((await sb.loadMessages(otherPeer.hex)).length, 1);
    expect(bStore.postBatches, [1, 1]);
    expect(errorJournal.entries, isEmpty);
  });

  test(
    'history repairs provisional positions in bounded durable cohorts',
    () async {
      await seed(64);
      final originals = await sa.loadMessages(peer.hex);
      for (var i = 0; i < originals.length; i++) {
        final row = originals[i];
        await sb.appendMessage(
          Message(
            id: row.id,
            conversationId: row.conversationId,
            direction: row.direction,
            body: row.body,
            timestamp: row.timestamp,
            status: row.status,
            author: identity.hex,
            seq: 2000 + i,
            positionVerified: false,
          ),
        );
      }
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final repaired = await sb.loadMessages(peer.hex);
      expect(repaired.map((row) => row.id), originals.map((row) => row.id));
      expect(
        repaired.map((row) => (row.orderAuthor, row.orderSeq)),
        originals.map((row) => (row.orderAuthor, row.orderSeq)),
      );
      expect(repaired.every((row) => row.author == identity.hex), isTrue);
      expect(await sb.loadEventsSince(peer.hex, a.hex, 0), isEmpty);
      expect(bStore.orderingBatches.fold<int>(0, (n, size) => n + size), 64);
      expect(
        bStore.orderingBatches.length,
        lessThanOrEqualTo(4),
        reason:
            'sixteen authenticated ordering corrections share one durable publication',
      );
      expect(bStore.orderingBatches.every((size) => size <= 16), isTrue);
    },
  );

  test(
    'unsupported ordering batches retain the ordinary durable merge',
    () async {
      await seed(4);
      final originals = await sa.loadMessages(peer.hex);
      for (var i = 0; i < originals.length; i++) {
        final row = originals[i];
        await sb.appendMessage(
          Message(
            id: row.id,
            conversationId: row.conversationId,
            direction: row.direction,
            body: row.body,
            timestamp: row.timestamp,
            status: row.status,
            author: identity.hex,
            seq: 2000 + i,
            positionVerified: false,
          ),
        );
      }
      sb.ordinaryOrderingOnly = true;
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final held = await sb.loadMessages(peer.hex);
      expect(
        held.map((m) => (m.id, m.orderAuthor, m.orderSeq)),
        originals.map((m) => (m.id, m.orderAuthor, m.orderSeq)),
      );
      expect(bStore.orderingBatches, [1, 1, 1, 1]);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test('mixed insert and ordering cohorts preserve the full history', () async {
    await seed(40);
    final originals = await sa.loadMessages(peer.hex);
    for (var i = 0; i < originals.length; i += 2) {
      final row = originals[i];
      await sb.appendMessage(
        Message(
          id: row.id,
          conversationId: row.conversationId,
          direction: row.direction,
          body: row.body,
          timestamp: row.timestamp,
          status: row.status,
          author: identity.hex,
          seq: 2000 + i,
          positionVerified: false,
        ),
      );
    }
    ma.start();
    mb.start();
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    final held = await sb.loadMessages(peer.hex);
    expect(
      held.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
      originals.map((m) => (m.id, m.body, m.orderAuthor, m.orderSeq)),
    );
    expect(held.map((m) => m.id).toSet(), hasLength(40));
    expect(bStore.orderingBatches.fold<int>(0, (n, size) => n + size), 20);
  });

  test(
    'revocation at ordering publication leaves raw positions and cursor intact',
    () async {
      await seed(16);
      final originals = await sa.loadMessages(peer.hex);
      for (var i = 0; i < originals.length; i++) {
        final row = originals[i];
        await sb.appendMessage(
          Message(
            id: row.id,
            conversationId: row.conversationId,
            direction: row.direction,
            body: row.body,
            timestamp: row.timestamp,
            status: row.status,
            author: identity.hex,
            seq: 2000 + i,
            positionVerified: false,
          ),
        );
      }
      var checked = false;
      sb.beforePreparedCommit = () async {
        checked = true;
        bSiblings = [];
      };
      ma.start();
      mb.start();
      await until(() async => checked && errorJournal.entries.isNotEmpty);
      expect(
        (await sb.loadMessages(peer.hex)).every((m) => m.ordering == null),
        isTrue,
      );
      expect(bStore.orderingBatches, isEmpty);
      final saved =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(saved['cursor'], isNull);
      expect(applied, 0);
    },
  );

  test(
    'reconnect starts history after late bindings without waiting for a timer',
    () async {
      await seed(1);
      net.dropPresence = true;
      final encode = mb.ownHistoryEncode, apply = mb.ownHistoryApply;
      final owner = mb.groupBindingsOwner;
      mb.ownHistoryEncode = null;
      mb.ownHistoryApply = null;
      mb.groupBindingsOwner = null;
      mb.start();
      ma.start();
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q'] != null,
        ),
        isEmpty,
      );
      mb.ownHistoryEncode = encode;
      mb.ownHistoryApply = apply;
      mb.groupBindingsOwner = owner;
      mb.myOtherDevices = () async => [];
      mb.onOwnDeviceHistoryReady(owner!);
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q'] != null,
        ),
        isEmpty,
      );
      mb.myOtherDevices = () async => [a];
      await mb.reconcileOnConnect();
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
        ),
        isNotEmpty,
      );
      await until(() async => await count() == 1);
    },
  );

  test(
    'a late old roster read cannot cancel the new binding history pull',
    () async {
      net.dropPresence = true;
      final oldRoster = Completer<List<NodeId>>();
      mb.myOtherDevices = () => oldRoster.future;
      mb.start();
      await Future<void>(() {});
      mb.groupBindingsOwner = Object();
      mb.myOtherDevices = () async => [a];
      mb.onOwnDeviceHistoryReady(mb.groupBindingsOwner!);
      tb.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: a,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.presence(a.hex).encode(),
        ),
      );
      await until(
        () async => net.history.any(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
        ),
      );
      final ask = net.history.lastWhere(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
      );
      oldRoster.complete([]);
      await Future<void>(() {});
      await _historyReply(ta, b, ask.body['id'] as String, {
        'op': 'list',
        'rows': [
          {'peer': peer.hex, 'count': 1, 'hash': '0' * 64},
        ],
      });
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
        ),
        isNotEmpty,
      );
    },
  );

  for (final replace in [false, true]) {
    test('a history send held in device lookup cannot outlive its host '
        '(replacement=$replace)', () async {
      net.dropPresence = true;
      final deviceRead = Completer<NodeId>();
      var reads = 0;
      tb.readNodeId = () {
        reads++;
        return deviceRead.future;
      };
      mb.start();
      await Future<void>(() {});
      expect(reads, greaterThan(0));
      expect(net.history.where((f) => f.from == b), isEmpty);

      mb.groupBindingsOwner = replace ? Object() : null;
      tb.readNodeId = null;
      if (replace) {
        mb.onOwnDeviceHistoryReady(mb.groupBindingsOwner!);
        await Future<void>(() {});
        expect(
          net.history.where((f) => f.from == b && f.body['q'] != null),
          hasLength(1),
        );
      }
      final before = net.history.where((f) => f.from == b).length;
      deviceRead.complete(b);
      await Future<void>(() {});
      expect(
        net.history.where((f) => f.from == b),
        hasLength(before),
        reason: 'the retired host must not enqueue its pending query',
      );
    });
  }

  test(
    'only the current ready host starts history and repeated notices share its pull',
    () async {
      net.dropPresence = true;
      final encode = mb.ownHistoryEncode, apply = mb.ownHistoryApply;
      mb.ownHistoryEncode = null;
      mb.ownHistoryApply = null;
      final oldOwner = mb.groupBindingsOwner!;
      mb.start();
      await Future<void>(() {});
      final owner = Object();
      mb.groupBindingsOwner = owner;
      mb.ownHistoryEncode = encode;
      mb.ownHistoryApply = apply;
      mb.onOwnDeviceHistoryReady(oldOwner);
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q'] != null,
        ),
        isEmpty,
      );
      for (var i = 0; i < 10; i++) {
        mb.onOwnDeviceHistoryReady(owner);
      }
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
        ),
        hasLength(1),
      );
      await mb.dispose();
      final count = net.history.length;
      mb.onOwnDeviceHistoryReady(owner);
      await Future<void>(() {});
      expect(net.history.length, count);
    },
  );

  test(
    'reconnect cannot read history before its current host is ready',
    () async {
      net.dropPresence = true;
      final encode = mb.ownHistoryEncode, apply = mb.ownHistoryApply;
      mb.ownHistoryEncode = null;
      mb.ownHistoryApply = null;
      mb.groupBindingsOwner = null;
      mb.start();
      final owner = Object();
      mb.groupBindingsOwner = owner;
      mb.ownHistoryEncode = encode;
      mb.ownHistoryApply = apply;
      await mb.reconcileOnConnect();
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q'] != null,
        ),
        isEmpty,
      );
      mb.onOwnDeviceHistoryReady(owner);
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
        ),
        hasLength(1),
      );
    },
  );

  test('reflected edit provenance survives an own-device history page', () async {
    await seed(1);
    await sa.editMessage(
      peer.hex,
      'm0000',
      'reflected text',
      seq: 99,
      reflected: true,
    );
    ma.start();
    mb.start();
    await until(() async => (await sb.editSeqs(peer.hex))['m0000'] == 99);
    final message = (await sb.loadMessages(peer.hex)).single;
    expect(message.body, 'reflected text');
    expect(message.reflectedEdit, isTrue);
    expect(message.positionVerified, isTrue);
    expect(
      await sb.loadEventsSince(peer.hex, a.hex, 0),
      isEmpty,
      reason:
          'a history page must not turn reflected text into an authored post/edit',
    );
    await restartB();
    expect((await sb.loadMessages(peer.hex)).single.reflectedEdit, isTrue);
  });

  test(
    'authenticated same-value edit repairs reflected history provenance',
    () async {
      await seed(1);
      await sb.appendMessage((await sa.loadMessages(peer.hex)).single);
      await sa.editMessage(
        peer.hex,
        'm0000',
        'same text',
        seq: 99,
        reflected: true,
      );
      ma.start();
      mb.start();
      await until(() async => (await sb.editSeqs(peer.hex))['m0000'] == 99);
      expect((await sb.loadMessages(peer.hex)).single.reflectedEdit, isTrue);
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      // Genuine evidence now reaches A. The body and revision do not change:
      // provenance itself must change the inventory digest and reach B.
      await sa.editMessage(peer.hex, 'm0000', 'same text', seq: 99);
      expect((await sa.loadMessages(peer.hex)).single.reflectedEdit, isFalse);
      await restartB();
      await until(
        () async => !(await sb.loadMessages(peer.hex)).single.reflectedEdit,
      );
      expect(
        (await sb.loadEventsSince(
          peer.hex,
          a.hex,
          0,
        )).where((event) => event.body == 'same text'),
        hasLength(1),
      );
    },
  );

  test(
    'a reflected history page cannot demote authentic same-value evidence',
    () async {
      await seed(1);
      await sb.appendMessage((await sa.loadMessages(peer.hex)).single);
      await sa.editMessage(
        peer.hex,
        'm0000',
        'same text',
        seq: 99,
        reflected: true,
      );
      await sb.editMessage(peer.hex, 'm0000', 'same text', seq: 99);
      net.drop = (from, to, frame) => from == b && frame['i'] != null;
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect((await sb.loadMessages(peer.hex)).single.reflectedEdit, isFalse);
    },
  );

  test(
    'old originals recover without counterpart or device-log events',
    () async {
      await seed(40);
      ma.start();
      mb.start();
      await until(() async => await count() == 40);
      expect(
        (await sb.loadMessages(peer.hex)).map((m) => m.id),
        (await sa.loadMessages(peer.hex)).map((m) => m.id),
      );
      expect(await sb.pendingOutboxFrames(), isEmpty);
      expect(
        net.history.where((e) => e.body['q']?['op'] == 'page'),
        isNotEmpty,
      );
    },
  );

  test('resume inventory can retire an entirely held conversation', () async {
    await seed(40);
    final source = await sa.loadMessages(peer.hex);
    for (final message in source) {
      await sb.appendMessage(message);
    }
    await sa.putSetting(
      'device.history.cursor.v2:${b.hex}',
      jsonEncode({
        'peer': peer.hex,
        'cursor': [source[7].timestamp.millisecondsSinceEpoch, source[7].id],
      }),
    );
    ma.start();
    mb.start();
    await until(
      () async =>
          await sa.getSetting('device.history.cursor.v2:${b.hex}') == '{}',
    );
    expect(
      net.history.where(
        (frame) => frame.from == a && frame.body['q']?['op'] == 'page',
      ),
      isEmpty,
    );
  });

  test(
    'resume cursor can confirm newer held rows before fetching a suffix',
    () async {
      await seed(40);
      final source = await sa.loadMessages(peer.hex);
      for (final message in source.take(32)) {
        await sb.appendMessage(message);
      }
      await sb.putSetting(
        'device.history.cursor.v2:${a.hex}',
        jsonEncode({
          'peer': peer.hex,
          'cursor': [source[7].timestamp.millisecondsSinceEpoch, source[7].id],
        }),
      );
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(await count(), 40);
      expect(applied, 8);
      final requests = net.history.where(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
      );
      expect(requests, hasLength(1));
      expect(requests.single.body['q']['cursor'][1], 'm0007');
      expect(requests.single.body['q']['prefix']['count'], 32);
    },
  );

  test('smaller inventory carrying a newer edit is still fetched', () async {
    await seed(40);
    for (final message in (await sa.loadMessages(peer.hex)).take(32)) {
      await sb.appendMessage(message);
    }
    await sb.editMessage(peer.hex, 'm0013', 'edit on smaller sibling', seq: 7);
    ma.start();
    mb.start();
    await until(
      () async =>
          (await sa.loadMessageById(peer.hex, 'm0013'))!.body ==
              'edit on smaller sibling' &&
          await count() == 40,
    );
    expect((await sa.editSeqs(peer.hex))['m0013'], 7);
    expect(
      net.history.where(
        (frame) => frame.from == a && frame.body['q']?['op'] == 'page',
      ),
      isNotEmpty,
    );
  });

  test('a known late tail does not hide a matching earlier prefix', () async {
    await seed(40);
    final source = await sa.loadMessages(peer.hex);
    for (final message in [...source.take(24), ...source.skip(36)]) {
      await sb.appendMessage(message);
    }
    net.drop = (from, to, body) => from == a && body['q'] != null;
    ma.start();
    mb.start();
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    final recovered = await sb.loadMessages(peer.hex);
    expect(recovered.map((m) => m.id), source.map((m) => m.id));
    expect(applied, 16, reason: 'the matching first 24 rows need no replay');
    final requests = net.history
        .where((frame) => frame.from == b && frame.body['q']?['op'] == 'page')
        .toList();
    expect(requests, hasLength(1));
    final parts =
        net.history
            .where(
              (frame) =>
                  frame.from == a &&
                  frame.body['id'] == requests.single.body['id'] &&
                  frame.body['b'] is String,
            )
            .toList()
          ..sort(
            (left, right) =>
                (left.body['i'] as int).compareTo(right.body['i'] as int),
          );
    final bytes = BytesBuilder();
    for (final part in parts) {
      bytes.add(base64Decode(part.body['b'] as String));
    }
    final reply = jsonDecode(utf8.decode(bytes.takeBytes())) as Map;
    expect(reply['prefix']['count'], 24);
    expect(reply['prefix']['position'][1], 'm0023');
    expect(reply['events'], hasLength(16));
  });

  test(
    'long endpoints reduce hints to fit the existing query budget',
    () async {
      final source = <Message>[];
      for (var i = 0; i < 40; i++) {
        final message = Message(
          id: 'm${i.toString().padLeft(4, '0')}${'x' * 500}',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: 'long-endpoint-$i',
          timestamp: DateTime.utc(2020).add(Duration(seconds: i)),
          status: MessageStatus.delivered,
          author: a.hex,
          seq: i + 1,
          positionVerified: true,
        );
        source.add(message);
        await sa.appendMessage(message);
        if (i < 32) await sb.appendMessage(message);
      }
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final request =
          net.history
                  .firstWhere(
                    (frame) =>
                        frame.from == b && frame.body['q']?['op'] == 'page',
                  )
                  .body['q']
              as Map;
      expect(jsonEncode(request).length, lessThanOrEqualTo(1500));
      expect(
        (request['prefixFallbacks'] as List).length,
        inInclusiveRange(0, 6),
      );
      expect(applied, 8);
      expect(
        (await sb.loadMessages(peer.hex)).map((m) => m.id),
        source.map((m) => m.id),
      );
    },
  );

  test('verified held prefix is not transferred and applied again', () async {
    await seed(40);
    for (final message in (await sa.loadMessages(peer.hex)).take(32)) {
      await sb.appendMessage(message);
    }
    ma.start();
    mb.start();
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    final source = await sa.loadMessages(peer.hex);
    final recovered = await sb.loadMessages(peer.hex);
    expect(recovered.map((m) => m.id), source.map((m) => m.id));
    expect(applied, 8, reason: 'only the missing suffix should be mirrored');
    final requests = net.history.where(
      (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
    );
    expect(requests, hasLength(1));
    expect(requests.single.body['q']['prefix']['count'], 32);
    await until(
      () async =>
          await sa.getSetting('device.history.cursor.v2:${b.hex}') == '{}',
    );
    expect(
      net.history.where(
        (frame) => frame.from == a && frame.body['q']?['op'] == 'page',
      ),
      isEmpty,
      reason: 'A already holds the entire smaller inventory of B',
    );
  });

  for (final mismatch in ['gap', 'edit', 'delivery', 'position']) {
    test('a held prefix with a $mismatch is not skipped', () async {
      await seed(40);
      final source = await sa.loadMessages(peer.hex);
      for (var i = 0; i < 32; i++) {
        if (mismatch == 'gap' && i == 13) continue;
        final message = source[i];
        await sb.appendMessage(
          mismatch == 'position' && i == 13
              ? Message(
                  id: message.id,
                  conversationId: message.conversationId,
                  direction: message.direction,
                  body: message.body,
                  timestamp: message.timestamp,
                  status: message.status,
                  author: identity.hex,
                  seq: 99,
                  positionVerified: false,
                )
              : message.copyWith(
                  status: mismatch == 'delivery' && i == 13
                      ? MessageStatus.sent
                      : message.status,
                ),
        );
      }
      if (mismatch == 'edit') {
        await sa.editMessage(peer.hex, 'm0013', 'corrected', seq: 7);
      }
      // Isolate the receiving pull so a reverse pull cannot repair the
      // mismatch before the source checks the proposed prefix.
      net.drop = (from, to, body) => from == a && body['q'] != null;
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final recovered = await sb.loadMessages(peer.hex);
      expect(recovered.map((m) => m.id), source.map((m) => m.id));
      final repaired = recovered.singleWhere((m) => m.id == 'm0013');
      expect(repaired.orderAuthor, a.hex);
      expect(repaired.orderSeq, 14);
      expect(repaired.status, MessageStatus.delivered);
      if (mismatch == 'edit') {
        expect(repaired.body, 'corrected');
        expect((await sb.editSeqs(peer.hex))['m0013'], 7);
      }
      // A matching part before row 13 may be skipped, but the gap or stale
      // state at row 13 must still take the ordinary repair path.
      expect(applied, inInclusiveRange(27, 40));
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
        ),
        hasLength(inInclusiveRange(1, 2)),
      );
    });
  }

  for (final malformed in ['over limit', 'not descending']) {
    test('malformed prefix fallbacks are refused: $malformed', () async {
      await seed(40);
      for (final message in (await sa.loadMessages(peer.hex)).take(32)) {
        await sb.appendMessage(message);
      }
      Map<String, dynamic>? held;
      var blockOriginal = true;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        if (held == null && from == b && body['q']?['prefix'] != null) {
          held = Map<String, dynamic>.from(body);
          return true;
        }
        if (blockOriginal &&
            from == b &&
            held != null &&
            jsonEncode(body['q']) == jsonEncode(held!['q'])) {
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held != null);
      final query = Map<String, dynamic>.from(held!['q'] as Map);
      query['prefixFallbacks'] = List.filled(
        malformed == 'over limit' ? 8 : 1,
        query['prefix'],
      );
      expect(jsonEncode(query).length, lessThanOrEqualTo(1500));
      final read = Completer<void>();
      sa.afterMessagesRead = () async => read.complete();
      await net.send(
        tb,
        a,
        WireEnvelope.deviceHistory(jsonEncode({...held!, 'q': query})).encode(),
      );
      await read.future;
      // The fake store's remaining operations finish in microtasks. This
      // event barrier observes refusal, without asserting a timing threshold.
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) =>
              frame.from == a &&
              frame.body['id'] == held!['id'] &&
              frame.body['i'] != null,
        ),
        isEmpty,
      );
      expect(applied, 0);
      blockOriginal = false;
      await net.send(
        tb,
        a,
        WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
      );
      await until(() async => await count() == 40);
      expect(errorJournal.entries, isEmpty);
    });
  }

  test('a prefix changed in flight falls back before checkpointing', () async {
    await seed(40);
    for (final message in (await sa.loadMessages(peer.hex)).take(32)) {
      await sb.appendMessage(message);
    }
    Map<String, dynamic>? held;
    net.drop = (from, to, body) {
      if (from == a && body['q'] != null) return true;
      if (held == null && from == b && body['q']?['prefix'] != null) {
        held = Map<String, dynamic>.from(body);
        return true;
      }
      return false;
    };
    ma.start();
    mb.start();
    await until(() async => held != null);
    await sb.editMessage(peer.hex, 'm0000', 'newer local edit', seq: 7);
    bStore.pageCursorId = 'm0031';
    bStore.refusePageCursor = true;
    // Only reject a jump to the proposed prefix, not the ordinary page which
    // later reaches this position after repairing/revalidating its rows.
    beforeApply = (_) async => bStore.refusePageCursor = false;
    await net.send(
      tb,
      a,
      WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
    );
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    expect(await count(), 40);
    expect(applied, 40);
    expect(bStore.refused, isFalse);
    expect(
      (await sb.loadMessageById(peer.hex, 'm0000'))!.body,
      'newer local edit',
    );
    expect(errorJournal.entries, isEmpty);
    final requests = net.history
        .where((frame) => frame.from == b && frame.body['q']?['op'] == 'page')
        .toList();
    final fallback = requests.firstWhere(
      (frame) => frame.body['id'] != held!['id'],
    );
    expect(fallback.body['q']['cursor'], isNull);
    expect(fallback.body['q']['prefix'], isNull);
  });

  test('revocation during prefix recheck cannot advance its cursor', () async {
    await seed(40);
    for (final message in (await sa.loadMessages(peer.hex)).take(32)) {
      await sb.appendMessage(message);
    }
    Map<String, dynamic>? held;
    net.drop = (from, to, body) {
      if (from == a && body['q'] != null) return true;
      if (held == null && from == b && body['q']?['prefix'] != null) {
        held = Map<String, dynamic>.from(body);
        return true;
      }
      return false;
    };
    ma.start();
    mb.start();
    await until(() async => held != null);
    sb.afterMessagesRead = () async => bSiblings = [];
    await net.send(
      tb,
      a,
      WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
    );
    await until(() async => errorJournal.entries.isNotEmpty);
    final progress =
        jsonDecode((await sb.getSetting('device.history.cursor.v2:${a.hex}'))!)
            as Map;
    expect(progress['cursor'], isNull);
    expect(applied, 0);
    expect(await count(), 32);
  });

  test('an unconfirmed prefix cannot advance the receiver cursor', () async {
    await seed(40);
    for (final message in (await sa.loadMessages(peer.hex)).take(32)) {
      await sb.appendMessage(message);
    }
    Map<String, dynamic>? held;
    net.drop = (from, to, body) {
      if (from == a && body['q'] != null) return true;
      if (held == null && from == b && body['q']?['prefix'] != null) {
        held = Map<String, dynamic>.from(body);
        return true;
      }
      return false;
    };
    ma.start();
    mb.start();
    await until(() async => held != null);
    final proposed = Map<String, dynamic>.from(held!['q']['prefix'] as Map);
    final hash = proposed['hash'] as String;
    proposed['hash'] = '${hash[0] == '0' ? '1' : '0'}${hash.substring(1)}';
    await _historyReply(ta, b, held!['id'] as String, {
      'op': 'page',
      'peer': peer.hex,
      'prefix': proposed,
      'events': <String>[],
      'next': null,
    });
    await until(() async => errorJournal.entries.isNotEmpty);
    final progress =
        jsonDecode((await sb.getSetting('device.history.cursor.v2:${a.hex}'))!)
            as Map;
    expect(progress['cursor'], isNull);
    expect(applied, 0);
    expect(await count(), 32);
  });

  test(
    'failed prefix checkpoint requires fresh confirmation after restart',
    () async {
      await seed(24);
      for (final message in (await sa.loadMessages(peer.hex)).take(16)) {
        await sb.appendMessage(message);
      }
      net.drop = (from, to, body) => from == a && body['q'] != null;
      bStore.pageCursorId = 'm0015';
      bStore.refusePageCursor = true;
      ma.start();
      mb.start();
      await until(
        () async => bStore.refused && errorJournal.entries.isNotEmpty,
      );
      expect(await count(), 16);
      final progress =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(progress['cursor'], isNull);
      expect(progress.containsKey('prefix'), isFalse);
      expect(applied, 0);
      await mb.dispose();
      mb = service(tb, sb, a)..start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(await count(), 24);
      expect(applied, 8);
    },
  );

  test('verified prefix can precede an oversized record', () async {
    await seed(10, bodyBytes: 160000);
    for (final message in (await sa.loadMessages(peer.hex)).take(9)) {
      await sb.appendMessage(message);
    }
    ma.start();
    mb.start();
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    final recovered = await sb.loadMessages(peer.hex);
    expect(
      recovered.map((m) => m.id),
      (await sa.loadMessages(peer.hex)).map((m) => m.id),
    );
    expect(recovered.last.body, '9' * 160000);
    expect(applied, 1);
    expect(
      net.history.where(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'record',
      ),
      isNotEmpty,
    );
    expect(errorJournal.entries, isEmpty);
  });

  test('equal content cannot hide a provisional history position', () async {
    await seed(1);
    final original = (await sa.loadMessages(peer.hex)).single;
    await sb.appendMessage(
      Message(
        id: original.id,
        conversationId: original.conversationId,
        direction: original.direction,
        body: original.body,
        timestamp: original.timestamp,
        status: original.status,
        author: identity.hex,
        seq: 99,
        positionVerified: false,
      ),
    );
    ma.start();
    mb.start();
    // Wait for the durable inventory pass, not an arbitrary latency target.
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    final repaired = (await sb.loadMessages(peer.hex)).single;
    expect(repaired.orderAuthor, original.orderAuthor);
    expect(repaired.orderSeq, original.orderSeq);
    expect(repaired.body, original.body);
    expect(repaired.status, original.status);
    expect(
      repaired.author,
      identity.hex,
      reason: 'ordering repair must not promote echo content into authorship',
    );
    expect(repaired.seq, 99);
    expect(await sb.loadEventsSince(peer.hex, a.hex, 0), isEmpty);
    expect(
      net.history.where(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
      ),
      isNotEmpty,
    );
  });

  test('matching repaired ordering does not require raw authorship', () async {
    await seed(1);
    final original = (await sa.loadMessages(peer.hex)).single;
    await sb.appendMessage(
      Message(
        id: original.id,
        conversationId: original.conversationId,
        direction: original.direction,
        body: original.body,
        timestamp: original.timestamp,
        status: original.status,
        author: identity.hex,
        seq: 99,
        positionVerified: false,
      ),
    );
    expect(
      await sb.adoptMessageOrdering(
        peer.hex,
        original.id,
        provisionalAuthor: identity.hex,
        provisionalSeq: 99,
        author: original.orderAuthor!,
        seq: original.orderSeq!,
      ),
      isTrue,
    );
    ma.start();
    mb.start();
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    expect(
      net.history.where(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
      ),
      isEmpty,
    );
    expect(applied, 0);
    final held = (await sb.loadMessages(peer.hex)).single;
    expect(held.orderAuthor, original.orderAuthor);
    expect(held.orderSeq, original.orderSeq);
    expect(held.author, identity.hex);
    expect(held.seq, 99);
  });

  test('equal-revision offline edits converge between own devices', () async {
    await seed(1);
    await sb.appendMessage((await sa.loadMessages(peer.hex)).single);
    await sa.editMessage(peer.hex, 'm0000', 'left', seq: 7);
    await sb.editMessage(peer.hex, 'm0000', 'right', seq: 7);
    ma.start();
    mb.start();
    await until(
      () async =>
          (await sa.loadMessages(peer.hex)).single.body ==
          (await sb.loadMessages(peer.hex)).single.body,
    );
  });

  test(
    'history repairs a held original after the edit left the device journal',
    () async {
      await seed(1);
      await sb.appendMessage((await sa.loadMessages(peer.hex)).single);
      await sa.editMessage(peer.hex, 'm0000', 'offline edit', seq: 7);
      ma.start();
      mb.start();
      await until(
        () async =>
            (await sb.loadMessages(peer.hex)).single.body == 'offline edit',
      );
      expect((await sb.editSeqs(peer.hex))['m0000'], 7);
    },
  );

  test(
    'history repairs a held outgoing row after the delivered event expired',
    () async {
      await seed(1);
      await sb.appendMessage(
        (await sa.loadMessages(
          peer.hex,
        )).single.copyWith(status: MessageStatus.sent),
      );
      ma.start();
      mb.start();
      await until(
        () async =>
            (await sb.loadMessages(peer.hex)).single.status ==
            MessageStatus.delivered,
      );
      expect(await sb.pendingOutboxFrames(), isEmpty);
    },
  );

  test(
    'a stale source cannot replace a newer held edit or undo delivery',
    () async {
      await seed(1, status: MessageStatus.failed);
      final original = (await sa.loadMessages(peer.hex)).single;
      await sb.appendMessage(
        original.copyWith(status: MessageStatus.delivered),
      );
      await sa.editMessage(peer.hex, 'm0000', 'older', seq: 7);
      await sb.editMessage(peer.hex, 'm0000', 'newer', seq: 9);
      // Keep A stale on purpose. B may request A's pages; A cannot learn B's
      // newer snapshot and hide a temporary rollback by sending it back later.
      net.drop = (from, to, frame) => from == b && frame['i'] != null;
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final held = (await sb.loadMessages(peer.hex)).single;
      expect(held.body, 'newer');
      expect(held.status, MessageStatus.delivered);
      expect((await sb.editSeqs(peer.hex))['m0000'], 9);
    },
  );

  test(
    'an edit during snapshot cannot pair the old body with the new frontier',
    () async {
      await seed(1);
      await sb.appendMessage((await sa.loadMessages(peer.hex)).single);
      await sa.editMessage(peer.hex, 'm0000', 'version seven', seq: 7);
      sa.afterMessagesRead = () =>
          sa.editMessage(peer.hex, 'm0000', 'version eight', seq: 8);
      ma.start();
      mb.start();
      await until(
        () async =>
            (await sb.loadMessages(peer.hex)).single.body == 'version eight',
      );
      expect((await sb.editSeqs(peer.hex))['m0000'], 8);
    },
  );

  test(
    'a recovered edited message keeps its edited marker and revision',
    () async {
      await seed(1);
      await sa.editMessage(peer.hex, 'm0000', 'edited before recovery', seq: 7);
      ma.start();
      mb.start();
      await until(() async => (await sb.editSeqs(peer.hex))['m0000'] == 7);
      final held = (await sb.loadMessages(peer.hex)).single;
      expect(held.body, 'edited before recovery');
      expect(held.edited, isTrue);
      expect(held.status, MessageStatus.delivered);
    },
  );

  test(
    'a recovery page cannot resurrect a deleted held message via its edit',
    () async {
      await seed(1);
      await sb.appendMessage((await sa.loadMessages(peer.hex)).single);
      await sb.deleteMessage(peer.hex, 'm0000');
      await sa.editMessage(peer.hex, 'm0000', 'must remain deleted', seq: 7);
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(await sb.isMessageDeleted(peer.hex, 'm0000'), isTrue);
      expect(await sb.loadMessages(peer.hex), isEmpty);
      expect(await sb.loadMessageHistory(peer.hex, 'm0000'), isEmpty);
    },
  );

  test(
    'same-text inline emoji edits retain their metadata and edit frontier',
    () async {
      final message = Message(
        id: 'emoji-edit',
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: kInlineCustomEmojiFallback,
        timestamp: DateTime.utc(2020),
        status: MessageStatus.delivered,
        author: a.hex,
        seq: 1,
        positionVerified: true,
        customEmoji: const [InlineCustomEmoji(offset: 0, dataB64: 'AQ==')],
      );
      await sa.appendMessage(message);
      await sb.appendMessage(message);
      await sa.editMessage(
        peer.hex,
        message.id,
        message.body,
        seq: 7,
        customEmoji: const [InlineCustomEmoji(offset: 0, dataB64: 'Ag==')],
      );
      ma.start();
      mb.start();
      await until(() async => (await sb.editSeqs(peer.hex))[message.id] == 7);
      expect(
        (await sb.loadMessages(peer.hex)).single.customEmoji.single.dataB64,
        'Ag==',
      );
    },
  );

  test(
    'failed delivery-state persistence leaves the page for restart',
    () async {
      await seed(1);
      await sb.appendMessage(
        (await sa.loadMessages(
          peer.hex,
        )).single.copyWith(status: MessageStatus.sent),
      );
      bStore.refuseDelivery = true;
      ma.start();
      mb.start();
      await until(
        () async => bStore.deliveryRefused && errorJournal.entries.isNotEmpty,
      );
      expect(
        (await sb.loadMessages(peer.hex)).single.status,
        MessageStatus.sent,
      );
      final progress =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(progress['peer'], peer.hex);
      expect(progress['cursor'], isNull);
      await restartB();
      await until(
        () async =>
            (await sb.loadMessages(peer.hex)).single.status ==
            MessageStatus.delivered,
      );
    },
  );

  test(
    'inventory continues beyond eight conversations with a bounded cursor',
    () async {
      final peers = [for (var i = 0; i < 10; i++) id(110 + i)];
      for (var i = 0; i < peers.length; i++) {
        final contact = Contact(
          nodeId: peers[i],
          status: ContactStatus.accepted,
        );
        await sa.upsertContact(contact);
        await sb.upsertContact(contact);
        await sa.appendMessage(
          Message(
            id: 'conversation-$i',
            conversationId: peers[i].hex,
            direction: MessageDirection.outgoing,
            body: 'history-$i',
            timestamp: DateTime.utc(2020),
            status: MessageStatus.delivered,
            author: a.hex,
            seq: 1,
            positionVerified: true,
          ),
        );
      }
      ma.start();
      mb.start();
      await until(() async {
        for (var i = 0; i < peers.length; i++) {
          final rows = await sb.loadMessages(peers[i].hex);
          if (rows.length != 1 || rows.single.id != 'conversation-$i') {
            return false;
          }
        }
        return true;
      });
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(applied, peers.length);
      expect(
        net.history
            .where((e) => e.from == b && e.body['q']?['op'] == 'list')
            .length,
        greaterThan(1),
      );
    },
  );

  test(
    'large pages reassemble out of order; repeats create one logical row',
    () async {
      net.reverseParts = true;
      await seed(17, bodyBytes: 6000);
      ma.start();
      mb.start();
      await until(() async => await count() == 17);
      expect(
        (await sb.loadMessages(peer.hex)).map((m) => m.body),
        (await sa.loadMessages(peer.hex)).map((m) => m.body),
      );
      expect(
        (await sb.loadMessages(peer.hex)).map((m) => m.id).toSet(),
        hasLength(17),
      );
    },
  );

  for (final escaped in [false, true]) {
    test(
      'history pages fit bytes when eight ${escaped ? 'escaped UTF-8' : 'long'} messages do not',
      () async {
        net.reverseParts = true;
        await seed(
          17,
          bodyBytes: 20000,
          messageBody: escaped ? List.filled(4500, '\\"🦉').join() : null,
        );
        ma.start();
        mb.start();
        await until(
          () async => await count() == 17 || errorJournal.entries.isNotEmpty,
        );
        expect(
          await count(),
          17,
          reason:
              'a bounded prefix must advance instead of rejecting the whole page',
        );
        final source = await sa.loadMessages(peer.hex);
        final received = await sb.loadMessages(peer.hex);
        expect(received.map((row) => row.id), source.map((row) => row.id));
        expect(received.map((row) => row.body), source.map((row) => row.body));
        expect(
          received.map((row) => row.orderAuthor),
          source.map((row) => row.orderAuthor),
        );
        expect(
          received.map((row) => row.orderSeq),
          source.map((row) => row.orderSeq),
        );
        expect(
          received.every((row) => row.status == MessageStatus.delivered),
          isTrue,
        );
        final replies = <String, Map<int, Map<String, dynamic>>>{};
        for (final frame in net.history.where(
          (frame) => frame.from == a && frame.to == b,
        )) {
          final body = frame.body;
          if (body['i'] case final int index) {
            replies.putIfAbsent(body['id'] as String, () => {})[index] = body;
          }
        }
        var pages = 0;
        for (final parts in replies.values) {
          expect(parts.length, parts[0]!['n']);
          final bytes = BytesBuilder();
          for (var i = 0; i < parts.length; i++) {
            bytes.add(base64Decode(parts[i]!['b'] as String));
          }
          final payload = bytes.takeBytes();
          expect(payload.length, lessThanOrEqualTo(64 * 2048));
          final reply = jsonDecode(utf8.decode(payload)) as Map;
          if (reply['op'] == 'page') {
            pages++;
            expect(reply['events'] as List, hasLength(lessThan(8)));
          }
        }
        expect(pages, greaterThanOrEqualTo(3));
        expect(errorJournal.entries, isEmpty);
      },
    );
  }

  test(
    'restart resumes the byte-limited page cursor without replaying its prefix',
    () async {
      await seed(17, bodyBytes: 20000);
      var hold = true, held = false;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        final query = body['q'];
        if (hold &&
            from == b &&
            query is Map &&
            query['op'] == 'page' &&
            query['cursor'] != null) {
          held = true;
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held && await count() > 0);
      final prefix = await sb.loadMessages(peer.hex);
      expect(prefix.length, inExclusiveRange(0, 8));
      final saved =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      final cursor = [
        prefix.last.timestamp.millisecondsSinceEpoch,
        prefix.last.id,
      ];
      expect(saved['cursor'], cursor);
      final before = net.history.length;
      hold = false;
      await restartB();
      await until(() async => await count() == 17);
      final resumed = net.history
          .skip(before)
          .firstWhere(
            (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
          );
      expect(resumed.body['q']['cursor'], cursor);
      expect(applied, 17);
      expect(
        (await sb.loadMessages(peer.hex)).map((row) => row.id),
        (await sa.loadMessages(peer.hex)).map((row) => row.id),
      );
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'one oversized history event does not block its following messages',
    () async {
      await seed(3);
      await sa.editMessage(
        peer.hex,
        'm0001',
        List.filled(160000, 'z').join(),
        seq: 7,
      );
      net.reverseParts = true;
      ma.start();
      mb.start();
      await until(
        () async => await count() == 3 || errorJournal.entries.isNotEmpty,
      );
      expect(await count(), 3);
      final expected = await sa.loadMessages(peer.hex);
      final got = await sb.loadMessages(peer.hex);
      expect(got.map((row) => row.id), expected.map((row) => row.id));
      expect(got.map((row) => row.body), expected.map((row) => row.body));
      expect(
        got.map((row) => row.orderAuthor),
        expected.map((row) => row.orderAuthor),
      );
      expect(
        got.map((row) => row.orderSeq),
        expected.map((row) => row.orderSeq),
      );
      expect((await sb.editSeqs(peer.hex))['m0001'], 7);
      expect(got.every((row) => row.status == MessageStatus.delivered), isTrue);
      expect(applied, 3);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'restart discards a partial record and keeps its preceding durable cursor',
    () async {
      await seed(3);
      await sa.editMessage(peer.hex, 'm0001', 'x' * 160000, seq: 4);
      var hold = true, held = false;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        final q = body['q'];
        if (hold &&
            from == b &&
            q is Map &&
            q['op'] == 'record' &&
            q['offset'] == 65536) {
          held = true;
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held);
      expect(await count(), 1);
      final progress =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect((progress['cursor'] as List)[1], 'm0000');
      final before = net.history.length;
      hold = false;
      await restartB();
      await until(() async => await count() == 3);
      final first = net.history
          .skip(before)
          .firstWhere(
            (frame) => frame.from == b && frame.body['q']?['op'] == 'record',
          );
      expect(first.body['q']['offset'], 0);
      expect(applied, 3);
      expect((await sb.loadMessageById(peer.hex, 'm0001'))!.body, 'x' * 160000);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'editing a partial record restarts it without mixing revisions',
    () async {
      await seed(1, bodyBytes: 160000);
      Map<String, dynamic>? held;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        final q = body['q'];
        if (held == null &&
            from == b &&
            q is Map &&
            q['op'] == 'record' &&
            q['offset'] == 65536) {
          held = Map<String, dynamic>.from(body);
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held != null);
      expect(await count(), 0);
      await sa.editMessage(peer.hex, 'm0000', 'n' * 160000, seq: 9);
      await net.send(
        tb,
        a,
        WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
      );
      await until(() async => await count() == 1);
      expect((await sb.loadMessageById(peer.hex, 'm0000'))!.body, 'n' * 160000);
      expect((await sb.editSeqs(peer.hex))['m0000'], 9);
      expect(applied, 1);
      expect(
        net.history
            .where(
              (frame) => frame.from == b && frame.body['q']?['op'] == 'record',
            )
            .map((frame) => frame.body['q']['hash'])
            .toSet(),
        hasLength(2),
      );
      expect(errorJournal.entries, isEmpty);
    },
  );

  test('partial record cannot revive expired content', () async {
    await seed(
      1,
      bodyBytes: 160000,
      at: now.subtract(const Duration(seconds: 1)),
    );
    await sa.upsertContact(
      (await sa.getContact(peer))!.copyWith(disappearingTtlSeconds: 5),
    );
    Map<String, dynamic>? held;
    net.drop = (from, to, body) {
      if (from == a && body['q'] != null) return true;
      final q = body['q'];
      if (held == null &&
          from == b &&
          q is Map &&
          q['op'] == 'record' &&
          q['offset'] == 65536) {
        held = Map<String, dynamic>.from(body);
        return true;
      }
      return false;
    };
    ma.start();
    mb.start();
    await until(() async => held != null);
    now = now.add(const Duration(seconds: 10));
    await net.send(
      tb,
      a,
      WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
    );
    await until(
      () async =>
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    expect(await count(), 0);
    expect(applied, 0);
    expect(errorJournal.entries, isEmpty);
  });

  test(
    'digest failures release record credit and never advance the cursor',
    () async {
      await seed(1, bodyBytes: 500000);
      Map<String, dynamic>? held;
      var corrupt = true;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        final q = body['q'];
        if (corrupt &&
            held == null &&
            from == b &&
            q is Map &&
            q['op'] == 'record' &&
            q['offset'] == 0) {
          held = Map<String, dynamic>.from(body);
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      for (var attempt = 0; attempt < 9; attempt++) {
        await until(() async => held != null);
        final q = held!['q'] as Map;
        await _historyReply(ta, b, held!['id'] as String, {
          'op': 'record',
          'peer': peer.hex,
          'key': 'm0000',
          'hash': q['hash'],
          'offset': 0,
          'data': base64Encode(Uint8List(65536)),
        });
        await until(() async => errorJournal.entries.isNotEmpty);
        expect(await count(), 0);
        expect(applied, 0);
        final progress =
            jsonDecode(
                  (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
                )
                as Map;
        expect(progress['cursor'], isNull);
        errorJournal.clear();
        held = null;
        if (attempt == 8) corrupt = false;
        now = now.add(const Duration(minutes: 6));
        tb.incoming.add(
          InboundMessage(
            src: identity,
            srcDevice: a,
            provenance: SenderProvenance.signed,
            payload: WireEnvelope.presence(a.hex).encode(),
          ),
        );
      }
      await until(() async => await count() == 1);
      expect((await sb.loadMessageById(peer.hex, 'm0000'))!.body, '0' * 500000);
      expect(applied, 1);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'record descriptors reserve at most four MiB and binding change releases them',
    () async {
      final sources = [
        ta,
        for (var i = 100; i < 104; i++) _Endpoint(net, id(i)),
      ];
      for (final endpoint in sources.skip(1)) {
        addTearDown(endpoint.dispose);
      }
      bSiblings = sources.map((source) => source.me).toList();
      mb.start();
      await until(
        () async =>
            net.history
                .where(
                  (frame) =>
                      frame.from == b && frame.body['q']?['op'] == 'list',
                )
                .length ==
            5,
      );
      for (final source in sources) {
        final ask = net.history.lastWhere(
          (frame) =>
              frame.from == b &&
              frame.to == source.me &&
              frame.body['q']?['op'] == 'list',
        );
        await _historyReply(source, b, ask.body['id'] as String, {
          'op': 'list',
          'rows': [
            {'peer': peer.hex, 'count': 1, 'hash': '0' * 64},
          ],
        });
      }
      await until(
        () async =>
            net.history
                .where(
                  (frame) =>
                      frame.from == b && frame.body['q']?['op'] == 'page',
                )
                .length ==
            5,
      );
      Map<String, dynamic> descriptor() => {
        'op': 'page',
        'peer': peer.hex,
        'record': {
          'position': [DateTime.utc(2020).millisecondsSinceEpoch, 'record'],
          'bytes': 1024 * 1024,
          'hash': '1' * 64,
        },
      };
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i];
        final ask = net.history.lastWhere(
          (frame) =>
              frame.from == b &&
              frame.to == source.me &&
              frame.body['q']?['op'] == 'page',
        );
        await _historyReply(source, b, ask.body['id'] as String, descriptor());
        if (i < 4) {
          await until(
            () async => net.history.any(
              (frame) =>
                  frame.from == b &&
                  frame.to == source.me &&
                  frame.body['q']?['op'] == 'record',
            ),
          );
        }
      }
      // All fixture roster/storage futures complete in microtasks. Drain the
      // turn after the last descriptor; this is an event barrier, not a speed gate.
      await Future<void>(() {});
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'record',
        ),
        hasLength(4),
      );
      final before = net.history.length;
      mb.groupBindingsOwner = Object();
      mb.onOwnDeviceHistoryReady(mb.groupBindingsOwner!);
      now = now.add(const Duration(seconds: 31));
      for (final source in sources) {
        tb.incoming.add(
          InboundMessage(
            src: identity,
            srcDevice: source.me,
            provenance: SenderProvenance.signed,
            payload: WireEnvelope.presence(source.me.hex).encode(),
          ),
        );
      }
      final fifth = sources.last;
      await until(
        () async => net.history
            .skip(before)
            .any(
              (frame) =>
                  frame.from == b &&
                  frame.to == fifth.me &&
                  frame.body['q']?['op'] == 'list',
            ),
      );
      final inventory = net.history.lastWhere(
        (frame) =>
            frame.from == b &&
            frame.to == fifth.me &&
            frame.body['q']?['op'] == 'list',
      );
      await _historyReply(fifth, b, inventory.body['id'] as String, {
        'op': 'list',
        'rows': [
          {'peer': peer.hex, 'count': 1, 'hash': '0' * 64},
        ],
      });
      await until(
        () async => net.history
            .skip(before)
            .any(
              (frame) =>
                  frame.from == b &&
                  frame.to == fifth.me &&
                  frame.body['q']?['op'] == 'page',
            ),
      );
      final ask = net.history.lastWhere(
        (frame) =>
            frame.from == b &&
            frame.to == fifth.me &&
            frame.body['q']?['op'] == 'page',
      );
      await _historyReply(fifth, b, ask.body['id'] as String, descriptor());
      await until(
        () async => net.history
            .skip(before)
            .any(
              (frame) =>
                  frame.from == b &&
                  frame.to == fifth.me &&
                  frame.body['q']?['op'] == 'record',
            ),
      );
      expect(await count(), 0);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'oversized record descriptors leave the durable cursor in place',
    () async {
      await seed(1, bodyBytes: 160000);
      Map<String, dynamic>? held;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        if (held == null && from == b && body['q']?['op'] == 'page') {
          held = Map<String, dynamic>.from(body);
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held != null);
      await _historyReply(ta, b, held!['id'] as String, {
        'op': 'page',
        'peer': peer.hex,
        'record': {
          'position': [DateTime.utc(2020).millisecondsSinceEpoch, 'm0000'],
          'bytes': 1024 * 1024 + 1,
          'hash': '1' * 64,
        },
      });
      await until(() async => errorJournal.entries.isNotEmpty);
      expect(await count(), 0);
      expect(
        net.history.where(
          (frame) => frame.from == b && frame.body['q']?['op'] == 'record',
        ),
        isEmpty,
      );
      final progress =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(progress['cursor'], isNull);
    },
  );

  test(
    'revoked source cannot complete a partial record across binding replacement',
    () async {
      await seed(1, bodyBytes: 160000);
      Map<String, dynamic>? held;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        final q = body['q'];
        if (held == null &&
            from == b &&
            q is Map &&
            q['op'] == 'record' &&
            q['offset'] == 65536) {
          held = Map<String, dynamic>.from(body);
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held != null);
      final rejected = Completer<void>();
      bSiblings = [];
      mb.myOtherDevices = () async {
        if (!rejected.isCompleted) rejected.complete();
        return bSiblings;
      };
      await net.send(
        tb,
        a,
        WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
      );
      await rejected.future;
      await Future<void>(() {});
      expect(await count(), 0);
      final progress =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(progress['cursor'], isNull);
      await sa.editMessage(peer.hex, 'm0000', 'fresh' * 40000, seq: 10);
      bSiblings = [a];
      mb.groupBindingsOwner = Object();
      mb.onOwnDeviceHistoryReady(mb.groupBindingsOwner!);
      now = now.add(const Duration(seconds: 31));
      tb.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: a,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.presence(a.hex).encode(),
        ),
      );
      await until(() async => await count() == 1);
      expect(
        (await sb.loadMessageById(peer.hex, 'm0000'))!.body,
        'fresh' * 40000,
      );
      expect((await sb.editSeqs(peer.hex))['m0000'], 10);
      expect(applied, 1);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test(
    'a valid record request still requires current source-side authorization',
    () async {
      await seed(1, bodyBytes: 160000);
      Map<String, dynamic>? held;
      net.drop = (from, to, body) {
        if (from == a && body['q'] != null) return true;
        final q = body['q'];
        if (held == null &&
            from == b &&
            q is Map &&
            q['op'] == 'record' &&
            q['offset'] == 65536) {
          held = Map<String, dynamic>.from(body);
          return true;
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(() async => held != null);
      final checked = Completer<void>();
      ma.myOtherDevices = () async {
        if (!checked.isCompleted) checked.complete();
        return [];
      };
      final before = net.history.length;
      await net.send(
        tb,
        a,
        WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
      );
      await checked.future;
      await Future<void>(() {});
      expect(
        net.history
            .skip(before)
            .where((frame) => frame.from == a && frame.body['i'] != null),
        isEmpty,
      );
      expect(await count(), 0);
      ma.myOtherDevices = () async => [b];
      await net.send(
        tb,
        a,
        WireEnvelope.deviceHistory(jsonEncode(held)).encode(),
      );
      await until(() async => await count() == 1);
      expect(applied, 1);
      expect(errorJournal.entries, isEmpty);
    },
  );

  test('short history uses bounded pages of thirty-two messages', () async {
    await seed(65);
    ma.start();
    mb.start();
    await until(
      () async =>
          await count() == 65 &&
          await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
    );
    final requests = net.history
        .where((frame) => frame.from == b && frame.body['q']?['op'] == 'page')
        .toList();
    expect(requests, hasLength(3));
    expect(applied, 65);
    expect(errorJournal.entries, isEmpty);
  });

  test(
    'revocation at the prepared storage boundary refuses all unpublished rows',
    () async {
      await seed(32);
      var checked = false;
      sb.beforePreparedCommit = () async {
        checked = true;
        bSiblings = [];
      };
      ma.start();
      mb.start();
      await until(() async => checked && errorJournal.entries.isNotEmpty);
      expect(await count(), 0);
      expect(applied, 0);
      expect(bStore.postBatches, isEmpty);
      final saved =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(saved['cursor'], isNull);
    },
  );

  test('an over-cap page is rejected before applying any message', () async {
    await seed(33);
    // Only B runs; A's replies are supplied explicitly below.
    mb.start();
    await until(
      () async => net.history.any(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
      ),
    );
    final inventory = net.history.lastWhere(
      (frame) => frame.from == b && frame.body['q']?['op'] == 'list',
    );
    await _historyReply(ta, b, inventory.body['id'] as String, {
      'op': 'list',
      'rows': [
        {'peer': peer.hex, 'count': 33, 'hash': '0' * 64},
      ],
    });
    await until(
      () async => net.history.any(
        (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
      ),
    );
    final request = net.history.lastWhere(
      (frame) => frame.from == b && frame.body['q']?['op'] == 'page',
    );
    await _historyReply(ta, b, request.body['id'] as String, {
      'op': 'page',
      'peer': peer.hex,
      'events': [
        for (final row in await sa.loadMessages(peer.hex))
          deviceMirrorOf(peer.hex, row).event.toBody(),
      ],
      'next': null,
    });
    await until(() async => errorJournal.entries.isNotEmpty);
    expect(await count(), 0);
    expect(applied, 0);
    final saved =
        jsonDecode((await sb.getSetting('device.history.cursor.v2:${a.hex}'))!)
            as Map;
    expect(saved['cursor'], isNull);
  });

  test(
    'revocation within a larger page leaves its cursor uncommitted',
    () async {
      await seed(65);
      beforeApply = (event) async {
        if (event.key == 'm0019') bSiblings = [];
      };
      ma.start();
      mb.start();
      await until(
        () async => await count() == 16 && errorJournal.entries.isNotEmpty,
      );
      final saved =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(saved['cursor'], isNull);
      // The next cohort was prepared, but revocation prevents its entire
      // publication. Only the first durable cohort is allowed to survive.
      expect(applied, 16);
      expect(bStore.postBatches, [16]);
      expect(await sb.loadMessageById(peer.hex, 'm0016'), isNull);
    },
  );

  test('restart continues the acknowledged durable page cursor', () async {
    await seed(96);
    var held = false;
    net.drop = (from, to, body) {
      final q = body['q'];
      if (from == b &&
          q is Map &&
          q['op'] == 'page' &&
          q['cursor'] is List &&
          (q['cursor'] as List)[1] == 'm0063') {
        held = true;
        return true;
      }
      return false;
    };
    ma.start();
    mb.start();
    await until(() async => held && await count() == 64);
    final mark = net.history.length;
    net.drop = null;
    await restartB();
    await until(() async => await count() == 96);
    final resumed =
        net.history
                .skip(mark)
                .firstWhere((e) => e.from == b && e.body['q']?['op'] == 'page')
                .body['q']
            as Map;
    expect((resumed['cursor'] as List)[1], 'm0063');
    expect(applied, 96);
  });

  test(
    'failed page apply does not advance; restart retries missing rows',
    () async {
      await seed(20);
      var refused = false;
      beforeApply = (event) async {
        if (event.key == 'm0003' && !refused) {
          refused = true;
          throw StateError('/private/secret-path secret-id');
        }
      };
      ma.start();
      mb.start();
      await until(() async => refused && errorJournal.entries.isNotEmpty);
      final cursor = await sb.getSetting('device.history.cursor.v2:${a.hex}');
      expect(jsonDecode(cursor!)['cursor'], isNull);
      expect(
        errorJournal.entries.map((e) => e.message).join(),
        isNot(contains('secret')),
      );
      beforeApply = null;
      await restartB();
      await until(() async => await count() == 20);
      expect(
        (await sb.loadMessages(peer.hex)).map((m) => m.id).toSet(),
        hasLength(20),
      );
    },
  );

  test('failed durable cursor write retries the page after restart', () async {
    await seed(65);
    bStore.refusePageCursor = true;
    bStore.pageCursorId = 'm0031';
    ma.start();
    mb.start();
    await until(() async => bStore.refused && errorJournal.entries.isNotEmpty);
    expect(await count(), 32);
    final cursor =
        jsonDecode((await sb.getSetting('device.history.cursor.v2:${a.hex}'))!)
            as Map;
    expect(cursor['cursor'], isNull);
    await restartB();
    await until(() async => await count() == 65);
    expect(
      (await sb.loadMessages(peer.hex)).map((m) => m.id).toSet(),
      hasLength(65),
    );
  });

  test(
    'a new binding restarts an unfinished pull without using the old session',
    () async {
      await seed(20);
      final entered = Completer<void>(), release = Completer<void>();
      beforeApply = (event) async {
        if (event.key == 'm0003') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
      };
      ma.start();
      mb.start();
      await entered.future.timeout(const Duration(seconds: 8));
      mb.groupBindingsOwner = Object();
      mb.onOwnDeviceHistoryReady(mb.groupBindingsOwner!);
      beforeApply = null;
      now = now.add(const Duration(seconds: 31));
      tb.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: a,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.presence(a.hex).encode(),
        ),
      );
      release.complete();
      await until(() async => await count() == 20);
      expect(
        (await sb.loadMessages(peer.hex)).map((m) => m.id).toSet(),
        hasLength(20),
      );
    },
  );

  test(
    'an already completed matching inventory does not resend message pages',
    () async {
      await seed(16);
      ma.start();
      mb.start();
      await until(() async => await count() == 16);
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      final pages = net.history
          .where((e) => e.from == b && e.body['q']?['op'] == 'page')
          .length;
      final requests = net.history.length;
      now = now.add(const Duration(seconds: 31));
      tb.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: a,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.presence(a.hex).encode(),
        ),
      );
      await until(() async => net.history.length > requests + 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        net.history
            .where((e) => e.from == b && e.body['q']?['op'] == 'page')
            .length,
        pages,
      );
    },
  );

  InboundMessage historyRequest(int nonce, {int padding = 0}) => InboundMessage(
    src: identity,
    srcDevice: b,
    provenance: SenderProvenance.signed,
    payload: WireEnvelope.deviceHistory(
      jsonEncode({
        'v': 1,
        'd': b.hex,
        'id': nonce.toRadixString(16).padLeft(32, '0'),
        'q': {'op': 'list', if (padding > 0) 'padding': 'x' * padding},
      }),
    ).encode(),
  );

  Future<void> requestSourcePage(String requestId) async {
    ma.start(); // The requester deliberately has no listener or pull task.
    await Future<void>(() {});
    ta.incoming.add(
      InboundMessage(
        src: identity,
        srcDevice: b,
        provenance: SenderProvenance.signed,
        payload: WireEnvelope.deviceHistory(
          jsonEncode({
            'v': 1,
            'd': b.hex,
            'id': requestId,
            'q': {'op': 'page', 'peer': peer.hex, 'cursor': null},
          }),
        ).encode(),
      ),
    );
  }

  test(
    'local page encoding does not reread the roster for every row',
    () async {
      await seed(32);
      final encode = ma.ownHistoryEncode!;
      var encoded = 0, rosterReads = 0, readsAtFirst = 0;
      final entered = Completer<void>(), release = Completer<void>();
      ma.myOtherDevices = () async {
        rosterReads++;
        return [b];
      };
      ma.ownHistoryEncode = (peer, message) async {
        encoded++;
        if (encoded == 1) readsAtFirst = rosterReads;
        if (encoded == 32) {
          entered.complete();
          await release.future;
        }
        return encode(peer, message);
      };
      const requestId = 'cccccccccccccccccccccccccccccccc';
      await requestSourcePage(requestId);
      await entered.future;
      try {
        expect(encoded, 32);
        expect(
          rosterReads - readsAtFirst,
          0,
          reason: 'bounded local encoding must not pay for 31 fresh journals',
        );
        expect(net.history.where((e) => e.body['id'] == requestId), isEmpty);
      } finally {
        release.complete();
      }
      await until(() async {
        final parts = net.history.where((e) => e.body['id'] == requestId);
        return parts.isNotEmpty && parts.length == parts.first.body['n'];
      });
      final parts = net.history
          .where((e) => e.body['id'] == requestId)
          .toList();
      expect(
        rosterReads - readsAtFirst,
        greaterThanOrEqualTo(parts.length),
        reason: 'each disclosed part must still obtain fresh authorization',
      );
    },
  );

  test('a revoke during page encoding refuses every reply part', () async {
    await seed(32);
    var live = true, encoded = 0;
    final encode = ma.ownHistoryEncode!;
    final entered = Completer<void>(), release = Completer<void>();
    final rechecked = Completer<void>();
    ma.myOtherDevices = () async {
      if (!live && !rechecked.isCompleted) rechecked.complete();
      return live ? [b] : [];
    };
    ma.ownHistoryEncode = (peer, message) async {
      if (++encoded == 32) {
        entered.complete();
        await release.future;
      }
      return encode(peer, message);
    };
    const requestId = 'dddddddddddddddddddddddddddddddd';
    final sent = Completer<void>();
    net.drop = (_, _, body) {
      if (body['id'] == requestId && !sent.isCompleted) sent.complete();
      return false;
    };
    await requestSourcePage(requestId);
    await entered.future;
    live = false;
    release.complete();
    await Future.any([rechecked.future, sent.future]);
    await Future<void>(() {});
    expect(rechecked.isCompleted, isTrue);
    expect(sent.isCompleted, isFalse);
    expect(net.history.where((e) => e.body['id'] == requestId), isEmpty);
  });

  test(
    'revoke prevents subsequent inline-file preparation within a page',
    () async {
      await seed(1);
      await sa.appendMessage(
        Message(
          id: 'inline-file',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: 'attachment',
          timestamp: DateTime.utc(2020).add(const Duration(seconds: 1)),
          status: MessageStatus.delivered,
          fileId: 'fixture-local-blob',
        ),
      );
      var live = true;
      final rechecked = Completer<void>(), encodedFile = Completer<void>();
      ma.myOtherDevices = () async {
        if (!live && !rechecked.isCompleted) rechecked.complete();
        return live ? [b] : [];
      };
      final encode = ma.ownHistoryEncode!;
      ma.ownHistoryEncode = (peer, message) async {
        if (message.fileId != null) encodedFile.complete();
        final event = await encode(peer, message);
        live = false;
        return event;
      };
      const requestId = 'ffffffffffffffffffffffffffffffff';
      await requestSourcePage(requestId);
      await Future.any([rechecked.future, encodedFile.future]);
      await Future<void>(() {});
      expect(
        encodedFile.isCompleted,
        isFalse,
        reason:
            'inline-file encoding may register content, so it needs a fresh gate',
      );
      expect(net.history.where((e) => e.body['id'] == requestId), isEmpty);
    },
  );

  test(
    'a replacement binding stops a locally encoded page before its next row',
    () async {
      await seed(32);
      var encoded = 0;
      final encode = ma.ownHistoryEncode!;
      final entered = Completer<void>(), release = Completer<void>();
      final resumed = Completer<void>();
      ma.ownHistoryEncode = (peer, message) async {
        if (++encoded == 1) {
          entered.complete();
          await release.future;
          resumed.complete();
        }
        return encode(peer, message);
      };
      const requestId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      await requestSourcePage(requestId);
      await entered.future;
      ma.groupBindingsOwner = Object();
      ma.onOwnDeviceHistoryReady(ma.groupBindingsOwner!);
      release.complete();
      await resumed.future;
      await Future<void>(() {});
      expect(encoded, 1);
      expect(net.history.where((e) => e.body['id'] == requestId), isEmpty);
    },
  );

  Future<Completer<void>> holdHistoryAdmission({
    List<NodeId> Function()? roster,
    bool failOnRelease = false,
  }) async {
    ma.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final entered = Completer<void>(), release = Completer<void>();
    ma.isOwnDevice = (node) async => node == identity || node == b;
    ma.myOtherDevices = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      if (failOnRelease) throw StateError('fixture history close failure');
      return roster?.call() ?? [b];
    };
    ta.incoming.add(historyRequest(0));
    await entered.future.timeout(const Duration(seconds: 1));
    return release;
  }

  test(
    'history work is frame-bounded, coalesced and joined during shutdown',
    () async {
      final release = await holdHistoryAdmission();
      final budget = ma.historyInboundAdmission;
      try {
        for (var i = 0; i < 40; i++) {
          ta.incoming.add(historyRequest(0));
        }
        await until(() async => budget.coalescedFrames >= 40);
        expect(budget.queuedFrames, 1);
        for (var i = 1; i <= budget.maxFrames + 10; i++) {
          ta.incoming.add(historyRequest(i));
        }
        await until(() async => budget.droppedFrames > 0);
        expect(budget.queuedFrames, budget.maxFrames);
        expect(budget.queuedBytes, lessThanOrEqualTo(budget.maxBytes));
        await ma
            .deliverInbound(
              InboundMessage(
                src: peer,
                provenance: SenderProvenance.signed,
                payload: const WireEnvelope.message(
                  'chat survives history flood',
                  id: 'live-behind-flood',
                  seq: 0,
                ).encode(),
              ),
            )
            .timeout(const Duration(seconds: 1));
        expect(
          (await sa.loadMessageById(peer.hex, 'live-behind-flood'))?.body,
          'chat survives history flood',
        );
        final closing = ma.dispose();
        expect(budget.isClosed, isTrue);
        release.complete();
        await closing;
        expect(budget.queuedFrames, 0);
        expect(budget.queuedBytes, 0);
        expect(
          net.history.where(
            (entry) => entry.from == a && entry.body['i'] != null,
          ),
          isEmpty,
          reason: 'close revokes queued history work before disclosure',
        );
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test(
    'history admission also bounds bytes for one authenticated sender',
    () async {
      final release = await holdHistoryAdmission();
      final budget = ma.historyInboundAdmission;
      try {
        for (var i = 1; i <= 100; i++) {
          ta.incoming.add(historyRequest(i, padding: 4300));
        }
        await until(() async => budget.droppedFrames > 0);
        expect(budget.queuedBytes, lessThanOrEqualTo(budget.maxKnownPeerBytes));
        expect(budget.queuedFrames, lessThan(budget.maxFrames));
        final closing = ma.dispose();
        release.complete();
        await closing;
        expect(budget.queuedFrames, 0);
        expect(budget.queuedBytes, 0);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test(
    'revocation refuses history requests already waiting in its lane',
    () async {
      var liveDevices = [b];
      final release = await holdHistoryAdmission(roster: () => liveDevices);
      try {
        ta.incoming.add(historyRequest(1));
        await until(() async => ma.historyInboundAdmission.queuedFrames == 2);
        liveDevices = [];
        release.complete();
        await until(() async => ma.historyInboundAdmission.queuedFrames == 0);
        expect(
          net.history.where(
            (entry) => entry.from == a && entry.body['i'] != null,
          ),
          isEmpty,
        );
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test('a failing history read cannot abort messaging shutdown', () async {
    final release = await holdHistoryAdmission(failOnRelease: true);
    try {
      final closing = ma.dispose();
      release.complete();
      await closing;
      expect(ma.historyInboundAdmission.queuedFrames, 0);
      expect(ma.historyInboundAdmission.queuedBytes, 0);
      expect(
        errorJournal.entries.where((entry) => entry.kind == 'device-history'),
        isNotEmpty,
      );
    } finally {
      if (!release.isCompleted) release.complete();
    }
  });

  test('a failed history handler does not poison its next request', () async {
    ma.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ma.isOwnDevice = (node) async => node == identity || node == b;
    var fail = true;
    ma.myOtherDevices = () async {
      if (fail) {
        fail = false;
        throw StateError('fixture history admission failure');
      }
      return [b];
    };
    ta.incoming.add(historyRequest(1));
    ta.incoming.add(historyRequest(2));
    await until(
      () async => net.history.any(
        (entry) =>
            entry.from == a &&
            entry.body['id'] == '2'.padLeft(32, '0') &&
            entry.body['i'] != null,
      ),
    );
    expect(
      errorJournal.entries.where((entry) => entry.kind == 'device-history'),
      isNotEmpty,
    );
    expect(
      net.history.where(
        (entry) =>
            entry.from == a &&
            entry.body['id'] == '1'.padLeft(32, '0') &&
            entry.body['i'] != null,
      ),
      isEmpty,
    );
  });

  test(
    'a large reversed history page fits the dedicated admission budget',
    () async {
      net.reverseParts = true;
      await seed(8, bodyBytes: 12000);
      ma.start();
      mb.start();
      await until(() async => (await sb.loadMessages(peer.hex)).length == 8);
      expect(
        (await sb.loadMessages(
          peer.hex,
        )).every((row) => row.body.length == 12000),
        isTrue,
      );
    },
  );

  test(
    'retained history slices do not repeat roster reads or starve the tail',
    () async {
      Map<String, dynamic>? firstPart;
      var dropTail = true;
      net.drop = (from, to, body) {
        if (from != a || to != b) return false;
        if (body['q'] != null) return true; // Only B initiates this recovery.
        if (body['i'] is int && (body['n'] as int) > 1) {
          if (body['i'] == 0) firstPart ??= Map<String, dynamic>.of(body);
          return dropTail && body['i'] != 0;
        }
        return false;
      };
      var rosterReads = 0;
      mb.myOtherDevices = () async {
        rosterReads++;
        return [a];
      };
      await seed(17, bodyBytes: 6000);
      ma.start();
      mb.start();
      await until(
        () async =>
            firstPart != null &&
            mb.historyInboundAdmission.queuedFrames == 0 &&
            mb.inboundAdmission.queuedFrames == 0,
      );
      final before = rosterReads;
      for (var i = 0; i < 20; i++) {
        tb.incoming.add(
          InboundMessage(
            src: identity,
            srcDevice: a,
            provenance: SenderProvenance.signed,
            payload: WireEnvelope.deviceHistory(jsonEncode(firstPart)).encode(),
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      await until(
        () async =>
            mb.historyInboundAdmission.queuedFrames == 0 &&
            mb.inboundAdmission.queuedFrames == 0,
      );
      expect(
        rosterReads,
        before,
        reason: 'an already held slice needs no new grant or journal read',
      );
      dropTail = false;
      await until(() async => (await sb.loadMessages(peer.hex)).length == 17);
    },
  );

  test(
    'slow sibling history admission does not hold ordinary messages',
    () async {
      ma.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final entered = Completer<void>(), release = Completer<void>();
      ma.isOwnDevice = (node) async => node == identity || node == b;
      ma.myOtherDevices = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return [b];
      };
      ta.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: b,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.deviceHistory(
            jsonEncode({
              'v': 1,
              'd': b.hex,
              'id': 'a' * 32,
              'q': {'op': 'list'},
            }),
          ).encode(),
        ),
      );
      try {
        await entered.future.timeout(const Duration(seconds: 1));
        await ma
            .deliverInbound(
              InboundMessage(
                src: peer,
                provenance: SenderProvenance.signed,
                payload: const WireEnvelope.message(
                  'live while history waits',
                  id: 'live-behind-history',
                  seq: 0,
                ).encode(),
              ),
            )
            .timeout(const Duration(seconds: 1));
        expect(
          (await sa.loadMessageById(peer.hex, 'live-behind-history'))?.body,
          'live while history waits',
        );
      } finally {
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    },
  );

  test(
    'claimed, wrong-device and revoked requests disclose no history',
    () async {
      await seed(10);
      ma.start(); // B intentionally has no inbound listener yet.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final baseline = net.history.length;
      final body = jsonEncode({
        'v': 1,
        'd': b.hex,
        'id': '1' * 32,
        'q': {'op': 'list'},
      });
      for (final frame in [
        InboundMessage(
          src: identity,
          srcDevice: b,
          payload: WireEnvelope.deviceHistory(body).encode(),
        ),
        InboundMessage(
          src: identity,
          srcDevice: peer,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.deviceHistory(body).encode(),
        ),
        InboundMessage(
          src: peer,
          srcDevice: b,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.deviceHistory(body).encode(),
        ),
      ]) {
        ta.incoming.add(frame);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(net.history.length, baseline);
      // Mailbox ingestion refuses this live-only protocol even with valid auth.
      await ma.deliverInbound(
        InboundMessage(
          src: identity,
          srcDevice: b,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.deviceHistory(body).encode(),
        ),
      );
      expect(net.history.length, baseline);
      ma.myOtherDevices = () async => [];
      ta.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: b,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.deviceHistory(body).encode(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(net.history.length, baseline);
      ma.myOtherDevices = () async => [b];
      ta.incoming.add(
        InboundMessage(
          src: identity,
          srcDevice: b,
          provenance: SenderProvenance.signed,
          payload: WireEnvelope.deviceHistory(body).encode(),
        ),
      );
      await until(
        () async => net.history
            .skip(baseline)
            .any((e) => e.from == a && e.body['i'] != null),
      );
    },
  );

  test(
    'expired source history is not copied before the background sweep',
    () async {
      await seed(16);
      final contact = (await sa.getContact(peer))!;
      await sa.upsertContact(contact.copyWith(disappearingTtlSeconds: 5));
      ma.start();
      mb.start();
      await until(
        () async =>
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(await count(), 0);
      expect(
        net.history.where((e) => e.from == b && e.body['q']?['op'] == 'page'),
        isEmpty,
      );
    },
  );

  test(
    'a delayed cached page cannot bring back expired source content',
    () async {
      await seed(1, at: now.subtract(const Duration(seconds: 2)));
      final contact = (await sa.getContact(peer))!;
      await sa.upsertContact(contact.copyWith(disappearingTtlSeconds: 5));
      var delayedPage = false;
      net.drop = (from, to, frame) {
        if (from == a && frame['i'] != null) {
          final reply =
              jsonDecode(utf8.decode(base64Decode(frame['b'] as String)))
                  as Map;
          if (reply['op'] == 'page') {
            delayedPage = true;
            now = now.add(const Duration(seconds: 10));
          }
        }
        return false;
      };
      ma.start();
      mb.start();
      await until(
        () async =>
            delayedPage &&
            await sb.getSetting('device.history.cursor.v2:${a.hex}') == '{}',
      );
      expect(await count(), 0);
      expect(applied, 0);
    },
  );

  test(
    'revocation stops the remaining page and leaves its cursor uncommitted',
    () async {
      await seed(20);
      final entered = Completer<void>(), release = Completer<void>();
      beforeApply = (event) async {
        if (event.key == 'm0003') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
      };
      ma.start();
      mb.start();
      await entered.future.timeout(const Duration(seconds: 8));
      bSiblings.clear();
      release.complete();
      await until(() async => errorJournal.entries.isNotEmpty);
      expect(await count(), lessThanOrEqualTo(4));
      final cursor =
          jsonDecode(
                (await sb.getSetting('device.history.cursor.v2:${a.hex}'))!,
              )
              as Map;
      expect(cursor['cursor'], isNull);
    },
  );
}
