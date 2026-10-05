import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

class _CountingFakeKvLogStore extends FakeKvLogStore {
  int iterLogRangeCalls = 0;
  bool enforceSmallRecords = false;
  bool rejectNextCommit = false;

  @override
  int commit(List<KvLogOp> ops) {
    if (rejectNextCommit) {
      rejectNextCommit = false;
      throw StateError('injected atomic commit refusal');
    }
    if (enforceSmallRecords &&
        ops.whereType<AppendLogOp>().any((op) => op.payload.length > 1800)) {
      throw StateError('incompressible record exceeds guaranteed capacity');
    }
    return super.commit(ops);
  }

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    iterLogRangeCalls++;
    return super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
  }
}

void main() {
  late HiddenVolumeStorage storage;
  late _CountingFakeKvLogStore fake;

  setUp(() async {
    fake = _CountingFakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => fake,
    );
    await storage.open(password: 'pw', createIfMissing: true);
  });

  Uint8List wire(String s) => Uint8List.fromList(s.codeUnits);

  test('enqueue surfaces a pending frame; ack retires it', () async {
    expect(await storage.pendingOutboxFrames(), isEmpty);

    await storage.enqueueOutboxFrame('sigreq:m1', 'peerA', wire('hello'));
    var pending = await storage.pendingOutboxFrames();
    expect(pending.length, 1);
    expect(pending.single.frameId, 'sigreq:m1');
    expect(pending.single.peerHex, 'peerA');
    expect(pending.single.wire, wire('hello'));

    await storage.ackOutboxFrame('sigreq:m1', fromPeerHex: 'peerA');
    expect(await storage.pendingOutboxFrames(), isEmpty);
  });

  test('enqueue is idempotent on frameId', () async {
    await storage.enqueueOutboxFrame('f', 'peer', wire('a'));
    await storage.enqueueOutboxFrame('f', 'peer', wire('a'));
    expect((await storage.pendingOutboxFrames()).length, 1);
  });

  test('acking an unknown id is a harmless no-op', () async {
    await storage.enqueueOutboxFrame('keep', 'peer', wire('x'));
    await storage.ackOutboxFrame('never-enqueued', fromPeerHex: 'peer');
    final pending = await storage.pendingOutboxFrames();
    expect(pending.length, 1);
    expect(pending.single.frameId, 'keep');
  });

  test('an ack from the wrong peer does not retire the frame', () async {
    // `reconnect:`/`accept:` ids are derived from the peer and `gcr:` ids are
    // shared across holders, so an accepted contact can know an id addressed to
    // someone else. Retiring on the id alone let them ACK it first and suppress
    // that delivery outright (audit XV-02).
    await storage.enqueueOutboxFrame('reconnect:victim', 'victim', wire('x'));

    await storage.ackOutboxFrame('reconnect:victim', fromPeerHex: 'attacker');
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
      {'reconnect:victim'},
      reason: 'a stranger\'s ack must not retire it',
    );

    // Control: the addressee's own ack still works, so the check is rejecting
    // the wrong sender and not acks in general.
    await storage.ackOutboxFrame('reconnect:victim', fromPeerHex: 'victim');
    expect(await storage.pendingOutboxFrames(), isEmpty);
  });

  test('multiple frames fold independently', () async {
    await storage.enqueueOutboxFrame('a', 'p1', wire('1'));
    await storage.enqueueOutboxFrame('b', 'p2', wire('2'));
    await storage.enqueueOutboxFrame('c', 'p1', wire('3'));
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
      {'a', 'b', 'c'},
    );

    await storage.ackOutboxFrame('b', fromPeerHex: 'p2');
    expect(
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toSet(),
      {'a', 'c'},
    );
  });

  test('re-enqueue after ack works (self-heal path)', () async {
    await storage.enqueueOutboxFrame('f', 'peer', wire('v1'));
    await storage.ackOutboxFrame('f', fromPeerHex: 'peer');
    expect(await storage.pendingOutboxFrames(), isEmpty);
    // A later distinct frame with the same id (e.g. a fresh request) re-appears.
    await storage.enqueueOutboxFrame('f', 'peer', wire('v2'));
    final pending = await storage.pendingOutboxFrames();
    expect(pending.length, 1);
    expect(pending.single.wire, wire('v2'));
  });

  test(
    'concurrent duplicate enqueue persists one payload and index row',
    () async {
      await Future.wait([
        for (var i = 0; i < 16; i++)
          storage.enqueueOutboxFrame('same', 'peer', wire('payload')),
      ]);

      expect(await storage.pendingOutboxFrames(), hasLength(1));
      expect(fake.count(Ns.outbox), 1);
      expect(fake.count(Ns.outboxIndex), 1);
    },
  );

  Uint8List randomWire(int length) {
    final random = Random(231);
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  test(
    'large incompressible frame survives reopen and recipient ACK',
    () async {
      fake.enforceSmallRecords = true;
      final payload = randomWire(16 * 1024);
      await storage.enqueueOutboxFrame('large', 'recipient', payload);
      expect(fake.count(Ns.outbox), greaterThan(2));
      final rows = fake.count(Ns.outbox);
      final reopened = HiddenVolumeStorage(
        ({required password, required bool create}) => fake,
      );
      await reopened.open(password: 'pw', createIfMissing: true);
      final pending = await reopened.pendingOutboxFrames();
      expect(pending.single.wire, payload);
      expect(pending.single.frameId, 'large');
      expect(
        fake.count(Ns.outbox),
        rows,
        reason: 'startup orphan cleanup must preserve every live part',
      );
      await reopened.ackOutboxFrame('large', fromPeerHex: 'wrong');
      expect(await reopened.pendingOutboxFrames(), hasLength(1));
      await reopened.ackOutboxFrame('large', fromPeerHex: 'recipient');
      expect(await reopened.pendingOutboxFrames(), isEmpty);
      expect(fake.count(Ns.outbox), 0);
      expect(fake.count(Ns.outboxIndex), 0);
    },
  );

  test('failed commit exposes no partial frame and allows retry', () async {
    fake.enforceSmallRecords = true;
    await storage.pendingOutboxFrames(); // initialize before fault injection
    fake.rejectNextCommit = true;
    final payload = randomWire(8000);
    await expectLater(
      storage.enqueueOutboxFrame('large', 'peer', payload),
      throwsStateError,
    );
    expect(await storage.pendingOutboxFrames(), isEmpty);
    expect(fake.count(Ns.outbox), 0);
    expect(fake.count(Ns.outboxIndex), 0);
    await storage.enqueueOutboxFrame('large', 'peer', payload);
    expect((await storage.pendingOutboxFrames()).single.wire, payload);
  });

  test(
    'missing or replaced part never yields a changed network envelope',
    () async {
      for (final missing in [true, false]) {
        await storage.enqueueOutboxFrame('damaged', 'peer', randomWire(9000));
        final key = fake.kvKeys(Ns.outboxIndex).single;
        final root = int.parse(utf8.decode(fake.get(Ns.outboxIndex, key)!));
        final manifest =
            jsonDecode(utf8.decode(fake.readLog(Ns.outbox, root)!)) as Map;
        final first = manifest['first'] as int;
        fake.commit([
          if (missing)
            DeleteLogOp(Ns.outbox, first)
          else
            AppendLogOp(Ns.outbox, first, Uint8List(1800)),
        ]);
        final reopened = HiddenVolumeStorage(
          ({required password, required bool create}) => fake,
        );
        await reopened.open(password: 'pw', createIfMissing: true);
        expect(await reopened.pendingOutboxFrames(), isEmpty);
        expect(fake.count(Ns.outbox), 0);
        storage = reopened;
      }
    },
  );
}
