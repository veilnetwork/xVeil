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

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required bool create}) => FakeKvLogStore());

  Completer<void>? holdNextRecord;
  var heldRecords = 0;

  @override
  Future<String?> getSetting(String key) async {
    if (key.startsWith('served:') && holdNextRecord != null) {
      final held = holdNextRecord!;
      holdNextRecord = null;
      heldRecords++;
      await held.future;
    }
    return super.getSetting(key);
  }
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final me = NodeId(Uint8List.fromList(List.filled(32, 1)));
  final requester = NodeId(Uint8List.fromList(List.filled(32, 2)));
  final sent = <PieceChunkFrame>[];

  void request(String cid) => inbound.add(
    InboundMessage(
      src: requester,
      payload: pieceRequestEnvelope(contentId: cid, indices: [0]).encode(),
      provenance: SenderProvenance.sessionPeer,
    ),
  );

  @override
  Future<NodeId> nodeId() async => me;
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.pieceChunk) sent.add(parsePieceChunk(env.body));
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(1);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => inbound.close();
}

class _Stand {
  _Stand(this.time) {
    service = MessagingService(
      transport,
      storage,
      now: () => DateTime.utc(2026).add(time.elapsed),
      contentPacing: Duration.zero,
      contentServeBatch: 1,
    );
  }
  final FakeAsync time;
  final transport = _Transport();
  final storage = _Storage();
  late final MessagingService service;
  final bytes = Uint8List.fromList(List.generate(8 * 4096, (i) => i % 251));
  var slow = false;
  Completer<void>? holdNextRead;
  var activeReads = 0;
  var maxReads = 0;
  var reads = 0;
  late String cid;

  Future<void> init() async {
    await storage.open(password: 'test', createIfMissing: true);
    service.start();
    await storage.upsertContact(
      Contact(nodeId: transport.requester, status: ContactStatus.accepted),
    );
    cid = await service.registerGroupContentStreaming(
      'fixture.bin',
      bytes.length,
      (offset, length) async {
        if (holdNextRead != null) {
          final held = holdNextRead!;
          holdNextRead = null;
          await held.future;
        }
        if (slow) {
          reads++;
          activeReads++;
          if (activeReads > maxReads) maxReads = activeReads;
          await Future<void>.delayed(const Duration(seconds: 10));
          activeReads--;
        }
        return Uint8List.sublistView(bytes, offset, offset + length);
      },
      close: () async {},
    );
  }

  Future<void> finish() {
    final done = service.dispose().then((_) => transport.dispose());
    time.flushMicrotasks();
    time.elapse(const Duration(minutes: 2));
    return done;
  }
}

void main() {
  Future<void> run(void Function(_Stand stand, FakeAsync time) body) async {
    late Future<void> cleanup;
    late FakeAsync virtualTime;
    try {
      fakeAsync((time) {
        virtualTime = time;
        final stand = _Stand(time);
        var ready = false;
        stand.init().then((_) => ready = true);
        time.flushMicrotasks();
        expect(ready, isTrue);
        try {
          body(stand, time);
        } finally {
          cleanup = stand.finish();
        }
      });
    } finally {
      var done = false;
      cleanup.then((_) => done = true);
      // Subscription.cancel may return Dart's shared root-zone future. Let
      // real microtasks settle too, then drain continuations in the fake zone.
      for (var i = 0; i < 40 && !done; i++) {
        await Future<void>.delayed(Duration.zero);
        virtualTime.elapse(const Duration(seconds: 10));
        virtualTime.flushMicrotasks();
      }
      expect(done, isTrue, reason: 'all stand services must finish teardown');
    }
  }

  test(
    'progressing datagram serve keeps its exclusive slot past 50 seconds',
    () {
      return run((stand, time) {
        stand.slow = true;
        stand.transport.request(stand.cid);
        time.flushMicrotasks();
        // Each read finishes within the step bound. Re-requests keep the peer's
        // interest fresh, while the complete payload needs 80 virtual seconds.
        for (var i = 0; i < 15; i++) {
          time.elapse(const Duration(seconds: 5));
          stand.transport.request(stand.cid);
          time.flushMicrotasks();
        }
        time.elapse(const Duration(seconds: 5));
        expect(
          stand.maxReads,
          1,
          reason: 'total elapsed time cannot release a live serve',
        );
        expect(stand.reads, 8);
        expect(
          stand.transport.sent.map((ch) => ch.chunkIndex),
          List.generate(8, (i) => i),
        );
        expect(stand.transport.sent.expand((ch) => ch.data), stand.bytes);
      });
    },
  );

  test(
    'expired source preparation cannot send after a retry has completed',
    () {
      return run((stand, time) {
        final held = Completer<void>();
        stand.storage.holdNextRecord = held;
        stand.transport.request(stand.cid);
        time.flushMicrotasks();
        expect(stand.storage.heldRecords, 1);
        time.elapse(const Duration(seconds: 51));
        stand.transport.request(stand.cid);
        time.flushMicrotasks();
        time.elapse(Duration.zero);
        expect(
          stand.transport.sent.length,
          8,
          reason: 'hung preparation must release its slot',
        );
        held.complete();
        time.flushMicrotasks();
        time.elapse(Duration.zero);
        expect(
          stand.transport.sent.length,
          8,
          reason: 'the expired preparation must not resume delivery',
        );
      });
    },
  );
  test('abandoned datagram serve stops and a later request can resume', () {
    return run((stand, time) {
      stand.slow = true;
      stand.transport.request(stand.cid);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 80));
      expect(stand.reads, 6);
      expect(stand.transport.sent.length, 6);
      expect(stand.activeReads, 0);
      stand.slow = false;
      stand.transport.request(stand.cid);
      time.flushMicrotasks();
      time.elapse(Duration.zero);
      expect(stand.transport.sent.length, 14);
    });
  });

  test('a stuck read releases delivery and its late bytes are not sent', () {
    return run((stand, time) {
      final held = Completer<void>();
      stand.holdNextRead = held;
      stand.transport.request(stand.cid);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 16));
      expect(stand.transport.sent.length, 7);
      expect(
        stand.transport.sent.map((ch) => ch.chunkIndex),
        List.generate(7, (i) => i + 1),
      );
      held.complete();
      time.flushMicrotasks();
      time.elapse(Duration.zero);
      expect(stand.transport.sent.length, 7);
      stand.transport.request(stand.cid);
      time.flushMicrotasks();
      time.elapse(Duration.zero);
      expect(stand.transport.sent.length, 15);
    });
  });

  test('a read completing after disposal does not publish its bytes', () {
    return run((stand, time) {
      final held = Completer<void>();
      stand.holdNextRead = held;
      stand.transport.request(stand.cid);
      time.flushMicrotasks();
      stand.service.dispose();
      held.complete();
      time.flushMicrotasks();
      time.elapse(Duration.zero);
      expect(stand.transport.sent.length, 0);
    });
  });
}
