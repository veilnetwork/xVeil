import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _GuardStorage extends HiddenVolumeStorage {
  _GuardStorage(super.opener);
  Future<void> Function()? afterOriginalRead;
  bool refuseOriginalRead = false;
  Completer<void>? replacementObserved;
  @override
  Future<Message?> loadMessageById(
    String conversationId,
    String messageId,
  ) async {
    if (refuseOriginalRead) throw StateError('fixture read refused');
    final result = await super.loadMessageById(conversationId, messageId);
    await afterOriginalRead?.call();
    return result;
  }

  @override
  Future<bool> replaceOutboxFrames(
    List<OutboxFrame> expected,
    List<OutboxFrame> replacement,
  ) async {
    final result = await super.replaceOutboxFrames(expected, replacement);
    final observed = replacementObserved;
    if (observed != null && !observed.isCompleted) observed.complete();
    return result;
  }
}

class _CaptureTransport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final wires = <Uint8List>[];
  final firstSend = Completer<void>();
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    wires.add(Uint8List.fromList(payload));
    if (!firstSend.isCompleted) firstSend.complete();
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => [];
  @override
  Future<void> dispose() => inbound.close();
}

void main() {
  final peer = _id(2);
  late FakeHvContainer container;
  late _GuardStorage storage;
  late MessagingService messaging;
  late _CaptureTransport transport;
  late DateTime now;

  void bind() {
    transport = _CaptureTransport();
    messaging = MessagingService(transport, storage, now: () => now);
  }

  setUp(() async {
    now = DateTime.now();
    container = FakeHvContainer();
    storage = _GuardStorage(container.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        disappearingTtlSeconds: 30,
      ),
    );
    await storage.appendMessage(
      Message(
        id: 'target',
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: 'original',
        timestamp: now,
        author: _id(1).hex,
        seq: 1,
        status: MessageStatus.delivered,
      ),
    );
    bind();
  });
  tearDown(() async {
    await messaging.dispose();
    await transport.dispose();
    await storage.close();
  });

  Future<List<WireEnvelope>> pending() async => [
    for (final frame in await storage.pendingOutboxFrames())
      WireEnvelope.decode(frame.wire),
  ];

  test(
    'expiry removes a real queued edit and preserves its sequence slot',
    () async {
      await messaging.editOwnMessage('target', 'PRIVATE_EXPIRED_EDIT');
      await transport.firstSend.future.timeout(const Duration(seconds: 10));
      final before = await pending();
      expect(
        before.where((e) => e.kind == WireKind.edit).single.body,
        'PRIVATE_EXPIRED_EDIT',
      );
      final seq = before.single.seq;
      expect(seq, isNotNull);
      await storage.enqueueOutboxFrame(
        'unrelated',
        peer.hex,
        const WireEnvelope.del('another').withFrameId('unrelated').encode(),
      );
      now = now.add(const Duration(seconds: 31));
      await messaging.sweepAllDisappearing();
      expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
      final after = await pending();
      expect(
        after.any((e) => e.body.contains('PRIVATE_EXPIRED_EDIT')),
        isFalse,
      );
      expect(after.where((e) => e.kind == WireKind.voidSeq).single.seq, seq);
      expect(
        after.any((e) => e.kind == WireKind.del && e.id == 'another'),
        isTrue,
      );
    },
  );

  test('flush never re-sends an edit after the original expires', () async {
    await messaging.editOwnMessage('target', 'PRIVATE_REDRIVEN_EDIT');
    await transport.firstSend.future.timeout(const Duration(seconds: 10));
    expect(
      transport.wires.any((w) => WireEnvelope.decode(w).kind == WireKind.edit),
      isTrue,
    );
    transport.wires.clear();
    now = now.add(const Duration(seconds: 31));
    await messaging.debugFlushOutboxFrames();
    expect(
      transport.wires.any((w) => WireEnvelope.decode(w).kind == WireKind.edit),
      isFalse,
    );
    expect((await pending()).any((e) => e.kind == WireKind.edit), isFalse);
  });

  for (final ttl in [null, 30]) {
    test(
      'live edit survives with TTL $ttl and uses original post time',
      () async {
        await storage.upsertContact(
          (await storage.getContact(
            peer,
          ))!.copyWith(disappearingTtlSeconds: ttl),
        );
        await messaging.editOwnMessage('target', 'LIVE_EDIT');
        await transport.firstSend.future.timeout(const Duration(seconds: 10));
        transport.wires.clear();
        now = now.add(Duration(seconds: ttl == null ? 31 : 20));
        await messaging.debugFlushOutboxFrames();
        expect((await pending()).single.kind, WireKind.edit);
        expect(
          transport.wires.any(
            (w) => WireEnvelope.decode(w).kind == WireKind.edit,
          ),
          isTrue,
        );
      },
    );
  }

  test('an edit just before expiry cannot buy another window', () async {
    now = now.add(const Duration(seconds: 29));
    await messaging.editOwnMessage('target', 'LATE_EDIT');
    await transport.firstSend.future.timeout(const Duration(seconds: 10));
    now = now.add(const Duration(seconds: 1));
    await messaging.debugFlushOutboxFrames();
    expect(await storage.isMessageDeleted(peer.hex, 'target'), isTrue);
    expect((await pending()).any((e) => e.kind == WireKind.edit), isFalse);
  });

  for (final seq in [null, 0]) {
    test(
      'expired legacy edit without valid sequence $seq is discarded locally',
      () async {
        final wire = WireEnvelope.edit(
          'target',
          'LEGACY_EDIT',
          seq: seq,
        ).withFrameId('legacy').encode();
        await storage.enqueueOutboxFrame('legacy', peer.hex, wire);
        now = now.add(const Duration(seconds: 31));
        await messaging.sweepAllDisappearing();
        expect(await storage.pendingOutboxFrames(), isEmpty);
        expect(transport.wires, isEmpty);
        await messaging.dispose();
        await transport.dispose();
        await storage.close();
        expect(await storage.open(password: 'fixture'), isTrue);
        bind();
        expect(await storage.pendingOutboxFrames(), isEmpty);
      },
    );
  }

  test('tombstone survives reopen, disabled TTL and clock rollback', () async {
    await messaging.editOwnMessage('target', 'DELETED_EDIT');
    await transport.firstSend.future.timeout(const Duration(seconds: 10));
    // Emulate the previously shipped journal-only cleanup, then a restart.
    await storage.deleteMessage(peer.hex, 'target');
    await storage.upsertContact(
      (await storage.getContact(peer))!.copyWith(disappearingTtlSeconds: null),
    );
    await messaging.dispose();
    await transport.dispose();
    await storage.close();
    expect(await storage.open(password: 'fixture'), isTrue);
    now = now.subtract(const Duration(days: 1));
    bind();
    await messaging.sweepAllDisappearing();
    expect((await pending()).single.kind, WireKind.voidSeq);
    expect(transport.wires, isEmpty);
  });

  test(
    'expired edit is refused before enqueue or initial transport send',
    () async {
      now = now.add(const Duration(seconds: 30));
      await messaging.sendDurable(
        peer,
        'pre-expired',
        const WireEnvelope.edit('target', 'NEVER_PERSIST', seq: 2),
      );
      final after = await pending();
      expect(after.single.kind, WireKind.voidSeq);
      expect(after.single.seq, 2);
      expect(after.single.id, isNull);
      expect(after.single.body, isEmpty);
      expect(
        transport.wires.any(
          (w) => WireEnvelope.decode(w).kind == WireKind.edit,
        ),
        isFalse,
      );
    },
  );

  test(
    'unknown targets, another conversation and non-edit wire are retained',
    () async {
      final other = _id(3);
      await storage.upsertContact(
        Contact(
          nodeId: other,
          status: ContactStatus.accepted,
          disappearingTtlSeconds: 30,
        ),
      );
      await storage.enqueueOutboxFrame(
        'elsewhere',
        other.hex,
        const WireEnvelope.edit(
          'target',
          'OTHER_CONVERSATION',
          seq: 2,
        ).withFrameId('elsewhere').encode(),
      );
      await storage.enqueueOutboxFrame(
        'missing',
        peer.hex,
        const WireEnvelope.edit(
          'unknown',
          'UNKNOWN_TARGET',
          seq: 3,
        ).withFrameId('missing').encode(),
      );
      await storage.enqueueOutboxFrame(
        'edit:misleading',
        peer.hex,
        const WireEnvelope.message(
          'KEEP_NON_EDIT',
        ).withFrameId('edit:misleading').encode(),
      );
      await storage.enqueueOutboxFrame(
        'bad',
        peer.hex,
        Uint8List.fromList([0xff]),
      );
      now = now.add(const Duration(seconds: 31));
      await messaging.sweepAllDisappearing();
      expect(
        (await storage.pendingOutboxFrames()).map((f) => f.frameId),
        unorderedEquals(['elsewhere', 'missing', 'edit:misleading', 'bad']),
      );
    },
  );

  test(
    'blocked peer does not stop cleanup of a locally deleted edit',
    () async {
      await messaging.editOwnMessage('target', 'BLOCKED_EDIT');
      await transport.firstSend.future.timeout(const Duration(seconds: 10));
      await storage.upsertContact(
        (await storage.getContact(
          peer,
        ))!.copyWith(status: ContactStatus.blocked),
      );
      now = now.add(const Duration(seconds: 31));
      await messaging.sweepAllDisappearing();
      expect((await pending()).single.kind, WireKind.voidSeq);
    },
  );

  test(
    'expiry while queued validation waits prevents the initial send',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      storage.afterOriginalRead = () async {
        if (!entered.isCompleted &&
            (await pending()).any(
              (e) => e.kind == WireKind.edit && e.id == 'target',
            )) {
          entered.complete();
          await release.future;
        }
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      storage.replacementObserved = Completer<void>();
      final editing = messaging.editOwnMessage(
        'target',
        'WAITING_INITIAL_EDIT',
      );
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        expect((await pending()).single.kind, WireKind.edit);
        expect(transport.wires, isEmpty);
        now = now.add(const Duration(seconds: 31));
      } finally {
        if (!release.isCompleted) release.complete();
      }
      await editing;
      await storage.replacementObserved!.future.timeout(
        const Duration(seconds: 10),
      );
      await storage.finishOutboxCleanup();
      expect((await pending()).single.kind, WireKind.voidSeq);
      expect(transport.wires, isEmpty);
    },
  );

  test(
    'expiry after a flush snapshot was selected is checked before redrive',
    () async {
      await messaging.editOwnMessage('target', 'WAITING_REDRIVE_EDIT');
      await transport.firstSend.future.timeout(const Duration(seconds: 10));
      transport.wires.clear();
      now = now.add(const Duration(seconds: 20));
      final entered = Completer<void>(), release = Completer<void>();
      storage.afterOriginalRead = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final flushing = messaging.debugFlushOutboxFrames();
      await entered.future.timeout(const Duration(seconds: 10));
      now = now.add(const Duration(seconds: 11));
      release.complete();
      await flushing;
      expect((await pending()).single.kind, WireKind.voidSeq);
      expect(transport.wires, isEmpty);
    },
  );

  test(
    'failed expiry read retains the body but other recipients still send',
    () async {
      await messaging.editOwnMessage('target', 'RETRY_AFTER_READ_FAILURE');
      await transport.firstSend.future.timeout(const Duration(seconds: 10));
      transport.wires.clear();
      final other = _id(3);
      await storage.upsertContact(
        Contact(nodeId: other, status: ContactStatus.accepted),
      );
      await storage.enqueueOutboxFrame(
        'other-delete',
        other.hex,
        const WireEnvelope.del(
          'other-target',
        ).withFrameId('other-delete').encode(),
      );
      storage.refuseOriginalRead = true;
      now = now.add(const Duration(seconds: 31));
      await messaging.debugFlushOutboxFrames();
      expect((await pending()).any((e) => e.kind == WireKind.edit), isTrue);
      expect(
        transport.wires.any(
          (w) => WireEnvelope.decode(w).kind == WireKind.edit,
        ),
        isFalse,
      );
      expect(
        transport.wires.any((w) => WireEnvelope.decode(w).kind == WireKind.del),
        isTrue,
      );
      storage.refuseOriginalRead = false;
      await messaging.sweepAllDisappearing();
      expect((await pending()).any((e) => e.kind == WireKind.edit), isFalse);
    },
  );
}
