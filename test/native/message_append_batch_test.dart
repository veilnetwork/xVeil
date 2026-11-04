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
  bool hold = false, refuse = false, uncertain = false;
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final rows = ops
        .whereType<AppendLogOp>()
        .where(
          (op) =>
              op.namespace >= Ns.messageLogShardFirst &&
              op.namespace <= Ns.messageLogShardLast,
        )
        .length;
    if (rows == 0) return super.commit(ops);
    commitRows.add(rows);
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
    storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => backing,
    );
    expect(await storage.open(password: passwordText), isTrue);
  });
  tearDown(() async {
    if (!enabled) return;
    if (!backing.release.isCompleted) backing.release.complete();
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
    storage = HiddenVolumeStorage.async(
      workerSpaceOpener('${directory.path}/store.hv'),
    );
    expect(await storage.open(password: passwordText), isTrue);
  }

  MessageOrderingAdoption correction(int seq) => MessageOrderingAdoption(
    conversationId: 'peer',
    messageId: 'row-$seq',
    provisionalAuthor: 'author',
    provisionalSeq: seq,
    author: 'canonical',
    seq: seq + 1000,
  );

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
        for (var i = 1; i <= 16; i++) storage.appendMessage(row(i)),
      ]);
      backing.commitRows.clear();
      final requests = [for (var i = 1; i <= 16; i++) correction(i)];
      expect(
        await storage.adoptMessageOrderingBatch(
          requests,
          beforeCommit: () async {},
        ),
        List.filled(16, true),
      );
      expect(backing.commitRows, [16]);
      await reopen();
      final held = await storage.loadMessages('peer');
      expect(
        held.map((m) => (m.id, m.author, m.seq, m.orderAuthor, m.orderSeq)),
        [
          for (var i = 1; i <= 16; i++)
            ('row-$i', 'author', i, 'canonical', i + 1000),
        ],
      );
      expect(held.map((m) => m.body), [
        for (var i = 1; i <= 16; i++) row(i).body,
      ]);
      expect(held.every((m) => m.status == MessageStatus.delivered), isTrue);
      expect(await storage.loadEventsSince('peer', 'canonical', 0), isEmpty);
      expect(
        await storage.adoptMessageOrderingBatch(
          requests,
          beforeCommit: () async {},
        ),
        List.filled(16, false),
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

  test(
    'native prepared cohort publishes one durable transaction and deduplicates retry',
    () async {
      final rows = [for (var i = 1; i <= 16; i++) row(i)];
      expect(
        await storage.appendMissingMessageBatch(
          rows,
          beforeCommit: () async {},
        ),
        List.filled(16, PreparedMessageWrite.appended),
      );
      expect(backing.commitRows, [16]);
      await reopen();
      expect(
        await storage.appendMissingMessageBatch(
          rows,
          beforeCommit: () async {},
        ),
        List.filled(16, PreparedMessageWrite.existing),
      );
      expect(await ids(), [for (var i = 1; i <= 16; i++) 'row-$i']);
    },
    skip: skip,
  );

  for (final uncertain in [false, true]) {
    test(
      'native prepared cohort retries failure without duplicate posts ($uncertain)',
      () async {
        backing.refuse = !uncertain;
        backing.uncertain = uncertain;
        final rows = [row(1), row(2)];
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
            2,
            uncertain
                ? PreparedMessageWrite.existing
                : PreparedMessageWrite.appended,
          ),
        );
        expect(await ids(), ['row-1', 'row-2']);
        final sync = await storage.conversationSync('peer');
        expect(sync.highWater['author'], 2);
        expect(sync.holes, isEmpty);
      },
      skip: skip,
    );
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
