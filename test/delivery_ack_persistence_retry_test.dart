import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
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
  final postPeers = <NodeId>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    if (frame.kind == WireKind.message) {
      posts.add(frame.id!);
      postPeers.add(dst);
    }
  }
}

class _CommitFault extends FakeKvLogStore {
  bool refuseStatus = false;
  bool afterCommit = false;
  final refusedIds = <String>{};
  int refusals = 0;
  @override
  int commit(List<KvLogOp> ops) {
    if (ops.whereType<AppendLogOp>().any((op) {
      final row = jsonDecode(utf8.decode(op.payload)) as Map;
      return row['op'] == 'status' &&
          (refuseStatus || refusedIds.contains(row['id']));
    })) {
      refusals++;
      if (afterCommit) super.commit(ops);
      throw StateError('fixture status commit refusal');
    }
    return super.commit(ops);
  }
}

class _HeldStatus extends HiddenVolumeStorage {
  _HeldStatus(super.opener, {this.hold = true});
  bool hold;
  int calls = 0;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> markMessageStatus(
    String peer,
    String id,
    MessageStatus status,
  ) async {
    calls++;
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.markMessageStatus(peer, id, status);
  }
}

class _ReadFault extends HiddenVolumeStorage {
  _ReadFault(super.opener);
  bool refuseTarget = false;
  int refusals = 0;
  final reads = <String>{};
  @override
  Future<Message?> loadMessageById(String peer, String id) {
    reads.add(id);
    if (refuseTarget) {
      refusals++;
      throw StateError('fixture target read refusal');
    }
    return super.loadMessageById(peer, id);
  }
}

