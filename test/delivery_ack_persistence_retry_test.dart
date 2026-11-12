import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

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

class _CommitFault extends FakeKvLogStore {
  bool refuseStatus = false;
  bool afterCommit = false;
  int refusals = 0;
  @override
  int commit(List<KvLogOp> ops) {
    if (refuseStatus &&
        ops.whereType<AppendLogOp>().any(
          (op) =>
              (jsonDecode(utf8.decode(op.payload)) as Map)['op'] == 'status',
        )) {
      refusals++;
      if (afterCommit) super.commit(ops);
      throw StateError('fixture status commit refusal');
    }
    return super.commit(ops);
  }
}

class _HeldStatus extends HiddenVolumeStorage {
  _HeldStatus(super.opener);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> markMessageStatus(
    String peer,
    String id,
    MessageStatus status,
  ) async {
    entered.complete();
    await release.future;
    return super.markMessageStatus(peer, id, status);
  }
}

class _ReadFault extends HiddenVolumeStorage {
  _ReadFault(super.opener);
  bool refuseTarget = false;
  int refusals = 0;
  @override
  Future<Message?> loadMessageById(String peer, String id) {
    if (refuseTarget) {
      refusals++;
      throw StateError('fixture target read refusal');
    }
    return super.loadMessageById(peer, id);
  }
}

void main() {
  final peer = _id(2);
  for (final fault in ['read', 'commit', 'commit-response']) {
    for (final recovery in ['repeat-ack', 'resend']) {
      test(
        'ACK persistence recovers after $fault refusal via $recovery',
        () async {
          final backing = _CommitFault();
          final storage = _ReadFault(
            ({required password, required bool create}) => backing,
          );
          await storage.open(password: 'fixture', createIfMissing: true);
          await storage.upsertContact(
            Contact(nodeId: peer, status: ContactStatus.accepted),
          );
          final link = _Link();
          final service = MessagingService(link, storage);
          addTearDown(() async {
            await service.dispose();
            await storage.close();
          });
          await service.sendText(peer, 'delivery persistence fixture');
          final id = (await storage.loadMessages(peer.hex)).single.id;
          final mirrored = <String>[];
          service.onMessageStatusChanged = (to, messageId, status) {
            expect(to, peer);
            expect(status, MessageStatus.delivered);
            mirrored.add(messageId);
          };
          Future<void> ack() => service.deliverInbound(
            InboundMessage(
              src: peer,
              provenance: SenderProvenance.sessionPeer,
              payload: WireEnvelope.ack(id).encode(),
            ),
          );
          link.posts.clear();
          storage.refuseTarget = fault == 'read';
          backing.refuseStatus = fault != 'read';
          backing.afterCommit = fault == 'commit-response';
          await ack();
          expect(
            fault == 'read' ? storage.refusals : backing.refusals,
            greaterThan(0),
          );
          storage.refuseTarget = false;
          backing.refuseStatus = false;
          expect(
            (await storage.loadMessageById(peer.hex, id))!.status,
            fault == 'commit-response'
                ? MessageStatus.delivered
                : MessageStatus.sent,
          );
          expect(mirrored, isEmpty);

          if (recovery == 'resend') {
            await service.flushOutbox();
            expect(
              link.posts,
              fault == 'commit-response' ? isNot(contains(id)) : contains(id),
              reason: 'failed persistence must not suppress receipt recovery',
            );
          }
          await ack();
          expect(
            (await storage.loadMessageById(peer.hex, id))!.status,
            MessageStatus.delivered,
          );
          expect(mirrored, fault == 'commit-response' ? isEmpty : [id]);
          final committed = backing.commitSeq();
          await ack();
          expect(
            backing.commitSeq(),
            committed,
            reason: 'settled duplicate ACK must remain write-free',
          );
          expect(mirrored, fault == 'commit-response' ? isEmpty : [id]);
          expect(await storage.loadMessages(peer.hex), hasLength(1));
          link.posts.clear();
          await service.flushOutbox();
          expect(link.posts, isEmpty);
        },
      );
    }
  }
  test('pending ACK persistence still cancels a racing resend', () async {
    final backing = FakeKvLogStore();
    final storage = _HeldStatus(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final link = _Link();
    final service = MessagingService(link, storage);
    addTearDown(() async {
      await service.dispose();
      await storage.close();
    });
    await service.sendText(peer, 'held persistence fixture');
    final id = (await storage.loadMessages(peer.hex)).single.id;
    final pending = service.deliverInbound(
      InboundMessage(
        src: peer,
        provenance: SenderProvenance.sessionPeer,
        payload: WireEnvelope.ack(id).encode(),
      ),
    );
    try {
      await storage.entered.future;
      link.posts.clear();
      await service.flushOutbox();
      expect(link.posts, isEmpty);
      expect(
        (await storage.loadMessageById(peer.hex, id))!.status,
        MessageStatus.sent,
      );
    } finally {
      storage.release.complete();
      await pending;
    }
    expect(
      (await storage.loadMessageById(peer.hex, id))!.status,
      MessageStatus.delivered,
    );
  });
}
