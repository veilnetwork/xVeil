import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart' show MessageDeletionIntent;
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/messaging.dart';
import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _GateStorage extends HiddenVolumeStorage {
  _GateStorage(super.opener);
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = true, failDelete = false;
  @override
  Future<void> deleteMessage(
    String conversation,
    String id, {
    MessageDeletionIntent? intent,
  }) {
    if (failDelete) throw StateError('fixture post-write deletion failed');
    return super.deleteMessage(conversation, id, intent: intent);
  }

  Message? staged;
  @override
  Future<Message> appendMessage(Message message) async {
    final row = await super.appendMessage(message);
    if (armed) {
      armed = false;
      staged = row;
      entered.complete();
      await release.future;
    }
    return row;
  }
}

class _Link implements VeilTransport {
  final input = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Stream<InboundMessage> messages() => input.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async => sent.add(WireEnvelope.decode(payload));
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
  Future<void> dispose() => input.close();
}

void main() {
  final peer = _id(2);
  late FakeHvContainer container;
  late _GateStorage storage;
  late _Link link;
  late MessagingService service;
  late DateTime now;
  late List<String> published;
  late List<IncomingNotice> notices;
  late StreamSubscription<IncomingNotice> subscription;
  setUp(() async {
    now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    );
    container = FakeHvContainer();
    storage = _GateStorage(container.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        disappearingTtlSeconds: 30,
      ),
    );
    link = _Link();
    service = MessagingService(link, storage, now: () => now);
    published = [];
    notices = [];
    service.onMessageStored = (_, row) => published.add(row.body);
    subscription = service.incoming.listen(notices.add);
  });
  tearDown(() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await subscription.cancel();
    await link.dispose();
    await storage.close();
  });
  Future<void> receive(WireEnvelope e) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: e.encode(),
    ),
  );
  Future<void> expireAppend() async {
    await storage.entered.future;
    expect(
      await storage.loadMessageById(peer.hex, storage.staged!.id),
      isNotNull,
      reason: 'positive control: row is visible while append completion waits',
    );
    expect(published, isEmpty);
    expect(link.sent.where((e) => e.kind == WireKind.ack), isEmpty);
    now = now.add(const Duration(seconds: 30));
    storage.release.complete();
  }

  bool rawContains(String needle) => [
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
      for (final row
          in container
              .rawStoreFor('fixture')!
              .iterLogRange(namespace: ns, limit: 8192))
        utf8.decode(row.payload),
  ].any((s) => s.contains(needle));
  test(
    'incoming post expiring during append is not published or notified',
    () async {
      final receiving = receive(
        WireEnvelope.message(
          'PRIVATE_DURING_APPEND',
          id: 'during-append',
          seq: 1,
          sentAtMs: now.millisecondsSinceEpoch,
        ),
      );
      await expireAppend();
      await receiving;
      await pumpEventQueue();
      expect(published, isEmpty);
      expect(notices, isEmpty);
      expect(await storage.loadMessageById(peer.hex, 'during-append'), isNull);
      expect(await storage.isMessageDeleted(peer.hex, 'during-append'), isTrue);
      expect(rawContains('PRIVATE_DURING_APPEND'), isFalse);
      expect(
        link.sent.any((e) => e.kind == WireKind.ack && e.id == 'during-append'),
        isTrue,
      );
    },
  );
  test(
    'outgoing post expiring during append is refused before journal or network',
    () async {
      final sending = service.sendText(peer, 'PRIVATE_DURING_APPEND');
      await expireAppend();
      final sent = await sending;
      expect(sent, isFalse);
      expect(published, isEmpty);
      expect(link.sent.any((e) => e.kind == WireKind.message), isFalse);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(rawContains('PRIVATE_DURING_APPEND'), isFalse);
    },
  );
  test(
    'file offer expiring during append cannot start an auto download',
    () async {
      final manifest =
          ContentManifest.fromBytes(
            'PRIVATE_DURING_APPEND.png',
            Uint8List.fromList([1, 2]),
          ).withEvent(
            msgId: 'during-append',
            author: peer.hex,
            seq: 1,
            ts: now.millisecondsSinceEpoch,
          );
      final receiving = receive(
        contentManifestEnvelope(jsonEncode(manifest.toJson())),
      );
      await expireAppend();
      await receiving;
      await pumpEventQueue();
      expect(published, isEmpty);
      expect(notices, isEmpty);
      expect(service.offeredContentCount, 0);
      expect(link.sent.any((e) => e.kind == WireKind.pieceRequest), isFalse);
      expect(rawContains('PRIVATE_DURING_APPEND'), isFalse);
      expect(await storage.isMessageDeleted(peer.hex, 'during-append'), isTrue);
    },
  );
  test('failed post-write expiry leaves incoming ACK retryable', () async {
    final frame = WireEnvelope.message(
      'PRIVATE_DURING_APPEND',
      id: 'during-append',
      seq: 1,
      sentAtMs: now.millisecondsSinceEpoch,
    );
    storage.failDelete = true;
    final receiving = receive(frame);
    await expireAppend();
    await receiving;
    expect(published, isEmpty);
    expect(link.sent.where((e) => e.kind == WireKind.ack), isEmpty);
    expect(await storage.loadMessageById(peer.hex, 'during-append'), isNotNull);
    storage.failDelete = false;
    await receive(frame);
    expect(await storage.isMessageDeleted(peer.hex, 'during-append'), isTrue);
    expect(
      link.sent.any((e) => e.kind == WireKind.ack && e.id == 'during-append'),
      isTrue,
    );
    expect(published, isEmpty);
  });

  test(
    'a tombstone arriving while append waits prevents publication even with TTL off',
    () async {
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final receiving = receive(
        WireEnvelope.message(
          'PRIVATE_DURING_APPEND',
          id: 'during-append',
          seq: 1,
          sentAtMs: now.millisecondsSinceEpoch,
        ),
      );
      await storage.entered.future;
      await storage.deleteMessage(peer.hex, 'during-append');
      storage.release.complete();
      await receiving;
      await pumpEventQueue();
      expect(published, isEmpty);
      expect(notices, isEmpty);
      expect(await storage.loadMessageById(peer.hex, 'during-append'), isNull);
    },
  );

  test(
    'declined streaming offer closes its unadvertised source once',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      var closes = 0;
      final sending = service.sendFileStreaming(
        peer,
        'PRIVATE_DURING_APPEND.bin',
        bytes.length,
        (offset, length) async =>
            Uint8List.sublistView(bytes, offset, offset + length),
        close: () async {
          closes++;
        },
      );
      await expireAppend();
      expect(await sending, isNull);
      expect(closes, 1);
      expect(published, isEmpty);
      expect(link.sent.any((e) => e.kind == WireKind.contentManifest), isFalse);
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  test(
    'unexpired delayed append keeps normal sender success and publication',
    () async {
      final sending = service.sendText(peer, 'LIVE_AFTER_APPEND');
      await storage.entered.future;
      storage.release.complete();
      expect(await sending, isTrue);
      expect(published, ['LIVE_AFTER_APPEND']);
      expect(
        link.sent.where((e) => e.kind == WireKind.message).single.body,
        'LIVE_AFTER_APPEND',
      );
    },
  );
  test(
    'pending delete plus append expiry publishes the deletion once',
    () async {
      var deletions = 0;
      service.onMessageDeleted = (_, _) {
        deletions++;
      };
      await receive(
        const WireEnvelope.del(
          'during-append',
        ).withFrameId('delete-before-post'),
      );
      final receiving = receive(
        WireEnvelope.message(
          'PRIVATE_DURING_APPEND',
          id: 'during-append',
          seq: 1,
          sentAtMs: now.millisecondsSinceEpoch,
        ),
      );
      await expireAppend();
      await receiving;
      expect(deletions, 1);
      expect(published, isEmpty);
      await receive(
        const WireEnvelope.del(
          'during-append',
        ).withFrameId('delete-before-post'),
      );
      expect(deletions, 1);
    },
  );

  test(
    'expiry of a stored greeting does not send that body in the handshake',
    () async {
      final sending = service.sendRequest(peer, 'PRIVATE_DURING_APPEND');
      await storage.entered.future;
      now = now.add(const Duration(seconds: 31));
      storage.release.complete();
      await sending;
      expect(published, isEmpty);
      expect(
        link.sent.where((e) => e.kind == WireKind.request).single.body,
        isEmpty,
      );
      expect(rawContains('PRIVATE_DURING_APPEND'), isFalse);
    },
  );
  test(
    'outgoing post expiring while required publisher waits is not sent',
    () async {
      storage.armed = false;
      final entered = Completer<void>(), release = Completer<void>();
      service.onMessageStored = (_, _) async {
        entered.complete();
        await release.future;
      };
      final sending = service.sendText(peer, 'PRIVATE_PUBLISHER_WAIT');
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        now = now.add(const Duration(seconds: 30));
      } finally {
        release.complete();
      }
      expect(await sending, isFalse);
      expect(link.sent.any((e) => e.kind == WireKind.message), isFalse);
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );
}
