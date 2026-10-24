import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/async_tasks.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/space_recommendation.dart';
import 'package:xveil/domain/space_join_request.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final acks = <String>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    if (frame.kind == WireKind.ack) acks.add(frame.id!);
  }
}

class _HeldStorage extends HiddenVolumeStorage {
  _HeldStorage(super.opener);
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false;
  @override
  Future<Message> appendMessage(Message message) async {
    final stored = await super.appendMessage(message);
    if (hold) {
      entered.complete();
      await release.future;
    }
    return stored;
  }
}

void main() {
  final peer = _id(2);
  late FakeHvContainer backing;
  late _HeldStorage storage;
  late _Link link;
  late MessagingService service;
  Future<void> open() async {
    storage = _HeldStorage(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    link = _Link();
    service = MessagingService(link, storage);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
  }

  Future<void> receive(WireEnvelope frame) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: frame.encode(),
    ),
  );
  WireEnvelope post({String body = 'original', String? fid}) {
    final frame = WireEnvelope.message(
      body,
      id: 'target',
      seq: 5,
      sentAtMs: 1000,
    );
    return fid == null ? frame : frame.withFrameId(fid);
  }

  setUp(() async {
    backing = FakeHvContainer();
    await open();
  });
  tearDown(() async {
    await service.dispose();
    await storage.close();
  });

  for (final framed in [false, true]) {
    test(
      'post retries a failed own-device publication before ACK framed=$framed',
      () async {
        var fail = true, calls = 0;
        service.onMessageStored = (_, _) async {
          calls++;
          if (fail) throw StateError('fixture journal refusal');
        };
        final frame = post(fid: framed ? 'post-frame' : null);
        await receive(frame);
        expect(await storage.loadMessages(peer.hex), hasLength(1));
        expect(link.acks, isEmpty);
        await receive(frame);
        expect(calls, 2);
        expect(link.acks, isEmpty);
        fail = false;
        await receive(frame);
        expect(calls, 3);
        expect(link.acks, contains('target'));
        if (framed) expect(link.acks, contains('post-frame'));
        await receive(frame);
        expect(
          calls,
          3,
          reason: 'an ordinary lost ACK must not re-publish on every retry',
        );
        expect(await storage.loadMessages(peer.hex), hasLength(1));
      },
    );
  }

  test(
    'a repaired publication refreshes the already-open conversation',
    () async {
      var fail = true, changes = 0;
      final sub = service.changes.listen((_) => changes++);
      addTearDown(sub.cancel);
      service.onMessageStored = (_, _) async {
        if (fail) throw StateError('fixture journal refusal');
      };
      await receive(post());
      await Future<void>.delayed(Duration.zero);
      changes = 0;
      fail = false;
      await receive(post());
      await Future<void>.delayed(Duration.zero);
      expect(changes, greaterThan(0));
    },
  );

  test(
    'restart recovery mirrors the stored row instead of altered retry bytes',
    () async {
      service.onMessageStored = (_, _) async =>
          throw StateError('fixture journal refusal');
      await receive(post());
      expect(link.acks, isEmpty);
      await service.dispose();
      await storage.close();
      await open();
      final mirrored = <Message>[];
      service.onMessageStored = (_, m) async => mirrored.add(m);
      await receive(post(body: 'forged replacement'));
      expect(mirrored, hasLength(1));
      expect(mirrored.single.body, 'original');
      expect(mirrored.single.author, peer.hex);
      expect(mirrored.single.seq, 5);
      expect(mirrored.single.timestamp.millisecondsSinceEpoch, 1000);
      expect(link.acks, contains('target'));
      expect(await storage.loadMessages(peer.hex), hasLength(1));
    },
  );

  test('a duplicate waits for a held mirror commit', () async {
    service.onMessageStored = (_, _) async =>
        throw StateError('fixture journal refusal');
    await receive(post());
    final entered = Completer<void>(), release = Completer<void>();
    service.onMessageStored = (_, _) async {
      entered.complete();
      await release.future;
    };
    final retry = receive(post());
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      expect(link.acks, isEmpty);
    } finally {
      release.complete();
      await retry;
    }
    expect(link.acks, contains('target'));
  });

  test(
    'provider detachment during append cannot silently skip a required mirror',
    () async {
      final tasks = AsyncTasks();
      service.onMessageStored = (_, _) => tasks.runRequired(() async {});
      storage.hold = true;
      final pending = receive(post());
      await storage.entered.future;
      service.onMessageStored = null;
      await tasks.close();
      storage.release.complete();
      await pending;
      expect(link.acks, isEmpty);
      var repaired = false;
      service.onMessageStored = (_, _) async => repaired = true;
      await receive(post());
      expect(repaired, isTrue);
      expect(link.acks, contains('target'));
    },
  );

  test(
    'a replacement publisher is not hidden by the previous completion cache',
    () async {
      var first = 0, second = 0;
      service.onMessageStored = (_, _) async => first++;
      await receive(post());
      service.onMessageStored = (_, _) async => second++;
      await receive(post());
      expect(first, 1);
      expect(second, 1);
    },
  );

  test(
    'legacy completed file query retries its missing mirror before ACK',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      var fail = true, calls = 0;
      final mirrored = <Message>[];
      service.onMessageStored = (_, m) async {
        calls++;
        if (fail) throw StateError('fixture journal refusal');
        mirrored.add(m);
      };
      await receive(
        fileMetaEnvelope(
          transferId: 'file-target',
          name: 'fixture.bin',
          size: bytes.length,
          count: 1,
          seq: 7,
          sentAtMs: 1000,
        ),
      );
      await receive(
        fileChunkEnvelope(
          transferId: 'file-target',
          index: 0,
          total: 1,
          data: bytes,
        ),
      );
      expect(calls, 1);
      expect(link.acks, isEmpty);
      final query = fileQueryEnvelope(
        transferId: 'file-target',
        name: 'altered-name.bin',
      );
      await receive(query);
      expect(calls, 2);
      expect(link.acks, isEmpty);
      fail = false;
      await receive(query);
      expect(mirrored, hasLength(1));
      expect(mirrored.single.fileName, 'fixture.bin');
      expect(await storage.loadFile(mirrored.single.fileId!), bytes);
      expect(link.acks, contains('file-target'));
      expect(await storage.loadMessages(peer.hex), hasLength(1));
    },
  );

  test(
    'a legacy text with only a frame id remains deduplicated across mirror retry',
    () async {
      var fail = true;
      final mirrored = <Message>[];
      service.onMessageStored = (_, m) async {
        if (fail) throw StateError('fixture journal refusal');
        mirrored.add(m);
      };
      await receive(
        const WireEnvelope(
          WireKind.message,
          'original',
        ).withFrameId('legacy-frame'),
      );
      expect(link.acks, isEmpty);
      fail = false;
      await receive(
        const WireEnvelope(
          WireKind.message,
          'altered',
        ).withFrameId('legacy-frame'),
      );
      expect(mirrored.single.body, 'original');
      expect(link.acks, contains('legacy-frame'));
      expect(await storage.loadMessages(peer.hex), hasLength(1));
    },
  );

  for (final kind in ['notice', 'card']) {
    test(
      '$kind frame is not ACKed or replay-dropped before its own-device commit',
      () async {
        final WireEnvelope frame;
        if (kind == 'notice') {
          frame = const WireEnvelope(
            WireKind.chatDeleted,
            '',
          ).withFrameId('notice-frame');
        } else {
          final space = _id(8), now = DateTime.now().millisecondsSinceEpoch;
          final card = SpaceRecommendationCard(
            campaignId: 'ab' * 32,
            spaceId: space,
            name: 'Fixture community',
            description: '',
            text: 'Fixture card',
            joinCode: SpaceJoinCode.encode(
              SpaceJoinTicket(
                ticketId: '11' * 32,
                spaceId: space,
                approver: peer,
                spaceName: 'Fixture community',
                createdAtMs: now,
                expiresAtMs: now + const Duration(days: 1).inMilliseconds,
              ),
            ),
          );
          frame = WireEnvelope.spaceRecommendation(
            card,
            id: 'card',
          ).withFrameId('card-frame');
        }
        var fail = true, calls = 0;
        service.onMessageStored = (_, _) async {
          calls++;
          if (fail) throw StateError('fixture journal refusal');
        };
        await receive(frame);
        expect(link.acks, isEmpty);
        await receive(frame);
        expect(calls, 2);
        expect(link.acks, isEmpty);
        fail = false;
        await receive(frame);
        expect(calls, 3);
        expect(link.acks, contains('$kind-frame'));
        if (kind == 'card') expect(link.acks, contains('card'));
        expect(await storage.loadMessages(peer.hex), hasLength(1));
      },
    );
  }
}
