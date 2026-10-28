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
import 'package:xveil/state/post_receipt_queue.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final entered = Completer<void>(), release = Completer<void>();
  final acknowledgements = <String>[];
  final destinations = <NodeId>[];
  final input = StreamController<InboundMessage>.broadcast();

  @override
  Stream<InboundMessage> messages() => input.stream;

  @override
  Future<void> dispose() async {
    await input.close();
    await super.dispose();
  }

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    if (frame.kind != WireKind.ack) return;
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    acknowledgements.add(frame.id!);
    destinations.add(dst);
  }
}

class _ReplyLink extends _Link {
  final replies = <int>[];

  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {
    replies.add(replyId);
    entered.complete();
    await release.future;
  }
}

void main() {
  test(
    'a retry keeps its direct ACK distinct from a parked one-time reply',
    () async {
      final link = _ReplyLink();
      final r = await _rig(transport: link);
      Future<void> receive(int reply) => r.service.deliverInbound(
        InboundMessage(
          src: _id(2),
          replyId: reply,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.message(
            'fixture',
            id: 'shared',
            seq: 1,
          ).encode(),
        ),
      );
      final first = receive(41);
      await link.entered.future;
      final repeat = receive(42);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      link.release.complete();
      await Future.wait([first, repeat]);
      expect(link.replies, [41]);
      expect(link.acknowledgements, ['shared']);
      expect(link.destinations, [_id(2)]);
      expect(await r.storage.loadMessages(_id(2).hex), hasLength(1));
    },
  );
  test(
    'a parked live receipt no longer owns the original inbound payload budget',
    () async {
      final r = await _rig();
      r.service.start();
      r.link.input.add(
        InboundMessage(
          src: _id(2),
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.message(
            'fixture body',
            id: 'live',
            seq: 1,
          ).encode(),
        ),
      );
      await r.link.entered.future;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (r.service.inboundAdmission.queuedFrames != 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(r.service.inboundAdmission.queuedFrames, 0);
      expect(r.service.inboundAdmission.queuedBytes, 0);
      expect(r.link.acknowledgements, isEmpty);
      expect(await r.storage.loadMessageById(_id(2).hex, 'live'), isNotNull);
      r.link.release.complete();
    },
  );
  test(
    'receipt count/byte budgets include the active send and coalesce pending retries',
    () async {
      final queue = PostReceiptQueue(maxJobs: 2, maxBytes: 12);
      final release = Completer<void>();
      final sent = <String>[];
      final first = queue.submit(
        key: 'first',
        bytes: 6,
        send: () async {
          await release.future;
          sent.add('first');
        },
      );
      final second = queue.submit(
        key: 'second',
        bytes: 6,
        send: () async => sent.add('second'),
      );
      final duplicate = queue.submit(
        key: 'first',
        bytes: 6,
        send: () async => fail('coalesced retry must not send'),
      );
      await queue.submit(
        key: 'overflow',
        bytes: 1,
        send: () async => fail('overflow must not send'),
      );
      expect(queue.pendingJobs, 2);
      expect(queue.pendingBytes, 12);
      expect(queue.coalesced, 1);
      expect(queue.dropped, 1);
      expect(identical(first, duplicate), isTrue);
      release.complete();
      await Future.wait([first, second]);
      expect(sent, ['first', 'second']);
      expect(queue.pendingJobs, 0);
      expect(queue.pendingBytes, 0);
      await queue.submit(
        key: 'first',
        bytes: 6,
        send: () async => sent.add('retry'),
      );
      expect(sent.last, 'retry');
      await queue.close();
    },
  );

  test(
    'an oversized receipt does not retain a job or call its sender',
    () async {
      final queue = PostReceiptQueue(maxBytes: 4);
      await queue.submit(
        key: 'large',
        bytes: 5,
        send: () async => fail('oversized job'),
      );
      expect(queue.dropped, 1);
      expect(queue.pendingJobs, 0);
      expect(queue.pendingBytes, 0);
      await queue.close();
    },
  );

  test(
    'a failed send or diagnostic callback cannot poison the next receipt',
    () async {
      final queue = PostReceiptQueue(
        onError: (_, _) => throw StateError('fixture diagnostic'),
      );
      final first = queue.submit(
        key: 'failure',
        bytes: 1,
        send: () async => throw StateError('fixture carrier'),
      );
      var secondSent = false;
      final second = queue.submit(
        key: 'healthy',
        bytes: 1,
        send: () async {
          secondSent = true;
        },
      );
      await Future.wait([first, second]);
      expect(queue.failed, 1);
      expect(secondSent, isTrue);
      expect(queue.pendingBytes, 0);
      await queue.close();
    },
  );

  test(
    'shutdown discards waiting receipts and joins its active send',
    () async {
      final queue = PostReceiptQueue();
      final release = Completer<void>();
      final first = queue.submit(
        key: 'active',
        bytes: 1,
        send: () => release.future,
      );
      final second = queue.submit(
        key: 'waiting',
        bytes: 1,
        send: () async => fail('waiting receipt after close'),
      );
      var closed = false;
      final close = queue.close().then((_) {
        closed = true;
      });
      await second;
      expect(closed, isFalse);
      expect(queue.pendingJobs, 1);
      await queue.submit(
        key: 'late',
        bytes: 1,
        send: () async => fail('late receipt after close'),
      );
      release.complete();
      await Future.wait([first, close]);
      expect(queue.pendingJobs, 0);
      expect(queue.pendingBytes, 0);
      await queue.close();
    },
  );

  test(
    'receipts for one identity remain addressed to their original physical devices',
    () async {
      final r = await _rig();
      Future<void> receive(NodeId device) => r.service.deliverInbound(
        InboundMessage(
          src: _id(2),
          srcDevice: device,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.message(
            'fixture',
            id: 'shared',
            seq: 1,
          ).encode(),
        ),
      );
      final first = receive(_id(4));
      await r.link.entered.future;
      final second = receive(_id(5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r.link.release.complete();
      await Future.wait([first, second]);
      expect(r.link.acknowledgements, ['shared', 'shared']);
      expect(r.link.destinations, [_id(4), _id(5)]);
      expect(await r.storage.loadMessages(_id(2).hex), hasLength(1));
    },
  );

  test(
    'a receipt discarded on service close is repaired from its stored post after restart',
    () async {
      final r = await _rig();
      Future<void> receive(MessagingService service, String id) =>
          service.deliverInbound(
            InboundMessage(
              src: _id(2),
              provenance: SenderProvenance.sessionPeer,
              payload: WireEnvelope.message(
                'fixture $id',
                id: id,
                seq: id == 'first' ? 1 : 2,
              ).encode(),
            ),
          );
      final first = receive(r.service, 'first');
      await r.link.entered.future;
      final second = receive(r.service, 'second');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (await r.storage.loadMessageById(_id(2).hex, 'second') == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await r.storage.loadMessageById(_id(2).hex, 'second'), isNotNull);
      var closed = false;
      final close = r.service.dispose().then((_) {
        closed = true;
      });
      await second;
      expect(closed, isFalse);
      r.link.release.complete();
      await Future.wait([first, close]);
      expect(r.link.acknowledgements, ['first']);
      final restarted = MessagingService(r.link, r.storage);
      addTearDown(restarted.dispose);
      await receive(restarted, 'second');
      expect(r.link.acknowledgements, ['first', 'second']);
      expect(await r.storage.loadMessages(_id(2).hex), hasLength(2));
    },
  );

  test(
    'a held post ACK does not stop another accepted message being stored',
    () async {
      final backing = FakeHvContainer();
      final storage = HiddenVolumeStorage(backing.passwordOpener);
      await storage.open(password: 'fixture', createIfMissing: true);
      final link = _Link();
      final service = MessagingService(link, storage);
      addTearDown(() async {
        if (!link.release.isCompleted) link.release.complete();
        await service.dispose();
        await storage.close();
        await link.dispose();
      });
      for (final peer in [_id(2), _id(3)]) {
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
      }
      Future<void> receive(NodeId peer, String id) => service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.message('fixture $id', id: id, seq: 1).encode(),
        ),
      );
      var firstSettled = false;
      final first = receive(_id(2), 'first').then((_) {
        firstSettled = true;
      });
      await link.entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(
        firstSettled,
        isFalse,
        reason: 'explicit delivery still joins its receipt',
      );
      expect(await storage.loadMessageById(_id(2).hex, 'first'), isNotNull);
      final second = receive(_id(3), 'second');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (await storage.loadMessageById(_id(3).hex, 'second') == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        await storage.loadMessageById(_id(3).hex, 'second'),
        isNotNull,
        reason:
            'durable dispatch must not wait for the previous peer ACK transport',
      );
      expect(link.acknowledgements, isEmpty);
      link.release.complete();
      await Future.wait([first, second]);
      expect(link.acknowledgements, ['first', 'second']);
    },
  );
}

Future<({HiddenVolumeStorage storage, _Link link, MessagingService service})>
_rig({_Link? transport}) async {
  final backing = FakeHvContainer();
  final storage = HiddenVolumeStorage(backing.passwordOpener);
  await storage.open(password: 'fixture', createIfMissing: true);
  final link = transport ?? _Link();
  final service = MessagingService(link, storage);
  await storage.upsertContact(
    Contact(nodeId: _id(2), status: ContactStatus.accepted),
  );
  addTearDown(() async {
    if (!link.release.isCompleted) link.release.complete();
    await service.dispose();
    await storage.close();
    await link.dispose();
  });
  return (storage: storage, link: link, service: service);
}
