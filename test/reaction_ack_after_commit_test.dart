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

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

class _Link extends LoopbackTransport {
  _Link({NodeId? self}) : super(localNodeId: self ?? _id(1));
  final sent = <WireEnvelope>[];
  Future<void> Function(Uint8List payload)? forward;
  bool failAck = false;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(payload);
    if (frame.kind == WireKind.ack && failAck) {
      throw StateError('injected network failure');
    }
    sent.add(frame);
    await forward?.call(payload);
  }

  int acks(String fid) => sent
      .where((frame) => frame.kind == WireKind.ack && frame.id == fid)
      .length;
}

class _Publication extends HiddenVolumeStorage {
  _Publication(super.opener);
  bool refuseBefore = false, refuseAfter = false;
  Completer<void>? entered, release;
  int committed = 0;
  @override
  Future<void> storeFile(String id, Uint8List bytes, {String? name}) async {
    if (id.startsWith('rx2:')) {
      entered?.complete();
      await release?.future;
      if (refuseBefore) throw StateError('injected full container');
    }
    await super.storeFile(id, bytes, name: name);
    if (id.startsWith('rx2:')) {
      committed++;
      if (refuseAfter) throw StateError('injected interruption after commit');
    }
  }
}

void main() {
  final peer = _id(2);
  late FakeHvContainer backing;
  late _Publication storage;
  late _Link link;
  late MessagingService service;
  var mirrored = 0;
  const fid = 'fixture-reaction';

  Future<void> open() async {
    storage = _Publication(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    link = _Link();
    service = MessagingService(link, storage);
    service.onPeerReactionReceived = (_, _, _, _) => mirrored++;
  }

  Future<void> receive({
    String emoji = '👍',
    int stamp = 1000,
    String frameId = fid,
    SenderProvenance proof = SenderProvenance.sessionPeer,
  }) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: proof,
      payload: WireEnvelope.reaction(
        'message',
        emoji,
        sentAtMs: stamp,
      ).withFrameId(frameId).encode(),
    ),
  );

  Future<String?> value() async =>
      (await service.loadReactions(peer.hex))['message']?[peer.hex];

  setUp(() async {
    backing = FakeHvContainer();
    mirrored = 0;
    await open();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
  });
  tearDown(() async {
    await service.dispose();
    await storage.close();
  });

  test('reaction ACK waits for durable publication', () async {
    final entered = storage.entered = Completer<void>();
    final release = storage.release = Completer<void>();
    final pending = receive();
    try {
      await entered.future;
      expect(link.acks(fid), 0);
      expect(mirrored, 0);
    } finally {
      release.complete();
      await pending;
    }
    expect(await value(), '👍');
    expect(link.acks(fid), 1);
    expect(mirrored, 1);
  });

  test('failed write leaves the same frame eligible for retry', () async {
    storage.refuseBefore = true;
    await receive();
    expect(await value(), isNull);
    expect(link.acks(fid), 0);
    expect(mirrored, 0);
    storage.refuseBefore = false;
    await receive();
    expect(await value(), '👍');
    expect(link.acks(fid), 1);
    expect(mirrored, 1);
    await receive();
    expect(link.acks(fid), 2);
    expect(mirrored, 1);
    expect(storage.committed, 1);
  });

  test(
    'interruption after commit reopens and retries without losing removal floor',
    () async {
      await receive();
      storage.refuseAfter = true;
      await receive(emoji: '', stamp: 2000, frameId: 'fixture-remove');
      expect(link.acks('fixture-remove'), 0);
      await service.dispose();
      await storage.close();
      await open();
      expect(await value(), isNull);
      await receive(emoji: '', stamp: 2000, frameId: 'fixture-remove');
      expect(link.acks('fixture-remove'), 1);
      expect(
        storage.committed,
        0,
        reason: 'already-durable value needs no rewrite',
      );
      await receive(stamp: 1999, frameId: 'fixture-older');
      expect(await value(), isNull);
      expect(link.acks('fixture-older'), 1);
    },
  );

  test(
    'lost ACK re-ACKs without repeating publication or sibling callback',
    () async {
      link.failAck = true;
      await receive();
      expect(await value(), '👍');
      expect(link.acks(fid), 0);
      link.failAck = false;
      await receive();
      expect(link.acks(fid), 1);
      expect(storage.committed, 1);
      expect(mirrored, 1);
    },
  );

  test('claimed copy cannot ACK or consume the authenticated retry', () async {
    await receive(proof: SenderProvenance.claimed);
    expect(link.acks(fid), 0);
    expect(await value(), isNull);
    await receive();
    expect(await value(), '👍');
    expect(link.acks(fid), 1);
  });

  test(
    'real sender outbox keeps a refused reaction until the retry commits',
    () async {
      final senderStorage = FakeHvContainer().storage();
      await senderStorage.open(
        password: 'sender-fixture',
        createIfMissing: true,
      );
      addTearDown(senderStorage.close);
      await senderStorage.upsertContact(
        Contact(nodeId: _id(1), status: ContactStatus.accepted),
      );
      var now = DateTime.fromMillisecondsSinceEpoch(100000);
      final senderLink = _Link(self: peer);
      final sender = MessagingService(
        senderLink,
        senderStorage,
        now: () => now,
      );
      addTearDown(sender.dispose);
      senderLink.forward = (payload) => service.deliverInbound(
        InboundMessage(
          src: peer,
          payload: payload,
          provenance: SenderProvenance.sessionPeer,
        ),
      );
      link.forward = (payload) => sender.deliverInbound(
        InboundMessage(
          src: _id(1),
          payload: payload,
          provenance: SenderProvenance.sessionPeer,
        ),
      );

      storage.refuseBefore = true;
      await sender.sendReaction(_id(1), 'message', '👍');
      expect(await value(), isNull);
      final queued = (await senderStorage.pendingOutboxFrames()).single;
      expect(WireEnvelope.decode(queued.wire).kind, WireKind.reaction);
      expect(link.acks(queued.frameId), 0);

      storage.refuseBefore = false;
      now = now.add(const Duration(minutes: 1));
      await sender.flushOutbox();
      expect(await value(), '👍');
      expect(await senderStorage.pendingOutboxFrames(), isEmpty);
      expect(link.acks(queued.frameId), 1);
      expect(mirrored, 1);
    },
  );
}
