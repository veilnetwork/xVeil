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

void main() {
  final peer = _id(2);
  late HiddenVolumeStorage storage;
  late MessagingService service;
  late _Link link;
  Future<void> receive(WireEnvelope frame) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: frame.encode(),
    ),
  );
  Future<void> unsend() =>
      receive(const WireEnvelope.del('target').withFrameId('fixture-delete'));
  Future<void> post() =>
      receive(const WireEnvelope.message('original', id: 'target', seq: 5));
  Future<void> target({
    MessageDirection direction = MessageDirection.incoming,
  }) async {
    await storage.appendMessage(
      Message(
        id: 'target',
        conversationId: peer.hex,
        direction: direction,
        body: 'original',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        author: direction == MessageDirection.incoming ? peer.hex : _id(1).hex,
        seq: 5,
      ),
    );
  }

  setUp(() async {
    storage = FakeHvContainer().storage();
    await storage.open(password: 'fixture', createIfMissing: true);
    link = _Link();
    service = MessagingService(link, storage);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
  });
  tearDown(() async {
    await service.dispose();
    await storage.close();
  });

  test('pending unsend joins own-device publication before post ACK', () async {
    await unsend();
    final entered = Completer<void>(), release = Completer<void>();
    var notifications = 0;
    service.onMessageDeleted = (p, id) async {
      notifications++;
      expect(p, peer);
      expect(id, 'target');
      expect(await storage.isMessageDeleted(peer.hex, id), isTrue);
      entered.complete();
      await release.future;
    };
    final incoming = post();
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      expect(link.acks, isNot(contains('target')));
    } finally {
      release.complete();
      await incoming;
    }
    expect(link.acks, contains('target'));
    expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
    await unsend();
    expect(notifications, 1);
    expect(link.acks, contains('fixture-delete'));
  });

  test(
    'peer unsend before incoming device mirror publishes to own journal',
    () async {
      await unsend();
      final notifications = <String>[];
      service.onMessageDeleted = (_, id) async => notifications.add(id);
      await service.applyMirroredMessage(
        peer: peer,
        msgId: 'target',
        direction: MessageDirection.incoming,
        body: 'original',
        tsMs: 1000,
      );
      expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
      expect(notifications, ['target']);
    },
  );

  test('post retry finishes failed tombstone publication before ACK', () async {
    await unsend();
    var fail = true, calls = 0;
    service.onMessageDeleted = (_, _) async {
      calls++;
      if (fail) throw StateError('injected own-device journal refusal');
    };
    await post();
    expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
    expect(link.acks, isNot(contains('target')));
    fail = false;
    await post();
    expect(calls, 2);
    expect(link.acks, contains('target'));
    await unsend();
    expect(calls, 2);
    expect(link.acks, contains('fixture-delete'));
  });

  test('direct peer delete ACK joins own-device commit', () async {
    await target();
    final entered = Completer<void>(), release = Completer<void>();
    service.onMessageDeleted = (_, _) async {
      entered.complete();
      await release.future;
    };
    final deleting = unsend();
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      expect(link.acks, isNot(contains('fixture-delete')));
    } finally {
      release.complete();
      await deleting;
    }
    expect(link.acks, contains('fixture-delete'));
  });

  test(
    'failed own-device publication still announces the completed local erasure',
    () async {
      await target(direction: MessageDirection.outgoing);
      var changes = 0;
      final sub = service.changes.listen((_) => changes++);
      addTearDown(sub.cancel);
      service.onMessageDeleted = (_, _) async {
        throw StateError('injected own-device journal refusal');
      };
      await expectLater(
        service.deleteMessageLocally('target'),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(await storage.loadMessageById(peer.hex, 'target'), isNull);
      expect(changes, greaterThan(0));
    },
  );

  test('local delete completes after own-device commit', () async {
    await target(direction: MessageDirection.outgoing);
    final entered = Completer<void>(), release = Completer<void>();
    service.onMessageDeleted = (_, _) async {
      entered.complete();
      await release.future;
    };
    var completed = false;
    final deleting = service
        .deleteMessageLocally('target')
        .then((_) => completed = true);
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      expect(completed, isFalse);
    } finally {
      release.complete();
      await deleting;
    }
    expect(completed, isTrue);
  });

  test(
    'own-device pending tombstone never echoes as a new local delete',
    () async {
      var notifications = 0;
      service.onMessageDeleted = (_, _) async {
        notifications++;
      };
      await service.applyMirroredDelete(peer: peer, msgId: 'target');
      await service.applyMirroredMessage(
        peer: peer,
        msgId: 'target',
        direction: MessageDirection.incoming,
        body: 'original',
        tsMs: 1000,
      );
      expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
      await post();
      expect(notifications, 0);
    },
  );
}
