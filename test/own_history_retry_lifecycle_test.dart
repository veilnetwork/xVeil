import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/device_history_backfill.dart' show deviceMirrorOf;
import 'package:xveil/state/messaging.dart';

NodeId _id(int tag) => NodeId(Uint8List(32)..fillRange(0, 32, tag));

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required create}) => FakeKvLogStore());
  Completer<void>? barrier;
  bool entered = false;
  @override
  Future<List<Conversation>> loadConversations() async {
    final pending = barrier;
    if (pending != null) {
      entered = true;
      await pending.future;
    }
    return super.loadConversations();
  }
}

class _Transport implements VeilTransport {
  final input = StreamController<InboundMessage>.broadcast();
  final queries = <({NodeId peer, Map<String, dynamic> body})>[];
  final held = <NodeId, Completer<void>>{};
  final hold = <NodeId>{};
  final replies = <({NodeId peer, Map<String, dynamic> body})>[];
  final heldReplies = <NodeId, Completer<void>>{};
  final holdReplies = <NodeId>{};
  var replyActive = 0, maxReplyActive = 0;
  var active = 0, maxActive = 0;

  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Stream<InboundMessage> messages() => input.stream;
  @override
  Future<void> send(
    NodeId peer,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    if (frame.kind != WireKind.deviceHistory) return;
    final body = jsonDecode(frame.body) as Map<String, dynamic>;
    if (body['q'] == null) {
      replies.add((peer: peer, body: body));
      replyActive++;
      if (replyActive > maxReplyActive) maxReplyActive = replyActive;
      try {
        if (holdReplies.contains(peer)) {
          await heldReplies.putIfAbsent(peer, Completer<void>.new).future;
        }
      } finally {
        replyActive--;
      }
      return;
    }
    queries.add((peer: peer, body: body));
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (hold.contains(peer)) {
        await held.putIfAbsent(peer, Completer<void>.new).future;
      }
    } finally {
      active--;
    }
  }

  void release(NodeId peer) {
    hold.remove(peer);
    held.remove(peer)?.complete();
  }

  void releaseReply(NodeId peer) {
    holdReplies.remove(peer);
    heldReplies.remove(peer)?.complete();
  }

  @override
  Future<void> sendWithReply(NodeId peer, Uint8List bytes) => send(peer, bytes);
  @override
  Future<void> sendReply(int replyId, Uint8List bytes) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => input.close();
}

class _Fixture {
  _Fixture(this.time, {List<NodeId>? devices, Set<NodeId>? heldDevices}) {
    siblings = devices ?? [_id(2)];
    transport.hold.addAll(heldDevices ?? const {});
  }
  final FakeAsync time;
  late List<NodeId> siblings;
  late final now = time.getClock(DateTime.utc(2026)).now;
  final transport = _Transport();
  final storage = _Storage();
  late MessagingService service;

  void drain() {
    time.flushMicrotasks();
    time.elapse(Duration.zero);
  }

  T finish<T>(Future<T> future) {
    var done = false;
    late T result;
    Object? error;
    StackTrace? stack;
    future.then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object cause, StackTrace trace) {
        error = cause;
        stack = trace;
        done = true;
      },
    );
    drain();
    expect(done, isTrue, reason: 'the in-memory fixture must be ready');
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return result;
  }

  void open() {
    finish(storage.open(password: 'fixture', createIfMissing: true));
    service = MessagingService(transport, storage, now: now);
    service.groupBindingsOwner = Object();
    service.selfIdentityHex = () async => _id(90).hex;
    service.myOtherDevices = () async => siblings;
    service.isOwnDevice = (peer) async =>
        peer == _id(90) || siblings.contains(peer);
    service.ownHistoryEncode = (peer, message) async =>
        deviceMirrorOf(peer.hex, message).event;
    service.ownHistoryApply = (_) async {};
    service.liveLegDeadline = const Duration(seconds: 1);
    service.onOwnDeviceHistoryReady(service.groupBindingsOwner!);
    service.start();
    drain();
    expect(
      transport.queries,
      hasLength(siblings.length),
      reason: 'each real history pull must have started',
    );
  }

  void presence(NodeId peer) {
    transport.input.add(
      InboundMessage(
        src: _id(90),
        srcDevice: peer,
        provenance: SenderProvenance.signed,
        payload: WireEnvelope.presence('${peer.hex}|r').encode(),
      ),
    );
    drain();
  }

  void historyQuery(NodeId peer, String requestId) {
    transport.input.add(
      InboundMessage(
        src: _id(90),
        srcDevice: peer,
        provenance: SenderProvenance.signed,
        payload: WireEnvelope.deviceHistory(
          jsonEncode({
            'v': 1,
            'd': peer.hex,
            'id': requestId,
            'q': {'op': 'list'},
          }),
        ).encode(),
      ),
    );
    drain();
  }

  List<Map<String, dynamic>> queries(NodeId peer) => [
    for (final entry in transport.queries)
      if (entry.peer == peer) entry.body,
  ];

  Future<void> close() async {
    final barrier = storage.barrier;
    if (barrier != null && !barrier.isCompleted) barrier.complete();
    for (final peer in transport.heldReplies.keys.toList()) {
      transport.releaseReply(peer);
    }
    for (final peer in transport.held.keys.toList()) {
      transport.release(peer);
    }
    Future<void> join(Future<void> work) async {
      var done = false;
      work.then((_) => done = true);
      for (var i = 0; i < 100 && !done; i++) {
        drain();
        await Future<void>.value();
      }
      expect(done, isTrue, reason: 'all owned fixture work must close');
      await work;
    }

    await join(service.dispose());
    await join(transport.dispose());
    await join(storage.close());
  }
}

