import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/app_controller.dart';
import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _ReadyController extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
}

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  bool held = false;
  bool refused = false;
  int prunes = 0;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<int> pruneConversationBefore(NodeId peer, DateTime cutoff) async {
    prunes++;
    if (!entered.isCompleted) entered.complete();
    if (held) await release.future;
    if (refused) throw StateError('fixture prune refused');
    return super.pruneConversationBefore(peer, cutoff);
  }
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
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
    sent.add(WireEnvelope.decode(payload));
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
  late _Storage storage;
  late _Transport transport;
  late MessagingService service;
  late DateTime now;
  final peer = _id(2);

  setUp(() async {
    now = DateTime.now();
    final container = FakeHvContainer();
    storage = _Storage(container.passwordOpener);
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
        id: 'expired',
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: 'PRIVATE_EXPIRED_POST',
        timestamp: now.subtract(const Duration(seconds: 40)),
        author: _id(1).hex,
        seq: 1,
      ),
    );
    await storage.appendMessage(
      Message(
        id: 'fresh',
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: 'KEEP_FRESH_POST',
        timestamp: now,
        author: _id(1).hex,
        seq: 2,
      ),
    );
    transport = _Transport();
    service = MessagingService(transport, storage, now: () => now);
  });
  tearDown(() async {
    if (!storage.release.isCompleted) storage.release.complete();
    await service.dispose();
    await transport.dispose();
    await storage.close();
  });

  test(
    'start removes already-expired rows without a timer tick or chat open',
    () async {
      service.start();
      await pumpEventQueue();
      expect(storage.prunes, 1);
      expect((await storage.loadMessages(peer.hex)).map((m) => m.id), [
        'fresh',
      ]);
    },
  );

  test(
    'physical TTL expiry includes the exact boundary and keeps the next millisecond',
    () async {
      // Storage persists millisecond timestamps; use that same precision so
      // truncation cannot turn the equality witness into a strictly older row.
      now = DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch);
      final cutoff = now.subtract(const Duration(seconds: 30));
      for (final entry in [
        ('exact-boundary', cutoff),
        ('next-millisecond', cutoff.add(const Duration(milliseconds: 1))),
      ]) {
        await storage.appendMessage(
          Message(
            id: entry.$1,
            conversationId: peer.hex,
            direction: MessageDirection.incoming,
            body: entry.$1,
            timestamp: entry.$2,
            author: peer.hex,
          ),
        );
      }
      await service.sweepAllDisappearing();
      expect(await storage.loadMessageById(peer.hex, 'exact-boundary'), isNull);
      expect(
        await storage.loadMessageById(peer.hex, 'next-millisecond'),
        isNotNull,
      );
    },
  );

  test(
    'UI first load hides TTL rows even before physical sweep finishes',
    () async {
      // No sweep: visibility must not depend on opening a screen/timer first.
      final container = ProviderContainer(
        overrides: [
          messagingServiceProvider.overrideWithValue(service),
          storageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        messagesProvider(peer.hex),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final visible = await container.read(messagesProvider(peer.hex).future);
      expect(visible.map((m) => m.id), ['fresh']);
      expect(
        (await storage.loadMessages(peer.hex)).map((m) => m.id),
        contains('expired'),
        reason:
            'positive control: this assertion tests projection, not pruning',
      );
    },
  );

  test(
    'conversation preview cannot disclose an expired last message before prune',
    () async {
      final other = _id(3);
      await storage.upsertContact(
        Contact(
          nodeId: other,
          status: ContactStatus.accepted,
          disappearingTtlSeconds: 30,
        ),
      );
      await storage.appendMessage(
        Message(
          id: 'old-preview',
          conversationId: other.hex,
          direction: MessageDirection.incoming,
          body: 'PRIVATE_EXPIRED_PREVIEW',
          timestamp: now.subtract(const Duration(seconds: 40)),
          author: other.hex,
          seq: 1,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_ReadyController.new),
          messagingServiceProvider.overrideWithValue(service),
          storageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(conversationsProvider, (_, _) {});
      addTearDown(sub.close);
      final visible = await container.read(conversationsProvider.future);
      expect(visible.singleWhere((c) => c.id == other.hex).lastMessage, isNull);
      expect(
        visible.singleWhere((c) => c.id == peer.hex).lastMessage!.body,
        'KEEP_FRESH_POST',
      );
      expect(
        (await storage.loadConversations())
            .singleWhere((c) => c.id == other.hex)
            .lastMessage!
            .body,
        'PRIVATE_EXPIRED_PREVIEW',
      );
    },
  );

  test(
    'an expired ordinary post is not retried during a slow physical prune',
    () async {
      storage.held = true;
      final sweep = service.sweepAllDisappearing();
      await storage.entered.future;
      try {
        await service.flushOutbox();
        expect(
          transport.sent
              .where((e) => e.kind == WireKind.message)
              .map((e) => e.body),
          isNot(contains('PRIVATE_EXPIRED_POST')),
        );
        expect(
          transport.sent
              .where((e) => e.kind == WireKind.message)
              .map((e) => e.body),
          contains('KEEP_FRESH_POST'),
        );
      } finally {
        storage.release.complete();
        await sweep;
      }
    },
  );

  test(
    'a second caller joins an unfinished startup sweep rather than reporting zero',
    () async {
      storage.held = true;
      service.start();
      await storage.entered.future;
      var completed = false;
      final joined = service.sweepAllDisappearing().then((count) {
        completed = true;
        return count;
      });
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(storage.prunes, 1);
      storage.release.complete();
      expect(await joined, 1);
      expect(await storage.loadMessageById(peer.hex, 'expired'), isNull);
    },
  );

  test(
    'teardown joins a started prune and never invokes a detached group hook',
    () async {
      storage.held = true;
      service.start();
      await storage.entered.future;
      var hookCalls = 0, closed = false;
      service.onDisappearingSweep = () async {
        hookCalls++;
      };
      final closing = service.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      storage.release.complete();
      await closing;
      expect(hookCalls, 0);
      expect(closed, isTrue);
    },
  );

  test(
    'a refused first prune retains periodic retry and hides the raw row',
    () async {
      storage.refused = true;
      service.start();
      await pumpEventQueue();
      expect(storage.prunes, 1);
      expect(service.disappearingSweepArmed, isTrue);
      expect(await storage.loadMessageById(peer.hex, 'expired'), isNotNull);
      storage.refused = false;
      expect(await service.sweepAllDisappearing(), 1);
      expect(await storage.loadMessageById(peer.hex, 'expired'), isNull);
    },
  );

  test(
    'readiness of a late/current group is coalesced; a stale owner cannot schedule',
    () async {
      storage.held = true;
      service.start();
      await storage.entered.future;
      final current = Object();
      service.groupBindingsOwner = current;
      var calls = 0;
      service.onDisappearingSweep = () async {
        calls++;
      };
      for (var i = 0; i < 100; i++) {
        service.onOwnDeviceHistoryReady(current);
      }
      storage.release.complete();
      await pumpEventQueue();
      expect(storage.prunes, 2);
      expect(calls, 2);
      service.groupBindingsOwner = Object();
      service.onOwnDeviceHistoryReady(current);
      await pumpEventQueue();
      expect(storage.prunes, 2);
    },
  );

  test(
    'repeated start adds no timer and disposal cancels every timer it owns',
    () async {
      final timers = <Timer>[];
      await runZoned(
        () async {
          service.start();
          await pumpEventQueue();
          final count = timers.length;
          service.start();
          expect(timers.length, count);
          await service.dispose();
          expect(timers.where((timer) => timer.isActive), isEmpty);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createPeriodicTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
    },
  );

  test(
    'slow initial cleanup defers stored group copies but not call controls',
    () async {
      storage.held = true;
      service.start();
      await storage.entered.future;
      await service.sendGroupSnapshot(
        peer,
        'ab' * 32,
        '{"retained":true}',
        awaitInitialSend: false,
      );
      await storage.enqueueOutboxFrame(
        'call:startup',
        peer.hex,
        WireEnvelope(
          WireKind.callSignal,
          '{}',
          sentAtMs: now.millisecondsSinceEpoch,
        ).withFrameId('call:startup').encode(),
      );
      await service.flushOutbox();
      expect(transport.sent.any((e) => e.kind == WireKind.groupEntry), isFalse);
      expect(transport.sent.any((e) => e.kind == WireKind.callSignal), isTrue);
      expect(
        (await storage.pendingOutboxFrames()).any(
          (f) => f.frameId.startsWith('grp:'),
        ),
        isTrue,
      );
      storage.release.complete();
      await pumpEventQueue();
      await service.flushOutbox();
      expect(transport.sent.any((e) => e.kind == WireKind.groupEntry), isTrue);
    },
  );
}
