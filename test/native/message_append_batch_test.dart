@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

import '../support/timed_native_store.dart';

class _NativePostStore extends TimedNativeStore {
  _NativePostStore(AsyncKvLogStore inner)
    : super(inner, Stopwatch()..start(), (_) {});
  final commitRows = <int>[];
  final commitBytes = <int>[];
  int idReservations = 0;
  bool hold = false, refuse = false, uncertain = false;
  bool holdReservation = false,
      refuseReservation = false,
      uncertainReservation = false;
  final entered = Completer<void>(), release = Completer<void>();
  final reservationEntered = Completer<void>(),
      reservationRelease = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final reservation = ops.whereType<PutOp>().any(
      (op) =>
          op.namespace == Ns.settings && utf8.decode(op.key) == 'msg_next_id',
    );
    if (reservation) {
      idReservations++;
      if (holdReservation) {
        holdReservation = false;
        reservationEntered.complete();
        await reservationRelease.future;
      }
      if (refuseReservation) {
        refuseReservation = false;
        throw StateError('native reservation refused');
      }
    }
    final rows = ops
        .whereType<AppendLogOp>()
        .where(
          (op) =>
              op.namespace >= Ns.messageLogShardFirst &&
              op.namespace <= Ns.messageLogShardLast,
        )
        .length;
    if (rows == 0) {
      final sequence = await super.commit(ops);
      if (reservation && uncertainReservation) {
        uncertainReservation = false;
        throw StateError('lost native reservation reply');
      }
      return sequence;
    }
    commitRows.add(rows);
    commitBytes.add(
      ops.whereType<AppendLogOp>().fold<int>(
        0,
        (n, op) => n + op.payload.length,
      ),
    );
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
    }
    if (refuse) {
      refuse = false;
      throw StateError('native pre-commit refusal');
    }
    final sequence = await super.commit(ops);
    if (uncertain) {
      uncertain = false;
      throw StateError('lost native post-commit reply');
    }
    return sequence;
  }
}

