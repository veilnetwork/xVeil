import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int tag) => NodeId(Uint8List(32)..fillRange(0, 32, tag));

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final messagesSent = <({NodeId peer, String? id})>[];
  final framesSent = <({NodeId peer, String? id})>[];

  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Future<void> send(
    NodeId peer,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    framesSent.add((peer: peer, id: frame.frameId));
    if (frame.kind == WireKind.message) {
      messagesSent.add((peer: peer, id: frame.id));
    }
    // Deliberately lose delivery and ACKs; retries retain their original ID.
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

/// Actual service/storage/ingress, with timers parked so a periodic retry
/// cannot accidentally satisfy the route-up assertion. No wall-clock sleeps.
class _Fixture {
  _Fixture(this.time);
  final FakeAsync time;
  final transport = _Transport();
  final storage = HiddenVolumeStorage(
    ({required password, required create}) => FakeKvLogStore(),
  );
  late MessagingService service;
  var clock = DateTime.now();
  var inboundSequence = 0;

  T finish<T>(Future<T> future) {
    var done = false;
    late T result;
    Object? failure;
    StackTrace? trace;
    future.then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        done = true;
      },
    );
    drain();
    expect(
      done,
      isTrue,
      reason: 'in-memory operation must finish without time',
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return result;
  }

  void drain() {
    time.flushMicrotasks();
    time.elapse(Duration.zero);
  }

  void open() {
    finish(storage.open(password: 'fixture', createIfMissing: true));
    for (final peer in [_id(2), _id(3)]) {
      finish(
        storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        ),
      );
    }
    service = MessagingService(transport, storage, now: () => clock)..start();
    drain();
  }

  Future<void> close() async {
    // Stream close futures can belong to either zone. Drain both while joining
    // each owner; behavior assertions above never advance the timer clock.
    Future<void> join(Future<void> work, String owner) async {
      var done = false;
      work.then((_) => done = true);
      for (var i = 0; i < 100 && !done; i++) {
        drain();
        await Future<void>.value();
      }
      expect(done, isTrue, reason: '$owner must release its in-memory work');
      await work;
    }

    await join(service.dispose(), 'service');
    await join(transport.dispose(), 'transport');
    await join(storage.close(), 'storage');
  }

  void hear(NodeId peer) {
    final sequence = ++inboundSequence;
    final id = 'activity-$sequence';
    transport.inbound.add(
      InboundMessage(
        src: peer,
        provenance: SenderProvenance.sessionPeer,
        payload: WireEnvelope.message(
          'peer activity',
          id: id,
          seq: sequence,
        ).encode(),
      ),
    );
    drain();
    expect(
      finish(storage.loadMessages(peer.hex)).map((m) => m.id),
      contains(id),
      reason: 'the authenticated inbound must actually have been processed',
    );
  }

  String queue(NodeId peer) {
    final id = 'pending-${peer.short}';
    finish(
      storage.appendMessage(
        Message(
          id: id,
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: 'pending retry',
          timestamp: clock,
          author: _id(1).hex,
          seq: 1,
        ),
      ),
    );
    finish(service.flushOutbox());
    expect(copies(id), 1, reason: 'the message must already be on its ladder');
    return id;
  }

  int copies(String id) =>
      transport.messagesSent.where((m) => m.id == id).length;

  String queueControl(NodeId peer) {
    final id = 'test:deferred-${peer.short}';
    finish(service.sendDurable(peer, id, const WireEnvelope.reconnect('')));
    expect(frameCopies(id), 1);
    expect(
      finish(storage.pendingOutboxFrames()).map((row) => row.frameId),
      contains(id),
      reason: 'the control frame must actually be pending',
    );
    return id;
  }

  int frameCopies(String id) =>
      transport.framesSent.where((frame) => frame.id == id).length;

  void advanceNudgeClock() => clock = clock.add(const Duration(seconds: 4));

  void routeUp(NodeId peer) {
    service.onDirectSessionUp(peer);
    drain();
  }
}

Future<void> _withFixture(void Function(_Fixture) run) async {
  late _Fixture fixture;
  try {
    fakeAsync((time) {
      fixture = _Fixture(time)..open();
      run(fixture);
    });
  } finally {
    await fixture.close();
  }
}

