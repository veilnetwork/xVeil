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
  final posts = <String>[];

  @override
  Future<void> send(
    NodeId dst,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    if (frame.kind == WireKind.message) posts.add(frame.id!);
  }
}

class _StatusWrites extends HiddenVolumeStorage {
  _StatusWrites(super.opener);
  int statusCalls = 0;

  @override
  Future<bool> markMessageStatus(
    String convHex,
    String msgId,
    MessageStatus status,
  ) {
    statusCalls++;
    return super.markMessageStatus(convHex, msgId, status);
  }
}

class _HeldAppend extends HiddenVolumeStorage {
  _HeldAppend(super.opener, {required this.beforeVisibility});
  final bool beforeVisibility;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<Message> appendMessage(Message row) async {
    if (beforeVisibility) {
      entered.complete();
      await release.future;
      return super.appendMessage(row);
    }
    final result = await super.appendMessage(row);
    entered.complete();
    await release.future;
    return result;
  }
}

void main() {
  final peer = _id(2), other = _id(4);
  late HiddenVolumeStorage storage;
  late MessagingService service;
  late _Link link;

  Future<void> open([HiddenVolumeStorage? candidate]) async {
    storage =
        candidate ?? HiddenVolumeStorage(FakeHvContainer().passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    for (final p in [peer, other]) {
      await storage.upsertContact(
        Contact(nodeId: p, status: ContactStatus.accepted),
      );
    }
    link = _Link();
    service = MessagingService(link, storage);
  }

  Future<void> close() async {
    await service.dispose();
    await storage.close();
  }

  Future<bool> mirror(NodeId to, String id) => service.applyMirroredMessage(
    peer: to,
    msgId: id,
    direction: MessageDirection.outgoing,
    body: 'from my other device',
    tsMs: DateTime.now().millisecondsSinceEpoch,
    author: _id(3).hex,
    seq: 1,
  );

  Future<void> delivered(NodeId to, String id) =>
      service.applyMirroredMessageStatus(
        peer: to,
        msgId: id,
        status: MessageStatus.delivered,
      );

  for (final receiptFirst in [false, true]) {
    test(
      'a duplicate delivered mirror does not requeue status, receiptFirst=$receiptFirst',
      () async {
        final counted = _StatusWrites(FakeHvContainer().passwordOpener);
        await open(counted);
        addTearDown(close);
        await storage.appendMessage(
          Message(
            id: 'already-delivered',
            conversationId: peer.hex,
            direction: MessageDirection.outgoing,
            body: 'original durable body',
            timestamp: DateTime.utc(2020),
            status: MessageStatus.delivered,
          ),
        );
        if (receiptFirst) await delivered(peer, 'already-delivered');
        counted.statusCalls = 0;
        final changed = await service.applyMirroredMessage(
          peer: peer,
          msgId: 'already-delivered',
          direction: MessageDirection.outgoing,
          body: 'duplicate must not replace original',
          tsMs: DateTime.now().millisecondsSinceEpoch,
          status: receiptFirst ? null : MessageStatus.delivered,
        );
        expect(changed, isFalse);
        expect(
          counted.statusCalls,
          0,
          reason: 'the freshly read row already carries terminal delivery',
        );
        final rows = await storage.loadMessages(peer.hex);
        expect(rows, hasLength(1));
        expect(rows.single.body, 'original durable body');
        expect(
          rows.single.timestamp.millisecondsSinceEpoch,
          DateTime.utc(2020).millisecondsSinceEpoch,
        );
        expect(rows.single.status, MessageStatus.delivered);
        await service.flushOutbox();
        expect(link.posts, isEmpty);
      },
    );
  }

  for (final previous in [
    MessageStatus.sending,
    MessageStatus.sent,
    MessageStatus.failed,
  ]) {
    test('a delivered mirror still repairs $previous exactly once', () async {
      final counted = _StatusWrites(FakeHvContainer().passwordOpener);
      await open(counted);
      addTearDown(close);
      await storage.appendMessage(
        Message(
          id: 'needs-repair',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: 'unchanged body',
          timestamp: DateTime.utc(2020),
          status: previous,
        ),
      );
      Future<bool> apply() => service.applyMirroredMessage(
        peer: peer,
        msgId: 'needs-repair',
        direction: MessageDirection.outgoing,
        body: 'duplicate body',
        tsMs: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.delivered,
      );
      expect(await apply(), isTrue);
      expect(counted.statusCalls, 1);
      expect(
        (await storage.loadMessageById(peer.hex, 'needs-repair'))!.status,
        MessageStatus.delivered,
      );
      expect(await apply(), isFalse);
      expect(counted.statusCalls, 1);
      expect(
        (await storage.loadMessages(peer.hex)).single.body,
        'unchanged body',
      );
    });
  }

  test(
    'a delivered duplicate still adopts its original device position',
    () async {
      final counted = _StatusWrites(FakeHvContainer().passwordOpener);
      await open(counted);
      addTearDown(close);
      final author = _id(3);
      service.isOwnDevice = (node) async => node == author;
      await storage.appendMessage(
        Message(
          id: 'canonical-position',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: 'peer echo remains unchanged',
          timestamp: DateTime.utc(2020),
          status: MessageStatus.delivered,
          author: peer.hex,
          seq: 99,
          positionVerified: false,
        ),
      );
      expect(
        await service.applyMirroredMessage(
          peer: peer,
          msgId: 'canonical-position',
          direction: MessageDirection.outgoing,
          body: 'original device mirror',
          tsMs: DateTime.now().millisecondsSinceEpoch,
          status: MessageStatus.delivered,
          author: author.hex,
          seq: 1,
          positionVerified: true,
        ),
        isTrue,
      );
      final held = (await storage.loadMessageById(
        peer.hex,
        'canonical-position',
      ))!;
      expect(held.body, 'peer echo remains unchanged');
      expect(held.author, peer.hex);
      expect(held.seq, 99);
      expect(held.orderAuthor, author.hex);
      expect(held.orderSeq, 1);
      expect(held.status, MessageStatus.delivered);
      expect(
        counted.statusCalls,
        0,
        reason: 'skip a status no-op without skipping ordering adoption',
      );
    },
  );

  test(
    'a sibling delivery report before its mirror is retained without orphan rows',
    () async {
      await open();
      addTearDown(close);
      var echoed = 0;
      service.onMessageStatusChanged = (_, _, _) => echoed++;
      await delivered(peer, 'status-first');
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(await mirror(peer, 'status-first'), isTrue);
      expect(
        (await storage.loadMessageById(peer.hex, 'status-first'))!.status,
        MessageStatus.delivered,
      );
      await service.flushOutbox();
      expect(link.posts, isEmpty);
      expect(
        echoed,
        0,
        reason: 'an own-device receipt must not be published back',
      );
    },
  );

  for (final before in [true, false]) {
    test(
      'sibling delivery races an unfinished append, beforeVisibility=$before',
      () async {
        final held = _HeldAppend(
          FakeHvContainer().passwordOpener,
          beforeVisibility: before,
        );
        await open(held);
        addTearDown(close);
        final applying = mirror(peer, 'in-flight');
        try {
          await held.entered.future;
          await delivered(peer, 'in-flight');
          await service.flushOutbox();
          expect(
            link.posts,
            isEmpty,
            reason: 'known delivery must stop a racing retry',
          );
        } finally {
          held.release.complete();
          await applying;
        }
        expect(
          (await storage.loadMessageById(peer.hex, 'in-flight'))!.status,
          MessageStatus.delivered,
        );
        await service.flushOutbox();
        expect(link.posts, isEmpty);
      },
    );
  }

  test('pending sibling delivery is scoped to its conversation', () async {
    await open();
    addTearDown(close);
    await delivered(peer, 'same-id');
    await mirror(other, 'same-id');
    expect(
      (await storage.loadMessageById(other.hex, 'same-id'))!.status,
      MessageStatus.sent,
    );
    await mirror(peer, 'same-id');
    expect(
      (await storage.loadMessageById(peer.hex, 'same-id'))!.status,
      MessageStatus.delivered,
    );
  });

  test(
    'delivery arriving during retry preparation prevents the stale send',
    () async {
      await open();
      addTearDown(close);
      await service.sendText(peer, 'local interrupted-publication recovery');
      final id = (await storage.loadMessages(peer.hex)).single.id;
      link.posts.clear();
      final entered = Completer<void>(), release = Completer<void>();
      service.onMessageStored = (_, _) async {
        entered.complete();
        await release.future;
      };
      final retrying = service.flushOutbox();
      try {
        await entered.future;
        await delivered(peer, id);
      } finally {
        release.complete();
        await retrying;
      }
      expect(
        link.posts,
        isEmpty,
        reason:
            'receipt can arrive after retry admission but before its prepared send',
      );
      expect(
        (await storage.loadMessageById(peer.hex, id))!.status,
        MessageStatus.delivered,
      );
    },
  );

  test(
    'an ordinary peer ACK for a missing row cannot pre-authorize a future mirror',
    () async {
      await open();
      addTearDown(close);
      await service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.ack('not-stored-yet').encode(),
        ),
      );
      expect(await storage.loadMessages(peer.hex), isEmpty);
      await mirror(peer, 'not-stored-yet');
      expect(
        (await storage.loadMessageById(peer.hex, 'not-stored-yet'))!.status,
        MessageStatus.sent,
      );
    },
  );

  test('delivery of an erased row does not restore the row', () async {
    await open();
    addTearDown(close);
    await mirror(peer, 'erased');
    await storage.deleteMessage(peer.hex, 'erased');
    await delivered(peer, 'erased');
    expect(await mirror(peer, 'erased'), isFalse);
    expect(await storage.loadMessages(peer.hex), isEmpty);
  });

  test(
    'delivery recovered across arrival order persists without the session cache',
    () async {
      final backing = FakeHvContainer();
      await open(HiddenVolumeStorage(backing.passwordOpener));
      addTearDown(close);
      await delivered(peer, 'durable-result');
      await mirror(peer, 'durable-result');
      await close();
      await open(HiddenVolumeStorage(backing.passwordOpener));
      expect(
        (await storage.loadMessageById(peer.hex, 'durable-result'))!.status,
        MessageStatus.delivered,
      );
      await service.flushOutbox();
      expect(link.posts, isEmpty);
    },
  );
}
