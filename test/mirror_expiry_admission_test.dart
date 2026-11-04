import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/event.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

void main() {
  final peer = id(2), sibling = id(3);
  late FakeHvContainer container;
  late HiddenVolumeStorage storage;
  late MessagingService messaging;
  var now = DateTime.utc(2026, 11, 4, 12);

  void bind() {
    messaging = MessagingService(
      LoopbackTransport(localNodeId: id(1)),
      storage,
      now: () => now,
    );
    messaging.groupBindingsOwner = Object();
    messaging.myOtherDevices = () async => [sibling];
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 4, 12);
    container = FakeHvContainer();
    storage = HiddenVolumeStorage(container.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        disappearingTtlSeconds: 30,
      ),
    );
    bind();
  });
  tearDown(() async {
    await messaging.dispose();
    await storage.close();
  });

  Future<bool> mirror(
    MessageDirection direction,
    DateTime sent, {
    String messageId = 'late',
  }) => messaging.applyMirroredMessage(
    peer: peer,
    msgId: messageId,
    direction: direction,
    body: 'expired-private-body',
    tsMs: sent.millisecondsSinceEpoch,
    author: direction == MessageDirection.incoming ? peer.hex : sibling.hex,
    seq: 1,
    positionVerified: true,
  );

  List<String> rawMessagePayloads() {
    final raw = container.rawStoreFor('fixture')!;
    return [
      for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
        for (final row in raw.iterLogRange(namespace: ns, limit: 8192))
          utf8.decode(row.payload),
    ];
  }

  for (final direction in MessageDirection.values) {
    test(
      'expired $direction mirror is refused before any body write',
      () async {
        final applied = await mirror(
          direction,
          now.subtract(const Duration(seconds: 31)),
        );
        expect(applied, isFalse);
        expect(await storage.loadMessageById(peer.hex, 'late'), isNull);
        expect(
          rawMessagePayloads().any(
            (row) => row.contains('expired-private-body'),
          ),
          isFalse,
        );
        expect(await storage.isMessageDeleted(peer.hex, 'late'), isTrue);
        final author = direction == MessageDirection.incoming
            ? peer.hex
            : sibling.hex;
        expect((await storage.conversationSync(peer.hex)).highWater[author], 1);
        final events = await storage.loadEventsSince(peer.hex, author, 0);
        expect(events, hasLength(1));
        expect(events.single.kind, EventKind.void_);
        expect(events.single.body, isNull);
        expect(events.single.target, isNull);
      },
    );
  }

  test('mirror just before its TTL is still accepted', () async {
    expect(
      await mirror(
        MessageDirection.incoming,
        now.subtract(const Duration(milliseconds: 29999)),
      ),
      isTrue,
    );
    expect(
      (await storage.loadMessageById(peer.hex, 'late'))!.body,
      'expired-private-body',
    );
  });

  test(
    'expiry is inclusive and a replay cannot return after TTL off or clock rollback',
    () async {
      final sent = now.subtract(const Duration(seconds: 30));
      expect(await mirror(MessageDirection.incoming, sent), isFalse);
      await storage.upsertContact(
        (await storage.getContact(
          peer,
        ))!.copyWith(disappearingTtlSeconds: null),
      );
      now = now.subtract(const Duration(minutes: 15));
      await messaging.dispose();
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      bind();
      expect(await mirror(MessageDirection.incoming, sent), isFalse);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(rawMessagePayloads(), hasLength(1));
    },
  );

  test(
    'future clock bound still normalizes once without poisoning read time',
    () async {
      expect(
        await mirror(
          MessageDirection.incoming,
          now.add(const Duration(days: 365)),
        ),
        isTrue,
      );
      final held = (await storage.loadMessageById(peer.hex, 'late'))!;
      expect(held.timestamp.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    },
  );

  test(
    'disabled TTL and legacy unknown positions keep their separate meanings',
    () async {
      await storage.upsertContact(
        (await storage.getContact(
          peer,
        ))!.copyWith(disappearingTtlSeconds: null),
      );
      expect(
        await mirror(
          MessageDirection.outgoing,
          now.subtract(const Duration(days: 1)),
        ),
        isTrue,
      );
      await storage.upsertContact(
        (await storage.getContact(peer))!.copyWith(disappearingTtlSeconds: 30),
      );
      expect(
        await messaging.applyMirroredMessage(
          peer: peer,
          msgId: 'legacy',
          direction: MessageDirection.incoming,
          body: 'legacy-expired-body',
          tsMs: now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
        ),
        isFalse,
      );
      expect(await storage.isMessageDeleted(peer.hex, 'legacy'), isTrue);
      expect(
        rawMessagePayloads().any((row) => row.contains('legacy-expired-body')),
        isFalse,
      );
      expect(
        (await storage.conversationSync(
          peer.hex,
        )).highWater.containsKey(peer.hex),
        isFalse,
      );
    },
  );

  test('expired media does not persist a thumbnail or offer', () async {
    expect(
      await messaging.applyMirroredMessage(
        peer: peer,
        msgId: 'photo',
        direction: MessageDirection.incoming,
        body: 'expired-media-body',
        tsMs: now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
        author: peer.hex,
        seq: 1,
        positionVerified: true,
        fileContentId: 'ab' * 32,
        fileName: 'expired.jpg',
        fileSize: 1000,
        thumb: 'PRIVATE_THUMB',
      ),
      isFalse,
    );
    expect(await storage.loadMessageById(peer.hex, 'photo'), isNull);
    expect(
      rawMessagePayloads().any(
        (row) => row.contains('PRIVATE_THUMB') || row.contains('expired.jpg'),
      ),
      isFalse,
    );
  });
}
