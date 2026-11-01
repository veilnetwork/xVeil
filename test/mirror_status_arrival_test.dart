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