void main() {
  final peer = _id(2);
  Future<void> ack(MessagingService service, String id, [NodeId? sender]) =>
      service.deliverInbound(
        InboundMessage(
          src: sender ?? peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.ack(id).encode(),
        ),
      );

  test(
    'blocked status retry does not stop later delivery timer ticks',
    () async {
      late FakeAsync timer;
      late _HeldStatus storage;
      late MessagingService service;
      try {
        fakeAsync((time) {
          timer = time;
          T finish<T>(Future<T> work) {
            var done = false;
            late T result;
            work.then((value) {
              result = value;
              done = true;
            });
            time.flushMicrotasks();
            time.elapse(Duration.zero);
            expect(
              done,
              isTrue,
              reason: 'in-memory setup must drain without time',
            );
            return result;
          }

          final backing = _CommitFault();
          storage = _HeldStatus(
            ({required password, required bool create}) => backing,
            hold: false,
          );
          finish(storage.open(password: 'fixture', createIfMissing: true));
          finish(
            storage.upsertContact(
              Contact(nodeId: peer, status: ContactStatus.accepted),
            ),
          );
          final link = _Link();
          service = MessagingService(link, storage);
          try {
            finish(service.sendText(peer, 'ACK waiting for local storage'));
            final id = finish(storage.loadMessages(peer.hex)).single.id;
            backing.refuseStatus = true;
            finish(ack(service, id));
            backing.refuseStatus = false;
            storage.hold = true;
            service.start();
            time.elapse(const Duration(seconds: 3));
            time.flushMicrotasks();
            expect(storage.entered.isCompleted, isTrue);
            finish(
              storage.appendMessage(
                Message(
                  id: 'later-message',
                  conversationId: peer.hex,
                  direction: MessageDirection.outgoing,
                  body: 'independent delivery',
                  timestamp: DateTime.now(),
                  status: MessageStatus.sent,
                ),
              ),
            );
            link.posts.clear();
            time.elapse(const Duration(seconds: 3));
            time.flushMicrotasks();
            expect(link.posts, contains('later-message'));
          } finally {
            storage.release.complete();
            time.flushMicrotasks();
          }
        });
      } finally {
        Future<void> join(Future<void> work) async {
          var done = false;
          work.then((_) => done = true);
          for (var i = 0; i < 100 && !done; i++) {
            timer.flushMicrotasks();
            timer.elapse(Duration.zero);
            await Future<void>.value();
          }
          expect(done, isTrue, reason: 'both fixture zones must drain');
          await work;
        }

        await join(service.dispose());
        await join(storage.close());
      }
    },
  );

  test('failed first page does not starve later receipts', () async {
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
    final ids = [for (var i = 0; i < 70; i++) 'receipt-$i'];
    for (final id in ids) {
      await storage.appendMessage(
        Message(
          id: id,
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: id,
          timestamp: DateTime.now().subtract(const Duration(minutes: 91)),
          status: MessageStatus.sent,
        ),
      );
    }
    backing.refuseStatus = true;
    for (final id in ids) {
      await ack(service, id);
    }
    backing.refuseStatus = false;
    backing.refusedIds.addAll(ids.take(64));
    await service.flushOutbox();
    expect(
      (await storage.loadMessages(
        peer.hex,
      )).every((m) => m.status == MessageStatus.sent),
      isTrue,
    );
    await service.flushOutbox();
    final rows = await storage.loadMessages(peer.hex);
    expect(
      rows
          .where((m) => m.status == MessageStatus.delivered)
          .map((m) => m.id)
          .toSet(),
      ids.skip(64).toSet(),
    );
    expect(rows.any((m) => m.status == MessageStatus.failed), isFalse);
    expect(link.posts, isEmpty);
  });

  test(
    'pending receipt does not settle another peer with the same id',
    () async {
      final backing = _CommitFault();
      final storage = _ReadFault(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      final other = _id(3);
      for (final p in [peer, other]) {
        await storage.upsertContact(
          Contact(nodeId: p, status: ContactStatus.accepted),
        );
        await storage.appendMessage(
          Message(
            id: 'same-id',
            conversationId: p.hex,
            direction: MessageDirection.outgoing,
            body: 'fixture',
            timestamp: DateTime.now(),
            status: MessageStatus.sent,
          ),
        );
      }
      final link = _Link();
      final service = MessagingService(link, storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      backing.refuseStatus = true;
      await ack(service, 'same-id');
      backing.refuseStatus = false;
      await service.flushOutbox();
      expect(
        (await storage.loadMessageById(peer.hex, 'same-id'))!.status,
        MessageStatus.delivered,
      );
      expect(
        (await storage.loadMessageById(other.hex, 'same-id'))!.status,
        MessageStatus.sent,
      );
      expect(link.postPeers, [other]);
    },
  );

  test('a settled orphan ACK cannot authorize a future mirror', () async {
    final backing = _CommitFault();
    final storage = _ReadFault(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final service = MessagingService(_Link(), storage);
    addTearDown(() async {
      await service.dispose();
      await storage.close();
    });
    await ack(service, 'future-row');
    await service.applyMirroredMessage(
      peer: peer,
      msgId: 'future-row',
      direction: MessageDirection.outgoing,
      body: 'later mirror',
      tsMs: DateTime.now().millisecondsSinceEpoch,
    );
    await service.flushOutbox();
    expect(
      (await storage.loadMessageById(peer.hex, 'future-row'))!.status,
      MessageStatus.sent,
    );
  });

  test(
    'deleting a pending delivery target leaves no orphan status event',
    () async {
      final backing = _CommitFault();
      final storage = _ReadFault(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final service = MessagingService(_Link(), storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      await service.sendText(peer, 'erased while status was pending');
      final id = (await storage.loadMessages(peer.hex)).single.id;
      backing.refuseStatus = true;
      await ack(service, id);
      await storage.deleteMessage(peer.hex, id);
      backing.refuseStatus = false;
      var published = 0;
      service.onMessageStatusChanged = (_, _, _) => published++;
      await service.flushOutbox();
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(await storage.isMessageDeleted(peer.hex, id), isTrue);
      expect(published, 0);
    },
  );

  for (final disposeDuringWrite in [false, true]) {
    test(
      'pending writer ownership survives ${disposeDuringWrite ? "dispose" : "a duplicate ACK"}',
      () async {
        final backing = _CommitFault();
        final storage = _HeldStatus(
          ({required password, required bool create}) => backing,
          hold: false,
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
        await service.sendText(peer, 'writer ownership fixture');
        final id = (await storage.loadMessages(peer.hex)).single.id;
        backing.refuseStatus = true;
        await ack(service, id);
        backing.refuseStatus = false;
        storage.hold = true;
        final published = <String>[];
        service.onMessageStatusChanged = (_, id, _) => published.add(id);
        final retry = service.flushOutbox();
        await storage.entered.future;
        var disposed = false;
        final following = disposeDuringWrite
            ? service.dispose().then((_) {
                disposed = true;
              })
            : ack(service, id);
        try {
          await Future<void>.delayed(Duration.zero);
          expect(disposed, isFalse);
        } finally {
          storage.release.complete();
          await Future.wait([retry, following]);
        }
        expect(
          storage.calls,
          2,
          reason: 'one failed initial write and one real recovery write',
        );
        expect(published, disposeDuringWrite ? isEmpty : [id]);
        expect(
          (await storage.loadMessageById(peer.hex, id))!.status,
          MessageStatus.delivered,
        );
      },
    );
  }

  test(
    'failed receipt storage is bounded even while point reads refuse',
    () async {
      final backing = _CommitFault();
      final storage = _ReadFault(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final service = MessagingService(_Link(), storage);
      addTearDown(() async {
        await service.dispose();
        await storage.close();
      });
      storage.refuseTarget = true;
      for (var i = 0; i <= 4096; i++) {
        await ack(service, 'bounded-$i');
      }
      storage.refuseTarget = false;
      storage.reads.clear();
      for (var i = 0; i < 64; i++) {
        await service.flushOutbox();
      }
      expect(storage.reads, hasLength(4096));
      expect(storage.reads, isNot(contains('bounded-0')));
      expect(storage.reads, contains('bounded-4096'));
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  for (final fault in ['read', 'commit', 'commit-response']) {
    for (final recovery in ['repeat-ack', 'maintenance']) {
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

          if (recovery == 'maintenance') {
            await service.flushOutbox();
            expect(
              link.posts,
              isEmpty,
              reason: 'maintenance persists the known ACK without re-sending',
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
  for (final age in [Duration.zero, const Duration(minutes: 91)]) {
    test(
      'maintenance saves the known ACK without recipient traffic age=$age',
      () async {
        final backing = _CommitFault();
        final storage = _ReadFault(
          ({required password, required bool create}) => backing,
        );
        await storage.open(password: 'fixture', createIfMissing: true);
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        const id = 'receipt-without-new-traffic';
        await storage.appendMessage(
          Message(
            id: id,
            conversationId: peer.hex,
            direction: MessageDirection.outgoing,
            body: 'already received by the contact',
            timestamp: DateTime.now().subtract(age),
            status: MessageStatus.sent,
          ),
        );
        final link = _Link();
        final service = MessagingService(link, storage);
        addTearDown(() async {
          await service.dispose();
          await storage.close();
        });
        final mirrored = <String>[];
        service.onMessageStatusChanged = (_, id, _) => mirrored.add(id);
        backing.refuseStatus = true;
        await service.deliverInbound(
          InboundMessage(
            src: peer,
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.ack(id).encode(),
          ),
        );
        expect(backing.refusals, 1);
        backing.refuseStatus = false;
        await service.flushOutbox(); // There is no recipient and no second ACK.
        expect(
          (await storage.loadMessageById(peer.hex, id))!.status,
          MessageStatus.delivered,
        );
        expect(link.posts, isEmpty);
        expect(mirrored, [id]);
      },
    );
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