void main() {
  test(
    'early reachability keeps the control retry due at the end of grace',
    () => _withFixture((f) {
      final peer = _id(2);
      f.hear(peer);
      final start = f.clock;
      final id = f.queueControl(peer);
      f.clock = start.add(const Duration(seconds: 4));
      f.hear(peer);
      expect(f.frameCopies(id), 1, reason: 'the ACK still gets its grace');
      f.clock = start.add(const Duration(seconds: 9));
      f.finish(f.service.flushOutbox());
      expect(f.frameCopies(id), 1);
      f.clock = start.add(const Duration(seconds: 10));
      f.finish(f.service.flushOutbox());
      expect(
        f.frameCopies(id),
        2,
        reason: 'the early nudge must survive until its grace expires',
      );
      expect(f.time.elapsed, Duration.zero);
    }),
  );

  test(
    'a deferred control nudge retains the growing retry grace',
    () => _withFixture((f) {
      final peer = _id(2);
      f.hear(peer);
      final id = f.queueControl(peer);
      f.clock = f.clock.add(const Duration(seconds: 21));
      f.finish(f.service.flushOutbox());
      expect(f.frameCopies(id), 2);
      final secondAttempt = f.clock;
      f.advanceNudgeClock();
      f.hear(peer);
      f.clock = secondAttempt.add(const Duration(seconds: 19));
      f.finish(f.service.flushOutbox());
      expect(f.frameCopies(id), 2, reason: 'second-attempt grace is 20 s');
      f.clock = secondAttempt.add(const Duration(seconds: 20));
      f.finish(f.service.flushOutbox());
      expect(
        f.frameCopies(id),
        3,
        reason: 'an early reachability signal must not be forgotten',
      );
      expect(f.time.elapsed, Duration.zero);
    }),
  );

  test(
    'steady control nudges cannot bypass exponential grace',
    () => _withFixture((f) {
      final peer = _id(2);
      f.hear(peer);
      final id = f.queueControl(peer);
      final attempts = [f.clock];
      for (var i = 0; i < 20; i++) {
        f.advanceNudgeClock();
        f.hear(peer);
        f.finish(f.service.flushOutbox());
        if (f.frameCopies(id) > attempts.length) attempts.add(f.clock);
        expect(
          f.frameCopies(id),
          attempts.length,
          reason: 'a nudge must never emit multiple copies',
        );
      }
      expect(
        attempts,
        hasLength(4),
        reason: 'the fixture must exercise several ladder steps',
      );
      for (var i = 1; i < attempts.length; i++) {
        expect(
          attempts[i].difference(attempts[i - 1]),
          greaterThanOrEqualTo(Duration(seconds: 10 * (1 << (i - 1)))),
        );
      }
      expect(f.time.elapsed, Duration.zero);
    }),
  );

  test(
    'a deferred control nudge is peer scoped and cancelled by ACK',
    () => _withFixture((f) {
      final peer = _id(2), other = _id(3);
      f.hear(peer);
      f.hear(other);
      final start = f.clock;
      final id = f.queueControl(peer), otherId = f.queueControl(other);
      f.advanceNudgeClock();
      f.hear(peer);
      f.transport.inbound.add(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.ack(id).encode(),
        ),
      );
      f.drain();
      expect(
        f.finish(f.storage.pendingOutboxFrames()).map((row) => row.frameId),
        [otherId],
        reason: 'the ACK must retire the actual durable row',
      );
      f.clock = start.add(const Duration(seconds: 10));
      f.finish(f.service.flushOutbox());
      expect(f.frameCopies(id), 1, reason: 'no deferred copy after ACK');
      expect(f.frameCopies(otherId), 1, reason: 'no nudge for the other peer');
      expect(f.time.elapsed, Duration.zero);
    }),
  );

  test(
    'authenticated activity cannot consume the direct-route retry nudge',
    () => _withFixture((f) {
      final peer = _id(2);
      f.hear(peer);
      final id = f.queue(peer);
      // Reach the capped ladder without waiting for any retry timer.
      for (var i = 0; i < 3; i++) {
        f.advanceNudgeClock();
        f.routeUp(peer);
        expect(f.copies(id), i + 2);
      }
      f.advanceNudgeClock();
      f.hear(peer);
      expect(
        f.copies(id),
        4,
        reason: 'steady inbound must not rewind messages',
      );
      f.routeUp(peer);
      expect(
        f.copies(id),
        5,
        reason: 'a usable route must release the pending 24-second retry',
      );
      expect(
        f.time.elapsed,
        Duration.zero,
        reason: 'no periodic retry may substitute for the route-up event',
      );
    }),
  );

  test(
    'a silence-ending inbound and route-up share the recovery cooldown',
    () => _withFixture((f) {
      final peer = _id(2);
      f.hear(peer);
      final id = f.queue(peer);
      f.clock = f.clock.add(const Duration(seconds: 30));
      f.hear(peer);
      expect(f.copies(id), 2, reason: 'silence ending must release the retry');
      f.routeUp(peer);
      expect(
        f.copies(id),
        2,
        reason: 'the same recovery must not immediately resend twice',
      );
      expect(f.time.elapsed, Duration.zero);
    }),
  );

  test(
    'repeated route notifications stay bounded and retain peer scope',
    () => _withFixture((f) {
      final peer = _id(2), other = _id(3);
      f.hear(peer);
      f.hear(other);
      final id = f.queue(peer), otherId = f.queue(other);
      f.advanceNudgeClock();
      f.routeUp(peer);
      expect(f.copies(id), 2);
      for (var i = 0; i < 10; i++) {
        f.hear(peer);
        f.routeUp(peer);
      }
      expect(f.copies(id), 2, reason: 'route-up storms must not restart sends');
      expect(f.copies(otherId), 1, reason: 'other peers keep their backoff');
      f.advanceNudgeClock();
      f.routeUp(peer);
      expect(f.copies(id), 3, reason: 'a later route event remains eligible');
      f.transport.inbound.add(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.ack(id).encode(),
        ),
      );
      f.drain();
      expect(
        f
            .finish(f.storage.loadMessages(peer.hex))
            .singleWhere((m) => m.id == id)
            .status,
        MessageStatus.delivered,
      );
      f.advanceNudgeClock();
      f.routeUp(peer);
      expect(f.copies(id), 3, reason: 'a receipt still retires the retry');
      expect(f.copies(otherId), 1);
      expect(f.time.elapsed, Duration.zero);
    }),
  );
}
