import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/event.dart';

final _peer = NodeId(Uint8List(32)..fillRange(0, 32, 7));

class _BoundedStore extends FakeKvLogStore {
  bool rejectNextMessageCommit = false;
  bool uncertainNextMessageCommit = false;
  bool failNextScrub = false;
  int scrubCalls = 0;
  int? maxMutationOps;
  final mutations = <List<KvLogOp>>[];

  @override
  int commit(List<KvLogOp> ops) {
    final messageOps = ops.whereType<AppendLogOp>().where(
      (op) => op.namespace >= Ns.messageLogShardFirst,
    );
    if (messageOps.isNotEmpty) {
      if (rejectNextMessageCommit) {
        rejectNextMessageCommit = false;
        throw StateError('injected message commit refusal');
      }
      if (ops.length > (maxMutationOps ?? 100000)) {
        throw hv.HvException('PayloadTooLarge', 'fixture operation batch cap');
      }
      if (messageOps.any((op) => op.payload.length > 1800)) {
        throw StateError('message record exceeds incompressible capacity');
      }
      mutations.add(List.of(ops));
    }
    final result = super.commit(ops);
    if (messageOps.isNotEmpty && uncertainNextMessageCommit) {
      uncertainNextMessageCommit = false;
      throw StateError('injected reply loss after atomic commit');
    }
    return result;
  }

  @override
  void scrub() {
    scrubCalls++;
    if (failNextScrub) {
      failNextScrub = false;
      throw StateError('injected interruption before scrub');
    }
    super.scrub();
  }
}

class _ControlledStore extends SyncWrappedAsyncKvLogStore {
  _ControlledStore(super.inner);
  Future<void> Function(List<KvLogOp>)? beforeCommit;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    await beforeCommit?.call(ops);
    return super.commit(ops);
  }
}

