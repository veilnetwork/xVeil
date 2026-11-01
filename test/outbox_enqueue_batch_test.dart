import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

class _EnqueueStore extends SyncWrappedAsyncKvLogStore {
  _EnqueueStore(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final writes = <List<KvLogOp>>[];
  bool refuse = false, uncertain = false, hold = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (!ops.whereType<PutOp>().any((op) => op.namespace == Ns.outboxIndex)) {
      return super.commit(ops);
    }
    writes.add(List.of(ops));
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    if (refuse) {
      refuse = false;
      throw StateError('injected enqueue refusal');
    }
    final result = await super.commit(ops);
    if (uncertain) {
      uncertain = false;
      throw StateError('injected enqueue reply loss');
    }
    return result;
  }
}

void main() {
  late _EnqueueStore backing;
  late HiddenVolumeStorage storage;
  setUp(() async {
    backing = _EnqueueStore(FakeKvLogStore());
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    await storage.open(password: 'fixture');
  });
  tearDown(() async {
    if (!backing.release.isCompleted) backing.release.complete();
    await storage.close();
  });

  Future<void> put(String id, {String peer = 'peer', Uint8List? wire}) =>
      storage.enqueueOutboxFrame(
        id,
        peer,
        wire ?? Uint8List.fromList(utf8.encode(id)),
      );
  Future<List<String>> ids([HiddenVolumeStorage? target]) async =>
      (await (target ?? storage).pendingOutboxFrames())
          .map((f) => f.frameId)
          .toList();

  for (final uncertain in [false, true]) {
    test(
      'single enqueue reloads durable image after failure ($uncertain)',
      () async {
        // Keep the cache warm before the uncertain new record.
        await put('keep');
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        await expectLater(put('new'), throwsStateError);
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => backing.raw,
        );
        await reopened.open(password: 'fixture');
        final expected = uncertain ? ['keep', 'new'] : ['keep'];
        expect(await ids(reopened), unorderedEquals(expected));
        expect(await ids(), unorderedEquals(expected));
        await put('new');
        expect(await ids(), unorderedEquals(['keep', 'new']));
        expect(backing.raw.kvKeys(Ns.outboxIndex), hasLength(2));
      },
    );
  }

  test('17 adjacent enqueues share bounded eight-frame commits', () async {
    await Future.wait([for (var i = 0; i < 17; i++) put('row-$i')]);
    expect(await ids(), unorderedEquals(List.generate(17, (i) => 'row-$i')));
    expect(
      backing.writes.map(
        (ops) => ops
            .whereType<PutOp>()
            .where((op) => op.namespace == Ns.outboxIndex)
            .length,
      ),
      [8, 8, 1],
    );
  });

  for (final uncertain in [false, true]) {
    test('enqueue batch failure is all-or-none ($uncertain)', () async {
      await put('keep');
      backing.refuse = !uncertain;
      backing.uncertain = uncertain;
      final first = put('first'), second = put('second');
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(
        await ids(),
        unorderedEquals(uncertain ? ['keep', 'first', 'second'] : ['keep']),
      );
      await Future.wait([put('first'), put('second')]);
      expect(await ids(), unorderedEquals(['keep', 'first', 'second']));
      expect(backing.raw.kvKeys(Ns.outboxIndex), hasLength(3));
    });
  }

  test('duplicate frame id keeps the first wire and recipient', () async {
    await Future.wait([
      put('same', wire: Uint8List.fromList([1])),
      put('same', wire: Uint8List.fromList([2])),
      put('same', peer: 'other', wire: Uint8List.fromList([3])),
    ]);
    final frame = (await storage.pendingOutboxFrames()).single;
    expect(frame.peerHex, 'peer');
    expect(frame.wire, [1]);
    expect(backing.raw.count(Ns.outbox), 1);
  });

  test(
    'ACK and pending reads retain ordering barriers between enqueues',
    () async {
      final first = put('first');
      final middle = ids();
      final ack = storage.ackOutboxFrame('first', fromPeerHex: 'peer');
      final replacement = put('first', wire: Uint8List.fromList([2]));
      final second = put('second');
      expect(await middle, ['first']);
      await Future.wait([first, ack, replacement, second]);
      expect(await ids(), unorderedEquals(['first', 'second']));
      expect(
        (await storage.pendingOutboxFrames())
            .singleWhere((f) => f.frameId == 'first')
            .wire,
        [2],
      );
    },
  );

  test(
    'enqueue snapshots caller-owned wire while waiting for the lane',
    () async {
      backing.hold = true;
      final first = put('held');
      await backing.entered.future;
      final wire = Uint8List.fromList([1]);
      final next = put('next', wire: wire);
      wire[0] = 9;
      backing.release.complete();
      await Future.wait([first, next]);
      expect(
        (await storage.pendingOutboxFrames())
            .singleWhere((f) => f.frameId == 'next')
            .wire,
        [1],
      );
    },
  );

  test('started batch is sealed and enqueue futures wait for commit', () async {
    backing.hold = true;
    var done = false;
    final first = put('first').then((_) => done = true);
    await backing.entered.future;
    final second = put('second'), third = put('third');
    expect(done, isFalse);
    expect(backing.raw.kvKeys(Ns.outboxIndex), isEmpty);
    backing.release.complete();
    await Future.wait([first, second, third]);
    expect(await ids(), unorderedEquals(['first', 'second', 'third']));
    expect(
      backing.writes.map(
        (ops) => ops
            .whereType<PutOp>()
            .where((op) => op.namespace == Ns.outboxIndex)
            .length,
      ),
      [1, 2],
    );
  });

  test(
    'encoded byte budget separates large frames without changing their wire',
    () async {
      final wire = Uint8List.fromList(List.generate(20000, (i) => i % 251));
      await Future.wait([
        put('large-1', wire: wire),
        put('large-2', wire: wire),
      ]);
      final pending = await storage.pendingOutboxFrames();
      expect(
        pending.map((f) => f.frameId),
        unorderedEquals(['large-1', 'large-2']),
      );
      expect(pending.every((f) => f.wire.length == wire.length), isTrue);
      expect(pending.first.wire, wire);
      expect(pending.last.wire, wire);
      expect(backing.writes, hasLength(2));
    },
  );

  for (final erase in [false, true]) {
    test(
      'maintenance drains accepted enqueues, rejecting late calls ($erase)',
      () async {
        backing.hold = true;
        final first = put('first');
        await backing.entered.future;
        final second = put('second'), third = put('third');
        final maintenance = erase ? storage.eraseSpace() : storage.close();
        final late = expectLater(put('late'), throwsStateError);
        backing.release.complete();
        await Future.wait([first, second, third, maintenance, late]);
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => backing.raw,
        );
        await reopened.open(password: 'fixture');
        expect(
          await ids(reopened),
          erase ? isEmpty : unorderedEquals(['first', 'second', 'third']),
        );
      },
    );
  }
}