void main() {
  final nativePath = Platform.environment['XVEIL_HV_DYLIB'];
  final enabled = nativePath?.isNotEmpty ?? false;
  final skip = enabled ? false : 'set XVEIL_HV_DYLIB to the qualified library';
  late Directory directory;
  late HiddenVolumeStorage storage;
  late _NativePostStore backing;
  late AsyncKvLogStore activeStore;
  const passwordText = 'native-positioned-fixture';
  final password = Uint8List.fromList(utf8.encode(passwordText));

  setUp(() async {
    if (!enabled) return;
    expect(ensureHiddenVolumeLoaded(dylibPath: nativePath), isTrue);
    directory = await Directory.systemTemp.createTemp(
      'xveil-native-positions-',
    );
    final path = '${directory.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      ),
    ).close();
    backing = _NativePostStore(
      (await workerSpaceOpener(path)(password: password, create: false))!,
    );
    activeStore = backing;
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    expect(await storage.open(password: passwordText), isTrue);
  });
  tearDown(() async {
    if (!enabled) return;
    if (!backing.release.isCompleted) backing.release.complete();
    if (!backing.reservationRelease.isCompleted) {
      backing.reservationRelease.complete();
    }
    await storage.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Message row(int seq) => Message(
    id: 'row-$seq',
    conversationId: 'peer',
    author: 'author',
    seq: seq,
    direction: MessageDirection.outgoing,
    body: 'native positioned message $seq',
    timestamp: DateTime.utc(2026, 1, 1),
    status: MessageStatus.delivered,
  );
  Future<List<String>> ids() async =>
      (await storage.loadMessages('peer')).map((m) => m.id).toList();
  Future<void> reopen() async {
    await storage.close();
    final open = workerSpaceOpener('${directory.path}/store.hv');
    storage = HiddenVolumeStorage.async(({
      required password,
      required create,
    }) async {
      final store = await open(password: password, create: create);
      if (store != null) activeStore = store;
      return store;
    });
    expect(await storage.open(password: passwordText), isTrue);
  }

  Future<int> reservedFloor() async {
    final raw = await activeStore.get(
      Ns.settings,
      Uint8List.fromList(utf8.encode('msg_next_id')),
    );
    expect(raw, isNotNull);
    return int.parse(utf8.decode(raw!));
  }

  Future<List<PreparedMessageWrite>?> fullBulk(int start) =>
      storage.appendMissingMessageBatch([
        for (var i = start; i < start + 64; i++) row(i),
      ], beforeCommit: () async {});

  test(
    'native full bulk amortizes durable reservations and resets on worker restart',
    () async {
      for (var start = 1; start <= 1024; start += 64) {
        expect(
          await fullBulk(start),
          List.filled(64, PreparedMessageWrite.appended),
        );
      }
      expect(backing.idReservations, lessThanOrEqualTo(6));
      expect(backing.commitRows, List.filled(16, 64));
      final records = await backing.inner.iterLogRange(
        namespace: Ns.messageLogShardFirst,
        limit: 2000,
      );
      final floor = await reservedFloor();
      expect(records, hasLength(1024));
      expect(floor - records.last.logId - 1, lessThanOrEqualTo(256));
      expect(records.every((r) => r.logId < floor), isTrue);
      await reopen();
      expect((await ids()).toSet(), {for (var i = 1; i <= 1024; i++) 'row-$i'});
      await storage.appendMessage(row(1025));
      expect(await reservedFloor() - floor, 8);
      final smallFloor = await reservedFloor();
      await reopen();
      await fullBulk(1026);
      expect(await reservedFloor() - smallFloor, 64);
      expect((await ids()).toSet(), {for (var i = 1; i <= 1089; i++) 'row-$i'});
    },
    skip: skip,
  );

  for (final uncertain in [false, true]) {
    test(
      'native grown reservation refuses publication until durable recovery ($uncertain)',
      () async {
        for (var start = 1; start <= 192; start += 64) {
          await fullBulk(start);
        }
        backing.holdReservation = true;
        backing.refuseReservation = !uncertain;
        backing.uncertainReservation = uncertain;
        final write = fullBulk(193);
        final failed = expectLater(write, throwsStateError);
        await backing.reservationEntered.future;
        expect(
          await backing.inner.iterLogRange(
            namespace: Ns.messageLogShardFirst,
            limit: 1000,
          ),
          hasLength(192),
        );
        backing.reservationRelease.complete();
        await failed;
        expect(
          await backing.inner.iterLogRange(
            namespace: Ns.messageLogShardFirst,
            limit: 1000,
          ),
          hasLength(192),
        );
        await storage.appendMessage(row(257));
        await fullBulk(193);
        final records = await backing.inner.iterLogRange(
          namespace: Ns.messageLogShardFirst,
          limit: 1000,
        );
        final floor = await reservedFloor();
        expect(records.map((r) => r.logId).toSet(), hasLength(257));
        expect(records.every((r) => r.logId < floor), isTrue);
        await reopen();
        expect((await ids()).toSet(), {
          for (var i = 1; i <= 257; i++) 'row-$i',
        });
        final sync = await storage.conversationSync('peer');
        expect(sync.highWater['author'], 257);
        expect(sync.holes, isEmpty);
      },
      skip: skip,
    );
  }

  test(
    'native sustained ID allocation persists across two worker restarts',
    () async {
      for (var i = 1; i <= 256; i++) {
        await storage.appendMessage(row(i));
      }
      expect(backing.idReservations, lessThanOrEqualTo(8));
      final records = await backing.inner.iterLogRange(
        namespace: Ns.messageLogShardFirst,
        limit: 1000,
      );
      final cursor = int.parse(
        utf8.decode(
          (await backing.inner.get(
            Ns.settings,
            Uint8List.fromList(utf8.encode('msg_next_id')),
          ))!,
        ),
      );
      expect(records, hasLength(256));
      expect(records.every((r) => r.logId < cursor), isTrue);
      for (var i = 257; i <= 258; i++) {
        await reopen();
        await storage.appendMessage(row(i));
        expect((await ids()).toSet(), {for (var n = 1; n <= i; n++) 'row-$n'});
      }
    },
    skip: skip,
  );

  MessageOrderingAdoption correction(int seq) => MessageOrderingAdoption(
    conversationId: 'peer',
    messageId: 'row-$seq',
    provisionalAuthor: 'author',
    provisionalSeq: seq,
    author: 'canonical',
    seq: seq + 1000,
  );

  test('native concurrent single ordering calls coalesce durably', () async {
    for (var i = 1; i <= 64; i++) {
      await storage.appendMessage(row(i));
    }
    backing.commitRows.clear();
    backing.commitBytes.clear();
    expect(
      await Future.wait([
        for (var i = 1; i <= 64; i++)
          storage.adoptMessageOrdering(
            'peer',
            'row-$i',
            provisionalAuthor: 'author',
            provisionalSeq: i,
            author: 'canonical',
            seq: i + 1000,
          ),
      ]),
      List.filled(64, true),
    );
    expect(backing.commitRows.length, lessThanOrEqualTo(8));
    expect(backing.commitRows.every((count) => count <= 16), true);
    expect(backing.commitRows.fold<int>(0, (n, count) => n + count), 64);
    expect(backing.commitBytes.every((bytes) => bytes <= 1800), true);
    await reopen();
    final held = await storage.loadMessages('peer');
    expect(
      held.map(
        (m) => (
          m.id,
          m.body,
          m.status,
          m.author,
          m.seq,
          m.orderAuthor,
          m.orderSeq,
        ),
      ),
      [
        for (var i = 1; i <= 64; i++)
          (
            'row-$i',
            row(i).body,
            MessageStatus.delivered,
            'author',
            i,
            'canonical',
            i + 1000,
          ),
      ],
    );
    expect(await storage.loadEventsSince('peer', 'canonical', 0), isEmpty);
  }, skip: skip);

  test('native same-image A/B/A ordering commit census', () async {
    await Future.wait([
      for (var i = 1; i <= 64; i++) storage.appendMessage(row(i)),
    ]);
    await storage.close();
    final seed = await File('${directory.path}/store.hv').readAsBytes();
    final phases = <Map<String, Object>>[];
    final requests = [for (var i = 1; i <= 64; i++) correction(i)];
    for (var phase = 0; phase < 3; phase++) {
      final path = '${directory.path}/ordering-phase-$phase.hv';
      await File(path).writeAsBytes(seed, flush: true);
      expect(await File(path).readAsBytes(), seed);
      backing = _NativePostStore(
        (await workerSpaceOpener(path)(password: password, create: false))!,
      );
      storage = HiddenVolumeStorage.async(
        ({required password, required create}) async => backing,
      );
      expect(await storage.open(password: passwordText), isTrue);
      final watch = Stopwatch()..start();
      if (phase == 1) {
        for (var i = 0; i < 64; i += 16) {
          expect(
            await storage.adoptMessageOrderingBatch(
              requests.sublist(i, i + 16),
              beforeCommit: () async {},
            ),
            List.filled(16, true),
          );
        }
      } else {
        for (final r in requests) {
          expect(
            await storage.adoptMessageOrdering(
              r.conversationId,
              r.messageId,
              provisionalAuthor: r.provisionalAuthor,
              provisionalSeq: r.provisionalSeq,
              author: r.author,
              seq: r.seq,
            ),
            isTrue,
          );
        }
      }
      watch.stop();
      final held = await storage.loadMessages('peer');
      expect(
        held.map((m) => (m.id, m.author, m.seq, m.orderAuthor, m.orderSeq)),
        [
          for (var i = 1; i <= 64; i++)
            ('row-$i', 'author', i, 'canonical', i + 1000),
        ],
      );
      expect(held.map((m) => m.body), [
        for (var i = 1; i <= 64; i++) row(i).body,
      ]);
      expect(await storage.loadEventsSince('peer', 'canonical', 0), isEmpty);
      expect(backing.commitRows.length, phase == 1 ? 4 : 64);
      expect(backing.commitRows.fold<int>(0, (a, b) => a + b), 64);
      phases.add({
        'mode': phase == 1 ? 'batch' : 'single',
        'rows': 64,
        'postCommits': backing.commitRows.length,
        'elapsedUs': watch.elapsedMicroseconds,
      });
      await storage.close();
    }
    final result = Platform.environment['XVEIL_NATIVE_ORDERING_RESULT'];
    if (result != null) {
      await File(result).writeAsString(
        jsonEncode({
          'schema': 'xveil-native-ordering-control/1',
          'sameSeedImage': true,
          'identicalLogicalOutcome': true,
          'phases': phases,
        }),
      );
    }
  }, skip: skip);

  test(
    'native ordering cohort preserves bodies raw positions and durable canonical order',
    () async {
      await Future.wait([
        for (var i = 1; i <= 64; i++) storage.appendMessage(row(i)),
      ]);
      backing.commitRows.clear();
      final requests = [for (var i = 1; i <= 64; i++) correction(i)];
      expect(
        await storage.adoptMessageOrderingBatch(
          requests,
          beforeCommit: () async {},
        ),
        List.filled(64, true),
      );
      expect(backing.commitRows, [64]);
      await reopen();
      final held = await storage.loadMessages('peer');
      expect(
        held.map((m) => (m.id, m.author, m.seq, m.orderAuthor, m.orderSeq)),
        [
          for (var i = 1; i <= 64; i++)
            ('row-$i', 'author', i, 'canonical', i + 1000),
        ],
      );
      expect(held.map((m) => m.body), [
        for (var i = 1; i <= 64; i++) row(i).body,
      ]);
      expect(held.every((m) => m.status == MessageStatus.delivered), isTrue);
      expect(await storage.loadEventsSince('peer', 'canonical', 0), isEmpty);
      expect(
        await storage.adoptMessageOrderingBatch(
          requests,
          beforeCommit: () async {},
        ),
        List.filled(64, false),
      );
    },
    skip: skip,
  );

  for (final uncertain in [false, true]) {
    test(
      'native ordering cohort recovers atomic failure ($uncertain)',
      () async {
        await Future.wait([
          storage.appendMessage(row(1)),
          storage.appendMessage(row(2)),
        ]);
        backing.uncertain = uncertain;
        backing.refuse = !uncertain;
        final requests = [correction(1), correction(2)];
        await expectLater(
          storage.adoptMessageOrderingBatch(
            requests,
            beforeCommit: () async {},
          ),
          throwsStateError,
        );
        await reopen();
        expect(
          await storage.adoptMessageOrderingBatch(
            requests,
            beforeCommit: () async {},
          ),
          List.filled(2, !uncertain),
        );
        final held = await storage.loadMessages('peer');
        expect(held.map((m) => m.orderSeq), [1001, 1002]);
        expect(held.map((m) => m.seq), [1, 2]);
      },
      skip: skip,
    );
  }

  for (final count in [64, 128, 256]) {
  test(
    'native prepared cohort ($count) publishes one durable transaction and deduplicates retry',
    () async {
      final rows = [for (var i = 1; i <= count; i++) row(i)];
      backing.hold = true;
      var completed = false;
      final publication = storage
          .appendMissingMessageBatch(rows, beforeCommit: () async {})
          .then((value) {
            completed = true;
            return value;
          });
      await backing.entered.future;
      try {
        expect(completed, isFalse, reason: 'no success before durable commit');
        expect(
          await backing.inner.iterLogRange(
            namespace: Ns.messageLogShardFirst,
            limit: 100,
          ),
          isEmpty,
        );
      } finally {
        backing.release.complete();
      }
      expect(await publication, List.filled(count, PreparedMessageWrite.appended));
      expect(backing.commitBytes.single, lessThanOrEqualTo(64 * 1800));
      expect(backing.commitRows, [count]);
      await reopen();
      expect(
        await storage.appendMissingMessageBatch(
          rows,
          beforeCommit: () async {},
        ),
        List.filled(count, PreparedMessageWrite.existing),
      );
      expect(await ids(), [for (var i = 1; i <= count; i++) 'row-$i']);
    },
    skip: skip,
  );

  for (final uncertain in [false, true]) {
    test(
      'native prepared cohort ($count) retries failure without duplicate posts ($uncertain)',
      () async {
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        final rows = [for (var i = 1; i <= count; i++) row(i)];
        await expectLater(
          storage.appendMissingMessageBatch(rows, beforeCommit: () async {}),
          throwsStateError,
        );
        await reopen();
        expect(
          await storage.appendMissingMessageBatch(
            rows,
            beforeCommit: () async {},
          ),
          List.filled(
            count,
            uncertain
                ? PreparedMessageWrite.existing
                : PreparedMessageWrite.appended,
          ),
        );
        expect(await ids(), [for (var i = 1; i <= count; i++) 'row-$i']);
        final sync = await storage.conversationSync('peer');
        expect(sync.highWater['author'], count);
        expect(sync.holes, isEmpty);
      },
      skip: skip,
    );
  }

  }

  test(
    'native positioned burst preserves ID order status and high-water',
    () async {
      final clock = Stopwatch()..start();
      final saved = await Future.wait([
        for (var i = 1; i <= 128; i++) storage.appendMessage(row(i)),
      ]);
      clock.stop();
      final expected = [for (var i = 1; i <= 128; i++) 'row-$i'];
      expect(saved.map((m) => m.seq), [for (var i = 1; i <= 128; i++) i]);
      expect(await ids(), expected);
      expect(backing.commitRows.fold<int>(0, (a, b) => a + b), 128);
      await reopen();
      expect(await ids(), expected);
      expect(
        (await storage.loadMessages(
          'peer',
        )).every((m) => m.status == MessageStatus.delivered),
        isTrue,
      );
      final sync = await storage.conversationSync('peer');
      expect(sync.highWater['author'], 128);
      expect(sync.holes, isEmpty);
      final result = {
        'schema': 'xveil-native-positioned-append/1',
        'rows': 128,
        'dataCommits': backing.commitRows.length,
        'rowsPerCommit': backing.commitRows,
        'appendUs': clock.elapsedMicroseconds,
        'reopenedIdsOrderStatusAndHighWaterMatch': true,
      };
      final path = Platform.environment['XVEIL_NATIVE_MESSAGE_RESULT'];
      if (path != null) await File(path).writeAsString(jsonEncode(result));
    },
    skip: skip,
  );

  for (final uncertain in [false, true]) {
    test('native positioned batch recovers failure ($uncertain)', () async {
      backing.uncertain = uncertain;
      backing.refuse = !uncertain;
      final first = storage.appendMessage(row(1));
      final second = storage.appendMessage(row(2));
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(backing.commitRows, [2]);
      final expected = uncertain ? ['row-1', 'row-2'] : <String>[];
      expect(await ids(), expected);
      await reopen();
      expect(await ids(), expected);
    }, skip: skip);
  }

  for (final erase in [false, true]) {
    test(
      'native positioned batches drain before maintenance ($erase)',
      () async {
        backing.hold = true;
        final first = storage.appendMessage(row(1));
        await backing.entered.future;
        final accepted = [
          storage.appendMessage(row(2)),
          storage.appendMessage(row(3)),
        ];
        final maintenance = erase ? storage.eraseSpace() : storage.close();
        final refused = expectLater(
          storage.appendMessage(row(4)),
          throwsStateError,
        );
        backing.release.complete();
        await Future.wait([first, ...accepted, maintenance, refused]);
        await reopen();
        expect(await ids(), erase ? isEmpty : ['row-1', 'row-2', 'row-3']);
      },
      skip: skip,
    );
  }

  test(
    'native full prepared page atomically publishes both crossing shard markers',
    () async {
      await backing.commit([
        PutOp(
          Ns.settings,
          Uint8List.fromList(utf8.encode('msg_next_id')),
          Uint8List.fromList(utf8.encode('8191')),
        ),
      ]);
      final rows = [
        for (var i = 1; i <= 64; i++) row(i).copyWith(body: 'x' * 1400),
      ];
      expect(
        await storage.appendMissingMessageBatch(
          rows,
          beforeCommit: () async {},
        ),
        List.filled(64, PreparedMessageWrite.appended),
      );
      expect(backing.commitRows, [64]);
      expect(backing.commitBytes.single, lessThanOrEqualTo(64 * 1800));
      await reopen();
      expect(await ids(), [for (var i = 1; i <= 64; i++) 'row-$i']);
      expect(
        (await storage.loadMessages('peer')).map((m) => m.body),
        List.filled(64, 'x' * 1400),
      );
      final sync = await storage.conversationSync('peer');
      expect(sync.highWater['author'], 64);
      expect(sync.holes, isEmpty);
    },
    skip: skip,
  );

  test(
    'native positioned batch publishes both crossing shard markers',
    () async {
      await backing.commit([
        PutOp(
          Ns.settings,
          Uint8List.fromList(utf8.encode('msg_next_id')),
          Uint8List.fromList(utf8.encode('8191')),
        ),
      ]);
      await Future.wait([
        for (var i = 1; i <= 4; i++) storage.appendMessage(row(i)),
      ]);
      expect(backing.commitRows, [4]);
      await reopen();
      expect(await ids(), ['row-1', 'row-2', 'row-3', 'row-4']);
    },
    skip: skip,
  );
}
