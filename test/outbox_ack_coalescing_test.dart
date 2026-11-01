import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

class _AckStore extends SyncWrappedAsyncKvLogStore {
  _AckStore(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final retirements = <List<KvLogOp>>[];
  bool refuse = false, uncertain = false, hold = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (ops.whereType<DeleteOp>().any((op) => op.namespace == Ns.outboxIndex)) {
      retirements.add(ops);
      if (hold) {
        hold = false;
        entered.complete();
        await release.future;
      }
      if (refuse) {
        refuse = false;
        throw StateError('refused before commit');
      }
      final result = await super.commit(ops);
      if (uncertain) {
        uncertain = false;
        throw StateError('reply lost after commit');
      }
      return result;
    }
    return super.commit(ops);
  }
}

void main() {
  late _AckStore backing;
  late HiddenVolumeStorage storage;

  setUp(() async {
    backing = _AckStore(FakeKvLogStore());
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    await storage.open(password: 'fixture', createIfMissing: true);
  });
  tearDown(() async {
    if (!backing.release.isCompleted) backing.release.complete();
    await storage.close();
  });

  Future<void> put(String id, {String peer = 'peer'}) =>
      storage.enqueueOutboxFrame(id, peer, Uint8List.fromList(utf8.encode(id)));
  Future<Set<String>> pending() async =>
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toSet();

  for (final uncertain in [false, true]) {
    test(
      'single ACK reloads durable state after failure ($uncertain)',
      () async {
        await put('acknowledged');
        await put('keep', peer: 'other');
        backing.uncertain = uncertain;
        backing.refuse = !uncertain;
        await expectLater(
          storage.ackOutboxFrame('acknowledged', fromPeerHex: 'peer'),
          throwsStateError,
        );
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => backing.raw,
        );
        await reopened.open(password: 'fixture', createIfMissing: false);
        final durable = (await reopened.pendingOutboxFrames())
            .map((f) => f.frameId)
            .toSet();
        expect(durable, uncertain ? {'keep'} : {'acknowledged', 'keep'});
        expect(await pending(), durable);
        if (!uncertain) {
          await storage.ackOutboxFrame('acknowledged', fromPeerHex: 'peer');
          expect(await pending(), {'keep'});
        }
      },
    );
  }

  test('adjacent ACKs share one bounded atomic retirement', () async {
    for (var i = 0; i < 64; i++) {
      await put('row-$i');
    }
    await put('keep', peer: 'other');
    await Future.wait([
      for (var i = 0; i < 64; i++)
        storage.ackOutboxFrame('row-$i', fromPeerHex: 'peer'),
    ]);
    expect(await pending(), {'keep'});
    expect(backing.retirements, hasLength(1));
    expect(backing.retirements.single.whereType<DeleteOp>(), hasLength(64));
  });

  test('more than 64 adjacent ACKs split into bounded batches', () async {
    for (var i = 0; i < 129; i++) {
      await put('row-$i');
    }
    await put('keep', peer: 'other');
    await Future.wait([
      for (var i = 0; i < 129; i++)
        storage.ackOutboxFrame('row-$i', fromPeerHex: 'peer'),
    ]);
    expect(await pending(), {'keep'});
    expect(backing.retirements, hasLength(3));
    expect(backing.retirements.map((ops) => ops.whereType<DeleteOp>().length), [
      64,
      64,
      1,
    ]);
  });

  for (final uncertain in [false, true]) {
    test('coalesced ACK failure reloads all rows ($uncertain)', () async {
      await put('first');
      await put('second');
      await put('keep', peer: 'other');
      backing.uncertain = uncertain;
      backing.refuse = !uncertain;
      final first = storage.ackOutboxFrame('first', fromPeerHex: 'peer');
      final second = storage.ackOutboxFrame('second', fromPeerHex: 'peer');
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(backing.retirements, hasLength(1));
      expect(
        await pending(),
        uncertain ? {'keep'} : {'first', 'second', 'keep'},
      );
      await Future.wait([
        storage.ackOutboxFrame('first', fromPeerHex: 'peer'),
        storage.ackOutboxFrame('second', fromPeerHex: 'peer'),
      ]);
      expect(await pending(), {'keep'});
    });
  }

  test('duplicate ACKs consume one index deletion', () async {
    await put('same');
    await put('keep', peer: 'other');
    await Future.wait([
      for (var i = 0; i < 100; i++)
        storage.ackOutboxFrame('same', fromPeerHex: 'peer'),
    ]);
    expect(await pending(), {'keep'});
    expect(backing.retirements, hasLength(1));
    expect(backing.retirements.single.whereType<DeleteOp>(), hasLength(1));
  });

  test('pending read between ACKs observes its own queue position', () async {
    await put('first');
    await put('second');
    await put('keep', peer: 'other');
    final first = storage.ackOutboxFrame('first', fromPeerHex: 'peer');
    final middle = pending();
    final second = storage.ackOutboxFrame('second', fromPeerHex: 'peer');
    expect(await middle, {'second', 'keep'});
    await Future.wait([first, second]);
    expect(await pending(), {'keep'});
    expect(backing.retirements, hasLength(2));
  });

  test(
    'enqueue between ACKs is an ordering barrier even for the same id',
    () async {
      await put('reused');
      await put('keep', peer: 'other');
      final first = storage.ackOutboxFrame('reused', fromPeerHex: 'peer');
      final enqueue = put('reused');
      final second = storage.ackOutboxFrame('reused', fromPeerHex: 'peer');
      await Future.wait([first, enqueue, second]);
      expect(await pending(), {'keep'});
      expect(backing.retirements, hasLength(2));
    },
  );

  test(
    'peer change separates batches and a wrong peer cannot retire a row',
    () async {
      await put('first');
      await put('second', peer: 'other');
      final wrong = storage.ackOutboxFrame('second', fromPeerHex: 'peer');
      final first = storage.ackOutboxFrame('first', fromPeerHex: 'peer');
      final second = storage.ackOutboxFrame('second', fromPeerHex: 'other');
      await Future.wait([wrong, first, second]);
      expect(await pending(), isEmpty);
      expect(backing.retirements, hasLength(2));
    },
  );

  test(
    'ACK futures wait for durable commit and started batches are sealed',
    () async {
      await put('first');
      await put('second');
      await put('keep', peer: 'other');
      backing.hold = true;
      var firstDone = false, secondDone = false;
      final first = storage
          .ackOutboxFrame('first', fromPeerHex: 'peer')
          .then((_) => firstDone = true);
      await backing.entered.future;
      final second = storage
          .ackOutboxFrame('second', fromPeerHex: 'peer')
          .then((_) => secondDone = true);
      expect(firstDone, isFalse);
      expect(secondDone, isFalse);
      // Inspect the backing store without inserting an outbox queue barrier.
      expect(backing.raw.kvKeys(Ns.outboxIndex), hasLength(3));
      backing.release.complete();
      await Future.wait([first, second]);
      expect(await pending(), {'keep'});
      expect(backing.retirements, hasLength(2));
    },
  );
}
