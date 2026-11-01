import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/event.dart';

class _AppendStore extends SyncWrappedAsyncKvLogStore {
  _AppendStore(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final writes = <List<KvLogOp>>[];
  bool hold = false, refuse = false, uncertain = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final posts = ops.whereType<AppendLogOp>().where(
      (op) =>
          op.namespace >= Ns.messageLogShardFirst &&
          op.namespace <= Ns.messageLogShardLast,
    );
    if (posts.isEmpty) return super.commit(ops);
    expect(posts.every((op) => op.payload.length <= 1800), isTrue);
    writes.add(List.of(ops));
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    if (refuse) {
      refuse = false;
      throw StateError('injected before post commit');
    }
    final result = await super.commit(ops);
    if (uncertain) {
      uncertain = false;
      throw StateError('injected lost post commit reply');
    }
    return result;
  }
}

void main() {
  late FakeKvLogStore raw;
  late _AppendStore backing;
  late HiddenVolumeStorage storage;

  setUp(() async {
    raw = FakeKvLogStore();
    backing = _AppendStore(raw);
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    await storage.open(password: 'fixture');
  });
  tearDown(() async {
    if (!backing.release.isCompleted) backing.release.complete();
    await storage.close();
  });

  Message row(
    String id, {
    String conversation = 'conversation',
    String author = 'author',
    int? seq = 100,
    String body = 'small',
  }) => Message(
    id: id,
    conversationId: conversation,
    author: author,
    seq: seq,
    direction: MessageDirection.outgoing,
    body: body,
    timestamp: DateTime.utc(2026, 1, 1),
    status: MessageStatus.delivered,
  );
  List<Map<String, dynamic>> records() => [
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
      for (final entry in raw.iterLogRange(namespace: ns, limit: 8192))
        jsonDecode(utf8.decode(entry.payload)) as Map<String, dynamic>,
  ];
  Future<List<String>> ids([HiddenVolumeStorage? target]) async =>
      (await (target ?? storage).loadMessages(
        'conversation',
      )).map((message) => message.id).toList();

  test('40 adjacent positioned appends use bounded 16-row commits', () async {
    final stored = await Future.wait([
      for (var i = 0; i < 40; i++)
        storage.appendMessage(row('row-$i', seq: i + 1)),
    ]);
    expect(stored.map((r) => r.seq), List.generate(40, (i) => i + 1));
    expect(await ids(), List.generate(40, (i) => 'row-$i'));
    expect(backing.writes.map((ops) => ops.whereType<AppendLogOp>().length), [
      16,
      16,
      8,
    ]);
    expect(records(), hasLength(40));
    final local = await storage.appendMessage(row('local', seq: null));
    expect(local.seq, 1, reason: 'wire positions do not advance our cursor');
  });

  test('implicit local seq is a barrier and is allocated gap-free', () async {
    final results = await Future.wait([
      storage.appendMessage(row('wire-before-1', seq: 90)),
      storage.appendMessage(row('wire-before-2', seq: 91)),
      storage.appendMessage(row('local-1', seq: null)),
      storage.appendMessage(row('wire-after-1', seq: 92)),
      storage.appendMessage(row('wire-after-2', seq: 93)),
      storage.appendMessage(row('local-2', seq: null)),
    ]);
    expect(results.map((r) => r.seq), [90, 91, 1, 92, 93, 2]);
    expect(records().map((r) => r['id']), [
      'wire-before-1',
      'wire-before-2',
      'local-1',
      'wire-after-1',
      'wire-after-2',
      'local-2',
    ]);
  });

  for (final uncertain in [false, true]) {
    test(
      'batch failure has an all-or-none durable image ($uncertain)',
      () async {
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        final a = storage.appendMessage(row('first', seq: 1));
        final b = storage.appendMessage(row('second', seq: 2));
        await Future.wait([
          expectLater(a, throwsStateError),
          expectLater(b, throwsStateError),
        ]);
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => raw,
        );
        await reopened.open(password: 'fixture');
        final expected = uncertain ? ['first', 'second'] : <String>[];
        expect(await ids(reopened), expected);
        expect(await ids(), expected);
        expect((await storage.appendMessage(row('local', seq: null))).seq, 1);
      },
    );
  }

  test('started batch is sealed and futures wait for the commit', () async {
    backing.hold = true;
    var firstDone = false;
    final first = storage.appendMessage(row('first', seq: 1)).then((_) {
      firstDone = true;
    });
    await backing.entered.future;
    final rest = [
      storage.appendMessage(row('second', seq: 2)),
      storage.appendMessage(row('third', seq: 3)),
    ];
    expect(firstDone, isFalse);
    expect(records(), isEmpty);
    backing.release.complete();
    await first;
    await Future.wait(rest);
    expect(await ids(), ['first', 'second', 'third']);
    expect(backing.writes.map((ops) => ops.whereType<AppendLogOp>().length), [
      1,
      2,
    ]);
  });

  for (final erase in [false, true]) {
    test(
      'maintenance drains accepted batches and refuses late input ($erase)',
      () async {
        backing.hold = true;
        final first = storage.appendMessage(row('first', seq: 1));
        await backing.entered.future;
        final accepted = [
          storage.appendMessage(row('second', seq: 2)),
          storage.appendMessage(row('third', seq: 3)),
        ];
        final maintenance = erase ? storage.eraseSpace() : storage.close();
        final refused = expectLater(
          storage.appendMessage(row('late', seq: 4)),
          throwsStateError,
        );
        backing.release.complete();
        await Future.wait([first, ...accepted, maintenance, refused]);
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => raw,
        );
        await reopened.open(password: 'fixture');
        expect(
          await ids(reopened),
          erase ? isEmpty : ['first', 'second', 'third'],
        );
      },
    );
  }

  test(
    'another conversation/author progresses while one batch is held',
    () async {
      // First-use publication deliberately blocks writers sharing an unmarked
      // shard. Warm that marker so this tests per-author queuing, not its gate.
      await storage.appendMessage(row('warmup', conversation: 'warmup'));
      backing.writes.clear();
      backing.hold = true;
      final first = storage.appendMessage(row('held'));
      await backing.entered.future;
      await storage.appendMessage(
        row('other-conversation', conversation: 'other'),
      );
      await storage.appendMessage(row('other-author', author: 'different'));
      expect(records().where((m) => m['c'] != 'warmup').map((m) => m['id']), [
        'other-conversation',
        'other-author',
      ]);
      backing.release.complete();
      await first;
    },
  );

  test(
    'one batch crossing a shard boundary commits every marker with its data',
    () async {
      raw.commit([
        PutOp(
          Ns.settings,
          Uint8List.fromList(utf8.encode('msg_next_id')),
          Uint8List.fromList(utf8.encode('8191')),
        ),
      ]);
      await Future.wait([
        for (var i = 0; i < 4; i++)
          storage.appendMessage(row('cross-$i', seq: i + 1)),
      ]);
      expect(await ids(), ['cross-0', 'cross-1', 'cross-2', 'cross-3']);
      expect(backing.writes, hasLength(1));
      final ops = backing.writes.single;
      expect(ops.whereType<AppendLogOp>().map((op) => op.namespace).toSet(), {
        32,
        33,
      });
      final markers = ops.whereType<PutOp>().where(
        (op) => utf8.decode(op.key).startsWith('msglog_ns:v1:'),
      );
      expect(markers, hasLength(2));
    },
  );

  test(
    'a large positioned record preserves the existing fragmented path',
    () async {
      final large = '🌍' * 5000;
      await Future.wait([
        storage.appendMessage(row('before', seq: 1)),
        storage.appendMessage(row('large', seq: 2, body: large)),
        storage.appendMessage(row('after', seq: 3)),
      ]);
      final stored = await storage.loadMessages('conversation');
      expect(stored.map((m) => m.id), ['before', 'large', 'after']);
      expect(stored[1].body, large);
      expect(backing.writes, hasLength(3));
      expect(records().where((m) => m['messageParts'] == 1), hasLength(1));
    },
  );

  test(
    'clear retains a separate author turn between positioned batches',
    () async {
      final peer = NodeId(Uint8List(32));
      final before = storage.appendMessage(
        row('before', conversation: peer.hex),
      );
      final clear = storage.emitClearConversation(peer, 'author');
      final after = storage.appendMessage(row('after', conversation: peer.hex));
      await Future.wait([before, clear, after]);
      final rows = records();
      expect(rows, hasLength(3));
      expect(rows.first['id'], 'before');
      expect(rows[1]['k'], EventKind.clear.index);
      expect(rows.last['id'], 'after');
    },
  );

  test(
    'UTF-8 inline bound uses encoded bytes and retains every field',
    () async {
      final file = Message(
        id: 'file',
        conversationId: 'conversation',
        author: 'author',
        seq: 1,
        direction: MessageDirection.incoming,
        body: 'descriptor',
        timestamp: DateTime.utc(2026, 1, 1),
        status: MessageStatus.delivered,
        fileContentId: 'content',
        fileName: 'photo.png',
        fileSize: 42,
        fileExternal: true,
        thumb: 'thumb',
        replyToId: 'reply',
        forwardedFrom: 'display',
        edited: true,
        reflectedEdit: true,
        positionVerified: true,
      );
      final oversizedUtf8 = row('utf8', seq: 2, body: '🎧' * 450);
      await Future.wait([
        storage.appendMessage(file),
        storage.appendMessage(oversizedUtf8),
        storage.appendMessage(row('last', seq: 3)),
      ]);
      final stored = (await storage.loadMessages('conversation'));
      expect(stored.map((m) => m.id), ['file', 'utf8', 'last']);
      final restored = stored.first;
      expect(restored.fileContentId, file.fileContentId);
      expect(restored.fileName, file.fileName);
      expect(restored.fileSize, file.fileSize);
      expect(restored.fileExternal, isTrue);
      expect(restored.thumb, file.thumb);
      expect(restored.replyToId, file.replyToId);
      expect(restored.forwardedFrom, file.forwardedFrom);
      expect(restored.reflectedEdit, isTrue);
      expect(restored.edited, isTrue);
      expect(restored.positionVerified, isTrue);
      expect(stored[1].body, oversizedUtf8.body);
      expect(backing.writes, hasLength(3));
    },
  );

  test(
    'storage append does not invent deduplication of identical wire IDs',
    () async {
      await Future.wait([
        storage.appendMessage(row('same', seq: 1)),
        storage.appendMessage(row('same', seq: 2)),
      ]);
      expect(records().where((r) => r['id'] == 'same'), hasLength(2));
      expect((await storage.loadMessages('conversation')).single.seq, 2);
    },
  );
}
