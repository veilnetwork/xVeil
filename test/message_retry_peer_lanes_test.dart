import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/ratchet_persistence.dart';

NodeId _id(int tag) => NodeId(Uint8List(32)..fillRange(0, 32, tag));

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required create}) => FakeKvLogStore());
  final failedReads = <String>{};
  Future<void> Function(String id)? beforeFailureWrite;
  Future<void> Function(String id)? beforeDeletedRead;

  @override
  Future<bool> isMessageDeleted(String conversationId, String messageId) async {
    await beforeDeletedRead?.call(messageId);
    return super.isMessageDeleted(conversationId, messageId);
  }

  @override
  Future<bool> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) async {
    if (status == MessageStatus.failed) {
      await beforeFailureWrite?.call(messageId);
    }
    return super.markMessageStatus(conversationId, messageId, status);
  }

  @override
  Future<List<Message>> loadMessages(String id, {int? limit}) async {
    if (failedReads.contains(id)) throw StateError('damaged conversation');
    return super.loadMessages(id, limit: limit);
  }

  @override
  Future<List<Conversation>> loadConversations() async =>
      (await super.loadConversations())
        ..sort((a, b) => a.peer.nodeId.hex.compareTo(b.peer.nodeId.hex));
}

class _HeldReservation extends Fake implements RatchetPersistence {
  _HeldReservation(this.entered, this.release);

  final Completer<void> entered;
  final Completer<void> release;

  @override
  bool get degraded => false;

  @override
  Future<void> reserveBeforePublish(NodeId peer) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Future<int> flush({String why = 'unknown', bool now = false}) async => 0;

  @override
  Future<int> close() async => 0;
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final gates = <String, Completer<void>>{};
  final failAfterGate = <String>{};
  final sent = <({NodeId peer, String id})>[];
  int active = 0, peak = 0;
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Future<void> send(
    NodeId peer,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    if (frame.kind != WireKind.message) return;
    final id = frame.id!;
    sent.add((peer: peer, id: id));
    active++;
    if (active > peak) peak = active;
    try {
      await gates[id]?.future;
      if (failAfterGate.contains(id)) {
        throw StateError('late transport failure');
      }
    } finally {
      active--;
    }
  }

  @override
  Future<void> sendWithReply(NodeId peer, Uint8List bytes) => send(peer, bytes);
  @override
  Future<void> sendReply(int replyId, Uint8List bytes) async {}
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => inbound.close();
}

