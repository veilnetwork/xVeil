import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _Transport extends LoopbackTransport implements LocalSourceTransport {
  _Transport() : super(localNodeId: _id(1));
  final sent = <({WireEnvelope frame, int? lane, bool anonymous})>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add((
      frame: WireEnvelope.decode(payload),
      lane: null,
      anonymous: anonymous,
    ));
  }

  @override
  Future<void> sendOnLocalLane(
    NodeId dst,
    Uint8List payload, {
    required int localLane,
    bool anonymous = false,
  }) async {
    sent.add((
      frame: WireEnvelope.decode(payload),
      lane: localLane,
      anonymous: anonymous,
    ));
  }
}

void main() {
  for (final anonymous in [false, true]) {
    test(
      'bulk slices retain background lane after restart (anonymous: $anonymous)',
      () async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'test', createIfMissing: true);
        final peer = _id(2);
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        final transport = _Transport();
        final messaging = MessagingService(
          transport,
          storage,
          anonymous: anonymous,
        );
        await messaging.sendGroupSnapshot(peer, 'group', 'g' * 10000);
        await messaging.sendCloudDocumentFrame(peer, 'document', 'd' * 10000);
        await messaging.sendGroupSnapshot(peer, 'group', 'small group delta');
        await messaging.sendCloudDocumentFrame(
          peer,
          'document',
          'small document delta',
        );
        final initial = transport.sent.toList();
        final chunks = initial
            .where(
              (s) =>
                  s.frame.kind == WireKind.groupEntryChunk ||
                  s.frame.kind == WireKind.cloudDocumentChunk,
            )
            .toList();
        expect(chunks.length, greaterThan(2));
        expect(
          chunks.every((s) => s.lane == 3 && s.anonymous == anonymous),
          isTrue,
        );
        final small = initial
            .where(
              (s) =>
                  s.frame.kind == WireKind.groupEntry ||
                  s.frame.kind == WireKind.cloudDocument,
            )
            .toList();
        expect(small.length, 2);
        expect(
          small.every((s) => s.lane == null && s.anonymous == anonymous),
          isTrue,
        );
        final pending = await storage.pendingOutboxFrames();
        expect(pending.length, initial.length);
        await messaging.dispose();

        // A fresh service has no scheduling cache: it must recover the lane
        // from the persisted bytes, and preserve every frame id and payload.
        final restartedTransport = _Transport();
        final restarted = MessagingService(
          restartedTransport,
          storage,
          anonymous: anonymous,
        );
        addTearDown(restarted.dispose);
        await restarted.debugFlushOutboxFrames();
        expect(restartedTransport.sent.length, initial.length);
        for (final send in restartedTransport.sent) {
          final before = initial.singleWhere(
            (s) => s.frame.frameId == send.frame.frameId,
          );
          expect(send.frame.encode(), before.frame.encode());
          expect(send.lane, before.lane);
          expect(send.anonymous, anonymous);
        }
      },
    );

    test(
      'small file bodies use background lane and metadata stays normal (anonymous: $anonymous)',
      () async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'test', createIfMissing: true);
        final peer = _id(2);
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        final transport = _Transport();
        final messaging = MessagingService(
          transport,
          storage,
          anonymous: anonymous,
        );
        addTearDown(messaging.dispose);
        await messaging.sendFile(peer, Uint8List(6000), 'small.bin');
        final chunks = transport.sent
            .where((s) => s.frame.kind == WireKind.fileChunk)
            .toList();
        expect(chunks.length, greaterThan(1));
        expect(
          chunks.every((s) => s.lane == 3 && s.anonymous == anonymous),
          isTrue,
        );
        final meta = transport.sent.singleWhere(
          (s) => s.frame.kind == WireKind.fileMeta,
        );
        expect(meta.lane, isNull);
        expect(meta.anonymous, anonymous);
      },
    );
  }
}
