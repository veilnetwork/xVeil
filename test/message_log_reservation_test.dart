import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _Store extends SyncWrappedAsyncKvLogStore {
  _Store(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final reservations = <int>[];
  bool loseReply = false, refuse = false;
  Completer<void>? entered, release;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final cursors = ops.whereType<PutOp>().where(
      (op) =>
          op.namespace == Ns.settings && utf8.decode(op.key) == 'msg_next_id',
    );
    if (cursors.isNotEmpty) {
      reservations.add(int.parse(utf8.decode(cursors.single.value)));
      entered?.complete();
      await release?.future;
      entered = null;
      release = null;
      if (refuse) {
        refuse = false;
        throw StateError('refused reservation');
      }
    }
    final result = await super.commit(ops);
    if (cursors.isNotEmpty && loseReply) {
      loseReply = false;
      throw StateError('lost reservation reply');
    }
    return result;
  }
}

Message _row(String id, {String conversation = 'conv', int? seq}) => Message(
  id: id,
  conversationId: conversation,
  author: 'author',
  seq: seq,
  direction: MessageDirection.outgoing,
  body: id,
  timestamp: DateTime.utc(2026),
);

void main() {
  late FakeKvLogStore raw;
  late _Store store;
  late HiddenVolumeStorage storage;
  setUp(() async {
    raw = FakeKvLogStore();
    store = _Store(raw);
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => store,
    );
    await storage.open(password: 'fixture');
  });
  tearDown(() => storage.close());

  test(
    'sustained appends amortize reservation commits and reopen starts small',
    () async {
      for (var i = 0; i < 256; i++) {
        expect((await storage.appendMessage(_row('row-$i'))).seq, i + 1);
      }
      expect(
        store.reservations.length,
        lessThanOrEqualTo(8),
        reason:
            'internal ID bookkeeping must not require one fsync per eight rows',
      );
      final oldRows = raw.iterLogRange(
        namespace: Ns.messageLogShardFirst,
        limit: 1000,
      );
      expect(oldRows, hasLength(256));
      final cursor = store.reservations.last;
      expect(oldRows.every((row) => row.logId < cursor), true);
      expect(cursor - oldRows.last.logId, lessThanOrEqualTo(64));
      await storage.close();
      await storage.open(password: 'fixture');
      final count = store.reservations.length;
      expect((await storage.appendMessage(_row('reopened'))).seq, 257);
      expect(store.reservations.length, count + 1);
      expect(
        store.reservations.last - cursor,
        lessThanOrEqualTo(8),
        reason: 'a new short session must not inherit a large unused range',
      );
      final rows = raw.iterLogRange(
        namespace: Ns.messageLogShardFirst,
        limit: 1000,
      );
      expect(rows.last.logId, greaterThanOrEqualTo(cursor));
      expect(rows.map((row) => row.logId).toSet(), hasLength(257));
      expect(await storage.loadMessages('conv'), hasLength(257));
    },
  );

  for (final uncertain in [false, true]) {
    test(
      'no data is published before reservation settles, lost reply=$uncertain',
      () async {
        store.entered = Completer<void>();
        store.release = Completer<void>();
        final entered = store.entered!, release = store.release!;
        store.refuse = !uncertain;
        store.loseReply = uncertain;
        final write = storage.appendMessage(_row('refused'));
        final failed = expectLater(write, throwsStateError);
        await entered.future;
        expect(raw.count(Ns.messageLogShardFirst), 0);
        release.complete();
        await failed;
        expect(raw.count(Ns.messageLogShardFirst), 0);
        expect((await storage.appendMessage(_row('retry'))).seq, 1);
        await storage.close();
        await storage.open(password: 'fixture');
        expect((await storage.appendMessage(_row('next'))).seq, 2);
        final rows = raw.iterLogRange(
          namespace: Ns.messageLogShardFirst,
          limit: 100,
        );
        expect(rows.map((r) => r.logId).toSet(), hasLength(2));
        expect((await storage.loadMessages('conv')).map((r) => r.id), [
          'retry',
          'next',
        ]);
      },
    );
  }

  test(
    'reservation clamps at shard capacity without publishing out of range',
    () async {
      // Allocator initialization has not run yet.
      raw.commit([
        PutOp(
          Ns.settings,
          _bytes('msg_next_id'),
          _bytes('${Ns.messageLogShardCapacity - 3}'),
        ),
      ]);
      for (var i = 0; i < 4; i++) {
        await storage.appendMessage(_row('tail-$i', seq: i + 1));
      }
      expect(store.reservations.single, Ns.messageLogShardCapacity + 1);
      await expectLater(
        storage.appendMessage(_row('overflow', seq: 5)),
        throwsRangeError,
      );
      expect(raw.count(Ns.messageLogShardLast), 4);
    },
  );
}