void main() {
  late _Storage storage;
  late _Transport transport;
  late MessagingService service;
  late List<Future<void>> runs;
  setUp(() async {
    storage = _Storage();
    await storage.open(password: 'fixture', createIfMissing: true);
    transport = _Transport();
    service = MessagingService(transport, storage);
    runs = [];
  });
  tearDown(() async {
    for (final gate in transport.gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(runs);
    expect(transport.active, 0);
    await service.dispose();
    await storage.close();
  });
  Future<void> queue(
    int peer,
    String id, {
    int seq = 1,
    DateTime? timestamp,
  }) async {
    await storage.upsertContact(Contact(nodeId: _id(peer)));
    await storage.appendMessage(
      Message(
        id: id,
        conversationId: _id(peer).hex,
        direction: MessageDirection.outgoing,
        author: _id(1).hex,
        body: id,
        seq: seq,
        timestamp: timestamp ?? DateTime.now(),
      ),
    );
  }

  Future<void> barrier() => Future<void>.delayed(Duration.zero);
  Future<void> flush() {
    final run = service.flushOutbox();
    runs.add(run);
    return run;
  }

  List<String> ids(int peer) => [
    for (final sent in transport.sent)
      if (sent.peer == _id(peer)) sent.id,
  ];

  for (final stage in ['journal', 'ratchet']) {
    for (final change in ['block', 'block then unblock', 'sibling receipt']) {
      test('first send rechecks $change after waiting on $stage', () async {
        final peer = _id(2);
        await storage.upsertContact(Contact(nodeId: peer));
        final entered = Completer<void>(), release = Completer<void>();
        if (stage == 'journal') {
          service.onMessageStored = (_, _) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
        } else {
          service.ratchet = _HeldReservation(entered, release);
        }

        final sending = service.sendText(peer, 'first attempt');
        final acknowledged = change == 'sibling receipt';
        late final Message original;
        late final bool reported;
        try {
          await entered.future;
          original = (await storage.loadMessages(peer.hex)).single;
          expect(ids(2), isEmpty);
          if (acknowledged) {
            await service.applyMirroredMessageStatus(
              peer: peer,
              msgId: original.id,
              status: MessageStatus.delivered,
            );
          } else {
            await service.blockContact(peer);
            if (change == 'block then unblock') {
              await service.unblockContact(peer);
            }
          }
        } finally {
          release.complete();
          reported = await sending;
        }
        expect(ids(2), isEmpty);
        expect(reported, acknowledged);
        final saved = (await storage.loadMessages(peer.hex)).single;
        expect(saved.id, original.id);
        expect(
          saved.status,
          acknowledged ? MessageStatus.delivered : MessageStatus.sent,
        );
        if (change == 'block') await service.unblockContact(peer);
        await flush();
        expect(ids(2), acknowledged ? isEmpty : [original.id]);
      });
    }
  }

  for (final stage in ['storage', 'ratchet']) {
    for (final change in ['block', 'block then unblock', 'receipt']) {
      test('retry rechecks $change after waiting on $stage', () async {
        final peer = _id(2);
        Future<void> receiveReceipt(String id) => service.deliverInbound(
          InboundMessage(
            src: peer,
            payload: WireEnvelope.ack(id).encode(),
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        // Finish the first advisory sync before adding the reservation gate.
        await queue(2, 'prime');
        await flush();
        await receiveReceipt('prime');
        await barrier();
        transport.sent.clear();
        await queue(2, 'outstanding', seq: 2);
        final entered = Completer<void>(), release = Completer<void>();
        if (stage == 'storage') {
          storage.beforeDeletedRead = (id) async {
            if (id != 'outstanding' || entered.isCompleted) return;
            entered.complete();
            await release.future;
          };
        } else {
          service.ratchet = _HeldReservation(entered, release);
        }

        final retry = flush();
        try {
          await entered.future;
          expect(ids(2), isEmpty);
          if (change == 'receipt') {
            await receiveReceipt('outstanding');
          } else {
            await service.blockContact(peer);
            if (change == 'block then unblock') {
              await service.unblockContact(peer);
            }
          }
        } finally {
          release.complete();
          await retry;
        }
        expect(ids(2), isEmpty);

        if (change == 'block') await service.unblockContact(peer);
        await flush();
        expect(ids(2), change == 'receipt' ? isEmpty : ['outstanding']);
      });
    }
  }

  test('a held message does not delay another contact', () async {
    await queue(2, 'slow');
    await queue(3, 'healthy');
    transport.gates['slow'] = Completer<void>();
    unawaited(flush());
    await barrier();
    expect(ids(2), ['slow']);
    expect(ids(3), ['healthy']);
    expect(transport.gates['slow']!.isCompleted, isFalse);
  });

  test('shutdown joins an admitted retry status write and skips the next', () async {
    final old = DateTime.now().subtract(const Duration(hours: 2));
    await queue(2, 'first-expired', timestamp: old);
    await queue(
      2,
      'second-expired',
      seq: 2,
      timestamp: old.add(const Duration(seconds: 1)),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final writes = <String>[];
    storage.beforeFailureWrite = (id) {
      writes.add(id);
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };

    final retry = service.reconcileOnConnect();
    runs.add(retry);
    await entered.future;
    var closed = false;
    final closing = service.dispose().then<void>((_) => closed = true);
    try {
      await barrier();
      expect(closed, isFalse);
    } finally {
      release.complete();
      await Future.wait([retry, closing]);
    }
    expect(writes, ['first-expired']);
    expect(
      (await storage.loadMessageById(_id(2).hex, 'first-expired'))?.status,
      MessageStatus.failed,
    );
    expect(
      (await storage.loadMessageById(_id(2).hex, 'second-expired'))?.status,
      MessageStatus.sent,
    );

    final reopened = MessagingService(transport, storage);
    addTearDown(reopened.dispose);
    await reopened.reconcileOnConnect();
    expect(writes, ['first-expired', 'second-expired']);
    expect(
      (await storage.loadMessageById(_id(2).hex, 'second-expired'))?.status,
      MessageStatus.failed,
    );
  });

  test(
    'messages remain serial within a contact while others progress',
    () async {
      await queue(2, 'first');
      await queue(2, 'second', seq: 2);
      await queue(3, 'other');
      transport.gates['first'] = Completer<void>();
      final run = flush();
      await barrier();
      expect(ids(2), ['first']);
      expect(ids(3), ['other']);
      transport.gates['first']!.complete();
      await run;
      expect(ids(2), ['first', 'second']);
    },
  );

  test('at most four contacts run concurrently in a pass', () async {
    for (var i = 2; i < 8; i++) {
      await queue(i, 'peer-$i');
      transport.gates['peer-$i'] = Completer<void>();
    }
    unawaited(flush());
    await barrier();
    expect(transport.active, 4);
    expect(transport.sent, hasLength(4));
    transport.gates[transport.sent.first.id]!.complete();
    await barrier();
    expect(transport.sent, hasLength(5));
    expect(transport.peak, 4);
  });

  for (final lateFailure in [false, true]) {
    test(
      'a timed-out send retains its contact until settlement ($lateFailure)',
      () async {
        service.liveLegDeadline = Duration.zero;
        await queue(2, 'first');
        await queue(2, 'second', seq: 2);
        await queue(3, 'other');
        transport.gates['first'] = Completer<void>();
        if (lateFailure) transport.failAfterGate.add('first');
        await flush();
        expect(ids(2), ['first']);
        expect(ids(3), ['other']);
        await queue(2, 'third', seq: 3);
        await flush();
        expect(ids(2), ['first'], reason: 'deadline does not cancel transport');
        transport.gates['first']!.complete();
        await barrier();
        await flush();
        expect(ids(2), ['first', 'second', 'third']);
      },
    );
  }

  test('a pending send does not suppress terminal-age maintenance', () async {
    service.liveLegDeadline = Duration.zero;
    await queue(2, 'first');
    transport.gates['first'] = Completer<void>();
    await flush();
    await queue(
      2,
      'expired',
      seq: 2,
      timestamp: DateTime.now().subtract(const Duration(minutes: 91)),
    );
    await flush();
    final expired = (await storage.loadMessages(
      _id(2).hex,
    )).singleWhere((m) => m.id == 'expired');
    expect(expired.status, MessageStatus.failed);
    expect(ids(2), ['first']);
  });

  test('concurrent callers keep the four-contact bound', () async {
    for (var i = 2; i < 8; i++) {
      await queue(i, 'peer-$i');
      transport.gates['peer-$i'] = Completer<void>();
    }
    unawaited(flush());
    unawaited(flush());
    await barrier();
    expect(transport.active, 4);
    expect(transport.peak, 4);
    expect(transport.sent, hasLength(4));
  });

  test(
    'damaged histories do not abandon later contacts and failure remains visible',
    () async {
      for (var i = 2; i < 8; i++) {
        await queue(i, 'peer-$i');
      }
      storage.failedReads.addAll([for (var i = 2; i < 6; i++) _id(i).hex]);
      Object? failure;
      final run = service.flushOutbox().then<void>(
        (_) {},
        onError: (Object e) {
          failure = e;
        },
      );
      runs.add(run);
      await run;
      expect(failure, isA<StateError>());
      expect(ids(6), ['peer-6']);
      expect(ids(7), ['peer-7']);
    },
  );

  test(
    'concurrent flush callers do not duplicate a conversation pass',
    () async {
      await queue(2, 'first');
      transport.gates['first'] = Completer<void>();
      final a = flush(), b = flush();
      await barrier();
      expect(ids(2), ['first']);
      transport.gates['first']!.complete();
      await Future.wait([a, b]);
    },
  );

  test(
    'one contact journal cannot defer another contact or bypass persistence',
    () async {
      await queue(2, 'first');
      await queue(3, 'other');
      final held = Completer<void>();
      service.onMessageStored = (peer, _) async {
        if (peer == _id(2)) await held.future;
      };
      final run = flush();
      try {
        await barrier();
        expect(ids(2), isEmpty);
        expect(ids(3), ['other']);
      } finally {
        held.complete();
        await run;
      }
      expect(ids(2), ['first']);
    },
  );

  test(
    'a call pause while the journal is pending holds its later send',
    () async {
      await queue(2, 'first');
      final held = Completer<void>();
      service.onMessageStored = (_, _) => held.future;
      final run = flush();
      await barrier();
      service.backgroundStashPaused = true;
      held.complete();
      await run;
      expect(ids(2), isEmpty);
      service.backgroundStashPaused = false;
      await flush();
      expect(ids(2), ['first']);
    },
  );
}
