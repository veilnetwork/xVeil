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