Future<void> _run(
  void Function(_Fixture) body, {
  List<NodeId>? devices,
  Set<NodeId>? heldDevices,
}) async {
  late _Fixture fixture;
  try {
    fakeAsync((time) {
      fixture = _Fixture(time, devices: devices, heldDevices: heldDevices);
      fixture.open();
      body(fixture);
    });
  } finally {
    await fixture.close();
  }
}

void main() {
  test(
    'initial presence does not duplicate a freshly started query',
    () => _run((f) {
      final peer = _id(2);
      f.presence(peer);
      expect(
        f.queries(peer),
        hasLength(1),
        reason: 'a new request still gets its original two-second interval',
      );
      f.time.elapse(const Duration(seconds: 2));
      expect(f.queries(peer), hasLength(2));
    }),
  );

  test(
    'early recovery schedules the existing query after its minimum interval',
    () => _run((f) {
      final peer = _id(2);
      f.time.elapse(const Duration(milliseconds: 2500));
      expect(f.queries(peer), hasLength(2));
      f.presence(peer);
      expect(f.queries(peer), hasLength(2));
      f.time.elapse(const Duration(milliseconds: 1500));
      expect(
        f.queries(peer),
        hasLength(3),
        reason: 'keep early recovery evidence without an immediate duplicate',
      );
    }),
  );

  test(
    'a retry parked by readiness resumes after the same host is ready',
    () => _run((f) {
      final peer = _id(2), first = f.queries(_id(2)).single;
      final barrier = f.storage.barrier = Completer<void>();
      f.service.onOwnDeviceHistoryReady(f.service.groupBindingsOwner!);
      f.drain();
      expect(
        f.storage.entered,
        isTrue,
        reason: 'the real startup/expiry barrier must be pending',
      );
      f.time.elapse(const Duration(seconds: 3));
      expect(f.queries(peer), hasLength(1));
      barrier.complete();
      f.drain();
      expect(
        f.queries(peer),
        hasLength(2),
        reason: 'readiness must resume the retry whose timer already fired',
      );
      expect(f.queries(peer).last, first);
    }),
  );

  test(
    'reply timeout cannot release a serving slot before its wire settles',
    () => _run((f) {
      final peer = _id(2);
      f.transport.holdReplies.add(peer);
      f.historyQuery(peer, 'a' * 32);
      expect(f.transport.replies, hasLength(1));
      f.time.elapse(const Duration(seconds: 2));
      f.historyQuery(peer, 'b' * 32);
      expect(
        f.transport.replies,
        hasLength(1),
        reason: 'a timed-out reply is still an outstanding transport write',
      );
      expect(
        f.queries(peer).length,
        greaterThan(1),
        reason: 'independent requests retain full-duplex progress',
      );
      f.transport.releaseReply(peer);
      f.drain();
      f.historyQuery(peer, 'b' * 32);
      expect(f.transport.replies, hasLength(2));
      expect(f.transport.replies.last.body['id'], 'b' * 32);
      expect(f.transport.maxReplyActive, 1);
    }),
  );

  test(
    'retired reply writes retain the 32-device serving bound',
    () => _run((f) {
      for (final peer in f.siblings) {
        f.transport.holdReplies.add(peer);
        f.historyQuery(peer, 'a' * 32);
      }
      expect(f.transport.replyActive, 32);
      f.time.elapse(const Duration(seconds: 2));
      f.siblings = [_id(77)];
      f.finish(f.service.reconcileOnConnect());
      f.transport.holdReplies.add(_id(77));
      f.historyQuery(_id(77), 'b' * 32);
      expect(
        f.transport.replies.where((part) => part.peer == _id(77)),
        isEmpty,
        reason: 'old live replies still own serving credit',
      );
      f.transport.releaseReply(_id(2));
      f.drain();
      f.historyQuery(_id(77), 'b' * 32);
      expect(
        f.transport.replies.where((part) => part.peer == _id(77)),
        hasLength(1),
      );
      expect(f.transport.maxReplyActive, lessThanOrEqualTo(32));
    }, devices: [for (var i = 2; i < 34; i++) _id(i)]),
  );

  test(
    'a sibling presence retries the current query without restarting it',
    () => _run((f) {
      final peer = _id(2);
      f.time.elapse(const Duration(seconds: 9));
      final before = f.queries(peer);
      expect(before, hasLength(3)); // t=0, 2, 6; next due at t=14.
      f.presence(peer);
      final after = f.queries(peer);
      expect(after, hasLength(4), reason: 'presence must release the backoff');
      expect(
        after.last,
        before.last,
        reason: 'keep the same request ID, query and durable cursor',
      );
      for (var i = 0; i < 10; i++) {
        f.presence(peer);
      }
      expect(
        f.queries(peer),
        hasLength(4),
        reason: 'repeated presence must retain the 30-second wake throttle',
      );
    }),
  );

  test(
    'retry and timeout never stack sends behind a held history write',
    () => _run((f) {
      final peer = _id(2);
      final first = f.queries(peer).single;
      f.service.liveLegDeadline = const Duration(seconds: 1);
      f.time.elapse(const Duration(seconds: 7));
      expect(
        f.queries(peer),
        hasLength(1),
        reason: 'a timeout does not release the underlying send',
      );
      expect(f.transport.active, 1);
      f.transport.release(peer);
      f.drain();
      expect(
        f.queries(peer),
        hasLength(2),
        reason: 'one deferred retry resumes when the actual write settles',
      );
      expect(f.queries(peer).last, first);
      expect(f.transport.maxActive, 1);
    }, heldDevices: {_id(2)}),
  );

  test(
    'late send completion serves the new binding, never its retired query',
    () => _run((f) {
      final peer = _id(2), old = f.queries(_id(2)).single;
      f.service.groupBindingsOwner = Object();
      f.service.onOwnDeviceHistoryReady(f.service.groupBindingsOwner!);
      f.drain();
      expect(
        f.queries(peer),
        hasLength(1),
        reason: 'new bindings cannot stack on the previous binding send',
      );
      f.transport.release(peer);
      f.drain();
      expect(f.queries(peer), hasLength(2));
      expect(f.queries(peer).last['id'], isNot(old['id']));
      expect(f.transport.maxActive, 1);
    }, heldDevices: {_id(2)}),
  );

  test(
    'retired held sends retain the global 32-device admission bound',
    () => _run(
      (f) {
        expect(f.transport.active, 32);
        f.siblings = [_id(77)];
        f.finish(f.service.reconcileOnConnect());
        expect(
          f.queries(_id(77)),
          isEmpty,
          reason: 'retiring a pull must not forget its outstanding send',
        );
        f.transport.release(_id(2));
        f.drain();
        expect(
          f.queries(_id(77)),
          hasLength(1),
          reason: 'the next admitted sibling uses released credit',
        );
        expect(f.transport.maxActive, lessThanOrEqualTo(32));
      },
      devices: [for (var i = 2; i < 34; i++) _id(i)],
      heldDevices: {for (var i = 2; i < 34; i++) _id(i)},
    ),
  );

  test(
    'a deferred retry cannot outlive revocation of its sibling',
    () => _run((f) {
      final peer = _id(2);
      f.time.elapse(const Duration(seconds: 1));
      f.siblings = [];
      f.time.elapse(const Duration(seconds: 2));
      f.transport.release(peer);
      f.drain();
      expect(f.queries(peer), hasLength(1));
      f.presence(peer);
      expect(f.queries(peer), hasLength(1));
    }, heldDevices: {_id(2)}),
  );
}
