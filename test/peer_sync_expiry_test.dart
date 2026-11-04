import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart' show MessageDeletionIntent;
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/message_edit.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/core/error_journal.dart';
import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _NoPruneStorage extends HiddenVolumeStorage {
  _NoPruneStorage(super.opener);
  bool refuseDelete = false, loseDeleteReply = false;
  String? refuseReadId;
  @override
  Future<void> deleteMessage(
    String conversation,
    String id, {
    MessageDeletionIntent? intent,
  }) async {
    if (refuseDelete) throw StateError('PRIVATE_PATH_AND_BODY');
    await super.deleteMessage(conversation, id, intent: intent);
    if (loseDeleteReply) {
      loseDeleteReply = false;
      throw StateError('PRIVATE_PATH_AND_BODY');
    }
  }

  @override
  Future<Message?> loadMessageById(String conversation, String id) async {
    if (refuseReadId == id) throw StateError('PRIVATE_PATH_AND_BODY');
    return super.loadMessageById(conversation, id);
  }

  @override
  Future<int> pruneConversationBefore(NodeId peer, DateTime cutoff) async =>
      throw StateError('fixture physical prune unavailable');
}

class _Capture implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  Future<void> Function(WireEnvelope)? onSend;
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final envelope = WireEnvelope.decode(payload);
    sent.add(envelope);
    await onSend?.call(envelope);
  }

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
  Future<void> dispose() => inbound.close();
}

