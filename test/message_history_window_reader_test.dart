import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_rows_reader.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/message_history_key_index.dart';

Message row(
  String id, {
  String conversation = 'one',
  int time = 100,
  String? body,
  MessageStatus status = MessageStatus.sent,
  DateTime? at,
}) => Message(
  id: id,
  conversationId: conversation,
  direction: MessageDirection.outgoing,
  body: body ?? id,
  timestamp: at ?? DateTime.fromMillisecondsSinceEpoch(time),
  status: status,
  author: 'author',
  seq: time + 1,
);

int wireOrder(Message a, Message b) {
  final t = a.timestamp.millisecondsSinceEpoch.compareTo(
    b.timestamp.millisecondsSinceEpoch,
  );
  return t == 0 ? a.id.compareTo(b.id) : t;
}

class _Rows implements Storage, MessageRowsReader {
  final rows = <Message>[];
  int fullReads = 0;
  bool failFull = false;
  @override
  Future<List<Message>> loadMessageRows(String conversation) async {
    fullReads++;
    if (failFull) throw StateError('injected full read failure');
    return rows.where((row) => row.conversationId == conversation).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected fixture operation');
}

class _Window extends _Rows implements MessageHistoryWindowReader {
  int windowReads = 0;
  bool failWindow = false;
  (int, int?, String?)? arguments;
  @override
  Future<List<Message>> loadMessageHistoryWindow(
    String conversation, {
    required int limit,
    int? afterTimestampMs,
    String? afterId,
  }) async {
    windowReads++;
    arguments = (limit, afterTimestampMs, afterId);
    if (failWindow) throw StateError('injected bounded read failure');
    return [row('bounded')];
  }
}

class _PausedStore extends SyncWrappedAsyncKvLogStore {
  _PausedStore(super.raw);
  bool holdNext = false, failNext = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async {
    final rows = await super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
    if (namespace >= Ns.messageLogShardFirst &&
        namespace <= Ns.messageLogShardLast) {
      if (failNext) {
        failNext = false;
        throw StateError('injected fold failure');
      }
      if (holdNext) {
        holdNext = false;
        entered.complete();
        await release.future;
      }
    }
    return rows;
  }
}

void main() {
  test(
    'ordinary rows keep fresh bounded fallback and propagate failures',
    () async {
      final store = _Rows()
        ..rows.addAll([
          row('late', time: 9),
          row('early', time: 1),
          row('foreign', conversation: 'two'),
        ]);
      expect(
        (await readMessageHistoryWindow(store, 'one', limit: 1)).single.id,
        'early',
      );
      expect(
        (await readMessageHistoryWindow(
          store,
          'one',
          limit: 2,
          afterTimestampMs: 1,
          afterId: 'early',
        )).single.id,
        'late',
      );
      expect(store.fullReads, 2);
      store.failFull = true;
      await expectLater(
        readMessageHistoryWindow(store, 'one', limit: 1),
        throwsStateError,
      );
    },
  );

  test(
    'advertised bounded failure cannot reuse or fall back to a full view',
    () async {
      final store = _Window();
      expect(
        (await readMessageHistoryWindow(
          store,
          'one',
          limit: 7,
          afterTimestampMs: 3,
          afterId: 'cursor',
        )).single.id,
        'bounded',
      );
      expect(store.arguments, (7, 3, 'cursor'));
      expect(store.fullReads, 0);
      store.failWindow = true;
      await expectLater(
        readMessageHistoryWindow(store, 'one', limit: 7),
        throwsStateError,
      );
      expect(store.windowReads, 2);
      expect(store.fullReads, 0);
    },
  );

  test(
    'key index matches independent wire order and strictly exclusive cursors',
    () {
      final rows = {
        for (var i = 0; i < 91; i++)
          'key-$i': row('id-${i.toString().padLeft(3, '0')}', time: i ~/ 3),
      };
      final keys = rows.keys.toList();
      for (final input in [
        keys,
        keys.reversed.toList(),
        [...keys.skip(30), ...keys.take(30)],
        [
          for (var i = 0; i < keys.length; i += 2) keys[i],
          for (var i = 1; i < keys.length; i += 2) keys[i],
        ],
      ]) {
        final index = MessageHistoryKeyIndex(input, (key) => rows[key]!);
        final ordered = rows.values.toList()..sort(wireOrder);
        for (final cursor in <(int, String)?>[
          null,
          (-1, ''),
          (0, 'id-000'),
          (15, 'id-045'),
          (15, 'missing'),
          (1000, 'tail'),
        ]) {
          for (final limit in [0, 1, 7, 1000]) {
            final expected = ordered
                .where(
                  (m) =>
                      cursor == null ||
                      m.timestamp.millisecondsSinceEpoch > cursor.$1 ||
                      (m.timestamp.millisecondsSinceEpoch == cursor.$1 &&
                          m.id.compareTo(cursor.$2) > 0),
                )
                .take(limit);
            expect(
              index
                  .window(
                    (key) => rows[key]!,
                    limit: limit,
                    afterTimestampMs: cursor?.$1,
                    afterId: cursor?.$2,
                  )
                  .map((m) => m.id),
              expected.map((m) => m.id),
            );
          }
        }
      }
    },
  );

  test(
    'key index uses wire milliseconds, owns keys and resolves current values',
    () {
      final rows = {
        'x': row('z', at: DateTime.fromMicrosecondsSinceEpoch(100900)),
        'y': row('a', at: DateTime.fromMicrosecondsSinceEpoch(100100)),
      };
      final input = rows.keys.toList();
      final index = MessageHistoryKeyIndex(input, (key) => rows[key]!);
      input.clear();
      expect(index.window((key) => rows[key]!, limit: 2).map((m) => m.id), [
        'a',
        'z',
      ]);
      rows['x'] = rows['x']!.copyWith(
        body: 'fresh',
        status: MessageStatus.delivered,
      );
      final held = index.window((key) => rows[key]!, limit: 2);
      expect(
        (held.last.body, held.last.status),
        ('fresh', MessageStatus.delivered),
      );
      held.clear();
      expect(index.window((key) => rows[key]!, limit: 2), hasLength(2));
      expect(
        () => index.window((key) => rows[key]!, limit: -1),
        throwsArgumentError,
      );
      expect(
        () => index.window((key) => rows[key]!, limit: 1, afterId: 'x'),
        throwsArgumentError,
      );
    },
  );

  test(
    'a warm 100000-key tail page performs only logarithmic plus window lookups',
    () {
      final rows = {
        for (var i = 0; i < 100000; i++)
          '$i': row('id-${i.toString().padLeft(6, '0')}', time: i),
      };
      var reads = 0;
      Message lookup(String key) {
        reads++;
        return rows[key]!;
      }

      final index = MessageHistoryKeyIndex([
        '99999',
        ...rows.keys.take(99999),
      ], lookup);
      reads = 0;
      final tail = index.window(
        lookup,
        limit: 257,
        afterTimestampMs: 99742,
        afterId: 'id-099742',
      );
      expect(tail.map((m) => m.id), [
        for (var i = 99743; i < 100000; i++)
          'id-${i.toString().padLeft(6, '0')}',
      ]);
      expect(reads, lessThanOrEqualTo(280));
      reads = 0;
      expect(
        index.window(
          lookup,
          limit: 1,
          afterTimestampMs: 99999,
          afterId: 'id-099999',
        ),
        isEmpty,
      );
      expect(reads, lessThanOrEqualTo(20));
    },
  );

  group('current hidden-volume indexed rows', () {
    late HiddenVolumeStorage store;
    setUp(() => store = HiddenVolumeStorage.fromStore(FakeKvLogStore()));
    tearDown(() => store.close());
    Future<List<Message>> page({
      String conversation = 'one',
      int limit = 256,
      int? after,
      String? id,
    }) => readMessageHistoryWindow(
      store,
      conversation,
      limit: limit,
      afterTimestampMs: after,
      afterId: id,
    );

    test(
      'scope, detached windows and missing cursors retain current rows',
      () async {
        for (final m in [
          row('middle', time: 20),
          row('last', time: 30),
          row('first', time: 10),
          row('foreign', conversation: 'two'),
        ]) {
          await store.appendMessage(m);
        }
        final first = await page(limit: 2);
        expect(first.map((m) => m.id), ['first', 'middle']);
        first.clear();
        expect((await page(after: 20, id: 'middle')).single.id, 'last');
        expect((await page(after: 21, id: 'missing')).single.id, 'last');
        expect((await page(conversation: 'two')).single.id, 'foreign');
        expect(await page(conversation: 'empty'), isEmpty);
        await expectLater(page(limit: -1), throwsArgumentError);
        await expectLater(page(after: 20), throwsArgumentError);
      },
    );

    test(
      'warm index observes appends, edits, status, signatures and ordering',
      () async {
        await store.appendMessage(row('held', time: 20));
        await page();
        await store.appendMessage(row('earlier', time: 10));
        await store.editMessage('one', 'held', 'edited', seq: 50);
        await store.markMessageStatus('one', 'held', MessageStatus.delivered);
        await store.markMessageSignature(
          'one',
          'held',
          MessageSignature.verified,
        );
        expect(
          await store.adoptMessageOrdering(
            'one',
            'held',
            provisionalAuthor: 'author',
            provisionalSeq: 21,
            author: 'original',
            seq: 80,
          ),
          isTrue,
        );
        final rows = await page();
        expect(rows.map((m) => m.id), ['earlier', 'held']);
        expect(
          (
            rows.last.body,
            rows.last.status,
            rows.last.signature,
            rows.last.orderAuthor,
            rows.last.orderSeq,
          ),
          (
            'edited',
            MessageStatus.delivered,
            MessageSignature.verified,
            'original',
            80,
          ),
        );
        expect((await page(after: 10, id: 'earlier')).single.id, 'held');
      },
    );

    test(
      'in-place deletion invalidates a warm key index without a new log id',
      () async {
        await store.appendMessage(row('delete', time: 10));
        await store.appendMessage(row('keep', time: 20));
        await page();
        final frontier = await store.getSetting('msg_next_id');
        await store.deleteMessage('one', 'delete');
        expect(await store.getSetting('msg_next_id'), frontier);
        expect((await page()).single.id, 'keep');
        expect((await page(after: 10, id: 'delete')).single.id, 'keep');
      },
    );

    test(
      'clear and erase cannot expose an index built before maintenance',
      () async {
        final peer = NodeId(Uint8List(32)..fillRange(0, 32, 3));
        await store.appendMessage(row('gone', conversation: peer.hex));
        await store.appendMessage(row('foreign', conversation: 'two'));
        await page(conversation: peer.hex);
        await store.clearMessages(peer);
        expect(await page(conversation: peer.hex), isEmpty);
        expect((await page(conversation: 'two')).single.id, 'foreign');
        await store.eraseSpace();
        expect(await page(conversation: 'two'), isEmpty);
      },
    );
  });

  test('warm index cannot conceal an incremental fold failure', () async {
    final backing = _PausedStore(FakeKvLogStore());
    final store = HiddenVolumeStorage.fromAsyncStore(backing);
    addTearDown(store.close);
    await store.appendMessage(row('old'));
    await readMessageHistoryWindow(store, 'one', limit: 10);
    await store.appendMessage(row('new', time: 200));
    backing.failNext = true;
    await expectLater(
      readMessageHistoryWindow(store, 'one', limit: 10),
      throwsStateError,
    );
    expect(
      (await readMessageHistoryWindow(
        store,
        'one',
        limit: 10,
      )).map((m) => m.id),
      ['old', 'new'],
    );
  });

  test(
    'suspended window read is refused across close and same-handle reopen',
    () async {
      final backing = _PausedStore(FakeKvLogStore());
      final store = HiddenVolumeStorage.async(
        ({required password, required create}) async => backing,
      );
      addTearDown(() async {
        if (!backing.release.isCompleted) backing.release.complete();
        await store.close();
      });
      await store.open(password: 'fixture');
      await store.appendMessage(row('old'));
      await readMessageHistoryWindow(store, 'one', limit: 10);
      await store.appendMessage(row('later', time: 200));
      backing.holdNext = true;
      final reading = readMessageHistoryWindow(store, 'one', limit: 10);
      final failed = expectLater(reading, throwsStateError);
      await backing.entered.future;
      final closing = store.close();
      await expectLater(
        readMessageHistoryWindow(store, 'one', limit: 0),
        throwsStateError,
      );
      backing.release.complete();
      await failed;
      await closing;
      await store.open(password: 'fixture');
      expect(
        (await readMessageHistoryWindow(
          store,
          'one',
          limit: 10,
        )).map((m) => m.id),
        ['old', 'later'],
      );
    },
  );

  test(
    'same-size foreign space never inherits the prior identity key index',
    () async {
      var current = FakeKvLogStore();
      final store = HiddenVolumeStorage(
        ({required password, required create}) => current,
      );
      addTearDown(store.close);
      await store.open(password: 'old');
      await store.appendMessage(row('old'));
      await readMessageHistoryWindow(store, 'one', limit: 10);
      await store.close();
      current = FakeKvLogStore();
      await store.open(password: 'new');
      await store.appendMessage(row('new'));
      expect(
        (await readMessageHistoryWindow(store, 'one', limit: 10)).single.id,
        'new',
      );
    },
  );
}