void main() {
  late _BoundedStore backing;
  late HiddenVolumeStorage storage;
  late String large;
  Message row(
    String id,
    String body, {
    int? seq,
    String author = 'fixture-author',
  }) => Message(
    id: id,
    conversationId: _peer.hex,
    author: author,
    direction: MessageDirection.outgoing,
    body: body,
    timestamp: DateTime.utc(2026, 1, 1),
    seq: seq,
  );
  List<KvLogEntry> rawRows() => [
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
      ...backing.iterLogRange(namespace: ns, limit: 8192),
  ];
  HiddenVolumeStorage fresh() => HiddenVolumeStorage(
    ({required password, required bool create}) => backing,
  );
  setUp(() async {
    backing = _BoundedStore();
    storage = fresh();
    await storage.open(password: 'fixture');
    final random = Random(713);
    large = base64Encode(List.generate(10000, (_) => random.nextInt(256)));
  });

  test(
    'post, edit history and gap-fill expose one event per original sequence',
    () async {
      expect((await storage.appendMessage(row('large', large))).seq, 1);
      expect(await storage.editMessage(_peer.hex, 'large', '🦊$large'), 2);
      expect((await storage.appendMessage(row('small', 'keep'))).seq, 3);
      final reopened = fresh();
      await reopened.open(password: 'fixture');
      final rows = await reopened.loadMessages(_peer.hex);
      expect(rows.map((m) => m.id), ['large', 'small']);
      expect(rows.first.body, '🦊$large');
      expect((await reopened.loadMessageHistory(_peer.hex, 'large')).length, 2);
      final events = await reopened.loadEventsSince(
        _peer.hex,
        'fixture-author',
        0,
      );
      expect(events.map((e) => e.seq), [1, 2, 3]);
      expect(events.map((e) => e.kind), [
        EventKind.post,
        EventKind.edit,
        EventKind.post,
      ]);
      expect(
        (await reopened.conversationSync(
          _peer.hex,
        )).highWater['fixture-author'],
        3,
      );
    },
  );

  test(
    'refused atomic append leaves no parts and does not spend the author sequence',
    () async {
      backing.rejectNextMessageCommit = true;
      await expectLater(
        storage.appendMessage(row('failed', large)),
        throwsStateError,
      );
      expect(rawRows(), isEmpty);
      expect(await storage.loadMessages(_peer.hex), isEmpty);
      expect((await storage.appendMessage(row('retry', large))).seq, 1);
      expect((await storage.loadMessages(_peer.hex)).single.id, 'retry');
    },
  );

  test(
    'uncertain committed append remains readable on the live and reopened handle',
    () async {
      backing.uncertainNextMessageCommit = true;
      await expectLater(
        storage.appendMessage(row('committed', large)),
        throwsStateError,
      );
      expect((await storage.loadMessages(_peer.hex)).single.body, large);
      final reopened = fresh();
      await reopened.open(password: 'fixture');
      expect((await reopened.loadMessages(_peer.hex)).single.body, large);
      expect((await storage.appendMessage(row('next', 'small'))).seq, 2);
    },
  );

  for (final action in ['clear', 'prune']) {
    test(
      '$action retains its scrub obligation when interrupted before reclamation',
      () async {
        await storage.appendMessage(row('large', large));
        final before = backing.scrubCalls;
        backing.failNextScrub = true;
        await expectLater(
          action == 'clear'
              ? storage.clearMessages(_peer)
              : storage.pruneConversationBefore(_peer, DateTime.utc(2027)),
          throwsStateError,
        );
        expect(backing.scrubCalls, before + 1);
        final reopened = fresh();
        await reopened.open(password: 'fixture');
        expect(backing.scrubCalls, before + 2);
        expect(await reopened.loadMessages(_peer.hex), isEmpty);
        // A subsequent clean open does not vacuum again.
        final clean = fresh();
        await clean.open(password: 'fixture');
        expect(backing.scrubCalls, before + 2);
      },
    );
  }

  test('bulk scrub recovery also applies to ordinary small records', () async {
    await storage.appendMessage(row('small', 'small'));
    final before = backing.scrubCalls;
    backing.failNextScrub = true;
    await expectLater(storage.clearMessages(_peer), throwsStateError);
    expect(backing.scrubCalls, before + 1);
    final reopened = fresh();
    await reopened.open(password: 'fixture');
    expect(backing.scrubCalls, before + 2);
    expect(await reopened.loadMessages(_peer.hex), isEmpty);
  });

  for (final action in ['delete', 'clear', 'prune']) {
    test(
      '$action erases every fragment of the post and its retained edits',
      () async {
        await storage.appendMessage(row('large', large));
        await storage.editMessage(_peer.hex, 'large', '🦊$large');
        expect(
          rawRows().any(
            (e) => (jsonDecode(utf8.decode(e.payload)) as Map).containsKey('d'),
          ),
          isTrue,
        );
        if (action == 'delete') {
          await storage.deleteMessage(_peer.hex, 'large');
        } else if (action == 'clear') {
          await storage.clearMessages(_peer);
        } else {
          expect(
            await storage.pruneConversationBefore(_peer, DateTime.utc(2027)),
            1,
          );
        }
        expect(await storage.loadMessages(_peer.hex), isEmpty);
        for (final entry in rawRows()) {
          final raw = jsonDecode(utf8.decode(entry.payload)) as Map;
          expect(raw['messageParts'], isNull);
          expect(raw.containsKey('d'), isFalse);
        }
        final reopened = fresh();
        await reopened.open(password: 'fixture');
        expect(await reopened.loadMessageHistory(_peer.hex, 'large'), isEmpty);
        expect(
          (await reopened.conversationSync(
            _peer.hex,
          )).highWater['fixture-author'],
          2,
        );
      },
    );
  }

  test(
    'bulk fallback never splits a message head from its fragment erasure',
    () async {
      await storage.appendMessage(row('one', large));
      await storage.appendMessage(row('two', large));
      backing.mutations.clear();
      final heads = <int, int>{};
      for (final e in rawRows()) {
        final j = jsonDecode(utf8.decode(e.payload)) as Map;
        if (j['messageParts'] == 1) heads[e.logId] = j['count'] as int;
      }
      backing.maxMutationOps = heads.values.first + 2;
      await storage.clearMessages(_peer);
      expect(backing.mutations.length, greaterThanOrEqualTo(2));
      for (final commit in backing.mutations) {
        for (final op in commit.whereType<AppendLogOp>()) {
          if (heads.containsKey(op.logId)) {
            expect(
              commit.whereType<AppendLogOp>().length,
              heads[op.logId]! + 1,
            );
          }
        }
      }
      expect(await storage.loadMessages(_peer.hex), isEmpty);
    },
  );

  test(
    'oversize input is refused without spending a sequence and UTF-8 spans round-trip',
    () async {
      await expectLater(
        storage.appendMessage(row('oversize', List.filled(50, large).join())),
        throwsArgumentError,
      );
      expect(rawRows(), isEmpty);
      final unicode = List.filled(400, 'аб🦊').join();
      expect((await storage.appendMessage(row('unicode', unicode))).seq, 1);
      final reopened = fresh();
      await reopened.open(password: 'fixture');
      expect((await reopened.loadMessages(_peer.hex)).single.body, unicode);
    },
  );

  test(
    'a valid split record remains readable after raising the inline write threshold',
    () async {
      final body = List.filled(1200, 'a').join();
      await storage.appendMessage(row('kept', body));
      final head = rawRows().single;
      final payload = head.payload;
      expect(payload.length, greaterThan(1200));
      expect(payload.length, lessThanOrEqualTo(1800));
      final count = (payload.length + 1199) ~/ 1200;
      Uint8List encoded(Map<String, dynamic> j) =>
          Uint8List.fromList(utf8.encode(jsonEncode(j)));
      backing.commit([
        AppendLogOp(
          Ns.messageLogNamespaceFor(head.logId),
          head.logId,
          encoded({
            'messageParts': 1,
            'k': EventKind.void_.index,
            'first': head.logId + 1,
            'count': count,
            'length': payload.length,
            'sha256': crypto.sha256.convert(payload).toString(),
          }),
        ),
        for (var i = 0; i < count; i++)
          AppendLogOp(
            Ns.messageLogNamespaceFor(head.logId + 1 + i),
            head.logId + 1 + i,
            encoded({
              'messagePart': 1,
              'k': EventKind.void_.index,
              'owner': head.logId,
              'i': i,
              'd': base64Encode(
                payload.sublist(i * 1200, min((i + 1) * 1200, payload.length)),
              ),
            }),
          ),
      ]);
      final reopened = fresh();
      await reopened.open(password: 'fixture');
      expect((await reopened.loadMessages(_peer.hex)).single.body, body);
    },
  );

  for (final damage in ['missing', 'owner', 'digest', 'descriptor']) {
    test(
      '$damage part corruption fails closed instead of hiding a stored post',
      () async {
        await storage.appendMessage(row('large', large));
        final heads = rawRows().where(
          (e) =>
              (jsonDecode(utf8.decode(e.payload)) as Map)['messageParts'] == 1,
        );
        final head = heads.single;
        final meta =
            jsonDecode(utf8.decode(head.payload)) as Map<String, dynamic>;
        final first = meta['first'] as int;
        final ns = Ns.messageLogNamespaceFor(first);
        if (damage == 'missing') {
          backing.commit([DeleteLogOp(ns, first)]);
        } else if (damage == 'owner') {
          final part =
              jsonDecode(utf8.decode(backing.readLog(ns, first)!))
                  as Map<String, dynamic>;
          part['owner'] = head.logId + 1;
          backing.commit([
            AppendLogOp(
              ns,
              first,
              Uint8List.fromList(utf8.encode(jsonEncode(part))),
            ),
          ]);
        } else {
          if (damage == 'descriptor') {
            meta['count'] = 1 << 30;
            meta['length'] = 1 << 30;
          } else {
            meta['sha256'] = List.filled(64, '0').join();
          }
          backing.commit([
            AppendLogOp(
              Ns.messageLogNamespaceFor(head.logId),
              head.logId,
              Uint8List.fromList(utf8.encode(jsonEncode(meta))),
            ),
          ]);
        }
        final reopened = fresh();
        await reopened.open(password: 'fixture');
        await expectLater(
          reopened.loadMessages(_peer.hex),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'large crossing record and independent delayed writer remain visible after warm reads',
    () async {
      backing.commit([
        PutOp(
          Ns.settings,
          Uint8List.fromList(utf8.encode('msg_next_id')),
          Uint8List.fromList(utf8.encode('${Ns.messageLogShardSize - 2}')),
        ),
      ]);
      final controlled = _ControlledStore(backing);
      final opened = HiddenVolumeStorage.fromAsyncStore(controlled);
      final entered = Completer<void>();
      final release = Completer<void>();
      controlled.beforeCommit = (ops) async {
        if (ops.whereType<AppendLogOp>().any(
          (op) => (jsonDecode(utf8.decode(op.payload)) as Map)['id'] == 'held',
        )) {
          entered.complete();
          await release.future;
        }
      };
      // Publish a shard marker first so the held writer doesn't block discovery.
      await opened.appendMessage(row('seed', 'seed', seq: 1));
      final held = opened.appendMessage(row('held', 'held', seq: 2));
      await entered.future;
      await opened.appendMessage(
        row('large', large, seq: 3, author: 'independent'),
      );
      expect((await opened.loadMessages(_peer.hex)).map((m) => m.id), [
        'seed',
        'large',
      ]);
      release.complete();
      await held;
      expect((await opened.loadMessages(_peer.hex)).map((m) => m.id), [
        'seed',
        'held',
        'large',
      ]);
      final reopened = fresh();
      await reopened.open(password: 'fixture');
      expect((await reopened.loadMessages(_peer.hex)).map((m) => m.id), [
        'seed',
        'held',
        'large',
      ]);
    },
  );
}