void main() {
  final me = _id(1), peer = _id(2);
  late _NoPruneStorage storage;
  late _Capture transport;
  late MessagingService messaging;
  late DateTime now;
  setUp(() async {
    errorJournal.clear();
    now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    );
    storage = _NoPruneStorage(FakeHvContainer().passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        disappearingTtlSeconds: 30,
      ),
    );
    transport = _Capture();
    // Deliberately no start(): the peer-sync response must honour TTL even
    // when periodic/startup cleanup cannot remove its raw source copy.
    messaging = MessagingService(transport, storage, now: () => now);
  });
  tearDown(() async {
    await messaging.dispose();
    await transport.dispose();
    await storage.close();
  });

  Future<void> post(
    String id,
    int seq,
    DateTime at, {
    MessageDirection direction = MessageDirection.outgoing,
    bool file = false,
  }) async {
    await storage.appendMessage(
      Message(
        id: id,
        conversationId: peer.hex,
        direction: direction,
        body: id == 'live' ? 'LIVE_BODY' : 'PRIVATE_OLD_BODY',
        timestamp: at,
        author: direction == MessageDirection.outgoing ? me.hex : peer.hex,
        seq: seq,
        status: MessageStatus.delivered,
        fileId: file ? 'fixture-file-$id' : null,
        fileName: file
            ? (id == 'live' ? 'live.bin' : 'PRIVATE_OLD_FILE.bin')
            : null,
      ),
    );
  }

  Future<void> ask(Map<String, Object?> extra) => messaging.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: WireEnvelope.sync(jsonEncode({'hw': {}, ...extra})).encode(),
    ),
  );
  List<Map> echoes() => [
    for (final e in transport.sent)
      if (e.kind == WireKind.sync)
        if ((jsonDecode(e.body) as Map)['echo'] case final Map echo) echo,
  ];

  test(
    'gap-fill replaces expired original and late edit with voids, keeps live post',
    () async {
      await post('expired', 1, now.subtract(const Duration(seconds: 31)));
      await storage.editMessage(
        peer.hex,
        'expired',
        'PRIVATE_NEW_EDIT',
        seq: 2,
      );
      await post('live', 3, now);
      expect(
        (await storage.loadMessageById(peer.hex, 'expired'))!.body,
        'PRIVATE_NEW_EDIT',
        reason: 'positive control before the serving path',
      );
      await ask({});
      final replies = transport.sent
          .where(
            (e) =>
                e.kind == WireKind.message ||
                e.kind == WireKind.edit ||
                e.kind == WireKind.voidSeq,
          )
          .toList();
      expect(replies.any((e) => e.body.contains('PRIVATE_')), isFalse);
      expect(
        replies.where((e) => e.kind == WireKind.voidSeq).map((e) => e.seq),
        [1, 2],
      );
      expect(
        replies.singleWhere((e) => e.kind == WireKind.message).body,
        'LIVE_BODY',
      );
      expect(
        await storage.isMessageDeleted(peer.hex, 'expired'),
        isTrue,
        reason:
            'voids must follow a durable source decision, not just an age guess',
      );
    },
  );

  test(
    'gap-fill with an expired file sends no filename or file query',
    () async {
      await post(
        'expired',
        1,
        now.subtract(const Duration(seconds: 30)),
        file: true,
      );
      await post('live', 2, now, file: true);
      await ask({});
      expect(
        transport.sent
            .where((e) => e.kind == WireKind.fileQuery)
            .map((e) => e.body)
            .any((body) => body.contains('PRIVATE_')),
        isFalse,
      );
      expect(
        transport.sent.where((e) => e.kind == WireKind.voidSeq).single.seq,
        1,
      );
      expect(
        transport.sent.where((e) => e.kind == WireKind.fileQuery).length,
        1,
      );
    },
  );

  for (final edited in [false, true]) {
    test(
      'peer own-echo excludes expired ${edited ? 'edits' : 'posts'} and keeps live data',
      () async {
        await post(
          'expired',
          1,
          now.subtract(const Duration(seconds: 31)),
          direction: MessageDirection.incoming,
        );
        if (edited) {
          await storage.editMessage(
            peer.hex,
            'expired',
            'PRIVATE_ECHO_EDIT',
            seq: 2,
          );
        }
        await post('live', 3, now, direction: MessageDirection.incoming);
        await ask({
          'ow': [edited ? ownEchoKey('expired') : ownEchoKey('unrelated')],
          'os': 0,
          if (edited) 'oe': {ownEchoKey('expired'): 1},
          if (edited)
            'oh': {ownEchoKey('expired'): messageEditContentHash('old', [])},
        });
        final bodies = echoes();
        expect(bodies.any((e) => e['id'] == 'expired'), isFalse);
        expect(bodies.single['id'], 'live');
      },
    );
  }

  test(
    'failed local erase does not authorize a void; retry recovers without losing live data',
    () async {
      await post('expired', 1, now.subtract(const Duration(seconds: 31)));
      await post('live', 2, now);
      storage.refuseDelete = true;
      await ask({});
      expect(transport.sent.any((e) => e.kind == WireKind.voidSeq), isFalse);
      expect(
        transport.sent.where((e) => e.kind == WireKind.message).single.body,
        'LIVE_BODY',
      );
      expect(await storage.isMessageDeleted(peer.hex, 'expired'), isFalse);
      transport.sent.clear();
      storage.refuseDelete = false;
      now = now.add(const Duration(seconds: 6));
      await ask({});
      expect(
        transport.sent.where((e) => e.kind == WireKind.voidSeq).single.seq,
        1,
      );
      expect(
        transport.sent.where((e) => e.kind == WireKind.message).single.body,
        'LIVE_BODY',
      );
    },
  );

  test('a lost erase reply is resolved from the committed tombstone', () async {
    await post('expired', 1, now.subtract(const Duration(seconds: 31)));
    storage.loseDeleteReply = true;
    await ask({});
    expect(await storage.isMessageDeleted(peer.hex, 'expired'), isTrue);
    expect(
      transport.sent.where((e) => e.kind == WireKind.voidSeq).single.seq,
      1,
    );
    expect(transport.sent.any((e) => e.body.contains('PRIVATE_')), isFalse);
  });

  test(
    'a read failure defers only that body and never sends a guessed void',
    () async {
      await post('expired', 1, now.subtract(const Duration(seconds: 31)));
      await post('live', 2, now);
      storage.refuseReadId = 'expired';
      await ask({});
      expect(transport.sent.any((e) => e.kind == WireKind.voidSeq), isFalse);
      expect(
        transport.sent.where((e) => e.kind == WireKind.message).single.id,
        'live',
      );
      expect(transport.sent.any((e) => e.body.contains('PRIVATE_')), isFalse);
    },
  );

  test(
    'expiry while an earlier network send waits is checked again for the tail',
    () async {
      await post('first', 1, now);
      await post('live', 2, now);
      final entered = Completer<void>(), release = Completer<void>();
      transport.onSend = (e) async {
        if (e.kind == WireKind.message && e.id == 'first') {
          entered.complete();
          await release.future;
        }
      };
      final response = ask({});
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        now = now.add(const Duration(seconds: 30));
      } finally {
        release.complete();
        await response;
      }
      expect(
        transport.sent
            .where((e) => e.kind == WireKind.message)
            .map((e) => e.id),
        ['first'],
      );
      expect(
        transport.sent.where((e) => e.kind == WireKind.voidSeq).single.seq,
        2,
      );
    },
  );

  test(
    'own-echo tail expiring during a slow earlier reply is not returned',
    () async {
      await post(
        'first',
        1,
        now.subtract(const Duration(milliseconds: 1)),
        direction: MessageDirection.incoming,
      );
      await post('second', 2, now, direction: MessageDirection.incoming);
      final entered = Completer<void>(), release = Completer<void>();
      transport.onSend = (e) async {
        if (e.kind == WireKind.sync &&
            (jsonDecode(e.body) as Map)['echo']?['id'] == 'first') {
          entered.complete();
          await release.future;
        }
      };
      final response = ask({
        'ow': [ownEchoKey('unrelated')],
        'os': 0,
      });
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        now = now.add(const Duration(seconds: 30));
      } finally {
        release.complete();
        await response;
      }
      expect(echoes().map((e) => e['id']), ['first']);
      expect(
        transport.sent.any((e) => e.kind == WireKind.voidSeq),
        isFalse,
        reason: 'we cannot declare a void on the peer author stream',
      );
    },
  );

  test(
    'outgoing own-echo requests never advertise an expired body hash/key',
    () async {
      await post('expired', 1, now.subtract(const Duration(seconds: 31)));
      await storage.editMessage(
        peer.hex,
        'expired',
        'PRIVATE_NEW_EDIT',
        seq: 2,
      );
      await post('live', 3, now);
      messaging.myOtherDevices = () async => [_id(3)];
      await messaging.flushOutbox();
      await pumpEventQueue();
      final asks = [
        for (final e in transport.sent)
          if (e.kind == WireKind.sync)
            if ((jsonDecode(e.body) as Map)['ow'] case final List keys) keys,
      ];
      expect(asks, isNotEmpty);
      expect(asks.expand((keys) => keys), contains(ownEchoKey('live')));
      expect(
        asks.expand((keys) => keys),
        isNot(contains(ownEchoKey('expired'))),
      );
    },
  );

  test(
    'TTL off preserves normal old gap-fill and original authorship',
    () async {
      await storage.upsertContact(
        (await storage.getContact(
          peer,
        ))!.copyWith(disappearingTtlSeconds: null),
      );
      await post('expired', 1, now.subtract(const Duration(days: 1)));
      await ask({});
      final sent = transport.sent.singleWhere(
        (e) => e.kind == WireKind.message,
      );
      expect(sent.id, 'expired');
      expect(sent.seq, 1);
      expect(transport.sent.any((e) => e.kind == WireKind.voidSeq), isFalse);
    },
  );

  test(
    'expiry failure diagnostics export category/type without body, path or peer',
    () async {
      await post('expired', 1, now.subtract(const Duration(seconds: 31)));
      storage.refuseDelete = true;
      await ask({});
      expect(
        errorJournal.entries.any((e) => e.kind == 'peer-sync-expiry-erase'),
        isTrue,
      );
      now = now.add(const Duration(seconds: 6));
      storage.refuseReadId = 'expired';
      await ask({});
      expect(
        errorJournal.entries.any((e) => e.kind == 'peer-sync-expiry-read'),
        isTrue,
      );
      final text = errorJournal.toJson(
        platform: 'test',
        osVersion: 'unknown',
        appVersion: 'test',
        phase: 'chat',
        includeTimestamps: false,
      );
      for (final private in [
        'PRIVATE_PATH_AND_BODY',
        'PRIVATE_OLD_BODY',
        me.hex,
        peer.hex,
      ]) {
        expect(text, isNot(contains(private)));
      }
      expect(text, contains('StateError'));
      expect(text, isNot(contains('"at"')));
    },
  );
}
