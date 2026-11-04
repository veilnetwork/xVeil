import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart' show MessageDeletionIntent;
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  bool failExpiry = false, failDelete = false, failVoid = false;
  Completer<void>? expiryEntered, expiryRelease;
  @override
  Future<void> applyRemoteVoid(String conversation, String author, int seq) {
    if (failVoid) throw StateError('PRIVATE_VOID_PATH');
    return super.applyRemoteVoid(conversation, author, seq);
  }

  @override
  Future<bool> recordExpiredMessage(
    String conversation,
    String id, {
    String? author,
    int? seq,
  }) async {
    expiryEntered?.complete();
    await expiryRelease?.future;
    if (failExpiry) throw StateError('fixture expiry write refused');
    return super.recordExpiredMessage(
      conversation,
      id,
      author: author,
      seq: seq,
    );
  }

  @override
  Future<void> deleteMessage(
    String conversation,
    String id, {
    MessageDeletionIntent? intent,
  }) {
    if (failDelete) throw StateError('fixture deletion refused');
    return super.deleteMessage(conversation, id, intent: intent);
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
  late _Storage storage;
  late _Link link;
  late MessagingService service;
  late DateTime now;
  late List<String> published;
  late List<IncomingNotice> notices;
  late StreamSubscription<IncomingNotice> subscription;
  setUp(() async {
    errorJournal.clear();
    now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    );
    container = FakeHvContainer();
    storage = _Storage(container.passwordOpener);
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
    service.onMessageStored = (_, m) => published.add(m.body);
    subscription = service.incoming.listen(notices.add);
  });
  tearDown(() async {
    await service.dispose();
    await subscription.cancel();
    await link.dispose();
    await storage.close();
  });
  Future<void> receive(WireEnvelope e, {String? fid}) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: (fid == null ? e : e.withFrameId(fid)).encode(),
    ),
  );
  WireEnvelope post({DateTime? at, String id = 'late', int seq = 1}) =>
      WireEnvelope.message(
        'PRIVATE_LATE_BODY',
        id: id,
        seq: seq,
        sentAtMs: (at ?? now.subtract(const Duration(seconds: 31)))
            .millisecondsSinceEpoch,
      );
  Future<void> held({
    MessageDirection direction = MessageDirection.incoming,
    DateTime? at,
  }) => storage.appendMessage(
    Message(
      id: 'late',
      conversationId: peer.hex,
      direction: direction,
      body: 'HELD_ORIGINAL',
      timestamp: at ?? now.subtract(const Duration(seconds: 31)),
      author: direction == MessageDirection.incoming ? peer.hex : _id(1).hex,
      seq: 1,
      status: MessageStatus.delivered,
    ),
  );
  bool ack(String id) =>
      link.sent.any((e) => e.kind == WireKind.ack && e.id == id);
  List<String> raw() => [
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
      for (final row
          in container
              .rawStoreFor('fixture')!
              .iterLogRange(namespace: ns, limit: 8192))
        utf8.decode(row.payload),
  ];

  test(
    'late wire post never stores or publishes body and persists its empty slot before ACK',
    () async {
      await receive(post(), fid: 'post-frame');
      await pumpEventQueue();
      expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
      expect(raw().any((s) => s.contains('PRIVATE_LATE_BODY')), isFalse);
      expect(published, isEmpty);
      expect(notices, isEmpty);
      expect(await storage.isMessageDeleted(peer.hex, 'late'), isTrue);
      expect((await storage.conversationSync(peer.hex)).highWater[peer.hex], 1);
      expect(ack('late'), isTrue);
    },
  );
  test('expiry boundary is inclusive, next millisecond remains live', () async {
    await receive(post(at: now.subtract(const Duration(seconds: 30))));
    await receive(
      post(
        id: 'live',
        seq: 2,
        at: now
            .subtract(const Duration(seconds: 30))
            .add(const Duration(milliseconds: 1)),
      ),
    );
    expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
    expect(await storage.loadMessageById(peer.hex, 'live'), isNotNull);
    expect(published, ['PRIVATE_LATE_BODY']);
  });
  test(
    'fresh retry timestamp cannot republish an expired held original',
    () async {
      await held();
      await receive(post(at: now));
      expect(published, isEmpty);
      expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
      expect(ack('late'), isTrue);
    },
  );
  test('failed expiry commit leaves no ACK and exact retry succeeds', () async {
    storage.failExpiry = true;
    await receive(post(), fid: 'post-frame');
    expect(link.sent.where((e) => e.kind == WireKind.ack), isEmpty);
    expect(raw().any((s) => s.contains('PRIVATE_LATE_BODY')), isFalse);
    storage.failExpiry = false;
    await receive(post(), fid: 'post-frame');
    expect(ack('late'), isTrue);
    expect(await storage.isMessageDeleted(peer.hex, 'late'), isTrue);
  });
  test(
    'wire edit of expired post stores no new body and retains the authenticated edit slot',
    () async {
      await held();
      final edits = <String>[];
      service.onMessageEdited = (_, _, body, _) => edits.add(body);
      await receive(
        const WireEnvelope.edit('late', 'PRIVATE_LATE_EDIT', seq: 2),
        fid: 'edit-frame',
      );
      expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
      expect(raw().any((s) => s.contains('PRIVATE_LATE_EDIT')), isFalse);
      expect(edits, isEmpty);
      expect(ack('edit-frame'), isTrue);
      expect((await storage.conversationSync(peer.hex)).highWater[peer.hex], 2);
    },
  );
  test(
    'failed expiry delete does not ACK or publish an incoming edit',
    () async {
      await held();
      storage.failDelete = true;
      final e = const WireEnvelope.edit('late', 'PRIVATE_LATE_EDIT', seq: 2);
      await receive(e, fid: 'edit-frame');
      expect(ack('edit-frame'), isFalse);
      expect(
        (await storage.loadMessageById(peer.hex, 'late'))!.body,
        'HELD_ORIGINAL',
      );
      expect(raw().any((s) => s.contains('PRIVATE_LATE_EDIT')), isFalse);
      storage.failDelete = false;
      await receive(e, fid: 'edit-frame');
      expect(ack('edit-frame'), isTrue);
      expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
    },
  );
  test('a mirrored edit cannot revive expired outgoing text', () async {
    await held(direction: MessageDirection.outgoing);
    await service.applyMirroredEdit(
      peer: peer,
      msgId: 'late',
      body: 'PRIVATE_LATE_EDIT',
      seq: 2,
    );
    expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
    expect(raw().any((s) => s.contains('PRIVATE_LATE_EDIT')), isFalse);
    expect(await storage.isMessageDeleted(peer.hex, 'late'), isTrue);
  });
  test('expiry receipt waits for the actual tombstone commit', () async {
    storage.expiryEntered = Completer<void>();
    storage.expiryRelease = Completer<void>();
    final receiveFuture = receive(post(), fid: 'post-frame');
    try {
      await storage.expiryEntered!.future;
      expect(link.sent.where((e) => e.kind == WireKind.ack), isEmpty);
      expect(await storage.isMessageDeleted(peer.hex, 'late'), isFalse);
      expect(raw().any((s) => s.contains('PRIVATE_LATE_BODY')), isFalse);
    } finally {
      storage.expiryRelease!.complete();
      await receiveFuture;
    }
    expect(ack('late'), isTrue);
  });

  test(
    'failed deletion publication is retried without exposing old text',
    () async {
      var attempts = 0;
      service.onMessageDeleted = (_, _) {
        if (++attempts == 1) throw StateError('fixture journal unavailable');
      };
      await receive(post(), fid: 'post-frame');
      expect(link.sent.where((e) => e.kind == WireKind.ack), isEmpty);
      expect(await storage.isMessageDeleted(peer.hex, 'late'), isTrue);
      await receive(post(), fid: 'post-frame');
      expect(ack('late'), isTrue);
      expect(attempts, 2);
      expect(published, isEmpty);
    },
  );

  test(
    'failure of the empty edit slot leaves its exact frame retryable',
    () async {
      await held();
      final e = const WireEnvelope.edit('late', 'PRIVATE_LATE_EDIT', seq: 2);
      storage.failVoid = true;
      await receive(e, fid: 'edit-frame');
      expect(ack('edit-frame'), isFalse);
      expect(await storage.isMessageDeleted(peer.hex, 'late'), isTrue);
      storage.failVoid = false;
      await receive(e, fid: 'edit-frame');
      expect(ack('edit-frame'), isTrue);
      expect((await storage.conversationSync(peer.hex)).highWater[peer.hex], 2);
      expect(raw().any((s) => s.contains('PRIVATE_LATE_EDIT')), isFalse);
    },
  );

  test(
    'pending edit before expired original never writes either body',
    () async {
      final e = const WireEnvelope.edit('late', 'PRIVATE_LATE_EDIT', seq: 2);
      await receive(e, fid: 'edit-frame');
      expect(ack('edit-frame'), isFalse);
      await receive(post());
      expect(ack('late'), isTrue);
      await receive(e, fid: 'edit-frame');
      expect(ack('edit-frame'), isTrue);
      expect((await storage.conversationSync(peer.hex)).highWater[peer.hex], 2);
      expect(raw().any((s) => s.contains('PRIVATE_LATE_')), isFalse);
      expect(published, isEmpty);
    },
  );

  test('TTL off preserves an old ordinary post', () async {
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    await receive(post());
    expect(
      (await storage.loadMessageById(peer.hex, 'late'))!.body,
      'PRIVATE_LATE_BODY',
    );
    expect(published, ['PRIVATE_LATE_BODY']);
    expect(ack('late'), isTrue);
  });

  test('peer edit cannot expire our own outgoing original', () async {
    await held(direction: MessageDirection.outgoing);
    await receive(
      const WireEnvelope.edit('late', 'PRIVATE_LATE_EDIT', seq: 2),
      fid: 'edit-frame',
    );
    expect(
      (await storage.loadMessageById(peer.hex, 'late'))!.body,
      'HELD_ORIGINAL',
    );
    expect(await storage.isMessageDeleted(peer.hex, 'late'), isFalse);
    expect(raw().any((s) => s.contains('PRIVATE_LATE_EDIT')), isFalse);
  });
  test(
    'expiry errors expose only safe diagnostic categories and types',
    () async {
      await held();
      storage.failVoid = true;
      await receive(
        const WireEnvelope.edit('late', 'PRIVATE_LATE_EDIT', seq: 2),
        fid: 'edit-frame',
      );
      expect(
        errorJournal.entries.any((e) => e.kind == 'inbound-expiry'),
        isTrue,
      );
      final report = errorJournal.toJson(
        platform: 'test',
        osVersion: 'unknown',
        appVersion: 'test',
        phase: 'chat',
        includeTimestamps: false,
      );
      for (final secret in [
        'PRIVATE_VOID_PATH',
        'PRIVATE_LATE_EDIT',
        peer.hex,
        now.millisecondsSinceEpoch.toString(),
      ]) {
        expect(report.contains(secret), isFalse);
      }
      expect(report.contains('inbound-expiry'), isTrue);
      expect(report.contains('StateError'), isTrue);
    },
  );
}
