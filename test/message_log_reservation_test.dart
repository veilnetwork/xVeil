import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

class _Store extends SyncWrappedAsyncKvLogStore {
  _Store(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final reservations = <int>[];
  bool loseReply = false, refuse = false;
  bool refuseMessage = false, loseMessageReply = false;
  Completer<void>? entered, release;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final message = ops.whereType<AppendLogOp>().any(
      (op) =>
          op.namespace >= Ns.messageLogShardFirst &&
          op.namespace <= Ns.messageLogShardLast,
    );
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
    if (message && refuseMessage) {
      refuseMessage = false;
      throw StateError('refused data publication');
    }
    final result = await super.commit(ops);
    if (message && loseMessageReply) {
      loseMessageReply = false;
      throw StateError('lost data publication reply');
    }
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

  List<KvLogEntry> records() => [
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
      ...raw.iterLogRange(namespace: ns, limit: Ns.messageLogShardSize),
  ]..sort((a, b) => a.logId.compareTo(b.logId));
  Future<List<PreparedMessageWrite>?> bulk(
    int start, {
    int count = 64,
    Future<void> Function()? guard,
  }) => storage.appendMissingMessageBatch([
    for (var i = start; i < start + count; i++)
      _row('bulk-${i.toString().padLeft(5, '0')}', seq: i),
  ], beforeCommit: guard ?? () async {});
  Future<void> reopen() async {
    await storage.close();
    await storage.open(password: 'fixture');
  }

  test(
    'sustained full prepared cohorts amortize reserves within 256 unused IDs',
    () async {
      for (var start = 1; start <= 1024; start += 64) {
        expect(
          await bulk(start),
          List.filled(64, PreparedMessageWrite.appended),
        );
      }
      final all = records();
      expect(all, hasLength(1024));
      expect(store.reservations.length, lessThanOrEqualTo(6));
      expect(all.every((r) => r.logId < store.reservations.last), isTrue);
      expect(
        store.reservations.last - all.last.logId - 1,
        lessThanOrEqualTo(256),
      );
      expect(all.map((r) => r.logId).toSet(), hasLength(1024));
      expect(
        await store.get(Ns.settings, _bytes('conv_seq:conv:author')),
        isNull,
      );
      await reopen();
      expect((await storage.loadMessages('conv')).map((r) => r.id).toSet(), {
        for (var i = 1; i <= 1024; i++) 'bulk-${i.toString().padLeft(5, '0')}',
      });
    },
  );

  test(
    'bulk credits reset before both short and prepared reopened sessions',
    () async {
      for (var start = 1; start <= 1024; start += 64) {
        await bulk(start);
      }
      var floor = store.reservations.last;
      await reopen();
      await storage.appendMessage(_row('short-reopen', conversation: 'other'));
      expect(store.reservations.last - floor, 8);
      floor = store.reservations.last;
      await reopen();
      await bulk(1025);
      expect(store.reservations.last - floor, 64);
      expect(records().map((r) => r.logId).toSet(), hasLength(1089));
    },
  );

  test('refused admission does not earn bulk reservation credit', () async {
    for (var start = 1; start <= 192; start += 64) {
      await expectLater(
        bulk(start, guard: () async => throw StateError('refused admission')),
        throwsStateError,
      );
    }
    expect(records(), isEmpty);
    expect(store.reservations, [65, 129, 193]);
    await bulk(193);
    expect(store.reservations.last, 257);
    await bulk(257);
    expect(store.reservations.last, 385);
  });

  test(
    'partial prepared publications keep the ordinary reserve ceiling',
    () async {
      for (var start = 1; start <= 512; start += 32) {
        await bulk(start, count: 32);
      }
      final steps = [
        store.reservations.first - 1,
        for (var i = 1; i < store.reservations.length; i++)
          store.reservations[i] - store.reservations[i - 1],
      ];
      expect(steps, everyElement(lessThanOrEqualTo(64)));
      expect(records(), hasLength(512));
    },
  );

  for (final uncertain in [false, true]) {
    test('failed full publication does not earn credit ($uncertain)', () async {
      store.refuseMessage = !uncertain;
      store.loseMessageReply = uncertain;
      await expectLater(bulk(1), throwsStateError);
      if (uncertain) {
        expect(await bulk(1), List.filled(64, PreparedMessageWrite.existing));
      }
      await bulk(65);
      expect(store.reservations.take(2), [65, 129]);
      if (!uncertain) {
        await bulk(1);
      }
      await reopen();
      expect((await storage.loadMessages('conv')).map((m) => m.id).toSet(), {
        for (var i = 1; i <= 128; i++) 'bulk-${i.toString().padLeft(5, '0')}',
      });
      expect(records().map((r) => r.logId).toSet(), hasLength(128));
    });

    test(
      'grown reserve settles before publication and recovers smaller writes ($uncertain)',
      () async {
        for (var start = 1; start <= 192; start += 64) {
          await bulk(start);
        }
        store.entered = Completer<void>();
        store.release = Completer<void>();
        store.refuse = !uncertain;
        store.loseReply = uncertain;
        final entered = store.entered!, release = store.release!;
        final write = bulk(193);
        final refused = expectLater(write, throwsStateError);
        await entered.future;
        expect(records(), hasLength(192));
        release.complete();
        await refused;
        expect(records(), hasLength(192));
        await storage.appendMessage(
          _row('ordinary-after-error', conversation: 'other', seq: 1),
        );
        await bulk(193);
        await reopen();
        expect(await storage.loadMessages('conv'), hasLength(256));
        expect(await storage.loadMessages('other'), hasLength(1));
        expect(records().map((r) => r.logId).toSet(), hasLength(257));
        expect(
          records().every((r) => r.logId < store.reservations.last),
          isTrue,
        );
      },
    );
  }

  test(
    'grown prepared reservations clamp at the final shard capacity',
    () async {
      raw.commit([
        PutOp(
          Ns.settings,
          _bytes('msg_next_id'),
          _bytes('${Ns.messageLogShardCapacity - 255}'),
        ),
      ]);
      for (var start = 1; start <= 256; start += 64) {
        await bulk(start);
      }
      expect(store.reservations.last, Ns.messageLogShardCapacity + 1);
      expect(
        store.reservations,
        everyElement(lessThanOrEqualTo(Ns.messageLogShardCapacity + 1)),
      );
      expect(records(), hasLength(256));
      expect(records().last.logId, Ns.messageLogShardCapacity);
      await expectLater(
        storage.appendMessage(_row('overflow', seq: 257)),
        throwsRangeError,
      );
    },
  );

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
