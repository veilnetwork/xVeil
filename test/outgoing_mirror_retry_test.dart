import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final posts = <WireEnvelope>[];

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    if (frame.kind == WireKind.message) posts.add(frame);
  }
}

class _HeldStorage extends HiddenVolumeStorage {
  _HeldStorage(super.opener);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Message> appendMessage(Message message) async {
    final stored = await super.appendMessage(message);
    entered.complete();
    await release.future;
    return stored;
  }
}

void main() {
  for (final status in [MessageStatus.delivered, MessageStatus.failed]) {
    test(
      'terminal history is never exposed as a retry job: ${status.name}',
      () async {
        final storage = _HeldStorage(FakeHvContainer().passwordOpener);
        await storage.open(password: 'fixture', createIfMissing: true);
        final peer = _id(2), link = _Link();
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        final service = MessagingService(link, storage);
        final applying = service.applyMirroredMessage(
          peer: peer,
          msgId: 'old-${status.name}',
          direction: MessageDirection.outgoing,
          status: status,
          body: 'already completed elsewhere',
          tsMs: DateTime.now().millisecondsSinceEpoch,
          author: _id(3).hex,
          seq: 1,
        );
        try {
          await storage.entered.future;
          expect((await storage.loadMessages(peer.hex)).single.status, status);
          await service.flushOutbox();
          expect(
            link.posts,
            isEmpty,
            reason:
                'even a retry racing append completion must see terminal status',
          );
        } finally {
          storage.release.complete();
          await applying;
          await service.dispose();
          await storage.close();
        }
      },
    );
  }

  test(
    'delivered history repairs an existing sent copy without replacing its contents',
    () async {
      final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2), link = _Link();
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final service = MessagingService(link, storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      final at = DateTime.now().millisecondsSinceEpoch;
      await service.applyMirroredMessage(
        peer: peer,
        msgId: 'held',
        direction: MessageDirection.outgoing,
        body: 'original',
        tsMs: at,
        author: _id(3).hex,
        seq: 1,
      );
      expect(
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'held',
          direction: MessageDirection.outgoing,
          status: MessageStatus.delivered,
          body: 'must not replace original',
          tsMs: at + 100,
        ),
        isTrue,
      );
      final held = (await storage.loadMessages(peer.hex)).single;
      expect(held.status, MessageStatus.delivered);
      expect(held.body, 'original');
      expect(held.timestamp.millisecondsSinceEpoch, at);
      expect(held.author, _id(3).hex);
      expect(held.seq, 1);
      expect(
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'held',
          direction: MessageDirection.outgoing,
          status: MessageStatus.failed,
          body: 'stale failure',
          tsMs: at + 200,
        ),
        isFalse,
      );
      expect(
        (await storage.loadMessages(peer.hex)).single.status,
        MessageStatus.delivered,
      );
      await service.flushOutbox();
      expect(link.posts, isEmpty);
      await storage.deleteMessage(peer.hex, 'held');
      expect(
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'held',
          direction: MessageDirection.outgoing,
          status: MessageStatus.delivered,
          body: 'deleted',
          tsMs: at,
        ),
        isFalse,
      );
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  test('outgoing completion does not change a same-id incoming row', () async {
    final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    final service = MessagingService(_Link(), storage);
    addTearDown(() async {
      await service.dispose();
      await storage.close();
    });
    final peer = _id(2), at = DateTime.now().millisecondsSinceEpoch;
    await service.applyMirroredMessage(
      peer: peer,
      msgId: 'incoming',
      direction: MessageDirection.incoming,
      body: 'received',
      tsMs: at,
    );
    expect(
      await service.applyMirroredMessage(
        peer: peer,
        msgId: 'incoming',
        direction: MessageDirection.outgoing,
        status: MessageStatus.delivered,
        body: 'wrong direction',
        tsMs: at,
      ),
      isFalse,
    );
    final held = (await storage.loadMessages(peer.hex)).single;
    expect(held.direction, MessageDirection.incoming);
    expect(held.body, 'received');
  });

  test(
    'background retry defers an unfinished own-device journal commit',
    () async {
      final backing = FakeHvContainer();
      final storage = HiddenVolumeStorage(backing.passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final link = _Link();
      final service = MessagingService(link, storage);
      final entered = Completer<void>(), release = Completer<void>();
      var publications = 0;
      service.onMessageStored = (_, _) async {
        publications++;
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final send = service.sendText(peer, 'durable before network');
      await entered.future;
      final retry = service.flushOutbox();
      try {
        await retry.timeout(const Duration(seconds: 2));
        expect(
          link.posts,
          isEmpty,
          reason: 'a retry must not publish a row before its recovery journal',
        );
        expect(
          publications,
          1,
          reason: 'both send paths must share one commit',
        );
      } finally {
        release.complete();
        await send;
        await retry;
        await service.dispose();
        await storage.close();
      }
      expect(link.posts, isNotEmpty);
    },
  );

  test(
    'retry cannot overtake an append that exposed its row before returning',
    () async {
      final storage = _HeldStorage(FakeHvContainer().passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final link = _Link();
      final service = MessagingService(link, storage);
      var publications = 0;
      service.onMessageStored = (_, _) async => publications++;
      final send = service.sendText(peer, 'visible before append returns');
      try {
        await storage.entered.future;
        expect(await storage.loadMessages(peer.hex), hasLength(1));
        await service.flushOutbox();
        expect(link.posts, isEmpty);
        expect(publications, 0);
      } finally {
        storage.release.complete();
        await send;
        await service.dispose();
        await storage.close();
      }
      expect(publications, 1);
      expect(link.posts, hasLength(1));
    },
  );

  test(
    'failed journal publication is repaired before a retry reaches the peer',
    () async {
      final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final link = _Link();
      final service = MessagingService(link, storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      var fail = true, publications = 0;
      service.onMessageStored = (_, _) async {
        publications++;
        if (fail) throw StateError('fixture journal refusal');
      };
      await expectLater(
        service.sendText(peer, 'recover locally'),
        throwsStateError,
      );
      expect(await storage.loadMessages(peer.hex), hasLength(1));
      await expectLater(service.flushOutbox(), throwsStateError);
      expect(link.posts, isEmpty);
      fail = false;
      await service.flushOutbox();
      expect(link.posts.single.body, 'recover locally');
      expect(publications, 3);
      await service.flushOutbox();
      expect(publications, 3, reason: 'successful publication is not repeated');
    },
  );

  test(
    'restart recovery repairs publication once across concurrent retries',
    () async {
      final backing = FakeHvContainer();
      var storage = HiddenVolumeStorage(backing.passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      var service = MessagingService(_Link(), storage);
      service.onMessageStored = (_, _) async =>
          throw StateError('interrupted journal');
      await expectLater(
        service.sendText(peer, 'recover after restart'),
        throwsStateError,
      );
      await service.dispose();
      await storage.close();
      storage = HiddenVolumeStorage(backing.passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: false);
      final link = _Link();
      service = MessagingService(link, storage);
      final entered = Completer<void>(), release = Completer<void>();
      var publications = 0;
      service.onMessageStored = (_, _) async {
        publications++;
        entered.complete();
        await release.future;
      };
      final first = service.flushOutbox();
      try {
        await entered.future.timeout(const Duration(seconds: 2));
        await service.flushOutbox().timeout(const Duration(seconds: 2));
        expect(link.posts, isEmpty);
        expect(publications, 1);
      } finally {
        release.complete();
        await first;
        await service.dispose();
        await storage.close();
      }
      expect(link.posts.single.body, 'recover after restart');
    },
  );

  test('gap-fill cannot send a post before its local journal commit', () async {
    final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    final peer = _id(2);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final link = _Link();
    var clock = DateTime.now();
    final service = MessagingService(link, storage, now: () => clock);
    final entered = Completer<void>(), release = Completer<void>();
    service.onMessageStored = (_, _) async {
      entered.complete();
      await release.future;
    };
    final send = service.sendText(peer, 'do not gap-fill early');
    Future<void> ask() => service.deliverInbound(
      InboundMessage(
        src: peer,
        provenance: SenderProvenance.sessionPeer,
        payload: WireEnvelope.sync('{"hw":{}}').encode(),
      ),
    );
    try {
      await entered.future;
      for (var i = 0; i < 3; i++) {
        await ask();
        clock = clock.add(const Duration(seconds: 6));
      }
      expect(link.posts, isEmpty);
    } finally {
      release.complete();
      await send;
    }
    try {
      expect(link.posts.single.body, 'do not gap-fill early');
      link.posts.clear();
      await ask();
      expect(
        link.posts.single.body,
        'do not gap-fill early',
        reason: 'deferred local commits must not consume network reship rounds',
      );
    } finally {
      await service.dispose();
      await storage.close();
    }
  });

  test(
    'a pending local commit does not park retries for another conversation',
    () async {
      final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2), other = _id(4);
      for (final id in [peer, other]) {
        await storage.upsertContact(
          Contact(nodeId: id, status: ContactStatus.accepted),
        );
      }
      final link = _Link();
      final service = MessagingService(link, storage);
      final entered = Completer<void>(), release = Completer<void>();
      service.onMessageStored = (to, _) async {
        if (to == peer) {
          entered.complete();
          await release.future;
        }
      };
      final send = service.sendText(peer, 'held journal');
      try {
        await entered.future;
        await service.sendText(other, 'independent conversation');
        link.posts.clear();
        await service.flushOutbox().timeout(const Duration(seconds: 2));
        expect(link.posts.map((p) => p.body), ['independent conversation']);
      } finally {
        release.complete();
        await send;
        await service.dispose();
        await storage.close();
      }
    },
  );

  test(
    'retry of a sibling projection does not publish it back to the journal',
    () async {
      final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final link = _Link();
      final service = MessagingService(link, storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      service.onMessageStored = (_, _) => throw StateError('must not loop');
      expect(
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'sibling-post',
          direction: MessageDirection.outgoing,
          body: 'from my other device',
          tsMs: DateTime.now().millisecondsSinceEpoch,
          author: _id(3).hex,
          seq: 1,
        ),
        isTrue,
      );
      await service.flushOutbox();
      expect(link.posts.single.id, 'sibling-post');
    },
  );

  test(
    'gap-fill of delivered history does not republish old journal rows',
    () async {
      final storage = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final peer = _id(2);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final link = _Link();
      final service = MessagingService(link, storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      await service.sendText(peer, 'delivered history');
      await storage.markMessageStatus(
        peer.hex,
        link.posts.single.id!,
        MessageStatus.delivered,
      );
      link.posts.clear();
      service.onMessageStored = (_, _) =>
          throw StateError('old history must not churn');
      await service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.sync('{"hw":{}}').encode(),
        ),
      );
      expect(link.posts.single.body, 'delivered history');
    },
  );
}
