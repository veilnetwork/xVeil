import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
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
  final parts = <String, List<InboundMessage>>{};

  Future<void> send(_Endpoint from, NodeId to, Uint8List bytes) async {
    final env = WireEnvelope.decode(bytes);
    final target = endpoints[to];
    if (target == null || target.closed) return;
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
  @override
  Future<NodeId> nodeId() async => me;
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
  bool refused = false;
  bool refuseDelivery = false;
  bool deliveryRefused = false;

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
              utf8.decode(op.value).contains('m0007'),
        )) {
      refusePageCursor = false;
      refused = true;
      throw StateError('fixture cursor write failure');
    }
    return super.commit(ops);
  }
}

class _SnapshotStorage extends HiddenVolumeStorage {
  _SnapshotStorage(super.opener);
  Future<void> Function()? afterMessagesRead;

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
  final parts = (bytes.length + 2047) ~/ 2048;
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
            bytes.sublist(i * 2048, ((i + 1) * 2048).clamp(0, bytes.length)),
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
    m.ownHistoryApply = (event) async {
      await beforeApply?.call(event);
      final p = event.payload;
      await m.applyMirroredMessage(
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
    };
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
  }) async {
    for (var i = 0; i < count; i++) {
      await sa.appendMessage(
        Message(
          id: 'm${i.toString().padLeft(4, '0')}',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
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

  test('restart continues the acknowledged durable page cursor', () async {
    await seed(40);
    var held = false;
    net.drop = (from, to, body) {
      final q = body['q'];
      if (from == b &&
          q is Map &&
          q['op'] == 'page' &&
          q['cursor'] is List &&
          (q['cursor'] as List)[1] == 'm0015') {
        held = true;
        return true;
      }
      return false;
    };
    ma.start();
    mb.start();
    await until(() async => held && await count() == 16);
    final mark = net.history.length;
    net.drop = null;
    await restartB();
    await until(() async => await count() == 40);
    final resumed =
        net.history
                .skip(mark)
                .firstWhere((e) => e.from == b && e.body['q']?['op'] == 'page')
                .body['q']
            as Map;
    expect((resumed['cursor'] as List)[1], 'm0015');
    expect(applied, 40);
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
    await seed(20);
    bStore.refusePageCursor = true;
    ma.start();
    mb.start();
    await until(() async => bStore.refused && errorJournal.entries.isNotEmpty);
    expect(await count(), 8);
    final cursor =
        jsonDecode((await sb.getSetting('device.history.cursor.v2:${a.hex}'))!)
            as Map;
    expect(cursor['cursor'], isNull);
    await restartB();
    await until(() async => await count() == 20);
    expect(
      (await sb.loadMessages(peer.hex)).map((m) => m.id).toSet(),
      hasLength(20),
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
