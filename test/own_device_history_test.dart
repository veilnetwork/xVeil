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
    DateTime? at,
    MessageStatus status = MessageStatus.delivered,
  }) async {
    for (var i = 0; i < count; i++) {
      await sa.appendMessage(
        Message(
          id: 'm${i.toString().padLeft(4, '0')}',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: List.filled(bodyBytes, '${i % 10}').join(),
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
