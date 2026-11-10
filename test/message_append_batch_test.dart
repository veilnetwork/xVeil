import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
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

  Future<List<PreparedMessageWrite>?> publish(
    List<Message> rows, {
    Future<void> Function()? guard,
  }) => storage.appendMissingMessageBatch(
    rows,
    beforeCommit: guard ?? () async {},
  );

  MessageOrderingAdoption correction(
    String id,
    int from, {
    String conversation = 'conversation',
    String author = 'original-device',
  }) => MessageOrderingAdoption(
    conversationId: conversation,
    messageId: id,
    provisionalAuthor: 'author',
    provisionalSeq: from,
    author: author,
    seq: from + 1000,
  );
  Future<List<bool>?> repair(
    List<MessageOrderingAdoption> requests, {
    Future<void> Function()? guard,
  }) => storage.adoptMessageOrderingBatch(
    requests,
    beforeCommit: guard ?? () async {},
  );

  Future<bool> repairOne(String id, int from, {String author = 'canonical'}) =>
      storage.adoptMessageOrdering(
        'conversation',
        id,
        provisionalAuthor: 'author',
        provisionalSeq: from,
        author: author,
        seq: from + 1000,
      );

  test('concurrent single ordering calls amortize durable writes', () async {
    for (var i = 1; i <= 64; i++) {
      await storage.appendMessage(row('coalesced-$i', seq: i));
    }
    backing.writes.clear();
    expect(
      await Future.wait([
        for (var i = 1; i <= 64; i++) repairOne('coalesced-$i', i),
      ]),
      List.filled(64, true),
    );
    expect(backing.writes.length, lessThanOrEqualTo(8));
    expect(
      backing.writes.expand((ops) => ops.whereType<AppendLogOp>()),
      hasLength(64),
    );
    expect(
      await Future.wait([
        for (var i = 1; i <= 64; i++) repairOne('coalesced-$i', i),
      ]),
      List.filled(64, false),
    );
    final held = await storage.loadMessages('conversation');
    expect(
      held.map(
        (m) => (m.body, m.status, m.author, m.seq, m.orderAuthor, m.orderSeq),
      ),
      [
        for (var i = 1; i <= 64; i++)
          (
            'small',
            MessageStatus.delivered,
            'author',
            i,
            'canonical',
            i + 1000,
          ),
      ],
    );
    expect(
      await storage.loadEventsSince('conversation', 'canonical', 0),
      isEmpty,
    );
  });

  test('competing single corrections keep the first winner', () async {
    await storage.appendMessage(row('target', seq: 1));
    expect(
      await Future.wait([
        repairOne('target', 1, author: 'winner'),
        repairOne('target', 1, author: 'loser'),
      ]),
      [true, false],
    );
    expect(
      (await storage.loadMessageById('conversation', 'target'))!.orderAuthor,
      'winner',
    );
  });

  test(
    'an intervening append keeps its turn between ordering cohorts',
    () async {
      for (var i = 1; i <= 3; i++) {
        await storage.appendMessage(row('barrier-$i', seq: i));
      }
      backing.writes.clear();
      await Future.wait([
        repairOne('barrier-1', 1),
        storage.appendMessage(row('barrier-4', seq: 4)),
        repairOne('barrier-2', 2),
        repairOne('barrier-3', 3),
      ]);
      final writes = [
        for (final ops in backing.writes)
          [
            for (final op in ops.whereType<AppendLogOp>())
              (jsonDecode(utf8.decode(op.payload)) as Map)['id'],
          ],
      ];
      expect(writes, [
        ['barrier-1'],
        ['barrier-4'],
        ['barrier-2', 'barrier-3'],
      ]);
    },
  );

  for (final uncertain in [false, true]) {
    test(
      'single ordering cohort retries atomic failure ($uncertain)',
      () async {
        await storage.appendMessage(row('single-1', seq: 1));
        await storage.appendMessage(row('single-2', seq: 2));
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        final failed = await Future.wait([
          for (var i = 1; i <= 2; i++)
            repairOne('single-$i', i).then((_) => false, onError: (_) => true),
        ]);
        expect(failed, [true, true]);
        expect(
          await Future.wait([
            for (var i = 1; i <= 2; i++) repairOne('single-$i', i),
          ]),
          List.filled(2, !uncertain),
        );
        expect(records().where((r) => r['op'] == 'ordering'), hasLength(2));
      },
    );
  }

  for (final erase in [false, true]) {
    test('single ordering cohorts drain before maintenance ($erase)', () async {
      await storage.appendMessage(row('accepted', seq: 1));
      backing.hold = true;
      final writing = repairOne('accepted', 1);
      await backing.entered.future;
      final maintenance = erase ? storage.eraseSpace() : storage.close();
      final refused = expectLater(repairOne('late', 2), throwsStateError);
      backing.release.complete();
      expect(await writing, true);
      await Future.wait([maintenance, refused]);
      final opened = HiddenVolumeStorage(
        ({required password, required create}) => raw,
      );
      await opened.open(password: 'fixture');
      addTearDown(opened.close);
      final held = await opened.loadMessageById('conversation', 'accepted');
      if (erase) {
        expect(held, isNull);
      } else {
        expect(held!.orderAuthor, 'canonical');
      }
    });
  }

  test('oversized single ordering retains fragmented fallback', () async {
    await storage.appendMessage(row('large-correction', seq: 1));
    expect(await repairOne('large-correction', 1, author: 'x' * 2400), true);
    expect(
      (await storage.loadMessageById(
        'conversation',
        'large-correction',
      ))!.orderAuthor,
      'x' * 2400,
    );
  });

  test(
    'prepared ordering publishes one bounded bodyless transaction',
    () async {
      for (var i = 1; i <= 64; i++) {
        await storage.appendMessage(row('position-$i', seq: i));
      }
      backing.writes.clear();
      final requests = [
        for (var i = 1; i <= 64; i++) correction('position-$i', i),
      ];
      expect(await repair(requests), List.filled(64, true));
      expect(backing.writes, hasLength(1));
      expect(backing.writes.single.whereType<AppendLogOp>(), hasLength(64));
      final held = await storage.loadMessages('conversation');
      expect(
        held.every(
          (m) =>
              m.body == 'small' &&
              m.status == MessageStatus.delivered &&
              m.author == 'author',
        ),
        isTrue,
      );
      expect(held.map((m) => m.seq), [for (var i = 1; i <= 64; i++) i]);
      expect(held.map((m) => (m.orderAuthor, m.orderSeq)), [
        for (var i = 1; i <= 64; i++) ('original-device', i + 1000),
      ]);
      expect(
        await storage.loadEventsSince('conversation', 'original-device', 0),
        isEmpty,
      );
      expect(await repair(requests), List.filled(64, false));
      expect(backing.writes, hasLength(1));
    },
  );

  test(
    'prepared ordering skips stale absent canonical and deleted rows',
    () async {
      for (var i = 1; i <= 3; i++) {
        await storage.appendMessage(row('position-$i', seq: i));
      }
      expect(await repair([correction('position-1', 1)]), [true]);
      await storage.deleteMessage('conversation', 'position-3');
      backing.writes.clear();
      expect(
        await repair([
          correction('missing', 1),
          correction('position-1', 1),
          correction('position-2', 200),
          correction('position-3', 3),
        ]),
        [false, false, false, false],
      );
      expect(backing.writes, isEmpty);
      expect(
        await storage.loadMessageById('conversation', 'position-3'),
        isNull,
      );
      expect(
        (await storage.loadMessageById('conversation', 'position-2'))!.ordering,
        isNull,
      );
    },
  );

  for (final uncertain in [false, true]) {
    test(
      'prepared ordering retries an uncertain transaction ($uncertain)',
      () async {
        for (var i = 1; i <= 2; i++) {
          await storage.appendMessage(row('r-$i', seq: i));
        }
        backing.uncertain = uncertain;
        backing.refuse = !uncertain;
        final requests = [correction('r-1', 1), correction('r-2', 2)];
        await expectLater(repair(requests), throwsStateError);
        expect(await repair(requests), List.filled(2, !uncertain));
        expect(records().where((row) => row['op'] == 'ordering'), hasLength(2));
      },
    );
  }

  test(
    'ordering admission and racing deletion publish no unadmitted metadata',
    () async {
      await storage.appendMessage(row('target', seq: 1));
      final requests = [correction('target', 1)];
      await expectLater(
        repair(
          requests,
          guard: () async {
            throw StateError('revoked');
          },
        ),
        throwsStateError,
      );
      expect(
        (await storage.loadMessageById('conversation', 'target'))!.ordering,
        isNull,
      );
      late Future<void> deletion;
      await expectLater(
        repair(
          requests,
          guard: () async {
            deletion = storage.deleteMessage('conversation', 'target');
          },
        ),
        throwsStateError,
      );
      await deletion;
      expect(await storage.loadMessageById('conversation', 'target'), isNull);
      expect(records().where((row) => row['op'] == 'ordering'), isEmpty);
    },
  );

  test(
    'ordering preparation bounds and freezes its request list before waiting',
    () async {
      await storage.appendMessage(row('first', seq: 1));
      await storage.appendMessage(row('second', seq: 2));
      backing.hold = true;
      final first = storage.adoptMessageOrdering(
        'conversation',
        'first',
        provisionalAuthor: 'author',
        provisionalSeq: 1,
        author: 'first-winner',
        seq: 101,
      );
      await backing.entered.future;
      final requests = [correction('second', 2)];
      final second = repair(requests);
      requests[0] = correction('first', 1, author: 'mutated-loser');
      backing.release.complete();
      expect(await first, isTrue);
      expect(await second, [true]);
      expect(
        (await storage.loadMessageById('conversation', 'first'))!.orderAuthor,
        'first-winner',
      );
      expect(
        (await storage.loadMessageById('conversation', 'second'))!.orderAuthor,
        'original-device',
      );
      final count = backing.writes.length;
      expect(
        await repair([for (var i = 0; i < 257; i++) correction('r-$i', i)]),
        isNull,
      );
      expect(
        await repair([correction('large', 1, author: 'x' * 2000)]),
        isNull,
      );
      await expectLater(
        repair([correction('duplicate', 1), correction('duplicate', 2)]),
        throwsArgumentError,
      );
      expect(backing.writes, hasLength(count));
    },
  );

  for (final erase in [false, true]) {
    test(
      'accepted ordering batch drains before maintenance ($erase)',
      () async {
        await storage.appendMessage(row('target', seq: 1));
        backing.hold = true;
        final writing = repair([correction('target', 1)]);
        await backing.entered.future;
        final maintenance = erase ? storage.eraseSpace() : storage.close();
        final refused = expectLater(
          repair([correction('later', 2)]),
          throwsStateError,
        );
        backing.release.complete();
        await Future.wait([writing, maintenance, refused]);
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => raw,
        );
        await reopened.open(password: 'fixture');
        final held = await reopened.loadMessageById('conversation', 'target');
        if (erase) {
          expect(held, isNull);
        } else {
          expect(held!.orderAuthor, 'original-device');
        }
        await reopened.close();
      },
    );
  }

  test(
    'prepared cohort publishes once and rechecks existing durable rows',
    () async {
      final rows = [for (var i = 1; i <= 64; i++) row('prepared-$i', seq: i)];
      expect(
        await publish(rows),
        List.filled(64, PreparedMessageWrite.appended),
      );
      expect(backing.writes, hasLength(1));
      expect(backing.writes.single.whereType<AppendLogOp>(), hasLength(64));
      expect(
        await publish(rows),
        List.filled(64, PreparedMessageWrite.existing),
      );
      expect(backing.writes, hasLength(1));
      expect(records(), hasLength(64));
      final local = await storage.appendMessage(row('local', seq: null));
      expect(local.seq, 1);
    },
  );

  for (final count in [128, 256]) {
  for (final delta in [-1, 0, 1]) {
    test('$count prepared posts retain the aggregate byte boundary ($delta)',
        () async {
      await publish([row('probe-0000', body: '')]);
      final overhead = backing.writes.single.whereType<AppendLogOp>()
          .single.payload.length;
      final rows = [for (var i = 0; i < count; i++)
        row('bound-${i.toString().padLeft(4, '0')}',
            body: 'x' * (preparedMessageBatchMaxBytes ~/ count - overhead + (i == count - 1 ? delta : 0)))];
      final commits = backing.writes.length;
      var admissions = 0;
      final result = await publish(rows, guard: () async => admissions++);
      if (delta > 0) {
        expect(result, isNull);
        expect(admissions, 0);
        expect(backing.writes, hasLength(commits));
        expect(await ids(), ['probe-0000']);
      } else {
        expect(result, List.filled(count, PreparedMessageWrite.appended));
        expect(admissions, 1);
        expect(backing.writes, hasLength(commits + 1));
        final bytes = backing.writes.last.whereType<AppendLogOp>()
            .fold<int>(0, (n, op) => n + op.payload.length);
        expect(bytes, preparedMessageBatchMaxBytes + delta);
        final held = await storage.loadMessages('conversation');
        expect(held.where((m) => m.id.startsWith('bound-'))
            .map((m) => (m.id, m.body, m.status)),
          rows.map((m) => (m.id, m.body, m.status)));
      }
    });

    test('$count prepared corrections retain the aggregate byte boundary ($delta)',
        () async {
      await publish([row('probe-0000')]);
      await repair([correction('probe-0000', 100)]);
      final overhead = backing.writes.last.whereType<AppendLogOp>()
          .single.payload.length;
      final rows = [for (var i = 0; i < count; i++)
        row('bound-${i.toString().padLeft(4, '0')}')];
      await publish(rows);
      final commits = backing.writes.length;
      final requests = [for (var i = 0; i < rows.length; i++)
        correction(rows[i].id, 100, author: 'a' *
            (preparedMessageBatchMaxBytes ~/ count - overhead + 'original-device'.length +
                (i == count - 1 ? delta : 0)))];
      var admissions = 0;
      final result = await repair(requests, guard: () async => admissions++);
      if (delta > 0) {
        expect(result, isNull);
        expect(admissions, 0);
        expect(backing.writes, hasLength(commits));
      } else {
        expect(result, List.filled(count, true));
        expect(admissions, 1);
        expect(backing.writes, hasLength(commits + 1));
        final bytes = backing.writes.last.whereType<AppendLogOp>()
            .fold<int>(0, (n, op) => n + op.payload.length);
        expect(bytes, preparedMessageBatchMaxBytes + delta);
      }
      final held = (await storage.loadMessages('conversation'))
          .where((m) => m.id.startsWith('bound-')).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      expect(held.map((m) => (m.id, m.body, m.author, m.seq, m.status)),
          rows.map((m) => (m.id, m.body, m.author, m.seq, m.status)));
      expect(held.map((m) => m.orderAuthor), delta > 0
          ? everyElement('author') : requests.map((r) => r.author));
    });
  }

  }

  test(
    'prepared cohort never overwrites a live row or resurrects a tombstone',
    () async {
      await storage.appendMessage(row('live', seq: 1, body: 'wire winner'));
      await storage.appendMessage(row('deleted', seq: 2));
      await storage.deleteMessage('conversation', 'deleted');
      final result = await publish([
        row('live', seq: 1, body: 'stale mirror'),
        row('deleted', seq: 2, body: 'must never be stored'),
        row('new', seq: 3),
      ]);
      expect(result, [
        PreparedMessageWrite.existing,
        PreparedMessageWrite.suppressed,
        PreparedMessageWrite.appended,
      ]);
      expect(
        (await storage.loadMessageById('conversation', 'live'))!.body,
        'wire winner',
      );
      expect(await storage.loadMessageById('conversation', 'deleted'), isNull);
      expect(
        records().where((r) => r['body'] == 'must never be stored'),
        isEmpty,
      );
      expect(
        records().where((r) => r['id'] == 'live' && r['op'] == null),
        hasLength(1),
      );
    },
  );

  test(
    'prepared visibility guard refuses before any post publication',
    () async {
      await expectLater(
        publish(
          [row('refused')],
          guard: () async {
            throw StateError('fresh admission refused');
          },
        ),
        throwsStateError,
      );
      expect(records(), isEmpty);
      expect(await publish([row('refused')]), [PreparedMessageWrite.appended]);
      expect(records(), hasLength(1));
    },
  );

  test(
    'erasure starting during admission aborts prepared publication without deadlock',
    () async {
      final peer = NodeId.fromHex('00' * 32);
      await storage.appendMessage(row('existing', conversation: peer.hex));
      late Future<void> deleting;
      await expectLater(
        publish(
          [row('new', conversation: peer.hex)],
          guard: () async {
            deleting = storage.clearMessages(peer);
          },
        ),
        throwsStateError,
      );
      await deleting;
      expect(await storage.loadMessageById(peer.hex, 'new'), isNull);
      expect(await storage.loadMessageById(peer.hex, 'existing'), isNull);
      expect(await publish([row('new', conversation: peer.hex)]), [
        PreparedMessageWrite.appended,
      ]);
    },
  );

  for (final uncertain in [false, true]) {
    test(
      'prepared cohort retries a failed atomic publication ($uncertain)',
      () async {
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        final rows = [for (var i = 1; i <= 64; i++) row('retry-$i', seq: i)];
        await expectLater(publish(rows), throwsStateError);
        expect(await ids(), uncertain ? rows.map((r) => r.id) : isEmpty);
        expect(
          await publish(rows),
          List.filled(
            64,
            uncertain
                ? PreparedMessageWrite.existing
                : PreparedMessageWrite.appended,
          ),
        );
        expect(records().where((r) => r['op'] == null), hasLength(64));
      },
    );
  }

  test('unsupported prepared payloads perform no writes', () async {
    expect(await publish([row('large', body: 'x' * 2000)]), isNull);
    expect(await publish([row('unpositioned', seq: null)]), isNull);
    expect(await publish([for (var i = 0; i < 257; i++) row('id-$i')]), isNull);
    expect(
      await publish([
        for (var i = 0; i < 64; i++)
          row('bounded-$i', body: i == 63 ? 'x' * 2000 : 'short'),
      ]),
      isNull,
      reason: 'an unsupported tail must not publish a short prefix',
    );
    expect(records(), isEmpty);
    expect(backing.writes, isEmpty);
  });

  for (final erase in [false, true]) {
    test(
      'accepted prepared publication drains before maintenance ($erase)',
      () async {
        backing.hold = true;
        final insert = publish([row('one', seq: 1), row('two', seq: 2)]);
        await backing.entered.future;
        final maintenance = erase ? storage.eraseSpace() : storage.close();
        final refused = expectLater(publish([row('late')]), throwsStateError);
        backing.release.complete();
        await Future.wait([insert, maintenance, refused]);
        final reopened = HiddenVolumeStorage(
          ({required password, required create}) => raw,
        );
        await reopened.open(password: 'fixture');
        expect(await ids(reopened), erase ? isEmpty : ['one', 'two']);
        await reopened.close();
      },
    );
  }

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
